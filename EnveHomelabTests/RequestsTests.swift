import Foundation
import Testing
@testable import EnveHomelab

struct SeerrDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func requestsKeepOnlyUserNames() throws {
        let request = try decode(SeerrRequest.self, """
        {"id":5,"status":1,"type":"tv","is4k":true,"media":{"id":1,"tmdbId":10,"status":4},"seasons":[{"id":9,"seasonNumber":3,"status":1}],
         "requestedBy":{"id":2,"email":"a@example.com","plexToken":"secret","jellyfinUsername":"alex","plexUsername":""},
         "modifiedBy":"system"}
        """)
        #expect(request.requestedBy?.name == "alex", "Empty names are skipped")
        #expect(request.seasons?.map(\.seasonNumber) == [3])
        let item = SeerrRequestItem(request: request, title: "Show", year: nil)
        #expect(item.status == .pending && item.mediaStatus == .partiallyAvailable && item.canReroute)
        #expect(String(describing: request).contains("secret") == false, "Tokens are never decoded")
    }

    @Test func overseerrCountsWithoutCompleted() throws {
        let counts = try decode(SeerrRequestCounts.self, #"{"total":3,"movie":2,"tv":1,"pending":1,"approved":1,"declined":0,"processing":1,"available":1}"#)
        #expect(counts.completed == nil && counts.pending == 1)
    }

    @Test func tvWithoutSeasonsCannotBeRerouted() {
        let request = SeerrRequest(id: 1, status: 1, type: "tv")
        #expect(!SeerrRequestItem(request: request, title: "x").canReroute)
        #expect(SeerrRequestItem(request: SeerrRequest(id: 2, status: 1, type: "movie"), title: "y").canReroute)
    }

    @Test func defaultRoutingPrefersTheRequestThenServerDefaults() {
        let options = [
            SeerrRoutingOption(server: SeerrServer(id: 0, name: "Main", is4k: false, isDefault: true, activeDirectory: "/m", activeProfileId: 1),
                               profiles: [.init(id: 1, name: "HD"), .init(id: 2, name: "SD")], rootFolders: ["/m", "/k"]),
            SeerrRoutingOption(server: SeerrServer(id: 1, name: "Kids", is4k: false, isDefault: false, activeDirectory: "/k", activeProfileId: 2),
                               profiles: [.init(id: 2, name: "SD")], rootFolders: ["/k"]),
            SeerrRoutingOption(server: SeerrServer(id: 2, name: "UHD", is4k: true, isDefault: true, activeDirectory: "/u", activeProfileId: 3),
                               profiles: [.init(id: 3, name: "4K")], rootFolders: ["/u"]),
        ]
        let fresh = SeerrRequestItem(request: SeerrRequest(id: 1, status: 1, type: "movie", is4k: false), title: "a")
        #expect(SeerrMapping.defaultRouting(for: fresh, options: options) == SeerrRouting(serverID: 0, serverName: "Main", profileID: 1, profileName: "HD", rootFolder: "/m"))
        let routed = SeerrRequestItem(request: SeerrRequest(id: 2, status: 1, type: "movie", is4k: false, serverId: 1, profileId: 2, rootFolder: "/k"), title: "b")
        #expect(SeerrMapping.defaultRouting(for: routed, options: options)?.serverName == "Kids")
        let uhd = SeerrRequestItem(request: SeerrRequest(id: 3, status: 1, type: "movie", is4k: true), title: "c")
        #expect(SeerrMapping.defaultRouting(for: uhd, options: options)?.serverName == "UHD", "4K requests only go to 4K servers")
        #expect(SeerrMapping.defaultRouting(for: uhd, options: Array(options.prefix(2))) == nil)
    }

    @Test func summaryFlagsRestartAndCounts() {
        var overview = SeerrOverview(status: SeerrStatus(version: "3.0.1", restartRequired: true),
                                     requests: SeerrRequestCounts(total: 4, pending: 1), issues: SeerrIssueCounts(total: 2, open: 0))
        #expect(SeerrMapping.summary(overview, kind: .seerr).health == .warning)
        #expect(SeerrMapping.summary(overview, kind: .seerr).headline == "1 pending request")
        overview.status.restartRequired = false
        #expect(SeerrMapping.summary(overview, kind: .seerr).health == .warning, "A waiting request needs attention")
        overview.requests.pending = 0
        #expect(SeerrMapping.summary(overview, kind: .seerr).headline == "No pending requests")
        #expect(SeerrMapping.summary(overview, kind: .seerr).health == .ok)
    }

    @Test func sampleLifecycle() async throws {
        let sample = SampleSeerr()
        let pending = try await sample.requests(.pending, take: 10)
        #expect(pending.count == 2)
        let movie = try #require(pending.first { $0.isMovie })
        let options = try await sample.routingOptions(for: movie)
        try await sample.approve(movie, routing: SeerrMapping.defaultRouting(for: movie, options: options))
        #expect(try await sample.overview().requests.pending == 1)
        let issue = try #require(try await sample.issues(resolved: false).first)
        try await sample.setIssue(issue, resolved: true)
        #expect(try await sample.issues(resolved: false).isEmpty)
    }
}

