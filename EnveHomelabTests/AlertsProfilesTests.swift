import Foundation
import os
import Testing
@testable import EnveHomelab

private func observation(_ health: Health, id: String = "a", kind: AlertSourceKind = .serviceCheck) -> HealthObservation {
    HealthObservation(sourceKind: kind, sourceID: id, sourceName: "Plex", health: health, detail: "detail")
}

struct AlertTransitionTests {
    @Test func onlyChangesProduceEvents() {
        #expect(AlertTransition.event(previous: nil, observation: observation(.ok)) == nil, "A first healthy reading is not news")
        #expect(AlertTransition.event(previous: nil, observation: observation(.warning))?.severity == .warning)
        #expect(AlertTransition.event(previous: .warning, observation: observation(.warning)) == nil, "No repeats while unchanged")
        #expect(AlertTransition.event(previous: .warning, observation: observation(.critical))?.severity == .critical, "Worsening alerts again")
        #expect(AlertTransition.event(previous: .critical, observation: observation(.warning)) == nil, "Partial improvement is quiet")
        let recovery = AlertTransition.event(previous: .critical, observation: observation(.ok))
        #expect(recovery?.isRecovery == true && recovery?.severity == .info)
        #expect(AlertTransition.event(previous: .critical, observation: observation(.unknown)) == nil, "Unknown never alerts")
        #expect(AlertTransition.event(previous: .ok, observation: observation(.ok)) == nil)
    }

    @Test func ruleMatching() {
        let critical = AlertTransition.event(previous: .ok, observation: observation(.critical, id: "plex"))!
        let warning = AlertTransition.event(previous: .ok, observation: observation(.warning, id: "plex"))!
        let recovery = AlertTransition.event(previous: .critical, observation: observation(.ok, id: "plex"))!
        var rule = NotificationRule(name: "r", sourceKind: .serviceCheck, minimumSeverity: .critical)
        #expect(rule.matches(critical) && !rule.matches(warning) && rule.matches(recovery))
        rule.includeRecoveries = false
        #expect(!rule.matches(recovery))
        rule.sourceID = "other"
        #expect(!rule.matches(critical))
        rule.sourceID = nil
        rule.sourceKind = .integration
        #expect(!rule.matches(critical))
        rule.sourceKind = .serviceCheck
        rule.isEnabled = false
        #expect(!rule.matches(critical))
    }

    @Test func ntfyParsingAndTopics() {
        let data = Data("""
        {"id":"o","time":1,"event":"open","topic":"t"}
        {"id":"m","time":2,"event":"message","topic":"t","message":"hi","priority":4}
        not json
        """.utf8)
        let messages = NtfyClient.parse(data)
        #expect(messages.map(\.id) == ["m"] && messages[0].severity == .warning)
        #expect(NtfyConfiguration.isValidTopic("homelab-alerts_1"))
        #expect(!NtfyConfiguration.isValidTopic("has space") && !NtfyConfiguration.isValidTopic("") && !NtfyConfiguration.isValidTopic("ünïcode"))
    }
}

@MainActor
struct AlertCenterTests {
    private func makeCenter(delivered: OSAllocatedUnfairLock<[String]>) -> (AlertCenter, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "alerts-\(UUID().uuidString).json")
        let notifier = LocalNotifier(post: { event in delivered.withLock { $0.append(event.title) } }, authorize: {})
        let center = AlertCenter(file: JSONFile(url: url), keychain: KeychainStore(service: "tests.\(UUID().uuidString)"), notifier: notifier)
        return (center, url)
    }

    @Test func inboxDedupesAndRulesDeliver() async throws {
        let delivered = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (center, url) = makeCenter(delivered: delivered)
        defer { try? FileManager.default.removeItem(at: url) }
        await center.save(NotificationRule(name: "all", sourceKind: .serviceCheck, minimumSeverity: .warning, includeRecoveries: false))

        await center.observe([observation(.ok)])
        await center.observe([observation(.critical)])
        await center.observe([observation(.critical)])
        await center.observe([observation(.ok)])
        #expect(center.events.count == 2, "One alert and one recovery")
        #expect(center.unreadCount == 1)
        #expect(delivered.withLock { $0 } == ["Plex: critical"], "Recoveries excluded by the rule aren't delivered")

        let reloaded = AlertCenter(file: JSONFile(url: url), keychain: KeychainStore(service: "tests.\(UUID().uuidString)"), notifier: .silent)
        #expect(reloaded.events.count == 2)
        await reloaded.observe([observation(.ok)])
        #expect(reloaded.events.count == 2, "Last health survives relaunch, so nothing is re-announced")
        reloaded.markAllRead()
        #expect(reloaded.unreadCount == 0)
    }

    @Test func quietHoursKeepTheInboxButSilenceTheDevice() async throws {
        let delivered = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (center, url) = makeCenter(delivered: delivered)
        defer { try? FileManager.default.removeItem(at: url) }
        await center.save(NotificationRule(name: "all", sourceKind: .serviceCheck, minimumSeverity: .warning))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        center.setQuietHours(QuietHours(startMinute: (now + 1439) % 1440, endMinute: (now + 5) % 1440, allowCritical: true))

        await center.observe([observation(.warning, id: "w")])
        await center.observe([observation(.critical, id: "c")])
        #expect(center.events.count == 2, "Everything still reaches the inbox")
        #expect(delivered.withLock { $0 }.count == 1, "Only the critical alert breaks through")

        let reloaded = AlertCenter(file: JSONFile(url: url), keychain: KeychainStore(service: "tests.\(UUID().uuidString)"), notifier: .silent)
        #expect(reloaded.quietHours?.allowCritical == true)
        center.setQuietHours(nil)
        #expect(center.quietHours == nil)
    }

    @Test func testNotificationSkipsTheInbox() async {
        let delivered = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (center, url) = makeCenter(delivered: delivered)
        defer { try? FileManager.default.removeItem(at: url) }
        await center.sendTestNotification()
        #expect(delivered.withLock { $0 } == [AlertCenter.testEvent.title] && center.events.isEmpty)
    }
}

