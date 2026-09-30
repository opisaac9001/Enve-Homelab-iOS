import Foundation

/// Seerr, and the Overseerr and Jellyseerr releases it replaces, share one documented API.
enum SeerrRequestStatus: Int, Sendable {
    case pending = 1, approved, declined, failed, completed

    var title: String {
        switch self {
        case .pending: "Pending approval"
        case .approved: "Approved"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }
}

enum SeerrMediaStatus: Int, Sendable {
    case unknown = 1, pending, processing, partiallyAvailable, available, deleted

    var title: String {
        switch self {
        case .unknown: "Not in library"
        case .pending: "Waiting"
        case .processing: "Processing"
        case .partiallyAvailable: "Partly available"
        case .available: "Available"
        case .deleted: "Deleted"
        }
    }
}

enum SeerrRequestFilter: String, CaseIterable, Identifiable, Sendable {
    case pending, processing, failed, available, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "Pending"
        case .processing: "Processing"
        case .failed: "Failed"
        case .available: "Available"
        case .all: "All"
        }
    }
}

struct SeerrUser: Decodable, Sendable, Hashable {
    var id: Int
    var displayName: String?
    var username: String?
    var plexUsername: String?
    var jellyfinUsername: String?

    var name: String {
        [displayName, username, plexUsername, jellyfinUsername].compactMap { $0?.nilIfEmpty }.first ?? "User \(id)"
    }

    // Only names are read; user objects also carry email addresses and media-server tokens.
    private enum CodingKeys: String, CodingKey { case id, displayName, username, plexUsername, jellyfinUsername }
}

struct SeerrMedia: Decodable, Sendable, Hashable {
    var id: Int
    var tmdbId: Int?
    var tvdbId: Int?
    var status: Int?
    var mediaType: String?
}

struct SeerrSeason: Decodable, Sendable, Hashable {
    var seasonNumber: Int
}

struct SeerrRequest: Decodable, Sendable, Hashable {
    var id: Int
    var status: Int
    var type: String?
    var media: SeerrMedia?
    var createdAt: String?
    var requestedBy: SeerrUser?
    var is4k: Bool?
    var serverId: Int?
    var profileId: Int?
    var rootFolder: String?
    var seasons: [SeerrSeason]?

    var mediaType: String? { type ?? media?.mediaType }
}

struct SeerrPage<Item: Decodable & Sendable>: Decodable, Sendable {
    struct PageInfo: Decodable, Sendable { var results: Int? }
    var pageInfo: PageInfo?
    var results: [Item]
}

struct SeerrRequestCounts: Decodable, Sendable, Equatable {
    var total: Int
    var movie: Int?
    var tv: Int?
    var pending: Int
    var approved: Int?
    var declined: Int?
    var processing: Int?
    var available: Int?
    /// Seerr only; Overseerr doesn't report it.
    var completed: Int?
}

struct SeerrIssueCounts: Decodable, Sendable, Equatable {
    var total: Int
    var video: Int?
    var audio: Int?
    var subtitles: Int?
    var others: Int?
    var open: Int
    var closed: Int?
}

struct SeerrStatus: Decodable, Sendable {
    var version: String
    var updateAvailable: Bool?
    var restartRequired: Bool?
}

struct SeerrAbout: Decodable, Sendable {
    var totalRequests: Int?
    var totalMediaItems: Int?
}

struct SeerrIssueComment: Decodable, Sendable, Hashable {
    var id: Int?
    var message: String?
    var user: SeerrUser?
    var createdAt: String?
}

/// `/user/{id}/quota`; a nil or zero limit means unlimited.
struct SeerrQuota: Decodable, Sendable, Equatable {
    struct Limit: Decodable, Sendable, Equatable {
        var days: Int?
        var limit: Int?
        var used: Int?
        var remaining: Int?
        var restricted: Bool?

        var summary: String {
            guard let limit, limit > 0 else { return "Unlimited" }
            let window = days.map { " in \($0) day\($0 == 1 ? "" : "s")" } ?? ""
            return "\(used ?? 0) of \(limit) used\(window)" + (restricted == true ? " — limit reached" : "")
        }
    }
    var movie: Limit?
    var tv: Limit?
}

/// Only the season list of the documented TV detail response.
struct SeerrTVSeasons: Decodable, Sendable {
    struct Season: Decodable, Sendable, Hashable, Identifiable {
        var seasonNumber: Int
        var name: String?
        var episodeCount: Int?
        var id: Int { seasonNumber }
    }
    var seasons: [Season]?
}

