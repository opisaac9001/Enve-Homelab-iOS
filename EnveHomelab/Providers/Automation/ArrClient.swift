import Foundation

protocol ArrService: IntegrationService {
    var kind: IntegrationKind { get }
    func snapshot() async throws -> ArrSnapshot
    func run(_ command: ArrCommand) async throws
    func removeFromQueue(id: Int, removeFromClient: Bool, blocklist: Bool) async throws
    func testAllIndexers() async throws
    /// Items due in the window; Prowlarr has no calendar.
    func calendar(from start: Date, to end: Date, includeUnmonitored: Bool) async throws -> [UpcomingItem]
    /// Monitored, released items without a file, newest first.
    func missing(limit: Int) async throws -> ArrMissing
    func systemDiagnostics() async throws -> ArrSystemDiagnostics
    /// Runs one of the app-maintenance tasks in `ArrTask.runnable`.
    func runTask(_ task: ArrTask) async throws
}

extension ArrService {
    var supportsQueue: Bool { kind != .prowlarr }

    var commands: [ArrCommand] {
        kind == .prowlarr ? [] : [.rssSync, .refreshMonitoredDownloads]
    }

    func summary() async throws -> IntegrationSummary {
        let snapshot = try await snapshot()
        let worst = snapshot.health.map(\.type.health).max() ?? .ok
        let headline: String
        if kind == .prowlarr {
            let disabled = snapshot.indexers.filter { !$0.isEnabled || $0.disabledUntil.map { $0 > .now } == true }.count
            headline = "\(snapshot.indexers.count) indexers" + (disabled > 0 ? " · \(disabled) unavailable" : "")
        } else {
            headline = snapshot.queueTotal == 0 ? "Queue empty" : "\(snapshot.queueTotal) in queue"
        }
        let issues = snapshot.health.filter { $0.type == .warning || $0.type == .error }.count
        return IntegrationSummary(
            product: kind.displayName,
            version: snapshot.status.version,
            health: worst,
            headline: headline,
            detail: issues > 0 ? "\(issues) health issue\(issues == 1 ? "" : "s")" : nil
        )
    }
}

/// Radarr, Sonarr and Lidarr share one API shape; Prowlarr shares status and health.
struct ArrClient: ArrService {
    let kind: IntegrationKind
    let rest: RESTClient

    init(kind: IntegrationKind, url: URL, apiKey: String, pinnedFingerprint: String?) {
        self.kind = kind
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-Api-Key": apiKey])
    }

    var apiPath: String {
        switch kind {
        case .radarr, .sonarr: "api/v3"
        default: "api/v1"
        }
    }

    private var queueIncludes: [URLQueryItem] {
        switch kind {
        case .radarr: [URLQueryItem(name: "includeMovie", value: "true")]
        case .sonarr: [URLQueryItem(name: "includeSeries", value: "true"), URLQueryItem(name: "includeEpisode", value: "true")]
        case .lidarr: [URLQueryItem(name: "includeArtist", value: "true"), URLQueryItem(name: "includeAlbum", value: "true")]
        default: []
        }
    }

    func snapshot() async throws -> ArrSnapshot {
        async let status = rest.json(.get("\(apiPath)/system/status"), as: ArrSystemStatus.self)
        async let health = rest.json(.get("\(apiPath)/health"), as: [ArrHealthItem].self)
        if kind == .prowlarr {
            async let indexers = rest.json(.get("\(apiPath)/indexer"), as: [ProwlarrIndexer].self)
            async let statuses = rest.json(.get("\(apiPath)/indexerstatus"), as: [ProwlarrIndexerStatus].self)
            let blocked = Dictionary(try await statuses.map { ($0.indexerId, APIDate.parse($0.disabledTill)) }, uniquingKeysWith: { $1 })
            let merged = try await indexers.map { indexer in
                var indexer = indexer
                indexer.disabledUntil = blocked[indexer.id] ?? nil
                return indexer
            }
            return ArrSnapshot(status: try await status, health: try await health, queue: [], queueTotal: 0, diskSpace: [], indexers: merged.sorted { $0.name < $1.name })
        }
        let query = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: "100")] + queueIncludes
        async let queue = rest.json(.get("\(apiPath)/queue", query: query), as: ArrQueuePage.self)
        async let disks = rest.json(.get("\(apiPath)/diskspace"), as: [ArrDiskSpace].self)
        let page = try await queue
        return ArrSnapshot(
            status: try await status,
            health: try await health,
            queue: page.records,
            queueTotal: page.totalRecords,
            diskSpace: try await disks,
            indexers: []
        )
    }

    func run(_ command: ArrCommand) async throws {
        struct Body: Encodable { let name: String }
        _ = try await rest.data(try .post("\(apiPath)/command", json: Body(name: command.rawValue)))
    }

    func removeFromQueue(id: Int, removeFromClient: Bool, blocklist: Bool) async throws {
        _ = try await rest.data(.delete("\(apiPath)/queue/\(id)", query: [
            URLQueryItem(name: "removeFromClient", value: String(removeFromClient)),
            URLQueryItem(name: "blocklist", value: String(blocklist)),
        ]))
    }

    func testAllIndexers() async throws {
        _ = try await rest.data(RESTRequest(method: "POST", path: "\(apiPath)/indexer/testall"))
    }

    func calendar(from start: Date, to end: Date, includeUnmonitored: Bool) async throws -> [UpcomingItem] {
        let window = [URLQueryItem(name: "start", value: start.formatted(.iso8601)), URLQueryItem(name: "end", value: end.formatted(.iso8601)),
                      URLQueryItem(name: "unmonitored", value: String(includeUnmonitored))]
        switch kind {
        case .radarr:
            return try await rest.json(.get("\(apiPath)/calendar", query: window), as: [ArrCalendar.Movie].self).compactMap { $0.upcoming(from: start, to: end) }
        case .sonarr:
            return try await rest.json(.get("\(apiPath)/calendar", query: window + [URLQueryItem(name: "includeSeries", value: "true")]), as: [ArrCalendar.Episode].self).compactMap(\.upcoming)
        case .lidarr:
            return try await rest.json(.get("\(apiPath)/calendar", query: window + [URLQueryItem(name: "includeArtist", value: "true")]), as: [ArrCalendar.Album].self).compactMap(\.upcoming)
        default:
            return []
        }
    }

    func missing(limit: Int) async throws -> ArrMissing {
        let page = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: String(limit)), URLQueryItem(name: "monitored", value: "true")]
        let result: ArrMissing
        switch kind {
        case .radarr:
            let movies = try await rest.json(.get("\(apiPath)/wanted/missing", query: page), as: ArrPage<ArrCalendar.Movie>.self)
            result = ArrMissing(total: movies.totalRecords, items: movies.records.compactMap { $0.missing() })
        case .sonarr:
            let episodes = try await rest.json(.get("\(apiPath)/wanted/missing", query: page + [URLQueryItem(name: "includeSeries", value: "true")]), as: ArrPage<ArrCalendar.Episode>.self)
            result = ArrMissing(total: episodes.totalRecords, items: episodes.records.compactMap(\.upcoming))
        case .lidarr:
            let albums = try await rest.json(.get("\(apiPath)/wanted/missing", query: page + [URLQueryItem(name: "includeArtist", value: "true")]), as: ArrPage<ArrCalendar.Album>.self)
            result = ArrMissing(total: albums.totalRecords, items: albums.records.compactMap(\.upcoming))
        default:
            return ArrMissing(total: 0, items: [])
        }
        return ArrMissing(total: result.total, items: result.items.sorted { $0.date > $1.date })
    }
}