struct QuietHoursTests {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now)!
    }

    @Test func overnightWindowWrapsPastMidnight() {
        let hours = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(hours.contains(at(23)) && hours.contains(at(2)) && hours.contains(at(6, 59)))
        #expect(!hours.contains(at(7)) && !hours.contains(at(12)) && !hours.contains(at(21, 59)))
        let daytime = QuietHours(startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(daytime.contains(at(9)) && !daytime.contains(at(17)) && !daytime.contains(at(3)))
        #expect(!QuietHours(startMinute: 60, endMinute: 60).contains(at(1)), "An empty window never silences")
    }

    @Test func criticalAlertsCanBreakThrough() {
        let critical = AlertTransition.event(previous: .ok, observation: observation(.critical))!
        let warning = AlertTransition.event(previous: .ok, observation: observation(.warning))!
        let recovery = AlertTransition.event(previous: .critical, observation: observation(.ok))!
        var hours = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(!hours.silences(critical, at: at(23)) && hours.silences(warning, at: at(23)) && hours.silences(recovery, at: at(23)))
        #expect(!hours.silences(warning, at: at(12)))
        hours.allowCritical = false
        #expect(hours.silences(critical, at: at(23)))
    }
}

struct ProfileVisibilityTests {
    @Test func legacyProfilesSeeEverything() throws {
        let profile = try JSONDecoder().decode(HouseholdProfile.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000009","name":"Kids","role":"viewer"}"#.utf8))
        #expect(profile.visibleItems == nil && profile.showsServers && !profile.isLimited)
        #expect(profile.shows(UUID()) && profile.seesServers)
    }

    @Test func limitsApplyOnlyToViewers() throws {
        let allowed = UUID(), hidden = UUID()
        var profile = HouseholdProfile(name: "Kids", role: .viewer, visibleItems: [allowed], showsServers: false)
        #expect(profile.shows(allowed) && !profile.shows(hidden) && !profile.seesServers && profile.isLimited)
        let decoded = try JSONDecoder().decode(HouseholdProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        profile.role = .owner
        #expect(profile.shows(hidden) && profile.seesServers && !profile.isLimited, "Owners are never limited")
    }
}

struct WidgetSnapshotTests {
    @Test func rankingPutsProblemsFirst() {
        let snapshot = WidgetSnapshot(updatedAt: .now, items: [
            .init(id: "1", kind: "check", name: "b", detail: "", level: .ok),
            .init(id: "2", kind: "check", name: "a", detail: "", level: .critical),
            .init(id: "3", kind: "check", name: "c", detail: "", level: .warning),
            .init(id: "4", kind: "check", name: "a", detail: "", level: .ok),
        ], unreadAlerts: 0)
        #expect(snapshot.ranked.map(\.id) == ["2", "3", "4", "1"])
        #expect(snapshot.attentionCount == 2)
    }
}

@MainActor
struct ProfileStoreTests {
    @Test func alwaysKeepsAnOwner() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProfileStore(file: JSONFile(url: url))
        #expect(store.allowsActions && store.active.role == .owner)
        let owner = store.active
        var viewer = HouseholdProfile(name: "Kids", role: .viewer)
        try store.save(viewer)
        #expect(throws: ProfileError.self) { try store.delete(owner) }
        var demoted = owner
        demoted.role = .viewer
        #expect(throws: ProfileError.self) { try store.save(demoted) }
        viewer.name = "Family"
        try store.save(viewer)
        let reloaded = ProfileStore(file: JSONFile(url: url))
        #expect(reloaded.profiles.map(\.name).contains("Family"))
    }

    @Test func switchingToViewerNeedsNoAuthenticationAndDisablesActions() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let prompts = PromptLog()
        let store = ProfileStore(file: JSONFile(url: url)) { reason in prompts.append(reason) }
        let owner = store.active
        let viewer = HouseholdProfile(name: "Guest", role: .viewer)
        try store.save(viewer)
        #expect(store.viewerProtectionMissing)
        #expect(store.transitionNotice(to: viewer)?.contains("Anyone holding this device can switch back") == true)
        try await store.setRequireAuthentication(true)
        #expect(prompts.reasons.count == 1, "Turning the requirement on authenticates first")
        #expect(!store.viewerProtectionMissing)
        #expect(store.transitionNotice(to: viewer)?.contains("will ask for Face ID") == true)
        try await store.activate(viewer)
        #expect(!store.allowsActions)
        #expect(prompts.reasons.count == 1, "Dropping to view-only never asks")
        #expect(store.transitionNotice(to: owner) == nil, "Gaining control needs no warning")
        try await store.activate(owner)
        #expect(prompts.reasons.last == "Switch to \(owner.name)")
        #expect(store.allowsActions)
    }

