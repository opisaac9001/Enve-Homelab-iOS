import Foundation

/// Dispatcharr payloads also carry upstream provider URLs, provider passwords, channel names and client IPs.
/// These types declare only operational fields, so everything else is dropped at decode time and never stored.
struct DispatcharrStats: Decodable, Sendable {
    struct Live: Decodable, Sendable {
        struct Channel: Decodable, Sendable {
            var state: String?
            var client_count: Int?
            var healthy: Bool?
        }
        var channels: [Channel]?
        var count: Int?
    }
    struct Sessions: Decodable, Sendable { var total_connections: Int? }
    var live: Live?
    var vod: Sessions?
    var catchup: Sessions?
}

struct DispatcharrSource: Decodable, Sendable {
    var id: Int
    var name: String
    var is_active: Bool?
    var status: String?
    var last_message: String?
    var updated_at: String?

    var health: Health {
        switch status {
        case "error": .warning
        case "success", "idle": .ok
        case "disabled": .unknown
        default: .unknown
        }
    }
}

struct DispatcharrEvent: Decodable, Sendable {
    var id: Int
    var event_type: String
    var event_type_display: String?
    var timestamp: String?
}

/// `GET /api/backups/` entries and `GET /api/backups/schedule/` (both admin).
struct DispatcharrBackup: Decodable, Sendable, Equatable {
    var name: String
    var size: Int64?
    var created: String?
}

struct DispatcharrBackupSchedule: Decodable, Sendable, Equatable {
    var enabled: Bool
    var frequency: String?
    var retention_count: Int?
}

struct DispatcharrBackups: Sendable, Equatable {
    var files: [DispatcharrBackup]
    var schedule: DispatcharrBackupSchedule?

    static let staleAfter: TimeInterval = 14 * 86_400

    var latest: Date? { files.compactMap { APIDate.parse($0.created) }.max() }

    var health: Health {
        guard let latest else { return .warning }
        return Date.now.timeIntervalSince(latest) > Self.staleAfter ? .warning : .ok
    }
}

struct DispatcharrOverview: Sendable {
    var version: String?
    /// nil when Dispatcharr can't read its live state (it answers 500 when Redis is down).
    var stats: DispatcharrStats?
    var playlists: [DispatcharrSource]
    var guides: [DispatcharrSource]
    var errorEvents: [DispatcharrEvent]
    /// nil when the key's user isn't an admin.
    var backups: DispatcharrBackups?
}

protocol DispatcharrOperations: Sendable {
    func createBackup() async throws
}

/// Dispatcharr's documented REST API, limited to operational status: no catalogue, streams, playlist refreshes or provider details.
struct DispatcharrClient: DashboardService, DispatcharrOperations {
    let kind = IntegrationKind.dispatcharr
    static let errorEventTypes = ["m3u_error", "epg_error", "channel_error", "login_failed"]
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-API-Key": apiKey])
    }

    private struct Version: Decodable { var version: String }
    private struct Events: Decodable { var events: [DispatcharrEvent] }

    func overview() async throws -> DispatcharrOverview {
        async let version = try? rest.json(.get("api/core/version/"), as: Version.self)
        async let playlists = rest.json(.get("api/m3u/accounts/"), as: [DispatcharrSource].self)
        async let guides = rest.json(.get("api/epg/sources/"), as: [DispatcharrSource].self)
        let stats: DispatcharrStats?
        do {
            stats = try await rest.json(.get("proxy/stats/"), as: DispatcharrStats.self)
        } catch NetworkError.graphQL, NetworkError.httpStatus(500) {
            stats = nil
        }
        var events: [DispatcharrEvent] = []
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for type in Self.errorEventTypes {
            let recent = (try? await rest.json(.get("api/core/system-events/", query: [URLQueryItem(name: "event_type", value: type), URLQueryItem(name: "limit", value: "50")]), as: Events.self).events) ?? []
            events += recent.filter { (APIDate.parse($0.timestamp) ?? .distantPast) >= dayAgo }
        }
        events.sort { (APIDate.parse($0.timestamp) ?? .distantPast) > (APIDate.parse($1.timestamp) ?? .distantPast) }
        let files = try? await rest.json(.get("api/backups/"), as: [DispatcharrBackup].self)
        let schedule = try? await rest.json(.get("api/backups/schedule/"), as: DispatcharrBackupSchedule.self)
        return try await DispatcharrOverview(version: version?.version, stats: stats, playlists: playlists, guides: guides, errorEvents: events,
                                             backups: files.map { DispatcharrBackups(files: $0, schedule: schedule) })
    }

    func dashboard() async throws -> DashboardSnapshot {
        DispatcharrDashboard.snapshot(try await overview(), operations: self)
    }

    struct BackupTask: Decodable { var task_id: String; var task_token: String? }
    struct BackupStatus: Decodable { var state: String; var error: String? }

    /// The backup runs as a background task; waiting on its status is the only way to know whether it worked.
    func createBackup() async throws {
        let task = try await rest.json(.post("api/backups/create/"), as: BackupTask.self)
        let query = task.task_token.map { [URLQueryItem(name: "token", value: $0)] } ?? []
        for _ in 0..<45 {
            try await Task.sleep(for: .seconds(1))
            let status = try await rest.json(.get("api/backups/status/\(task.task_id)/", query: query), as: BackupStatus.self)
            switch status.state {
            case "completed": return
            case "failed": throw NetworkError.graphQL(["Dispatcharr couldn't create the backup: \(status.error ?? "unknown error")"])
            default: continue
            }
        }
    }
}