struct SeerrIssue: Decodable, Sendable, Hashable {
    var id: Int
    var issueType: Int
    var media: SeerrMedia?
    var createdBy: SeerrUser?
    var createdAt: String?
    var comments: [SeerrIssueComment]?

    var typeTitle: String {
        switch issueType {
        case 1: "Video"
        case 2: "Audio"
        case 3: "Subtitles"
        default: "Other"
        }
    }
}

/// Only the title fields of the documented movie and TV detail responses.
struct SeerrTitle: Decodable, Sendable {
    var title: String?
    var name: String?
    var releaseDate: String?
    var firstAirDate: String?

    var displayTitle: String? { (title ?? name)?.nilIfEmpty }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
}

struct SeerrServer: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var is4k: Bool
    var isDefault: Bool
    var activeDirectory: String?
    var activeProfileId: Int?
}

struct SeerrServerDetails: Decodable, Sendable {
    struct Profile: Decodable, Sendable, Hashable, Identifiable { var id: Int; var name: String }
    struct RootFolder: Decodable, Sendable, Hashable { var path: String; var freeSpace: Double? }
    var server: SeerrServer
    var profiles: [Profile]
    var rootFolders: [RootFolder]?
}

/// A request with the media title looked up.
struct SeerrRequestItem: Sendable, Hashable, Identifiable {
    var request: SeerrRequest
    var title: String
    var year: String?

    var id: Int { request.id }
    var status: SeerrRequestStatus? { SeerrRequestStatus(rawValue: request.status) }
    var mediaStatus: SeerrMediaStatus? { request.media?.status.flatMap(SeerrMediaStatus.init(rawValue:)) }
    var isMovie: Bool { request.mediaType == "movie" }
    var isTV: Bool { request.mediaType == "tv" }
    var displayTitle: String { year.map { "\(title) (\($0))" } ?? title }

    /// Seerr refuses a TV reroute without the request's seasons, which older releases don't report.
    var canReroute: Bool { isMovie || (isTV && !(request.seasons ?? []).isEmpty) }
}

struct SeerrIssueItem: Sendable, Hashable, Identifiable {
    var issue: SeerrIssue
    var title: String
    var id: Int { issue.id }
}

struct SeerrOverview: Sendable {
    var status: SeerrStatus
    var requests: SeerrRequestCounts
    var issues: SeerrIssueCounts?
    var about: SeerrAbout?
}

/// Where an approved request is sent: one of the Radarr or Sonarr servers configured in Seerr.
struct SeerrRouting: Sendable, Hashable {
    var serverID: Int
    var serverName: String
    var profileID: Int
    var profileName: String
    var rootFolder: String
}

struct SeerrRoutingOption: Sendable, Hashable, Identifiable {
    var server: SeerrServer
    var profiles: [SeerrServerDetails.Profile]
    var rootFolders: [String]
    var id: Int { server.id }
}

protocol RequestService: IntegrationService {
    var kind: IntegrationKind { get }
    func overview() async throws -> SeerrOverview
    func requests(_ filter: SeerrRequestFilter, take: Int) async throws -> [SeerrRequestItem]
    func routingOptions(for item: SeerrRequestItem) async throws -> [SeerrRoutingOption]
    func approve(_ item: SeerrRequestItem, routing: SeerrRouting?) async throws
    func decline(_ item: SeerrRequestItem) async throws
    func retry(_ item: SeerrRequestItem) async throws
    func delete(_ item: SeerrRequestItem) async throws
    func issues(resolved: Bool) async throws -> [SeerrIssueItem]
    func setIssue(_ item: SeerrIssueItem, resolved: Bool) async throws
    func users() async throws -> [SeerrUser]
    func quota(userID: Int) async throws -> SeerrQuota
    func seasons(for item: SeerrRequestItem) async throws -> [SeerrTVSeasons.Season]
    /// Changes a pending request's requester and, for series, its seasons; routing already on the request is kept.
    func update(_ item: SeerrRequestItem, requesterID: Int, seasons: [Int]?) async throws
    func issue(_ item: SeerrIssueItem) async throws -> SeerrIssueItem
    func comment(on item: SeerrIssueItem, message: String) async throws
}

extension RequestService {
    func summary() async throws -> IntegrationSummary {
        let overview = try await overview()
        return SeerrMapping.summary(overview, kind: kind)
    }
}

