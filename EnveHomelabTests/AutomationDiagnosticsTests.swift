import Foundation
import Testing
@testable import EnveHomelab

struct AutomationDiagnosticsTests {
    @Test func trackerHostsNeverKeepPaths() {
        #expect(TorrentTracker.host(of: "https://t.example.org/abcdef0123/announce") == "t.example.org")
        #expect(TorrentTracker.host(of: "udp://t.example.org:1337") == "t.example.org")
        #expect(TorrentTracker.host(of: "** [PeX] **") == "[PeX]")
        #expect(TorrentTracker.host(of: "garbage without scheme") == "Tracker")
    }

    @Test func qbittorrentStatusMapping() {
        func status(_ code: Int) -> TorrentTracker.Status {
            QBittorrentClient.tracker(.init(url: "https://x.example", status: code), index: 0).status
        }
        #expect([0, 1, 2, 3, 4].map(status) == [.disabled, .notContacted, .working, .updating, .notWorking])
    }

    @Test func transmissionStatusMapping() {
        func status(_ stat: TransmissionClient.TrackerStat) -> TorrentTracker.Status { TransmissionClient.tracker(stat, index: 0).status }
        #expect(status(.init(announceState: 3)) == .updating)
        #expect(status(.init(hasAnnounced: false)) == .notContacted)
        #expect(status(.init(hasAnnounced: true, lastAnnounceSucceeded: true)) == .working)
        #expect(status(.init(hasAnnounced: true, lastAnnounceSucceeded: false)) == .notWorking)
    }

    @Test func availableUpdateNeedsANewerInstallableRelease() {
        let latestInstalled = [ArrUpdate(version: "2", installed: true, installable: false, latest: true)]
        #expect(ArrSystemDiagnostics.availableUpdate(in: latestInstalled) == nil)
        let pending = [ArrUpdate(version: "2", installed: false, installable: true, latest: true), ArrUpdate(version: "1", installed: true, latest: false)]
        #expect(ArrSystemDiagnostics.availableUpdate(in: pending)?.version == "2")
        #expect(ArrSystemDiagnostics.availableUpdate(in: [ArrUpdate(version: "2", installed: false, installable: false, latest: true)]) == nil, "A release the app can't install isn't offered")
    }

    @Test func onlyMaintenanceTasksAreRunnable() {
        func task(_ name: String) -> ArrTask { ArrTask(id: 1, name: name, taskName: name) }
        #expect(["Backup", "Housekeeping", "CheckHealth"].allSatisfy { task($0).isRunnable })
        #expect(!["RssSync", "ApplicationUpdate", "RefreshMovie", "MissingEpisodeSearch", "CleanUpRecycleBin"].contains { task($0).isRunnable })
        #expect(Durations.timeSpan("00:00:03.2100000").map { abs($0 - 3.21) < 0.01 } == true, "Task durations keep fractional seconds")
    }

    @Test func samplesExposeTheNewDiagnostics() async throws {
        let radarr = SampleArrService(kind: .radarr)
        let diagnostics = try await radarr.systemDiagnostics()
        #expect(diagnostics.tasks.contains(where: \.isRunnable) && diagnostics.availableUpdate != nil)
        let qbt = SampleDownloadClient(kind: .qbittorrent)
        #expect(try await qbt.trackers(for: "x").contains { $0.status == .notWorking })
        #expect(DownloadClientView.torrentDiagnosticsKinds == [.qbittorrent, .transmission])
    }
}