enum DispatcharrDashboard {
    static func backupSection(_ backups: DispatcharrBackups?) -> DashboardSection {
        guard let backups else {
            return DashboardSection(id: "backups", title: "Backups", systemImage: "archivebox", emptyText: "Backups are only visible to an admin key.", rows: [])
        }
        var rows = [DashboardRow(id: "latest", title: backups.latest.map { "Last backup \(Format.relative($0))" } ?? "No backups yet",
                                 subtitle: "\(backups.files.count) file\(backups.files.count == 1 ? "" : "s") on the server",
                                 health: backups.health)]
        if let schedule = backups.schedule {
            rows.append(DashboardRow(id: "schedule", title: schedule.enabled ? "Scheduled backups on" : "Scheduled backups off",
                                     subtitle: schedule.enabled ? [schedule.frequency?.capitalizedFirst, schedule.retention_count.map { "keeps \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty : "Turn them on in Dispatcharr › Settings › Backups.",
                                     health: schedule.enabled ? .ok : .warning))
        }
        return DashboardSection(id: "backups", title: "Backups", systemImage: "archivebox", emptyText: "", rows: rows)
    }

    static func snapshot(_ overview: DispatcharrOverview, operations: some DispatcharrOperations) -> DashboardSnapshot {
        let live = overview.stats?.live
        let channels = live?.count ?? live?.channels?.count ?? 0
        let viewers = live?.channels?.compactMap(\.client_count).reduce(0, +) ?? 0
        let unhealthy = live?.channels?.filter { $0.healthy == false }.count ?? 0
        let sourceErrors = (overview.playlists + overview.guides).filter { $0.status == "error" }
        let health: Health = overview.stats == nil ? .critical : (sourceErrors.isEmpty && overview.errorEvents.isEmpty && unhealthy == 0 ? .ok : .warning)

        func sourceRows(_ sources: [DispatcharrSource], prefix: String) -> [DashboardRow] {
            sources.map { source in
                DashboardRow(id: "\(prefix):\(source.id)", title: source.name,
                             detail: APIDate.parse(source.updated_at).map { "Updated \(Format.relative($0))" },
                             health: source.is_active == false ? nil : source.health,
                             badge: source.is_active == false ? "Inactive" : (source.status?.replacingOccurrences(of: "_", with: " ").capitalizedFirst ?? "Unknown"),
                             message: source.status == "error" ? source.last_message?.nilIfEmpty : nil)
            }
        }

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: overview.stats == nil ? "Live status unavailable" : "\(channels) active channel\(channels == 1 ? "" : "s") · \(viewers) viewer\(viewers == 1 ? "" : "s")",
            detail: sourceErrors.isEmpty ? nil : "\(sourceErrors.count) source\(sourceErrors.count == 1 ? "" : "s") failing",
            notice: overview.stats == nil ? "Dispatcharr couldn't report live connections, which usually means its Redis service is down." : nil,
            metrics: [
                DashboardMetric(title: "Active channels", value: "\(channels)", systemImage: "dot.radiowaves.left.and.right", health: unhealthy > 0 ? .warning : nil),
                DashboardMetric(title: "Viewers", value: "\(viewers)", systemImage: "person.2"),
                DashboardMetric(title: "On-demand sessions", value: "\((overview.stats?.vod?.total_connections ?? 0) + (overview.stats?.catchup?.total_connections ?? 0))", systemImage: "play.rectangle"),
                DashboardMetric(title: "Errors (24 h)", value: "\(overview.errorEvents.count)", systemImage: "exclamationmark.triangle", health: overview.errorEvents.isEmpty ? .ok : .warning),
            ],
            actions: [
                DashboardAction(id: "backup", title: "Create Backup…", systemImage: "archivebox", targetKind: "Backup", targetName: "Dispatcharr database and settings",
                                consequence: "Dispatcharr writes a new backup file on its server. The app waits for it to finish and reports a failure if it doesn't.") {
                    try await operations.createBackup()
                },
            ],
            sections: [
                DashboardSection(id: "events", title: "Recent Errors", systemImage: "exclamationmark.triangle", trailing: "\(overview.errorEvents.count)", emptyText: "No errors in the last 24 hours.",
                                 rows: overview.errorEvents.map { event in
                                     DashboardRow(id: "event:\(event.id)", title: event.event_type_display ?? event.event_type.replacingOccurrences(of: "_", with: " ").capitalizedFirst,
                                                  detail: APIDate.parse(event.timestamp).map(Format.relative), health: .warning)
                                 }),
                backupSection(overview.backups),
                DashboardSection(id: "playlists", title: "Playlist Sources", systemImage: "list.bullet.rectangle", trailing: "\(overview.playlists.count)", emptyText: "No playlist sources.",
                                 rows: sourceRows(overview.playlists, prefix: "m3u")),
                DashboardSection(id: "guides", title: "Guide Sources", systemImage: "calendar", trailing: "\(overview.guides.count)", emptyText: "No guide sources.",
                                 rows: sourceRows(overview.guides, prefix: "epg")),
            ]
        )
    }
}
