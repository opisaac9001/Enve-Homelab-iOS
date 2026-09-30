import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh against the documented Jellyfin, Emby, Plex and Tautulli shapes.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct MediaManagementIntegrationTests {
    @Test func jellyfinManagementStreamsAndControls() async throws {
        let client = MediaBrowserClient(kind: .jellyfin, url: try FixtureServer.url("jf"), apiKey: "jf-key", deviceID: UUID(), pinnedFingerprint: nil)
        let session = try #require(try await client.sessions().first)
        #expect(session.selectedAudio?.title == "English - AAC - Stereo")
        #expect(session.selectedSubtitle == nil, "Subtitle index -1 means subtitles are off")
        #expect(session.canMessage && session.canSwitch(.audio) && session.canSwitch(.subtitle))

        let management = try await client.management()
        #expect(management.health.pendingRestart == true && management.health.canRestart == true)
        #expect(management.tasks?.first?.state == .running, "Running tasks sort first")
        #expect(management.tasks?.first?.progress == 0.4)
        #expect(management.tasks?.last?.lastOutcome == .failed)
        #expect(management.tasks?.last?.lastError == "ffmpeg exited with code 1")
        #expect(management.devices?.map(\.name) == ["Living Room"])
        #expect(management.users?.first?.isAdministrator == true)
        #expect(management.users?.last?.isDisabled == true)
        #expect(management.history?.last?.severity == .warning)
        #expect(management.unavailable.isEmpty)

        try await client.perform(.runTask(id: "task-chapters"))
        try await client.perform(.stopTask(id: "task-scan"))
        try await client.perform(.message(sessionID: "s1", text: "Server restarting soon"))
        try await client.perform(.setStream(sessionID: "s1", kind: .subtitle, index: 3))
        try await client.perform(.removeDevice(id: "dev-1"))
        try await client.perform(.restartServer)
        try await client.refresh(libraryID: "lib1")
        let log = try await FixtureServer.log()
        #expect(log.contains("jf task POST task-chapters"))
        #expect(log.contains("jf task DELETE task-scan"))
        #expect(log.contains("jf message s1 Server restarting soon"))
        #expect(log.contains("jf command s1 SetSubtitleStreamIndex 3"))
        #expect(log.contains("jf remove device dev-1"))
        #expect(log.contains("jf restart"))
        #expect(log.contains("jf refresh item lib1 imageRefreshMode,metadataRefreshMode,replaceAllImages,replaceAllMetadata"), "Library scans never replace existing metadata")
        await #expect(throws: NetworkError.self) { try await client.perform(.emptyTrash(libraryID: "lib1")) }
    }

    @Test func embyDegradesWhenAdminSectionsAreRefused() async throws {
        let client = MediaBrowserClient(kind: .emby, url: try #require(FixtureServer.http), apiKey: "emby-key", deviceID: UUID(), pinnedFingerprint: nil)
        let session = try #require(try await client.sessions().first)
        #expect(session.canMessage, "Emby lists supported commands at the top level")
        #expect(!session.canSwitch(.audio))
        let management = try await client.management()
        #expect(management.tasks?.count == 2)
        #expect(management.devices == nil && management.history == nil)
        #expect(management.unavailable == ["Devices", "Activity log"], "Refused admin sections are named, not fatal")
        try await client.perform(.message(sessionID: "s1", text: "Hello"))
        try await client.refresh(libraryID: "lib1")
        let log = try await FixtureServer.log()
        #expect(log.contains("emby message s1 Hello"), "Emby takes the message as query parameters")
        #expect(log.contains("emby refresh item lib1 ImageRefreshMode,MetadataRefreshMode,Recursive,ReplaceAllImages,ReplaceAllMetadata"))
    }

    @Test func plexManagementTracksAndMaintenance() async throws {
        let plex = PlexClient(url: try FixtureServer.url("plex"), token: "plex-token", clientID: UUID(), pinnedFingerprint: nil)
        let session = try #require(try await plex.sessions().first)
        #expect(session.selectedAudio?.title == "English (EAC3 5.1)")
        #expect(session.selectedSubtitle?.title == "English (SRT External)")
        #expect(session.location == "lan" && session.bandwidthKbps == 12_000)
        #expect(!session.canMessage, "Plex offers no messaging")

        let management = try await plex.management()
        #expect(management.health.updateVersion == "1.42.2.10156")
        #expect(management.tasks?.first?.id == "BackupDatabase")
        #expect(management.activities?.first?.cancellable == true)
        #expect(management.activities?.first?.progress == 0.55)
        #expect(management.history?.first?.title == "Sintel")

        for action: MediaAdminAction in [.runTask(id: "BackupDatabase"), .cancelActivity(id: "act-1"), .refreshMetadata(libraryID: "1"), .analyze(libraryID: "1"),
                                          .emptyTrash(libraryID: "1"), .plex(.optimizeDatabase), .plex(.cleanBundles), .plex(.checkForUpdates)] {
            try await plex.perform(action)
        }
        let log = try await FixtureServer.log()
        for entry in ["plex POST /butler/BackupDatabase", "plex DELETE /activities/act-1", "plex refresh 1 force=1", "plex PUT /library/sections/1/analyze",
                      "plex PUT /library/sections/1/emptyTrash", "plex PUT /library/optimize", "plex PUT /library/clean/bundles", "plex PUT /updater/check"] {
            #expect(log.contains(entry), "Missing \(entry)")
        }
        await #expect(throws: NetworkError.self) { try await plex.perform(.restartServer) }
    }

    @Test func tautulliTracksStatsAndMaintenance() async throws {
        let client = TautulliClient(url: try FixtureServer.url("tautulli"), apiKey: "tautulli-key-0000000000000000000", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.activity.sessions?.first?.tracks == "Audio: English AAC stereo (transcoded) · Subtitles: English PGS (burned in)")
        #expect(overview.stats.first { $0.stat_id == "top_platforms" }?.rows?.first?.total_plays?.int == 38, "Numbers sent as strings decode")
        let snapshot = TautulliDashboard.snapshot(overview, operations: client)
        #expect(snapshot.sections.first { $0.id == "top_users" }?.rows.first?.title == "Alex")
        #expect(snapshot.action("backup-db")?.confirmation == .confirm, "Backups ask first")
        for id in ["refresh-libraries", "refresh-users", "backup-db"] {
            try await #require(snapshot.action(id)).perform()
        }
        let log = try await FixtureServer.log()
        #expect(log.contains("tautulli refresh_libraries_list") && log.contains("tautulli refresh_users_list") && log.contains("tautulli backup_db"))
    }

    @Test func libraryCountsAndWatchStatistics() async throws {
        let jellyfin = MediaBrowserClient(kind: .jellyfin, url: try FixtureServer.url("jf"), apiKey: "jf-key", deviceID: UUID(), pinnedFingerprint: nil)
        #expect(try await jellyfin.itemCounts()?.entries.map(\.label) == ["Movies", "Series", "Episodes", "Collections"])
        let emby = MediaBrowserClient(kind: .emby, url: try FixtureServer.url("emby"), apiKey: "emby-key", deviceID: UUID(), pinnedFingerprint: nil)
        #expect(try await emby.itemCounts()?.MovieCount == 3)
        let tautulli = TautulliClient(url: try FixtureServer.url("tautulli"), apiKey: "tautulli-key-0000000000000000000", pinnedFingerprint: nil)
        let stats = try await tautulli.statistics(days: 30, userID: nil)
        #expect(stats.days.map(\.plays) == [4, 5, 2])
        #expect(stats.playsByType.map(\.type) == ["Movies", "TV", "Live TV"])
        #expect(stats.topMovies.first?.name == "Sintel" && stats.topShows.first?.plays == 14)

        let users = try await tautulli.watchUsers()
        #expect(users == [WatchUser(id: "133788", name: "Jon Snow")], "The local and inactive users are left out")
        let mine = try await tautulli.statistics(days: 7, userID: "133788")
        #expect(mine.totalPlays == 3)
        let summary = try await tautulli.userSummary(userID: "133788")
        #expect(summary.periods.map(\.title) == ["Last 24 hours", "Last 7 days", "Last 30 days", "All time"])
        #expect(summary.periods.last?.plays == 508 && summary.players.first?.name == "Plex Web (Chrome)")
    }
}
