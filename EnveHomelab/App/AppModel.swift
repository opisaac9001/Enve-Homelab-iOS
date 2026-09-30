import Foundation
import Network
import Observation
import UserNotifications
import WidgetKit

struct ServerContext: Sendable {
    let service: any UnraidService
    let profileID: UUID?
    let serverName: String
    let endpoint: ServerEndpoint?
    let isPreview: Bool
}

@MainActor
@Observable
final class AppModel {
    let store: ServerStore
    let serviceChecks: ServiceCheckStore
    let serviceHealth: ServiceHealthMonitor
    let ssh: SSHStore
    let integrations: IntegrationStore
    let integrationStatus: IntegrationStatusBoard
    let alerts: AlertCenter
    let profiles: ProfileStore
    let preferences: HomePreferences
    let diskHistory: DiskHistoryStore
    /// Preview-mode readings stay in memory so the sample server never writes history to disk.
    let previewDiskHistory = DiskHistoryStore(file: nil)
    private(set) var session: ServerSession?
    var deepLink: DeepLink?
    /// While offline nothing is refreshed, so last-known data stays on screen and no false alerts are raised.
    private(set) var isOffline = false {
        didSet {
            guard oldValue, !isOffline else { return }
            Task { await refreshIntegrations() }
        }
    }
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Set once everything is erased; the app then starts over with a fresh model.
    private(set) var isErased = false
    private let directory: URL
    private let keychain: KeychainStore
    private var sampleClients: [IntegrationKind: IntegrationClient] = [:]

    var showsSampleIntegrations: Bool {
        didSet { UserDefaults.standard.set(showsSampleIntegrations, forKey: Self.sampleIntegrationsKey) }
    }

    private static let sampleIntegrationsKey = "envehomelab.showsSampleIntegrations"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var directory = URL.applicationSupportDirectory
        var keychain = KeychainStore.shared
        #if DEBUG
        // UI tests start from empty, throwaway storage so runs never touch real servers or credentials.
        if arguments.contains("-isolatedStorage") {
            let run = UUID().uuidString
            directory = FileManager.default.temporaryDirectory.appending(path: "EnveHomelab-\(run)")
            keychain = KeychainStore(service: "\(KeychainStore.shared.service).isolated.\(run)")
        }
        #endif
        self.directory = directory
        self.keychain = keychain
        store = ServerStore(file: JSONFile(url: directory.appending(path: "servers.json")), keychain: keychain)
        serviceChecks = ServiceCheckStore(file: JSONFile(url: directory.appending(path: "service-checks.json")))
        ssh = SSHStore(fileURL: directory.appending(path: "ssh.json"), keychain: keychain)
        integrations = IntegrationStore(file: JSONFile(url: directory.appending(path: "integrations.json")), keychain: keychain)
        serviceHealth = ServiceHealthMonitor(file: JSONFile(url: directory.appending(path: "service-history.json")))
        integrationStatus = IntegrationStatusBoard(file: JSONFile(url: directory.appending(path: "integration-status.json")))
        alerts = AlertCenter(file: JSONFile(url: directory.appending(path: "alerts.json")), keychain: keychain)
        profiles = ProfileStore(file: JSONFile(url: directory.appending(path: "profiles.json")))
        preferences = HomePreferences(file: JSONFile(url: directory.appending(path: "preferences.json")))
        diskHistory = DiskHistoryStore(file: JSONFile(url: directory.appending(path: "disk-history.json")))
        showsSampleIntegrations = arguments.contains("-sampleIntegrations") || UserDefaults.standard.bool(forKey: Self.sampleIntegrationsKey)
        serviceHealth.observe = { [weak self] observations in await self?.handle(observations) }
        integrationStatus.observe = { [weak self] observations in await self?.handle(observations) }
        if arguments.contains("-previewMode") {
            openPreview()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        pathMonitor.start(queue: DispatchQueue(label: "EnveHomelab.path"))
    }

    func open(_ profile: ServerProfile) {
        let session = ServerSession(profile: profile)
        self.session = session
        Task { await session.connect(using: store) }
    }