enum SeerrMapping {
    static func summary(_ overview: SeerrOverview, kind: IntegrationKind) -> IntegrationSummary {
        let pending = overview.requests.pending
        let openIssues = overview.issues?.open ?? 0
        var parts = [pending == 0 ? "No pending requests" : "\(pending) pending request\(pending == 1 ? "" : "s")"]
        if openIssues > 0 { parts.append("\(openIssues) open issue\(openIssues == 1 ? "" : "s")") }
        return IntegrationSummary(product: kind.displayName, version: overview.status.version,
                                  // Waiting requests and open issues need someone to act, so they surface like warnings and can alert.
                                  health: overview.status.restartRequired == true || pending > 0 || openIssues > 0 ? .warning : .ok,
                                  headline: parts.joined(separator: " · "),
                                  detail: overview.status.restartRequired == true ? "Restart required to apply settings" : nil)
    }

    /// Prefers the request's own routing, then the server's defaults.
    static func defaultRouting(for item: SeerrRequestItem, options: [SeerrRoutingOption]) -> SeerrRouting? {
        let matching = options.filter { $0.server.is4k == (item.request.is4k ?? false) }
        guard let option = matching.first(where: { $0.server.id == item.request.serverId })
                ?? matching.first(where: \.server.isDefault) ?? matching.first else { return nil }
        let profile = option.profiles.first { $0.id == (option.server.id == item.request.serverId ? item.request.profileId : nil) }
            ?? option.profiles.first { $0.id == option.server.activeProfileId } ?? option.profiles.first
        let folder = [option.server.id == item.request.serverId ? item.request.rootFolder : nil, option.server.activeDirectory, option.rootFolders.first]
            .compactMap { $0?.nilIfEmpty }.first
        guard let profile, let folder else { return nil }
        return SeerrRouting(serverID: option.server.id, serverName: option.server.name, profileID: profile.id, profileName: profile.name, rootFolder: folder)
    }
}

