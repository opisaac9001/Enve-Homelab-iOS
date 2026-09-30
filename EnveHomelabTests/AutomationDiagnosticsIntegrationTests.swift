import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh against the documented Servarr system routes and the qBittorrent/Transmission tracker APIs.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct AutomationDiagnosticsIntegrationTests {
    @Test func arrSystemDiagnosticsAndSafeTasks() async throws {
        let client = ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil)
        let diagnostics = try await client.systemDiagnostics()
        #expect(diagnostics.tasks.map(\.taskName) == ["Backup", "RssSync"])
        #expect(diagnostics.tasks.map(\.isRunnable) == [true, false], "Only app-maintenance tasks can be run")
        #expect(diagnostics.problems.map(\.id) == [9, 8] && diagnostics.problemTotal == 57, "Info lines are filtered even if the server includes them")
        #expect(diagnostics.availableUpdate?.version == "5.27.0.10202")
        #expect(diagnostics.backups?.first?.size == 4_812_000)

        try await client.runTask(try #require(diagnostics.tasks.first))
        await #expect(throws: NetworkError.self, "RSS Sync grabs releases, so it isn't runnable here") { try await client.runTask(diagnostics.tasks[1]) }
        #expect(try await FixtureServer.log().contains("arr command Backup"))
    }

    @Test func qbittorrentTrackersHidePasskeysAndRecheck() async throws {
        let client = QBittorrentClient(url: try FixtureServer.url("qbt"), username: "admin", password: "p@ss&word", pinnedFingerprint: nil)
        let trackers = try await client.trackers(for: "abc123")
        #expect(trackers.map(\.host) == ["[DHT]", "tracker.example.org", "backup.example.net"])
        #expect(trackers.map(\.status) == [.disabled, .working, .notWorking])
        #expect(trackers[1].seeds == 42 && trackers[2].seeds == nil, "Unknown counts (-1) are dropped")
        #expect(!trackers.contains { $0.host.contains("passkey") }, "Announce paths never reach the UI")
        try await client.verify("abc123")
        #expect(try await FixtureServer.log().contains("qbt recheck abc123"))
    }

    @Test func transmissionTrackerStatsAndVerify() async throws {
        let client = TransmissionClient(url: try #require(FixtureServer.http), username: "rpc", password: "secret", pinnedFingerprint: nil)
        let trackers = try await client.trackers(for: "def456")
        #expect(trackers.map(\.host) == ["tracker.example.org", "down.example.net", "new.example.com"])
        #expect(trackers.map(\.status) == [.working, .notWorking, .notContacted])
        #expect(trackers[1].message == "Could not connect to tracker" && trackers[0].message == nil, "Success messages aren't repeated")
        try await client.verify("def456")
        #expect(try await FixtureServer.log().contains("transmission verify def456"))
    }
}