    @Test func failedAuthenticationKeepsTheCurrentState() async throws {
        struct Denied: Error {}
        let url = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProfileStore(file: JSONFile(url: url)) { _ in throw Denied() }
        await #expect(throws: Denied.self) { try await store.setRequireAuthentication(true) }
        #expect(!store.requireAuthenticationForOwner, "A device that can't authenticate can't lock itself")
    }
}

/// Records authentication prompts in place of Face ID.
final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var reasons: [String] { lock.withLock { stored } }
    func append(_ reason: String) { lock.withLock { stored.append(reason) } }
}

struct DeepLinkTests {
    @Test func roundTripsAndRejectsForeignURLs() {
        let id = UUID()
        for link in [DeepLink.alerts, .upcoming, .statistics, .integration(id), .serviceCheck(id)] {
            #expect(DeepLink(url: link.url) == link)
        }
        #expect(DeepLink(url: URL(string: "https://example.com/alerts")!) == nil)
        #expect(DeepLink(url: URL(string: "envehomelab://integration/not-a-uuid")!) == nil)
        #expect(DeepLink(url: URL(string: "envehomelab://check/\(id.uuidString)")!) == .serviceCheck(id), "Widget links use the check route")
    }
}

struct BackupTests {
    @Test func backupsNeverContainSecretsAndRoundTrip() throws {
        var host = SSHHost(name: "Tower", host: "tower.local", username: "root")
        host.authentication = .key(UUID())
        let backup = ConfigurationBackup(
            format: ConfigurationBackup.currentFormat,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            servers: [ServerProfile(name: "Tower", endpoints: [ServerEndpoint(kind: .local, url: URL(string: "https://tower.local")!)])],
            integrations: [IntegrationInstance(kind: .sonarr, name: "Sonarr", url: URL(string: "http://sonarr.local:8989")!)],
            serviceChecks: [],
            sshHosts: [host],
            notificationRules: [NotificationRule(name: "r", sourceKind: .integration)]
        )
        let data = try backup.encoded()
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["apiKey\"", "password\"", "secret\"", "token\"", "PRIVATE KEY"] {
            #expect(!text.contains(forbidden), "Backups must not contain \(forbidden)")
        }
        #expect(try ConfigurationBackup.decode(data) == backup)
        var future = backup
        future.format = 99
        #expect(throws: BackupError.self) { _ = try ConfigurationBackup.decode(try future.encoded()) }
    }

    @Test func unreadableDuplicateAndUnsafeEntriesAreLeftOut() throws {
        let id = UUID()
        let json = """
        {"format":1,"exportedAt":"2027-01-15T08:00:00Z","servers":[],"serviceChecks":[],"sshHosts":[],"notificationRules":[],
         "integrations":[
          {"id":"\(id)","kind":"sonarr","name":"Sonarr","url":"http://sonarr.local:8989","isEnabled":true,"isSample":false},
          {"id":"\(id)","kind":"sonarr","name":"Duplicate","url":"http://sonarr.local:8989","isEnabled":true,"isSample":false},
          {"id":"\(UUID())","kind":"some-future-service","name":"Future","url":"http://f.local","isEnabled":true,"isSample":false},
          {"id":"\(UUID())","kind":"radarr","name":"Embedded","url":"http://admin:hunter2@radarr.local","isEnabled":true,"isSample":false},
          {"id":"\(UUID())","kind":"radarr","name":"FTP","url":"ftp://radarr.local","isEnabled":true,"isSample":false},
          {"id":"\(UUID())","kind":"truenas","name":"Plain TrueNAS","url":"http://nas.local","isEnabled":true,"isSample":false},
          "not an object"
         ]}
        """
        let backup = try ConfigurationBackup.decode(Data(json.utf8))
        #expect(backup.integrations.map(\.name) == ["Sonarr"])
        #expect(backup.rejected == 6)
        #expect(backup.purpose == .backup, "Files without a purpose are backups")
    }