    func openPreview() {
        session = ServerSession(previewService: UnraidPreviewService())
    }

    func close() {
        session = nil
    }

    /// What the active profile may see; everything for Owners. Credentials stay on the device either way.
    var visibleIntegrations: [IntegrationInstance] { integrations.instances.filter { profiles.active.shows($0.id) } }
    var visibleSampleInstances: [IntegrationInstance] { sampleInstances.filter { profiles.active.shows($0.id) } }
    var visibleChecks: [ServiceCheck] { serviceChecks.checks.filter { profiles.active.shows($0.id) } }
    var visibleServers: [ServerProfile] { profiles.active.seesServers ? store.profiles : [] }
    var visibleSSHHosts: [SSHHost] { profiles.active.seesServers ? ssh.hosts : [] }

    /// Alerts about integrations or checks this profile can't see are left out of its inbox and badges.
    func isVisible(_ event: AlertEvent) -> Bool {
        switch event.sourceKind {
        case .integration, .serviceCheck: UUID(uuidString: event.sourceID).map(profiles.active.shows) ?? true
        case .ntfy: true
        }
    }

    var visibleUnreadAlerts: Int { alerts.events.filter { !$0.isRead && isVisible($0) }.count }

    func isVisible(_ link: DeepLink) -> Bool {
        switch link {
        case .alerts, .upcoming, .statistics: true
        case .integration(let id), .serviceCheck(let id): profiles.active.shows(id)
        }
    }

    var sampleInstances: [IntegrationInstance] {
        showsSampleIntegrations ? IntegrationKind.allCases.map(IntegrationConnector.sampleInstance(for:)) : []
    }

    func integrationInstance(id: UUID) -> IntegrationInstance? {
        integrations.instance(id: id) ?? sampleInstances.first { $0.id == id }
    }

    /// Sample clients are cached so their in-memory state survives navigation.
    func client(for instance: IntegrationInstance) throws -> IntegrationClient {
        if instance.isSample {
            if let cached = sampleClients[instance.kind] { return cached }
            let client = IntegrationConnector.sample(for: instance.kind)
            sampleClients[instance.kind] = client
            return client
        }
        return try IntegrationConnector.client(for: instance, secret: try integrations.secret(for: instance))
    }

    @ObservationIgnored private var lastWidgetSnapshot: WidgetSnapshot?

    private func handle(_ observations: [HealthObservation]) async {
        await alerts.observe(observations)
        publishWidgetSnapshot()
    }

