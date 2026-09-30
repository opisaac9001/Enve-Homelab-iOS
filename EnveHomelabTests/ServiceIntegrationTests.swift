import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh; each fixture route enforces the vendor's documented authentication.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct ServiceIntegrationTests {
    private func perform(_ snapshot: DashboardSnapshot, _ id: String) async throws {
        try await #require(snapshot.action(id), "Missing action \(id)").perform()
    }

    @Test func nzbgetSplitSizesPostProcessingAndDeleteModes() async throws {
        let client = NZBGetClient(url: try FixtureServer.url("nzbget"), username: "nzb", password: "get", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "25.3")
        #expect(overview.downloadRate == 3 * 1_048_576)
        let downloading = try #require(overview.items.first)
        let sixTimesTwoToThe32: Int64 = 25_769_803_776
        #expect(downloading.size == sixTimesTwoToThe32, "Lo/Hi halves combine into 64-bit sizes")
        #expect(downloading.progress == 0.5)
        #expect(downloading.eta == Double(3 * 4_294_967_296) / Double(3 * 1_048_576))
        let unpacking = overview.items[1]
        #expect(unpacking.state == .importing)
        #expect(unpacking.progress == 0.25, "Post-processing reports stage progress in permille")
        #expect(unpacking.message == "Unpacking Conference.Talks")

        try await client.pause(["5"])
        try await client.remove(["5"], deleteData: false)
        try await client.remove(["5"], deleteData: true)
        try await client.pauseAll()
        let log = try await FixtureServer.log()
        #expect(log.contains("nzbget GroupPause 5"))
        #expect(log.contains("nzbget GroupParkDelete 5"), "Keeping data parks the item")
        #expect(log.contains("nzbget GroupDelete 5"))
        #expect(log.contains("nzbget pausedownload"))
        await #expect(throws: NetworkError.unexpectedResponse("NZBGet didn't find that item in its queue.")) { try await client.pause(["99"]) }

        let wrong = NZBGetClient(url: try FixtureServer.url("nzbget"), username: "nzb", password: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func delugeLogsInConnectsDaemonAndControls() async throws {
        let client = DelugeClient(url: try FixtureServer.url("deluge"), password: "deluge-pw", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "2.2.0")
        #expect(overview.isPaused == false)
        let item = try #require(overview.items.first { $0.id == "abc" })
        #expect(item.progress == 0.425)
        #expect(item.state == .downloading)
        #expect(item.category == "linux")
        let broken = try #require(overview.items.first { $0.id == "def" })
        #expect(broken.state == .failed)
        #expect(broken.message == "Tracker unreachable")

        try await client.pause(["abc"])
        try await client.pauseAll()
        try await client.remove(["abc"], deleteData: true)
        let log = try await FixtureServer.log()
        #expect(log.contains("deluge connect host-a"))
        #expect(log.contains("deluge pause abc"))
        #expect(log.contains("deluge pause_session"))
        #expect(log.contains("deluge remove abc data=true"))

        let wrong = DelugeClient(url: try FixtureServer.url("deluge"), password: "nope", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func bazarrWantedProvidersTasksAndSearches() async throws {
        let client = BazarrClient(url: try FixtureServer.url("bazarr"), apiKey: "bazarr-key", pinnedFingerprint: nil)
        let snapshot = try await client.dashboard()
        #expect(snapshot.version == "1.6.2")
        #expect(snapshot.health == .warning)
        #expect(snapshot.detail == "Sonarr 4.0.15", "An unconfigured Radarr reports an empty version")
        #expect(snapshot.sections.first { $0.id == "episodes" }?.trailing == "40")
        try await perform(snapshot, "e3456:es:false:true")
        try await perform(snapshot, "task:wanted_search_missing_subtitles_series")
        try await perform(snapshot, "providers:reset")
        let log = try await FixtureServer.log()
        #expect(log.contains("bazarr episode 12/3456 es forced=false hi=true"))
        #expect(log.contains("bazarr task wanted_search_missing_subtitles_series"))
        #expect(log.contains("bazarr providers reset"))

        let wrong = BazarrClient(url: try FixtureServer.url("bazarr"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.dashboard() }
    }

    @Test func nzbHydraFallsBackToCapsAndReadsIndexerStatus() async throws {
        let client = NZBHydraClient(url: try FixtureServer.url("hydra"), apiKey: "hydra-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "8.5.0")
        #expect(overview.recentDownloads == nil, "Pre-v9 servers have no external API")
        let indexers = try #require(overview.indexers)
        #expect(indexers.map(\.health) == [.ok, .warning])
        #expect(indexers[1].disabledUntil?.date == Date(timeIntervalSince1970: 1_790_000_000.5), "Older servers send epoch seconds")
        let snapshot = HydraDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .warning)
        #expect(snapshot.actions.isEmpty)

        let wrong = NZBHydraClient(url: try FixtureServer.url("hydra"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func jackettInventoryAndTorznabTests() async throws {
        let client = JackettClient(url: try FixtureServer.url("jackett"), apiKey: "jackett-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.indexers.map(\.title) == ["Linux Tracker", "Private & Club"])
        #expect(overview.indexers.map(\.type) == ["public", "private"])
        #expect(try await client.test(indexerID: "linuxtracker") == 2)
        await #expect(throws: NetworkError.graphQL(["Login failed (Torznab error 900)"])) { _ = try await client.test(indexerID: "club") }
        #expect(try await FixtureServer.log().contains("jackett test club"))

        let wrong = JackettClient(url: try FixtureServer.url("jackett"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func tdarrNodesQueuesAndPause() async throws {
        let client = TdarrClient(url: try FixtureServer.url("tdarr"), apiKey: "tapi_fixture", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "2.92.01")
        let node = try #require(overview.nodes.first)
        #expect(node.node.nodeName == "Tower")
        #expect(node.limits?.queueLengths?["healthcheckcpu"]?.int == 2, "Numbers sent as strings still count")
        let snapshot = TdarrDashboard.snapshot(overview, operations: client)
        #expect(snapshot.headline == "1 worker busy · 9 queued")
        try await perform(snapshot, "pause:nodeA")
        #expect(snapshot.action("resume:nodeA") == nil, "A node reported as running offers pause only")
        #expect(try await FixtureServer.log().contains("tdarr node nodeA paused=true"))

        let missing = TdarrClient(url: try FixtureServer.url("tdarr"), apiKey: nil, pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await missing.overview() }
    }

    @Test func maintainerrCollectionsDueCountsAndRuns() async throws {
        let client = MaintainerrClient(url: try FixtureServer.url("maintainerr"), username: nil, password: nil, pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.status.version == "3.29.0", "Status JSON arrives as text/html")
        #expect(overview.health?.database == "ok")
        #expect(overview.dueCounts == [1: 1], "Only the member added long ago has passed its 30-day wait")
        let snapshot = MaintainerrDashboard.snapshot(overview, operations: client)
        #expect(snapshot.detail == "Update available")
        let handle = try #require(snapshot.action("handle"))
        #expect(handle.confirmation == .typed)
        #expect(handle.consequence.contains("Leaving Soon: 1 due — will delete the files"))
        try await perform(snapshot, "run-rules")
        try await perform(snapshot, "handle")
        let log = try await FixtureServer.log()
        #expect(log.contains("maintainerr execute rules") && log.contains("maintainerr handle collections"))
    }

    @Test func tautulliActivityHistoryAndPlexPassError() async throws {
        let client = TautulliClient(url: try FixtureServer.url("tautulli"), apiKey: "tautulli-key-0000000000000000000", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "v2.18.2")
        #expect(overview.plexReachable)
        let session = try #require(overview.activity.sessions?.first)
        #expect(session.progress_percent?.value == 76, "String percentages decode")
        #expect(session.decisionName == "Transcode (hardware)")
        #expect(overview.libraries.first?.countSummary == "62 shows · 3,745 episodes")
        let snapshot = TautulliDashboard.snapshot(overview, operations: client)
        #expect(snapshot.metrics.first { $0.title == "Transcodes" }?.value == "1")
        let stop = try #require(snapshot.action("stop:sess-1"))
        #expect(stop.confirmation == .destructive)
        await #expect(throws: NetworkError.graphQL(["Failed to terminate session: No Plex Pass subscription."])) { try await stop.perform() }
        #expect(try await FixtureServer.log().contains("tautulli terminate sess-1 message=\(TautulliClient.terminationMessage)"))

        let wrong = TautulliClient(url: try FixtureServer.url("tautulli"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func komgaCountsBrokenBooksAndAdminActions() async throws {
        let client = KomgaClient(url: try FixtureServer.url("komga"), apiKey: "komga-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "1.28.0")
        #expect(overview.seriesCount == 214)
        #expect(overview.bookCount == 3_812)
        #expect(overview.brokenBooks.content.first?.media.comment == "ERR_1008")
        try await client.scan(libraryID: "l1", deep: true)
        #expect(try await client.cancelQueuedTasks() == 4)
        let log = try await FixtureServer.log()
        #expect(log.contains("komga scan l1 deep=true"))
        #expect(log.contains("komga cancel tasks"))

        let wrong = KomgaClient(url: try FixtureServer.url("komga"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func kavitaPluginTokenRefreshAndNonAdminDegradation() async throws {
        let client = KavitaClient(url: try FixtureServer.url("kavita"), apiKey: "kavita-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "0.9.1.4")
        #expect(overview.totalSeries == 188, "Totals come from the Pagination header")
        #expect(APIDate.parse(overview.libraries.first?.lastScanned) != nil, ".NET timestamps without a zone parse")
        #expect(overview.admin == nil, "Admin endpoints answer 403 for this user")
        let snapshot = KavitaDashboard.snapshot(overview, operations: client)
        #expect(snapshot.notice != nil)
        #expect(snapshot.actions.isEmpty)

        let wrong = KavitaClient(url: try FixtureServer.url("kavita"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func audiobookshelfSessionsIssuesAndScans() async throws {
        let client = AudiobookshelfClient(url: try FixtureServer.url("abs"), apiKey: "abs-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "2.36.0")
        #expect(overview.sessions?.first?.playMethodName == "Transcode")
        #expect(overview.issues["a1"]?.total == 1)
        #expect(overview.recent.first?.title == "New Book")
        let snapshot = AudiobookshelfDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .warning)
        #expect(snapshot.action("issues:a1")?.confirmation == .typed)
        try await perform(snapshot, "force:a1")
        try await perform(snapshot, "issues:a1")
        let log = try await FixtureServer.log()
        #expect(log.contains("abs scan a1 force=1"))
        #expect(log.contains("abs remove issues a1"))

        let wrong = AudiobookshelfClient(url: try FixtureServer.url("abs"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func immichStorageStatisticsAndQueueCommands() async throws {
        let client = ImmichClient(url: try FixtureServer.url("immich"), apiKey: "immich-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "3.2.4")
        #expect(overview.statistics?.photos == 12_000)
        let snapshot = ImmichDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .warning, "Failed jobs need attention")
        #expect(snapshot.action("start:thumbnailGeneration") == nil, "A running queue can't be started again")
        #expect(snapshot.action("start:backgroundTask") == nil, "Immich rejects start for this queue")
        try await perform(snapshot, "pause:thumbnailGeneration")
        try await perform(snapshot, "clear-failed:thumbnailGeneration")
        let log = try await FixtureServer.log()
        #expect(log.contains("immich thumbnailGeneration pause force=false"))
        #expect(log.contains("immich thumbnailGeneration clear-failed force=false"))

        let wrong = ImmichClient(url: try FixtureServer.url("immich"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func wizarrInvitationsUsersAndActions() async throws {
        let client = WizarrClient(url: try FixtureServer.url("wizarr"), apiKey: "wizarr-key", pinnedFingerprint: nil)
        let snapshot = try await client.dashboard()
        #expect(snapshot.health == .warning, "An unverified media server is a problem")
        #expect(snapshot.action("remove:12")?.confirmation == .typed)
        try await perform(snapshot, "delete-invite:5")
        try await perform(snapshot, "extend:12")
        let log = try await FixtureServer.log()
        #expect(log.contains("wizarr delete invitation 5"))
        #expect(log.contains("wizarr extend 12 days=30"))

        let wrong = WizarrClient(url: try FixtureServer.url("wizarr"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.dashboard() }
    }

    @Test func glancesStatsViewsAndAlerts() async throws {
        let client = GlancesClient(url: try FixtureServer.url("glances"), username: nil, password: "glances-pw", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "4.5.7")
        #expect(overview.uptime == "3 days, 4:05:06")
        #expect(overview.sensors?.map(\.value) == [81, nil], "Placeholder readings decode as missing")
        #expect(overview.decoration("fs", item: "/", field: "used") == .critical)
        #expect(overview.decoration("sensors", item: "Package id 0", field: "value") == .warning)
        let snapshot = GlancesDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .critical)
        #expect(snapshot.action("clear-warnings") == nil, "Only an ongoing critical alert exists")
        #expect(snapshot.action("clear-all") != nil)
        try await client.clearEvents(warningsOnly: true)
        #expect(try await FixtureServer.log().contains("glances clear warning"))

        let wrong = GlancesClient(url: try FixtureServer.url("glances"), username: nil, password: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func crowdSecLocalDecisionsWithBouncerKey() async throws {
        let client = CrowdSecClient(url: try FixtureServer.url("crowdsec"), apiKey: "cs-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.lapiUp)
        let decision = try #require(overview.decisions.first)
        #expect(decision.value == "192.168.1.1")
        #expect(abs((decision.remaining ?? 0) - 13_917.363171728) < 0.001)

        let wrong = CrowdSecClient(url: try FixtureServer.url("crowdsec"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.forbidden("access forbidden")) { _ = try await wrong.overview() }
    }

    @Test func companionExportRestoresThroughValidatedImport() throws {
        let path = try #require(ProcessInfo.processInfo.environment["COMPANION_EXPORT"])
        let backup = try ConfigurationBackup.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(backup.rejected == 0, "Everything the companion writes must pass restore validation")
        #expect(backup.purpose == .companion)
        #expect(backup.integrations.map(\.kind) == [.radarr, .immich, .plex, .gluetun, .seerr], "Agent images like beszel-agent must not match the hub")
        #expect(backup.integrations.first { $0.kind == .immich }?.url.absoluteString == "http://192.168.1.20:2284", "Published ports are remapped")
        #expect(backup.serviceChecks.map(\.name) == ["grafana"])
        #expect(backup.servers.isEmpty && backup.sshHosts.isEmpty)

        let rerunPath = try #require(ProcessInfo.processInfo.environment["COMPANION_RERUN"])
        let rerun = try ConfigurationBackup.decode(Data(contentsOf: URL(fileURLWithPath: rerunPath)))
        #expect(Set(rerun.integrations.map(\.id)) == Set(backup.integrations.map(\.id)), "Re-running the script keeps each service's ID")
        let plan = ImportPlan.make(rerun, integrations: backup.integrations, checks: backup.serviceChecks, serverIDs: [], hostIDs: [], ruleIDs: [])
        #expect(plan.newIDs.isEmpty)
        #expect(plan.integrations.filter { if case .moved = $0.status { true } else { false } }.map(\.name) == ["Radarr"], "Only the changed port is offered as an update")
    }
}