struct WatchStatisticsTests {
    @Test func playsAreSummedPerDayAndType() throws {
        let plays = try JSONDecoder().decode(TautulliPlaysByDate.self, from: Data("""
        {"categories":["2026-09-27","2026-09-28","bad"],"series":[{"name":"Movies","data":[1,"2",5]},{"name":"TV","data":[3]},{"name":"Music","data":[0,0,0]}]}
        """.utf8))
        let stats = try JSONDecoder().decode([TautulliHomeStat].self, from: Data("""
        [{"stat_id":"top_tv","rows":[{"title":"Show","total_plays":"4","total_duration":3600},{"title":"","total_plays":1}]},
         {"stat_id":"top_users","rows":[{"friendly_name":null,"user":"alex","total_plays":2}]}]
        """.utf8))
        let result = WatchStatistics.make(plays: plays, stats: stats)
        #expect(result.days.map(\.plays) == [4, 2], "Unparseable dates are skipped and short series count as zero")
        #expect(result.totalPlays == 6 && result.busiestDay?.plays == 4)
        #expect(result.playsByType.map(\.type) == ["Movies", "TV"], "Types without plays are left out")
        #expect(result.topShows == [WatchStatistics.Ranked(name: "Show", plays: 4, duration: 3600)], "Rows without a name are dropped")
        #expect(result.topUsers.first?.name == "alex" && result.topMovies.isEmpty)
    }

    @Test func itemCountsOmitZeroes() throws {
        let counts = try JSONDecoder().decode(MediaItemCounts.self, from: Data(#"{"MovieCount":3,"SeriesCount":0,"EpisodeCount":12,"GameCount":4,"ItemCount":19}"#.utf8))
        #expect(counts.entries.map(\.label) == ["Movies", "Episodes"])
    }

    @Test func sampleStatisticsCoverThirtyDays() async throws {
        let stats = try await SampleTautulli().statistics(days: 30, userID: nil)
        #expect(stats.days.count == 30 && stats.totalPlays > 0)
        #expect(stats.playsByType.reduce(0) { $0 + $1.plays } == stats.totalPlays)
    }
}

struct WatchUserSummaryTests {
    @Test func periodsAndPlayersMapFromTautulli() throws {
        let watch = try JSONDecoder().decode([TautulliWatchTime].self, from: Data(#"[{"query_days":7,"total_plays":"3","total_time":15694},{"query_days":0,"total_plays":508,"total_time":1183080}]"#.utf8))
        let players = try JSONDecoder().decode([TautulliPlayerStat].self, from: Data(#"[{"platform":"Roku","player_name":"","total_plays":2},{"player_name":"iPad","total_plays":1,"total_time":60}]"#.utf8))
        let summary = WatchUserSummary.make(watchTime: watch, players: players)
        #expect(summary.periods.map(\.title) == ["Last 7 days", "All time"] && summary.periods.first?.plays == 3)
        #expect(summary.players.map(\.name) == ["Roku", "iPad"], "An empty player name falls back to the platform")
    }

    @Test func sampleSupportsRangesAndPeople() async throws {
        let sample = SampleTautulli()
        #expect(try await sample.statistics(days: 7, userID: nil).days.count == 7)
        let person = try await sample.statistics(days: 90, userID: "2")
        #expect(person.days.count == 90 && person.topUsers.isEmpty)
        #expect(try await sample.userSummary(userID: "2").periods.count == 4)
    }
}
