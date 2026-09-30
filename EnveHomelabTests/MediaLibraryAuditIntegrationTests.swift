import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh: the media-library audit additions against fixtures shaped by each product's documentation.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct MediaLibraryAuditIntegrationTests {
    @Test func tautulliProblemsAndNotificationFailures() async throws {
        let client = TautulliClient(url: try FixtureServer.url("tautulli"), apiKey: "tautulli-key-0000000000000000000", pinnedFingerprint: nil)
        let overview = try await client.overview()
        let problems = try #require(overview.problems)
        #expect(problems.map { $0.loglevel } == ["ERROR", "WARNING"], "Info lines are filtered out")
        let snapshot = TautulliDashboard.snapshot(overview, operations: client)
        let rows = try #require(snapshot.sections.first { $0.id == "problems" }).rows
        #expect(rows.first?.title.contains("token=[redacted]") == true && rows.first?.title.contains("abc123secret") == false, "Tokens in log lines are masked")
        let failures = try #require(overview.deliveryFailures)
        #expect(failures == [TautulliDeliveryFailure(agent: "discord", failures: 2, attempts: 3, lastFailure: Date(timeIntervalSince1970: 1_759_140_000))])
    }

    @Test func dispatcharrBackupsAndTaskOutcome() async throws {
        let client = DispatcharrClient(url: try FixtureServer.url("dispatcharr"), apiKey: "disp-key", pinnedFingerprint: nil)
        let backups = try #require(try await client.overview().backups)
        #expect(backups.files.count == 2 && backups.schedule?.enabled == true && backups.schedule?.retention_count == 7)
        #expect(backups.latest == APIDate.parse("2026-09-28T02:00:00+00:00"))
        // The fixture alternates success and failure; two runs must produce one of each rather than two apparent successes.
        var outcomes: [Bool] = []
        for _ in 0..<2 {
            do { try await client.createBackup(); outcomes.append(true) } catch is NetworkError { outcomes.append(false) }
        }
        #expect(outcomes.filter { $0 }.count == 1 && outcomes.count == 2, "A failed backup task is reported instead of looking like success")
    }

    @Test func libraryServerUpdatesAndBackups() async throws {
        let komga = try await KomgaClient(url: try FixtureServer.url("komga"), apiKey: "komga-key", pinnedFingerprint: nil).overview()
        #expect(komga.maintenance.update == .available("1.29.0"))

        let absClient = AudiobookshelfClient(url: try FixtureServer.url("abs"), apiKey: "abs-key", pinnedFingerprint: nil)
        let abs = try await absClient.overview()
        #expect(abs.backups?.first?.name == "2026-09-20T0100.audiobookshelf" && abs.backups?.first?.size == 21_000_000)
        #expect(abs.backups?.first?.date == Date(timeIntervalSince1970: 1_758_330_000))
        try await absClient.createBackup()
        #expect(try await FixtureServer.log().contains("abs backup"))

        let immich = try await ImmichClient(url: try FixtureServer.url("immich"), apiKey: "immich-key", pinnedFingerprint: nil).overview()
        #expect(immich.maintenance.update == .available("3.3.0") && immich.maintenance.backups?.first?.size == 412_000_000)
    }

    @Test func tracearrActivityAndTranscodeDetail() async throws {
        let overview = try await TracearrClient(url: try FixtureServer.url("tracearr"), apiKey: "trr_pub_fixture", pinnedFingerprint: nil).overview()
        let activity = try #require(overview.activity)
        #expect(activity.quality.transcodePercent == 30 && activity.peakConcurrent == 6 && activity.peakTranscodes == 3)
        let info = try #require(overview.streams.first?.transcodeInfo)
        #expect(info.fellBackToSoftware && info.isFallingBehind)
        #expect(info.summary == "Software fallback · 0.7× · Audio codec not supported")
    }

    @Test func jellyfinAndEmbyPluginsUpdatesAndLogs() async throws {
        let jellyfin = MediaBrowserClient(kind: .jellyfin, url: try FixtureServer.url("jf"), apiKey: "jf-key", deviceID: UUID(), pinnedFingerprint: nil)
        let management = try await jellyfin.management()
        #expect(management.plugins?.map(\.name) == ["Open Subtitles", "Playback Reporting"], "Plugins needing attention come first")
        #expect(management.plugins?.first?.statusTitle == "Failed to load")
        let files = try await jellyfin.logFiles()
        #expect(files.first?.name == "log_20260929.log", "Newest log first")
        let lines = try await jellyfin.logLines(try #require(files.first), limit: 2)
        #expect(lines.count == 2 && lines[0].contains("api_key=[redacted]") && !lines[0].contains("deadbeefcafe"))

        let emby = MediaBrowserClient(kind: .emby, url: try FixtureServer.url("emby"), apiKey: "emby-key", deviceID: UUID(), pinnedFingerprint: nil)
        let embyManagement = try await emby.management()
        #expect(embyManagement.health.updateVersion == "4.10.0.40")
        #expect(embyManagement.plugins?.first?.statusTitle == "Update 4.5.1.0")
        let embyFiles = try await emby.logFiles()
        let embyLines = try await emby.logLines(try #require(embyFiles.first), limit: 300)
        #expect(embyLines.last?.contains("X-Emby-Token=[redacted]") == true)
    }
}
