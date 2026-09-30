import Foundation
import Testing
@testable import EnveHomelab

struct MediaLibraryAuditTests {
    @Test func redactorMasksCredentialsButKeepsDiagnostics() {
        #expect(LogRedactor.redact("GET /Items?api_key=abc123&Limit=5 from 192.168.1.5") == "GET /Items?api_key=[redacted]&Limit=5 from 192.168.1.5")
        #expect(LogRedactor.redact("X-Plex-Token=xyz789 accepted") == "X-Plex-Token=[redacted] accepted")
        #expect(LogRedactor.redact("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload") == "Authorization: Bearer [redacted]")
        #expect(LogRedactor.redact("password: \"hunter2\"") == "password: \"[redacted]\"")
        #expect(LogRedactor.redact("MediaBrowser Client=\"x\", Token=\"secret-token\"") == "MediaBrowser Client=\"x\", Token=\"[redacted]\"")
        #expect(LogRedactor.redact("Scan of /mnt/media finished") == "Scan of /mnt/media finished")
    }

    @Test func semanticVersionComparison() {
        #expect(SemanticVersion.isNewer("v2.1.0", than: "2.0.9"))
        #expect(SemanticVersion.isNewer("0.9.1.5", than: "0.9.1.4"))
        #expect(!SemanticVersion.isNewer("1.28.0", than: "1.28.0"))
        #expect(!SemanticVersion.isNewer("1.2", than: "1.10"))
        #expect(SemanticVersion.isNewer("3.0.0-beta.1", than: "2.9.9"))
    }

    @Test func updateStates() {
        #expect(KomgaClient.update([KomgaRelease(version: "1.29.0", latest: true, preRelease: false)], current: "1.28.0") == .available("1.29.0"))
        #expect(KomgaClient.update([KomgaRelease(version: "1.30.0-rc", latest: true, preRelease: true)], current: "1.29.0") == .unknown, "Pre-releases aren't offered")
        #expect(KomgaClient.update(nil, current: "1.28.0") == .unknown)
        #expect(KavitaClient.update(KavitaUpdateNotification(currentVersion: "0.9.1.4", updateVersion: "0.9.2.0", isReleaseNewer: true)) == .available("0.9.2.0"))
        #expect(KavitaClient.update(KavitaUpdateNotification(currentVersion: "0.9.2.0", updateVersion: "0.9.2.0", isReleaseNewer: false)) == .upToDate)
        #expect(ImmichClient.update(latest: "v3.2.4", current: "3.2.4") == .upToDate)
        #expect(ImmichClient.update(latest: nil, current: "3.2.4") == .unknown)
    }

    @Test func maintenanceSectionFlagsStaleOrMissingBackups() {
        let stale = ServerMaintenance(update: .upToDate, backups: [.init(name: "old", date: .now.addingTimeInterval(-30 * 86_400))]).section()
        #expect(stale.rows.map(\.id) == ["update", "backups", "backup0"] && stale.rows[1].health == .warning)
        #expect(ServerMaintenance(backups: []).section().rows.first?.title == "No backups yet")
        #expect(ServerMaintenance(backups: [.init(name: "fresh", date: .now)]).section().rows.first?.health == .ok)
        #expect(ServerMaintenance().section().rows.isEmpty, "Nothing is claimed when the server wasn't asked")
    }

    @Test func pluginAttentionAndDeliverySummaries() {
        #expect(MediaPlugin(name: "a", status: "Active").needsAttention == false)
        #expect(MediaPlugin(name: "b", status: "Restart").statusTitle == "Needs restart")
        #expect(MediaPlugin(name: "c", availableUpdate: "2.0").needsAttention)
        let rows = [TautulliNotificationLog.Row(agent_name: "email", success: LooseNumber(1)), TautulliNotificationLog.Row(agent_name: "", success: LooseNumber(0), timestamp: LooseNumber(10))]
        #expect(TautulliDeliveryFailure.summarize(rows) == [TautulliDeliveryFailure(agent: "unknown", failures: 1, attempts: 1, lastFailure: Date(timeIntervalSince1970: 10))])
    }

    @Test func dispatcharrBackupHealth() {
        #expect(DispatcharrBackups(files: []).health == .warning)
        #expect(DispatcharrBackups(files: [.init(name: "x", created: Date.now.formatted(.iso8601))]).health == .ok)
        #expect(DispatcharrDashboard.backupSection(nil).rows.isEmpty)
        let off = DispatcharrDashboard.backupSection(DispatcharrBackups(files: [.init(name: "x", created: Date.now.formatted(.iso8601))], schedule: .init(enabled: false)))
        #expect(off.rows.last?.health == .warning)
    }

    @Test func samplesShowTheNewSections() async throws {
        let tautulli = try await SampleTautulli().dashboard()
        #expect(tautulli.sections.contains { $0.id == "problems" && !$0.rows.isEmpty })
        #expect(try await SampleKomga().dashboard().sections.first?.id == "maintenance")
        #expect(try await SampleDispatcharr().dashboard().sections.contains { $0.id == "backups" })
        #expect(try await SampleTracearr().dashboard().sections.contains { $0.id == "activity" })
        let logs = try await SampleMediaServer(kind: .jellyfin).logLines(MediaLogFile(name: "x"), limit: 10)
        #expect(logs.contains { $0.contains("api_key=[redacted]") })
    }
}
