import Foundation

struct TracearrHealth: Decodable, Sendable {
    struct Server: Decodable, Sendable {
        var id: String
        var name: String
        var type: String
        var online: Bool
        var activeStreams: Int?
    }
    var version: String?
    var servers: [Server]
}

struct TracearrToday: Decodable, Sendable {
    var activeStreams: Int?
    var todayPlays: Int?
    var watchTimeHours: Double?
    var alertsLast24h: Int?
    var activeUsersToday: Int?
}

struct TracearrStream: Decodable, Sendable {
    var id: String
    var serverName: String?
    var username: String
    var mediaTitle: String
    var mediaType: String?
    var showTitle: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var state: String
    var progressMs: Double?
    var durationMs: Double?
    var videoDecision: String?
    var isTranscode: Bool?
    var bitrate: Double?
    var resolution: String?
    var player: String?
    var product: String?
    var transcodeInfo: TranscodeInfo?

    /// How the media server is converting this stream, when it's transcoding.
    struct TranscodeInfo: Decodable, Sendable {
        var hwRequested: Bool?
        var hwDecoding: String?
        var hwEncoding: String?
        var speed: Double?
        var throttled: Bool?
        var reasons: [String]?

        /// Hardware was asked for but neither side uses it: the server fell back to the CPU.
        var fellBackToSoftware: Bool { hwRequested == true && (hwDecoding?.nilIfEmpty == nil) && (hwEncoding?.nilIfEmpty == nil) }
        /// Below real time and not deliberately throttled, so playback will buffer.
        var isFallingBehind: Bool { (speed ?? 1) < 1 && throttled != true }

        var summary: String? {
            var parts: [String] = []
            if let encoder = hwEncoding?.nilIfEmpty ?? hwDecoding?.nilIfEmpty { parts.append("Hardware (\(encoder))") } else if hwRequested == true { parts.append("Software fallback") }
            if let speed { parts.append(String(format: "%.1f×", speed) + (throttled == true ? " throttled" : "")) }
            if let reason = reasons?.first?.nilIfEmpty { parts.append(reason) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    var displayTitle: String {
        guard let show = showTitle?.nilIfEmpty else { return mediaTitle }
        let episode = [seasonNumber.map { String(format: "S%02d", $0) }, episodeNumber.map { String(format: "E%02d", $0) }].compactMap { $0 }.joined()
        return "\(show) · \(episode.isEmpty ? "" : episode + " ")\(mediaTitle)"
    }
}

struct TracearrViolation: Decodable, Sendable {
    struct Rule: Decodable, Sendable { var name: String? }
    struct User: Decodable, Sendable { var username: String }
    var id: String
    var serverName: String?
    var severity: String?
    var acknowledged: Bool
    var createdAt: String?
    var rule: Rule?
    var user: User?
}

/// `GET /public/activity` quality breakdown and concurrency peaks for a period.
struct TracearrActivity: Decodable, Sendable {
    struct Quality: Decodable, Sendable {
        var directPlayPercent: Int
        var directStreamPercent: Int
        var transcodePercent: Int
        var total: Int
    }
    struct Bucket: Decodable, Sendable { var total: Int; var transcode: Int }
    var quality: Quality
    var concurrent: [Bucket]

    var peakConcurrent: Int { concurrent.map(\.total).max() ?? 0 }
    var peakTranscodes: Int { concurrent.map(\.transcode).max() ?? 0 }
}

struct TracearrOverview: Sendable {
    var health: TracearrHealth
    var today: TracearrToday?
    var streams: [TracearrStream]
    var violations: [TracearrViolation]
    /// nil on releases or keys that can't read activity.
    var activity: TracearrActivity?
}

protocol TracearrOperations: Sendable {
    func terminate(streamID: String, reason: String) async throws
}

/// Tracearr's public API v1 (1.4.6+, still served by 2.x): health, streams, violations and stream termination with an owner's `trr_pub_` key.
struct TracearrClient: DashboardService, TracearrOperations {
    let kind = IntegrationKind.tracearr
    static let terminationReason = "Stopped by the server owner."
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api/v1/public"), pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(apiKey)"])
    }

    private struct DataList<Item: Decodable>: Decodable { var data: [Item] }

    func overview() async throws -> TracearrOverview {
        async let health = rest.json(.get("health"), as: TracearrHealth.self)
        async let today = try? rest.json(.get("stats/today", query: [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]), as: TracearrToday.self)
        async let streams = rest.json(.get("streams"), as: DataList<TracearrStream>.self)
        async let violations = rest.json(.get("violations", query: [URLQueryItem(name: "acknowledged", value: "false"), URLQueryItem(name: "pageSize", value: "25")]),
                                         as: DataList<TracearrViolation>.self)
        async let activity = try? rest.json(.get("activity", query: [URLQueryItem(name: "period", value: "week"), URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]),
                                            as: TracearrActivity.self)
        return try await TracearrOverview(health: health, today: today, streams: streams.data, violations: violations.data, activity: await activity)
    }

    func dashboard() async throws -> DashboardSnapshot {
        TracearrDashboard.snapshot(try await overview(), operations: self)
    }

    private struct Reason: Encodable { var reason: String }

    func terminate(streamID: String, reason: String) async throws {
        _ = try await rest.data(try .post("streams/\(streamID)/terminate", json: Reason(reason: reason)))
    }
}

