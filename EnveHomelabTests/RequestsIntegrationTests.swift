import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh against the documented Seerr request, service and issue routes.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct RequestsIntegrationTests {
    private func client(key: String = "seerr-key") throws -> SeerrClient {
        SeerrClient(url: try FixtureServer.url("seerr"), apiKey: key, pinnedFingerprint: nil)
    }

    @Test func titlesRoutingAndRequestLifecycle() async throws {
        let client = try client()
        let overview = try await client.overview()
        #expect(overview.status.version == "3.0.1" && overview.requests.pending == 2 && overview.issues?.open == 1 && overview.about?.totalMediaItems == 40)
        #expect(SeerrMapping.summary(overview, kind: .seerr).headline == "2 pending requests · 1 open issue")

        let pending = try await client.requests(.pending, take: 30)
        #expect(pending.map(\.displayTitle) == ["Sintel (2010)", "Pioneer One (2010)"], "Titles come from the item lookups")
        #expect(pending.first?.request.requestedBy?.name == "Jordan" && pending.last?.request.requestedBy?.name == "sam")
        #expect(pending.last?.canReroute == true)
        let failed = try await client.requests(.failed, take: 30)
        #expect(failed.first?.title == "TMDB 604", "A failed title lookup falls back to the ID instead of failing the list")

        let options = try await client.routingOptions(for: try #require(pending.first))
        #expect(options.map(\.server.name) == ["Radarr"], "4K servers are left out for a standard request")
        #expect(options.first?.rootFolders == ["/movies", "/kids"])
        let routing = SeerrMapping.defaultRouting(for: try #require(pending.first), options: options)
        #expect(routing == SeerrRouting(serverID: 0, serverName: "Radarr", profileID: 4, profileName: "HD-1080p", rootFolder: "/movies"))

        await #expect(throws: NetworkError.self) { try await self.client(key: "wrong").overview() }

        // The lifecycle changes fixture state, so it follows the reads in the same test.
        let users = try await client.users()
        #expect(users.map(\.name) == ["Jordan", "sam"])
        let quota = try await client.quota(userID: 3)
        #expect(quota.movie?.summary == "2 of 5 used in 7 days" && quota.tv?.summary == "Unlimited")
        await #expect(throws: NetworkError.self) { _ = try await client.quota(userID: 4) }
        let seasons = try await client.seasons(for: try #require(pending.last))
        #expect(seasons.map(\.seasonNumber) == [0, 1, 2])
        try await client.update(try #require(pending.last), requesterID: 3, seasons: [1, 2])
        await #expect(throws: NetworkError.self, "Seerr refuses a requester whose quota is exhausted") {
            try await client.update(try #require(pending.first), requesterID: 4, seasons: nil)
        }
        let refreshed = try await client.requests(.pending, take: 30)
        #expect(refreshed.last?.request.seasons?.map(\.seasonNumber) == [1, 2])
        let movie = try #require(refreshed.first { $0.isMovie })
        let series = try #require(refreshed.first { $0.isTV })
        try await client.approve(movie, routing: SeerrRouting(serverID: 0, serverName: "Radarr", profileID: 5, profileName: "Ultra-HD", rootFolder: "/kids"))
        try await client.approve(series, routing: SeerrRouting(serverID: 0, serverName: "Sonarr", profileID: 6, profileName: "HD", rootFolder: "/tv"))
        await #expect(throws: NetworkError.self, "Seerr only approves pending requests") { try await client.decline(movie) }

        let failedRequest = try #require(try await client.requests(.failed, take: 30).first)
        try await client.retry(failedRequest)
        try await client.delete(failedRequest)

        let issue = try #require(try await client.issues(resolved: false).first)
        #expect(issue.title == "Sintel" && issue.issue.typeTitle == "Subtitles" && issue.issue.comments?.first?.message == "Subtitles drift")
        try await client.comment(on: issue, message: "Replaced the subtitle file")
        let detail = try await client.issue(issue)
        #expect(detail.issue.comments?.last?.message == "Replaced the subtitle file" && detail.issue.comments?.last?.user?.name == "Owner")
        try await client.setIssue(issue, resolved: true)
        #expect(try await client.issues(resolved: false).isEmpty)

        let log = try await FixtureServer.log()
        #expect(log.contains("seerr route 41 movie server=0 profile=5 folder=/kids seasons="))
        #expect(log.contains("seerr approve 41"))
        #expect(log.contains("seerr route 40 tv server=undefined profile=undefined folder=undefined seasons=1,2 user=3"), "Editing keeps routing untouched and sends the chosen seasons")
        #expect(log.contains("seerr route 40 tv server=0 profile=6 folder=/tv seasons=1,2"), "A TV reroute resends the request's own seasons")
        #expect(log.contains("seerr comment 7 Replaced the subtitle file"))
        #expect(log.contains("seerr approve 40"))
        #expect(log.contains("seerr retry 38") && log.contains("seerr delete 38"))
        #expect(log.contains("seerr issue 7 resolved"))
    }
}
