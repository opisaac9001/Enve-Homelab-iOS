import Foundation

struct HydraIndexerStatus: Decodable, Sendable {
    var indexer: String
    var state: String
    var level: Int?
    var disabledUntil: HydraInstant?
    var lastError: String?
    var apiHits: Int?
    var apiHitLimit: Int?
    var downloadHits: Int?
    var downloadHitLimit: Int?

    var health: Health {
        switch state {
        case "ENABLED": .ok
        case "DISABLED_USER": .unknown
        case "DISABLED_SYSTEM_TEMPORARY": .warning
        default: .critical
        }
    }

    var stateName: String {
        switch state {
        case "ENABLED": "Enabled"
        case "DISABLED_USER": "Disabled by you"
        case "DISABLED_SYSTEM_TEMPORARY": "Backing off"
        case "DISABLED_SYSTEM": "Disabled by errors"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Current versions serialise instants as ISO-8601; older ones as epoch seconds.
struct HydraInstant: Decodable, Sendable {
    var date: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
        } else {
            date = APIDate.parse(try? container.decode(String.self))
        }
    }
}

struct HydraDownload: Decodable, Sendable {
    var id: Int
    var time: String?
    var title: String
    var indexer: String?
    var status: String?
    var error: String?
}

struct HydraOverview: Sendable {
    var version: String?
    /// nil when the server refuses stats access over the API.
    var indexers: [HydraIndexerStatus]?
    /// v9+ only.
    var recentDownloads: [HydraDownload]?
}

protocol HydraOperations: Sendable {
    func createBackup() async throws
}

/// NZBHydra2: version from Newznab caps, indexer status from the stats API, and the v9 external API where available.
struct NZBHydraClient: DashboardService, HydraOperations {
    let kind = IntegrationKind.nzbhydra
    private let rest: RESTClient
    private let apiKey: String

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-Api-Key": apiKey])
        self.apiKey = apiKey
    }

    private struct Ping: Decodable { var version: String }
    private struct Caps: Decodable {
        struct Server: Decodable {
            struct Attributes: Decodable { var version: String? }
            var attributes: Attributes
            enum CodingKeys: String, CodingKey { case attributes = "@attributes" }
        }
        var server: Server
    }
    private struct Page<Entry: Decodable>: Decodable { var entries: [Entry] }

    func overview() async throws -> HydraOverview {
        let keyQuery = [URLQueryItem(name: "apikey", value: apiKey)]
        var version: String?
        var isV9 = false
        // The external API answers 404 both for a wrong key and for servers older than v9.
        if let ping = try? await rest.json(.get("externalapi/v1/ping"), as: Ping.self) {
            version = ping.version
            isV9 = true
        } else {
            let data = try await rest.data(.get("api", query: [URLQueryItem(name: "t", value: "caps"), URLQueryItem(name: "o", value: "json")] + keyQuery))
            // Newznab reports errors, including a wrong key (code 100), as XML even when JSON was requested.
            if let error = (try? TorznabXMLParser.parse(data))?.error {
                throw error.code == "100" ? NetworkError.unauthorized : NetworkError.graphQL([error.description])
            }
            version = try RESTClient.decode(Caps.self, from: data).server.attributes.version
        }

        let indexers: [HydraIndexerStatus]?
        do {
            indexers = try await rest.json(try .post("api/stats/indexers", query: keyQuery, json: ["apikey": apiKey]), as: [HydraIndexerStatus].self)
        } catch let error as NetworkError {
            // Stats access is off unless the user allows it; that surfaces as an HTTP error, not a transport failure.
            switch error {
            case .forbidden, .httpStatus, .graphQL, .apiNotFound: indexers = nil
            default: throw error
            }
        }

        var downloads: [HydraDownload]?
        if isV9 {
            downloads = try? await rest.json(.get("externalapi/v1/history/downloads", query: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "limit", value: "15")]),
                                             as: Page<HydraDownload>.self).entries
        }
        return HydraOverview(version: version, indexers: indexers, recentDownloads: downloads)
    }

    func dashboard() async throws -> DashboardSnapshot {
        HydraDashboard.snapshot(try await overview(), operations: self)
    }

    func createBackup() async throws {
        _ = try await rest.data(.post("externalapi/v1/backups"))
    }
}

enum HydraDashboard {
    static func snapshot(_ overview: HydraOverview, operations: some HydraOperations) -> DashboardSnapshot {
        let indexers = overview.indexers ?? []
        let problems = indexers.filter { $0.health >= .warning }
        let enabled = indexers.filter { $0.state == "ENABLED" }
        let health: Health = overview.indexers == nil ? .unknown : (problems.contains { $0.health == .critical } ? .critical : (problems.isEmpty ? .ok : .warning))
        var sections = [
            DashboardSection(id: "indexers", title: "Indexers", systemImage: "magnifyingglass.circle", trailing: overview.indexers.map { _ in "\(enabled.count)/\(indexers.count) enabled" },
                             emptyText: overview.indexers == nil ? "Indexer status isn't available." : "No indexers are configured.",
                             rows: indexers.map { indexer in
                                 var limits: [String] = []
                                 if let hits = indexer.apiHits { limits.append("API \(hits)" + (indexer.apiHitLimit.map { "/\($0)" } ?? "")) }
                                 if let hits = indexer.downloadHits { limits.append("Downloads \(hits)" + (indexer.downloadHitLimit.map { "/\($0)" } ?? "")) }
                                 let until = indexer.disabledUntil?.date.map { "Retries \(Format.relative($0))" }
                                 return DashboardRow(id: indexer.indexer, title: indexer.indexer, subtitle: until, detail: limits.joined(separator: " · ").nilIfEmpty,
                                                     health: indexer.health, badge: indexer.stateName, message: indexer.health >= .warning ? indexer.lastError?.nilIfEmpty : nil)
                             }),
        ]
        if let downloads = overview.recentDownloads {
            sections.append(DashboardSection(id: "downloads", title: "Recent Grabs", systemImage: "arrow.down.doc", emptyText: "Nothing has been grabbed recently.",
                                             rows: downloads.map { download in
                                                 let failed = download.error?.nilIfEmpty != nil
                                                 return DashboardRow(id: "d\(download.id)", title: download.title,
                                                                     subtitle: [download.indexer, APIDate.parse(download.time).map(Format.relative)].compactMap { $0 }.joined(separator: " · "),
                                                                     health: failed ? .warning : nil, message: download.error?.nilIfEmpty)
                                             }))
        }
        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: overview.indexers == nil ? "Indexer status unavailable" : (problems.isEmpty ? "All \(enabled.count) indexers healthy" : "\(problems.count) indexer\(problems.count == 1 ? "" : "s") disabled"),
            notice: overview.indexers == nil ? "NZBHydra2 refused indexer statistics. Turn on Config › Auth › “Allow stats access via API”." : nil,
            metrics: overview.indexers == nil ? [] : [
                DashboardMetric(title: "Enabled indexers", value: "\(enabled.count)/\(indexers.count)", systemImage: "checkmark.circle"),
                DashboardMetric(title: "Disabled by errors", value: "\(problems.count)", systemImage: "exclamationmark.triangle", health: problems.isEmpty ? .ok : .warning),
            ],
            actions: overview.recentDownloads == nil ? [] : [
                DashboardAction(id: "backup", title: "Create Backup…", systemImage: "archivebox", targetKind: "Backup", targetName: "NZBHydra2 configuration and database",
                                consequence: "NZBHydra2 writes a new backup file on its server.") {
                    try await operations.createBackup()
                },
            ],
            sections: sections
        )
    }
}