    /// Writes last-known health for the widgets; timelines reload only when the content changes.
    func publishWidgetSnapshot() {
        var items: [WidgetSnapshot.Item] = visibleChecks.compactMap { check in
            serviceHealth.latest(for: check.id).map { result in
                WidgetSnapshot.Item(id: check.id.uuidString, kind: "check", name: check.name, detail: result.summary, level: Self.level(result.health()))
            }
        }
        items += visibleIntegrations.filter(\.isEnabled).compactMap { instance in
            let state = integrationStatus.state(for: instance.id)
            if let summary = state.value {
                return WidgetSnapshot.Item(id: instance.id.uuidString, kind: "integration", name: instance.name, detail: summary.headline, level: Self.level(summary.health))
            }
            if let error = state.error, !error.isCancellation {
                return WidgetSnapshot.Item(id: instance.id.uuidString, kind: "integration", name: instance.name, detail: error.errorDescription ?? "Unavailable", level: .critical)
            }
            return nil
        }
        let snapshot = WidgetSnapshot(updatedAt: .now, items: items, unreadAlerts: visibleUnreadAlerts)
        let changed = lastWidgetSnapshot.map { $0.items != snapshot.items || $0.unreadAlerts != snapshot.unreadAlerts } ?? true
        lastWidgetSnapshot = snapshot
        try? snapshot.save()
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    private static func level(_ health: Health) -> WidgetSnapshot.Item.Level {
        switch health {
        case .ok: .ok
        case .unknown: .unknown
        case .warning: .warning
        case .critical: .critical
        }
    }

    static let storedFileNames = ["servers", "service-checks", "ssh", "integrations", "service-history", "integration-status", "alerts", "profiles", "preferences", "disk-history"]

    /// Removes every credential, saved file, widget copy and delivered notification. Theme choice is kept.
    func eraseAllData() throws {
        try keychain.deleteAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Also catches damaged copies set aside as name.damaged-<date>.json.
        for file in files where Self.storedFileNames.contains(where: { file.lastPathComponent.hasPrefix("\($0).") }) {
            try FileManager.default.removeItem(at: file)
        }
        if let widgetFile = WidgetSnapshot.fileURL, FileManager.default.fileExists(atPath: widgetFile.path()) {
            try FileManager.default.removeItem(at: widgetFile)
        }
        WidgetCenter.shared.reloadAllTimelines()
        UserDefaults.standard.removeObject(forKey: Self.sampleIntegrationsKey)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        pathMonitor.cancel()
        isErased = true
    }

    nonisolated static let refreshTaskIdentifier = "com.isaaclamb.EnveHomelab.refresh"

    /// One pass over every enabled check, integration and ntfy topic; used by the background refresh task.
    func refreshEverything() async {
        guard !isOffline else { return }
        await serviceHealth.probe(serviceChecks.checks, allChecks: serviceChecks.checks, servers: store.profiles)
        await withTaskGroup(of: Void.self) { group in
            for instance in integrations.instances where instance.isEnabled {
                group.addTask { await self.integrationStatus.refresh(instance, using: self, force: true) }
            }
        }
        await alerts.pollNtfy()
    }

    func runServiceHealth() async {
        await serviceHealth.run(checks: { [weak self] in self.map { $0.isOffline || $0.isErased ? [] : $0.serviceChecks.checks } ?? [] }, servers: { [store] in store.profiles })
    }

    private func refreshIntegrations() async {
        await withTaskGroup(of: Void.self) { group in
            for instance in integrations.instances where instance.isEnabled {
                group.addTask { await self.integrationStatus.refresh(instance, using: self) }
            }
        }
    }
}

@MainActor
@Observable
final class ServerSession {
    enum Phase {
        case connecting
        case connected(ServerContext)
        case failed(ConnectionFailure)
    }

    private(set) var profile: ServerProfile?
    private(set) var phase: Phase

    var isPreview: Bool { profile == nil }

    var displayName: String {
        switch phase {
        case .connected(let context): context.serverName
        default: profile?.name ?? UnraidPreviewService.serverName
        }
    }

    init(profile: ServerProfile) {
        self.profile = profile
        phase = .connecting
    }

    init(previewService: UnraidPreviewService) {
        profile = nil
        phase = .connected(ServerContext(
            service: previewService,
            profileID: nil,
            serverName: UnraidPreviewService.serverName,
            endpoint: nil,
            isPreview: true
        ))
    }

    func connect(using store: ServerStore) async {
        guard let profile else { return }
        phase = .connecting
        let apiKey: String
        do {
            guard let key = try store.apiKey(for: profile), !key.isEmpty else {
                phase = .failed(ConnectionFailure(endpoint: nil, error: .missingCredentials))
                return
            }
            apiKey = key
        } catch {
            phase = .failed(ConnectionFailure(endpoint: nil, error: .unexpectedResponse(error.localizedDescription)))
            return
        }

        switch await UnraidConnector.connect(profile: profile, apiKey: apiKey) {
        case .success(let connection):
            phase = .connected(ServerContext(
                service: connection.client,
                profileID: profile.id,
                serverName: profile.name.isEmpty ? connection.identity.name : profile.name,
                endpoint: connection.endpoint,
                isPreview: false
            ))
        case .failure(let failure):
            phase = .failed(failure)
        }
    }

    func trust(_ certificate: CertificateSummary, endpointID: UUID, store: ServerStore) async throws {
        guard var profile else { return }
        profile.trust(certificate, for: endpointID)
        try store.save(profile, apiKey: nil)
        self.profile = profile
        await connect(using: store)
    }

    func reload(from store: ServerStore) async {
        guard let id = profile?.id, let updated = store.profile(id: id) else { return }
        profile = updated
        await connect(using: store)
    }
}