struct SeerrClient: RequestService {
    let kind = IntegrationKind.seerr
    private let rest: RESTClient
    private let titles = SeerrTitleCache()

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        let base = url.lastPathComponent == "v1" ? url : url.appending(path: "api/v1")
        rest = RESTClient(baseURL: base, pinnedFingerprint: pinnedFingerprint, headers: ["X-Api-Key": apiKey, "Accept": "application/json"])
    }

    func overview() async throws -> SeerrOverview {
        async let status = rest.json(.get("status", query: [URLQueryItem(name: "checkUpdateAvailable", value: "true")]), as: SeerrStatus.self)
        async let counts = rest.json(.get("request/count"), as: SeerrRequestCounts.self)
        async let issues = try? rest.json(.get("issue/count"), as: SeerrIssueCounts.self)
        async let about = try? rest.json(.get("settings/about"), as: SeerrAbout.self)
        return try await SeerrOverview(status: status, requests: counts, issues: issues, about: about)
    }

    func requests(_ filter: SeerrRequestFilter, take: Int) async throws -> [SeerrRequestItem] {
        let page = try await rest.json(.get("request", query: [
            URLQueryItem(name: "take", value: String(take)),
            URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "filter", value: filter.rawValue),
            URLQueryItem(name: "sort", value: "added"),
        ]), as: SeerrPage<SeerrRequest>.self)
        let titles = await lookUpTitles(page.results.map { ($0.mediaType, $0.media?.tmdbId) })
        return zip(page.results, titles).map { request, title in
            SeerrRequestItem(request: request, title: title?.displayTitle ?? Self.fallbackTitle(request.media), year: title?.year)
        }
    }

    func routingOptions(for item: SeerrRequestItem) async throws -> [SeerrRoutingOption] {
        let service = item.isMovie ? "radarr" : "sonarr"
        let servers = try await rest.json(.get("service/\(service)"), as: [SeerrServer].self).filter { $0.is4k == (item.request.is4k ?? false) }
        var options: [SeerrRoutingOption] = []
        for server in servers {
            let details = try await rest.json(.get("service/\(service)/\(server.id)"), as: SeerrServerDetails.self)
            options.append(SeerrRoutingOption(server: server, profiles: details.profiles, rootFolders: (details.rootFolders ?? []).map(\.path)))
        }
        return options
    }

    private struct UpdateBody: Encodable {
        var mediaType: String
        var seasons: [Int]?
        var is4k: Bool
        var serverId: Int?
        var profileId: Int?
        var rootFolder: String?
        var userId: Int?
    }

    private func put(_ item: SeerrRequestItem, _ body: UpdateBody) async throws {
        _ = try await rest.data(RESTRequest(method: "PUT", path: "request/\(item.id)", body: .json(try JSONEncoder().encode(body))))
    }

    func approve(_ item: SeerrRequestItem, routing: SeerrRouting?) async throws {
        if let routing, let type = item.request.mediaType {
            try await put(item, UpdateBody(mediaType: type, seasons: item.isTV ? item.request.seasons?.map(\.seasonNumber) : nil, is4k: item.request.is4k ?? false,
                                           serverId: routing.serverID, profileId: routing.profileID, rootFolder: routing.rootFolder))
        }
        _ = try await rest.data(.post("request/\(item.id)/approve"))
    }

    func decline(_ item: SeerrRequestItem) async throws {
        _ = try await rest.data(.post("request/\(item.id)/decline"))
    }

    func retry(_ item: SeerrRequestItem) async throws {
        _ = try await rest.data(.post("request/\(item.id)/retry"))
    }

    func delete(_ item: SeerrRequestItem) async throws {
        _ = try await rest.data(.delete("request/\(item.id)"))
    }

    func issues(resolved: Bool) async throws -> [SeerrIssueItem] {
        let page = try await rest.json(.get("issue", query: [
            URLQueryItem(name: "take", value: "30"),
            URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "filter", value: resolved ? "resolved" : "open"),
            URLQueryItem(name: "sort", value: "added"),
        ]), as: SeerrPage<SeerrIssue>.self)
        let titles = await lookUpTitles(page.results.map { ($0.media?.mediaType, $0.media?.tmdbId) })
        return zip(page.results, titles).map { issue, title in
            SeerrIssueItem(issue: issue, title: title?.displayTitle ?? Self.fallbackTitle(issue.media))
        }
    }

    func setIssue(_ item: SeerrIssueItem, resolved: Bool) async throws {
        _ = try await rest.data(.post("issue/\(item.id)/\(resolved ? "resolved" : "open")"))
    }

    func users() async throws -> [SeerrUser] {
        try await rest.json(.get("user", query: [URLQueryItem(name: "take", value: "100"), URLQueryItem(name: "skip", value: "0"),
                                                 URLQueryItem(name: "sort", value: "displayname")]), as: SeerrPage<SeerrUser>.self).results
    }

    func quota(userID: Int) async throws -> SeerrQuota {
        try await rest.json(.get("user/\(userID)/quota"), as: SeerrQuota.self)
    }

    func seasons(for item: SeerrRequestItem) async throws -> [SeerrTVSeasons.Season] {
        guard item.isTV, let tmdbID = item.request.media?.tmdbId else { return [] }
        return try await rest.json(.get("tv/\(tmdbID)"), as: SeerrTVSeasons.self).seasons ?? []
    }

    func update(_ item: SeerrRequestItem, requesterID: Int, seasons: [Int]?) async throws {
        guard let type = item.request.mediaType else { throw NetworkError.unexpectedResponse("Seerr didn't say whether this is a movie or series.") }
        try await put(item, UpdateBody(mediaType: type, seasons: item.isTV ? (seasons ?? item.request.seasons?.map(\.seasonNumber)) : nil,
                                       is4k: item.request.is4k ?? false, serverId: item.request.serverId, profileId: item.request.profileId,
                                       rootFolder: item.request.rootFolder, userId: requesterID))
    }

    func issue(_ item: SeerrIssueItem) async throws -> SeerrIssueItem {
        SeerrIssueItem(issue: try await rest.json(.get("issue/\(item.id)"), as: SeerrIssue.self), title: item.title)
    }

    func comment(on item: SeerrIssueItem, message: String) async throws {
        struct Body: Encodable { let message: String }
        _ = try await rest.data(try .post("issue/\(item.id)/comment", json: Body(message: message)))
    }

    private static func fallbackTitle(_ media: SeerrMedia?) -> String {
        media?.tmdbId.map { "TMDB \($0)" } ?? "Unknown title"
    }

    /// Looks up titles of items that are already requested or reported; nothing here browses or searches.
    private func lookUpTitles(_ keys: [(type: String?, tmdbID: Int?)]) async -> [SeerrTitle?] {
        await withTaskGroup(of: (Int, SeerrTitle?).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask { (index, await title(type: key.type, tmdbID: key.tmdbID)) }
            }
            var titles = [SeerrTitle?](repeating: nil, count: keys.count)
            for await (index, title) in group { titles[index] = title }
            return titles
        }
    }

    private func title(type: String?, tmdbID: Int?) async -> SeerrTitle? {
        guard let type, ["movie", "tv"].contains(type), let tmdbID else { return nil }
        let key = "\(type)/\(tmdbID)"
        if let cached = await titles.value(for: key) { return cached }
        guard let title = try? await rest.json(.get(key), as: SeerrTitle.self) else { return nil }
        await titles.store(title, for: key)
        return title
    }
}

private actor SeerrTitleCache {
    private var values: [String: SeerrTitle] = [:]
    func value(for key: String) -> SeerrTitle? { values[key] }
    func store(_ value: SeerrTitle, for key: String) { values[key] = value }
}