    @Test func householdFilesKeepTheirPurposeAndCanBeTrimmed() throws {
        let sonarr = IntegrationInstance(kind: .sonarr, name: "Sonarr", url: URL(string: "http://sonarr.local:8989")!)
        let seerr = IntegrationInstance(kind: .seerr, name: "Seerr", url: URL(string: "http://seerr.local:5055")!)
        let check = ServiceCheck(name: "Site", url: URL(string: "https://example.com")!)
        let share = ConfigurationBackup(format: 1, purpose: .household, exportedAt: Date(timeIntervalSince1970: 1_800_000_000), servers: [],
                                        integrations: [sonarr, seerr], serviceChecks: [check], sshHosts: [], notificationRules: [])
        let decoded = try ConfigurationBackup.decode(try share.encoded())
        #expect(decoded.purpose == .household && decoded == share)
        let trimmed = decoded.selecting([seerr.id, check.id])
        #expect(trimmed.integrations == [seerr] && trimmed.serviceChecks == [check] && trimmed.itemCount == 2)

        let unknown = String(decoding: try share.encoded(), as: UTF8.self).replacingOccurrences(of: "\"household\"", with: "\"future-purpose\"")
        #expect(try ConfigurationBackup.decode(Data(unknown.utf8)).purpose == .backup, "An unknown purpose still imports")
    }
}

struct JSONFileRecoveryTests {
    @MainActor
    @Test func damagedFilesAreSetAsideInsteadOfOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jsonfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "service-checks.json")
        try Data("{ truncated".utf8).write(to: url)

        let store = ServiceCheckStore(file: JSONFile(url: url))
        #expect(store.checks.isEmpty)
        #expect(store.loadError?.contains("damaged") == true)

        try store.save(ServiceCheck(name: "New", url: URL(string: "https://a.local")!))
        let preserved = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("damaged") }
        #expect(preserved.count == 1)
        #expect(try Data(contentsOf: directory.appending(path: preserved[0])) == Data("{ truncated".utf8))
    }
}

struct OfflineCacheAndDiscoveryTests {
    @Test func serviceResultsSurviveEncoding() throws {
        let certificate = CertificateSummary(host: "h", subject: "s", sha256Fingerprint: "AA", notValidBefore: nil, notValidAfter: Date(timeIntervalSince1970: 2_000_000_000), evaluationFailure: nil)
        let results = [
            ServiceCheckResult(checkedAt: Date(timeIntervalSince1970: 1_800_000_000), outcome: .responded(status: 200, accepted: true), responseTime: .milliseconds(120), certificate: certificate, trust: .reused("Tower"), finalURL: URL(string: "https://h/health")),
            ServiceCheckResult(checkedAt: Date(timeIntervalSince1970: 1_800_000_060), outcome: .failed(.untrustedCertificate(certificate)), responseTime: nil, certificate: certificate, trust: .none, finalURL: nil),
        ]
        let decoded = try JSONDecoder().decode([ServiceCheckResult].self, from: JSONEncoder().encode(results))
        #expect(decoded == results)
    }

    @MainActor
    @Test func statusBoardPersistsLastKnownSummaries() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let summary = IntegrationSummary(product: "Sonarr", version: "4", health: .ok, headline: "Queue empty")
        try JSONFile<[UUID: IntegrationStatusBoard.Cached]>(url: url).save([id: .init(summary: summary, updatedAt: Date(timeIntervalSince1970: 1_000))])
        let board = IntegrationStatusBoard(file: JSONFile(url: url))
        #expect(board.state(for: id).value == summary)
        #expect(board.isStale(id), "Cached data older than five minutes is labelled stale")
    }

    @Test func discoveredHostsAreCleaned() {
        #expect(DiscoveredService.cleanHost("tower.local.") == "tower.local")
        #expect(DiscoveredService.cleanHost("fe80::1%en0") == "fe80::1")
        let v6 = DiscoveredService(name: "n", type: .https, host: "fd00::5", port: 8443)
        #expect(v6.url?.absoluteString == "https://[fd00::5]:8443")
        #expect(DiscoveredService(name: "n", type: .ssh, host: "10.0.0.2", port: 22).url?.scheme == "http")
    }
}