enum TracearrDashboard {
    static func activitySection(_ activity: TracearrActivity?) -> DashboardSection {
        guard let activity else {
            return DashboardSection(id: "activity", title: "Playback This Week", systemImage: "chart.bar", emptyText: "Activity isn't available from this Tracearr release.", rows: [])
        }
        let quality = activity.quality
        return DashboardSection(id: "activity", title: "Playback This Week", systemImage: "chart.bar", trailing: "\(quality.total) plays", emptyText: "", rows: [
            DashboardRow(id: "quality", title: "\(quality.directPlayPercent)% direct play · \(quality.directStreamPercent)% direct stream · \(quality.transcodePercent)% transcode",
                         subtitle: "Share of plays by how the server delivered them",
                         health: quality.transcodePercent >= 50 ? .warning : .ok),
            DashboardRow(id: "peak", title: "Peak \(activity.peakConcurrent) at once", subtitle: "Up to \(activity.peakTranscodes) transcoding at the same time"),
        ])
    }

    static func snapshot(_ overview: TracearrOverview, operations: some TracearrOperations) -> DashboardSnapshot {
        let servers = overview.health.servers
        let offline = servers.filter { !$0.online }
        let streams = overview.streams
        let transcodes = streams.filter { $0.isTranscode == true || $0.videoDecision == "transcode" }.count
        let high = overview.violations.filter { $0.severity == "high" }

        return DashboardSnapshot(
            version: overview.health.version,
            health: !offline.isEmpty ? .critical : (overview.violations.isEmpty ? .ok : .warning),
            headline: "\(streams.count) stream\(streams.count == 1 ? "" : "s")" + (overview.violations.isEmpty ? "" : " · \(overview.violations.count) open violation\(overview.violations.count == 1 ? "" : "s")"),
            detail: offline.isEmpty ? nil : "Offline: " + offline.map(\.name).joined(separator: ", "),
            metrics: [
                DashboardMetric(title: "Streams", value: "\(streams.count)", systemImage: "play.tv"),
                DashboardMetric(title: "Transcodes", value: "\(transcodes)", systemImage: "cpu"),
                DashboardMetric(title: "Plays today", value: overview.today?.todayPlays.map { $0.formatted() } ?? "—", systemImage: "chart.bar"),
                DashboardMetric(title: "Open violations", value: "\(overview.violations.count)", systemImage: "exclamationmark.shield", health: high.isEmpty ? (overview.violations.isEmpty ? .ok : .unknown) : .warning),
            ],
            sections: [
                DashboardSection(id: "streams", title: "Now Playing", systemImage: "play.circle", trailing: "\(streams.count)", emptyText: "Nothing is playing.",
                                 rows: streams.map { stream in
                                     let decision = stream.isTranscode == true || stream.videoDecision == "transcode" ? "Transcode" : (stream.videoDecision == "copy" ? "Direct stream" : "Direct play")
                                     return DashboardRow(
                                         id: stream.id, title: stream.displayTitle,
                                         subtitle: [stream.username, stream.player ?? stream.product, stream.serverName].compactMap { $0 }.joined(separator: " · "),
                                         detail: [decision, stream.resolution, stream.bitrate.map { String(format: "%.1f Mbps", $0 / 1000) }].compactMap { $0 }.joined(separator: " · "),
                                         health: stream.transcodeInfo.map { $0.fellBackToSoftware || $0.isFallingBehind ? .warning : .ok },
                                         badge: stream.state.capitalizedFirst,
                                         progress: stream.durationMs.flatMap { $0 > 0 ? (stream.progressMs ?? 0) / $0 : nil },
                                         message: stream.transcodeInfo?.summary,
                                         actions: [DashboardAction(id: "stop:\(stream.id)", title: "Stop Stream…", systemImage: "stop.circle", targetKind: "Stream", targetName: "\(stream.username) — \(stream.displayTitle)",
                                                                   consequence: "\(stream.serverName ?? "The media server") stops \(stream.username)'s playback now, and Tracearr records it as a manual termination.",
                                                                   confirmation: .destructive) {
                                             try await operations.terminate(streamID: stream.id, reason: TracearrClient.terminationReason)
                                         }])
                                 }),
                activitySection(overview.activity),
                DashboardSection(id: "violations", title: "Open Violations", systemImage: "exclamationmark.shield", trailing: "\(overview.violations.count)",
                                 emptyText: "No unacknowledged violations. Acknowledge them in Tracearr; its public API doesn't allow it.",
                                 rows: overview.violations.map { violation in
                                     DashboardRow(id: violation.id, title: violation.rule?.name ?? "Rule violation",
                                                  subtitle: [violation.user?.username, violation.serverName].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                  detail: APIDate.parse(violation.createdAt).map { Format.relative($0) },
                                                  health: violation.severity == "high" ? .warning : .unknown, badge: violation.severity?.capitalizedFirst)
                                 }),
                DashboardSection(id: "servers", title: "Media Servers", systemImage: "server.rack", trailing: "\(servers.count)", emptyText: "No media servers are connected.",
                                 rows: servers.map { server in
                                     DashboardRow(id: server.id, title: server.name, subtitle: server.type.capitalizedFirst,
                                                  detail: server.activeStreams.map { "\($0) active stream\($0 == 1 ? "" : "s")" },
                                                  health: server.online ? .ok : .critical, badge: server.online ? "Online" : "Offline")
                                 }),
            ]
        )
    }
}
