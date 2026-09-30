import Foundation
import Observation
@preconcurrency import UserNotifications

@MainActor
@Observable
final class AlertCenter {
    static let inboxLimit = 500

    struct Snapshot: Codable, Sendable {
        var events: [AlertEvent] = []
        var rules: [NotificationRule] = []
        var lastHealth: [String: Int] = [:]
        var ntfy: NtfyConfiguration?
        var quietHours: QuietHours?
    }

    private(set) var events: [AlertEvent] = []
    private(set) var rules: [NotificationRule] = []
    private(set) var ntfy: NtfyConfiguration?
    private(set) var quietHours: QuietHours?
    private(set) var lastDeliveryError: String?
    private var lastHealth: [String: Health] = [:]
    private let file: JSONFile<Snapshot>
    private let keychain: KeychainStore
    private let notifier: LocalNotifier

    static let ntfyTokenAccount = "alerts.ntfy.token"

    init(file: JSONFile<Snapshot>, keychain: KeychainStore, notifier: LocalNotifier = .system) {
        self.file = file
        self.keychain = keychain
        self.notifier = notifier
        if let snapshot = try? file.load() {
            events = snapshot.events
            rules = snapshot.rules
            ntfy = snapshot.ntfy
            quietHours = snapshot.quietHours
            lastHealth = snapshot.lastHealth.compactMapValues(Health.init(rawValue:))
        }
    }

    var unreadCount: Int { events.filter { !$0.isRead && !$0.isRecovery }.count }

    private static func key(_ kind: AlertSourceKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    /// Records health changes and delivers matching events. Returns the new events.
    @discardableResult
    func observe(_ observations: [HealthObservation]) async -> [AlertEvent] {
        var produced: [AlertEvent] = []
        for observation in observations {
            let key = Self.key(observation.sourceKind, observation.sourceID)
            if let event = AlertTransition.event(previous: lastHealth[key], observation: observation) {
                produced.append(event)
            }
            if observation.health != .unknown { lastHealth[key] = observation.health }
        }
        await record(produced, forwardable: true)
        return produced
    }

    func pollNtfy() async {
        guard let configuration = ntfy, configuration.subscribe else { return }
        do {
            let messages = try await NtfyClient(configuration: configuration, token: try keychain.string(for: Self.ntfyTokenAccount)).poll(since: configuration.lastMessageID)
            guard let last = messages.last else { return }
            ntfy?.lastMessageID = last.id
            let incoming = messages.map {
                AlertEvent(
                    date: Date(timeIntervalSince1970: TimeInterval($0.time)),
                    severity: $0.severity,
                    sourceKind: .ntfy,
                    sourceID: configuration.topic,
                    sourceName: "ntfy · \(configuration.topic)",
                    title: $0.title ?? "ntfy · \(configuration.topic)",
                    body: $0.message ?? ""
                )
            }
            await record(incoming, forwardable: false)
            lastDeliveryError = nil
        } catch {
            lastDeliveryError = "ntfy: \(NetworkError.from(error).errorDescription ?? "unavailable")"
            persist()
        }
    }

    private func record(_ new: [AlertEvent], forwardable: Bool) async {
        guard !new.isEmpty else {
            persist()
            return
        }
        events.insert(contentsOf: new.sorted { $0.date > $1.date }, at: 0)
        if events.count > Self.inboxLimit { events.removeLast(events.count - Self.inboxLimit) }
        persist()
        for event in new {
            let matching = rules.filter { $0.matches(event) }
            if matching.contains(where: \.notifyOnDevice), quietHours?.silences(event) != true {
                await notifier.deliver(event)
            }
            if forwardable, matching.contains(where: \.forwardToNtfy), let configuration = ntfy {
                do {
                    try await NtfyClient(configuration: configuration, token: try keychain.string(for: Self.ntfyTokenAccount)).publish(event)
                } catch {
                    lastDeliveryError = "ntfy: \(NetworkError.from(error).errorDescription ?? "publish failed")"
                }
            }
        }
    }

    func markAllRead() {
        for index in events.indices { events[index].isRead = true }
        persist()
    }

    func markRead(_ event: AlertEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index].isRead = true
        persist()
    }

    func clear() {
        events.removeAll()
        persist()
    }

    func save(_ rule: NotificationRule) async {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        persist()
        if rule.notifyOnDevice && rule.isEnabled {
            await notifier.requestAuthorization()
        }
    }

    func delete(_ rule: NotificationRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    func configureNtfy(_ configuration: NtfyConfiguration?, token: String?) throws {
        if let token { try keychain.set(token, for: Self.ntfyTokenAccount) }
        if configuration == nil { try keychain.delete(Self.ntfyTokenAccount) }
        ntfy = configuration
        persist()
    }

    func setQuietHours(_ hours: QuietHours?) {
        quietHours = hours
        persist()
    }

    /// Delivers a sample alert through the same path as real ones, without adding it to the inbox.
    func sendTestNotification() async {
        await notifier.requestAuthorization()
        await notifier.deliver(Self.testEvent)
    }

    static var testEvent: AlertEvent {
        AlertEvent(date: .now, severity: .warning, sourceKind: .serviceCheck, sourceID: "test", sourceName: "Petty: Homelab",
                   title: "Test alert from Petty: Homelab", body: "If you can read this, alerts reach you here.")
    }

    func hasNtfyToken() -> Bool {
        (try? keychain.data(for: Self.ntfyTokenAccount)) != nil
    }

    func ntfyToken() -> String? {
        try? keychain.string(for: Self.ntfyTokenAccount)
    }

    private func persist() {
        try? file.save(Snapshot(events: events, rules: rules, lastHealth: lastHealth.mapValues(\.rawValue), ntfy: ntfy, quietHours: quietHours))
    }
}

/// Posts local notifications; the only delivery path that needs no server at all.
struct LocalNotifier: Sendable {
    let post: @Sendable (AlertEvent) async -> Void
    let authorize: @Sendable () async -> Void

    func deliver(_ event: AlertEvent) async { await post(event) }
    func requestAuthorization() async { await authorize() }

    static let system = LocalNotifier(
        post: { event in
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.threadIdentifier = "\(event.sourceKind.rawValue):\(event.sourceID)"
            content.sound = .default
            let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        },
        authorize: {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    )

    static let silent = LocalNotifier(post: { _ in }, authorize: {})
}
