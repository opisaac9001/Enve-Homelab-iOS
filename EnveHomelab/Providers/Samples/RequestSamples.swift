import Foundation

actor SampleSeerr: RequestService {
    nonisolated let kind = IntegrationKind.seerr

    private static func user(_ id: Int, _ name: String) -> SeerrUser { SeerrUser(id: id, displayName: name) }
    private static func ago(_ days: Double) -> String { Date.now.addingTimeInterval(-days * 86_400).formatted(.iso8601) }

    private var requests: [SeerrRequestItem] = [
        SeerrRequestItem(request: SeerrRequest(id: 41, status: 1, type: "movie", media: SeerrMedia(id: 90, tmdbId: 9001, status: 2), createdAt: ago(0.2),
                                               requestedBy: user(3, "Jordan"), is4k: false), title: "Open Film Festival Highlights", year: "2026"),
        SeerrRequestItem(request: SeerrRequest(id: 40, status: 1, type: "tv", media: SeerrMedia(id: 91, tmdbId: 9002, status: 2), createdAt: ago(1),
                                               requestedBy: user(4, "Sam"), is4k: false, seasons: [SeerrSeason(seasonNumber: 2)]), title: "Community Garden", year: "2025"),
        SeerrRequestItem(request: SeerrRequest(id: 38, status: 4, type: "movie", media: SeerrMedia(id: 92, tmdbId: 9003, status: 3), createdAt: ago(3),
                                               requestedBy: user(3, "Jordan"), is4k: false, serverId: 0, profileId: 4, rootFolder: "/data/movies"), title: "Sample Documentary", year: "2026"),
        SeerrRequestItem(request: SeerrRequest(id: 35, status: 2, type: "tv", media: SeerrMedia(id: 93, tmdbId: 9004, status: 3), createdAt: ago(6),
                                               requestedBy: user(1, "Owner"), is4k: false, serverId: 0, profileId: 6, rootFolder: "/data/tv", seasons: [SeerrSeason(seasonNumber: 1)]), title: "Open Source Chronicles", year: "2024"),
        SeerrRequestItem(request: SeerrRequest(id: 30, status: 5, type: "movie", media: SeerrMedia(id: 94, tmdbId: 9005, status: 5), createdAt: ago(20),
                                               requestedBy: user(4, "Sam"), is4k: false, serverId: 0, profileId: 4, rootFolder: "/data/movies"), title: "Night Sky Timelapse", year: "2023"),
    ]
    private var issues: [(item: SeerrIssueItem, resolved: Bool)] = [
        (SeerrIssueItem(issue: SeerrIssue(id: 7, issueType: 3, media: SeerrMedia(id: 94, tmdbId: 9005, mediaType: "movie"), createdBy: user(4, "Sam"), createdAt: ago(0.5),
                                          comments: [SeerrIssueComment(message: "English subtitles drift out of sync after the first half hour.")]), title: "Night Sky Timelapse"), false),
        (SeerrIssueItem(issue: SeerrIssue(id: 5, issueType: 2, media: SeerrMedia(id: 93, tmdbId: 9004, mediaType: "tv"), createdBy: user(3, "Jordan"), createdAt: ago(9),
                                          comments: [SeerrIssueComment(message: "Episode 3 has no audio.")]), title: "Open Source Chronicles"), true),
    ]

    private let routing = [
        SeerrRoutingOption(server: SeerrServer(id: 0, name: "Radarr", is4k: false, isDefault: true, activeDirectory: "/data/movies", activeProfileId: 4),
                           profiles: [.init(id: 4, name: "HD-1080p"), .init(id: 5, name: "Ultra-HD")], rootFolders: ["/data/movies", "/data/kids-movies"]),
        SeerrRoutingOption(server: SeerrServer(id: 1, name: "Radarr Archive", is4k: false, isDefault: false, activeDirectory: "/archive/movies", activeProfileId: 4),
                           profiles: [.init(id: 4, name: "HD-1080p")], rootFolders: ["/archive/movies"]),
    ]
    private let sonarrRouting = [
        SeerrRoutingOption(server: SeerrServer(id: 0, name: "Sonarr", is4k: false, isDefault: true, activeDirectory: "/data/tv", activeProfileId: 6),
                           profiles: [.init(id: 6, name: "HD-1080p"), .init(id: 7, name: "Any")], rootFolders: ["/data/tv", "/data/anime"]),
    ]

    func overview() async throws -> SeerrOverview {
        try await Task.sleep(for: .milliseconds(150))
        let statuses = requests.map(\.status)
        return SeerrOverview(
            status: SeerrStatus(version: "3.0.1", updateAvailable: false, restartRequired: false),
            requests: SeerrRequestCounts(total: requests.count, movie: requests.filter(\.isMovie).count, tv: requests.filter(\.isTV).count,
                                         pending: statuses.filter { $0 == .pending }.count, approved: statuses.filter { $0 == .approved }.count,
                                         declined: statuses.filter { $0 == .declined }.count,
                                         processing: requests.filter { $0.status == .approved && $0.mediaStatus != .available }.count,
                                         available: requests.filter { $0.mediaStatus == .available }.count, completed: statuses.filter { $0 == .completed }.count),
            issues: SeerrIssueCounts(total: issues.count, open: issues.filter { !$0.resolved }.count, closed: issues.filter(\.resolved).count),
            about: SeerrAbout(totalRequests: 128, totalMediaItems: 342)
        )
    }

    func requests(_ filter: SeerrRequestFilter, take: Int) async throws -> [SeerrRequestItem] {
        let matching = requests.filter { item in
            switch filter {
            case .pending: item.status == .pending
            case .processing: item.status == .approved && item.mediaStatus != .available
            case .failed: item.status == .failed
            case .available: item.mediaStatus == .available
            case .all: true
            }
        }
        return Array(matching.prefix(take))
    }

    func routingOptions(for item: SeerrRequestItem) async throws -> [SeerrRoutingOption] {
        item.isMovie ? routing : sonarrRouting
    }

    func approve(_ item: SeerrRequestItem, routing: SeerrRouting?) async throws {
        update(item.id) { request in
            request.request.status = SeerrRequestStatus.approved.rawValue
            request.request.media?.status = SeerrMediaStatus.processing.rawValue
            if let routing {
                request.request.serverId = routing.serverID
                request.request.profileId = routing.profileID
                request.request.rootFolder = routing.rootFolder
            }
        }
    }

    func decline(_ item: SeerrRequestItem) async throws { update(item.id) { $0.request.status = SeerrRequestStatus.declined.rawValue } }
    func retry(_ item: SeerrRequestItem) async throws { update(item.id) { $0.request.status = SeerrRequestStatus.approved.rawValue } }
    func delete(_ item: SeerrRequestItem) async throws { requests.removeAll { $0.id == item.id } }

    func issues(resolved: Bool) async throws -> [SeerrIssueItem] {
        issues.filter { $0.resolved == resolved }.map(\.item)
    }

    func setIssue(_ item: SeerrIssueItem, resolved: Bool) async throws {
        for index in issues.indices where issues[index].item.id == item.id { issues[index].resolved = resolved }
    }

    private let people = [SeerrUser(id: 1, displayName: "Owner"), SeerrUser(id: 3, displayName: "Jordan"), SeerrUser(id: 4, displayName: "Sam")]

    func users() async throws -> [SeerrUser] { people }

    func quota(userID: Int) async throws -> SeerrQuota {
        let used = requests.filter { $0.request.requestedBy?.id == userID }
        return SeerrQuota(movie: .init(days: 7, limit: userID == 1 ? 0 : 5, used: used.filter(\.isMovie).count, remaining: nil, restricted: false),
                          tv: .init(days: 7, limit: userID == 1 ? 0 : 3, used: used.filter(\.isTV).count, remaining: nil, restricted: false))
    }

    func seasons(for item: SeerrRequestItem) async throws -> [SeerrTVSeasons.Season] {
        item.isTV ? (1...3).map { SeerrTVSeasons.Season(seasonNumber: $0, name: "Season \($0)", episodeCount: 8) } : []
    }

    func update(_ item: SeerrRequestItem, requesterID: Int, seasons: [Int]?) async throws {
        let requester = people.first { $0.id == requesterID }
        update(item.id) { request in
            request.request.requestedBy = requester
            if let seasons, request.isTV { request.request.seasons = seasons.map { SeerrSeason(seasonNumber: $0) } }
        }
    }

    func issue(_ item: SeerrIssueItem) async throws -> SeerrIssueItem {
        issues.first { $0.item.id == item.id }?.item ?? item
    }

    func comment(on item: SeerrIssueItem, message: String) async throws {
        for index in issues.indices where issues[index].item.id == item.id {
            issues[index].item.issue.comments = (issues[index].item.issue.comments ?? [])
                + [SeerrIssueComment(id: Int.random(in: 100...999), message: message, user: people[0], createdAt: Date.now.formatted(.iso8601))]
        }
    }

    private func update(_ id: Int, _ change: (inout SeerrRequestItem) -> Void) {
        for index in requests.indices where requests[index].id == id { change(&requests[index]) }
    }
}
