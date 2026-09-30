import Foundation

/// Tautulli passes many Plex attributes through as strings ("27", "25318", "") and computes others as numbers.
struct LooseNumber: Decodable, Sendable, Equatable {
    var value: Double?

    init(_ value: Double?) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }

    var int: Int? { value.map { Int($0) } }
}

struct TautulliEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    struct Response: Decodable, Sendable {
        var result: String
        var message: String?
        var data: Value?
    }
    var response: Response
}

struct TautulliInfo: Decodable, Sendable {
    var tautulli_version: String
}

struct TautulliServerInfo: Decodable, Sendable {
    var pms_name: String?
    var pms_version: String?
}

struct TautulliServerStatus: Decodable, Sendable {
    var connected: Bool?
}

struct TautulliSession: Decodable, Sendable {
    var session_id: String?
    var session_key: LooseNumber?
    var friendly_name: String?
    var user: String?
    var full_title: String?
    var title: String?
    var media_type: String?
    var state: String?
    var progress_percent: LooseNumber?
    var player: String?
    var platform: String?
    var product: String?
    var transcode_decision: String?
    var stream_video_full_resolution: String?
    var quality_profile: String?
    var location: String?
    var bandwidth: LooseNumber?
    var transcode_hw_encoding: LooseNumber?
    var audio_decision: String?
    var subtitle_decision: String?
    var stream_audio_codec: String?
    var audio_language: String?
    var stream_audio_channel_layout: String?
    var subtitle_language: String?
    var subtitle_codec: String?
    var stream_subtitle_codec: String?

    static func decision(_ value: String?) -> String? {
        switch value {
        case "direct play": "direct"
        case "copy": "copied"
        case "transcode": "transcoded"
        case "burn": "burned in"
        default: value?.nilIfEmpty
        }
    }

    /// e.g. "Audio: English AAC 5.1 (transcoded) · Subtitles: English SRT (burned in)".
    var tracks: String? {
        var parts: [String] = []
        if let codec = stream_audio_codec?.nilIfEmpty {
            let audio = [audio_language?.nilIfEmpty, codec.uppercased(), stream_audio_channel_layout?.nilIfEmpty].compactMap { $0 }.joined(separator: " ")
            parts.append("Audio: \(audio)" + (Self.decision(audio_decision).map { " (\($0))" } ?? ""))
        }
        if let codec = (stream_subtitle_codec?.nilIfEmpty ?? subtitle_codec?.nilIfEmpty) {
            let subtitle = [subtitle_language?.nilIfEmpty, codec.uppercased()].compactMap { $0 }.joined(separator: " ")
            parts.append("Subtitles: \(subtitle)" + (Self.decision(subtitle_decision).map { " (\($0))" } ?? ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var decisionName: String? {
        switch transcode_decision {
        case "direct play": "Direct play"
        case "copy": "Direct stream"
        case "transcode": transcode_hw_encoding?.int == 1 ? "Transcode (hardware)" : "Transcode"
        default: transcode_decision?.capitalizedFirst
        }
    }
}

struct TautulliActivity: Decodable, Sendable {
    var stream_count: LooseNumber?
    var stream_count_direct_play: LooseNumber?
    var stream_count_direct_stream: LooseNumber?
    var stream_count_transcode: LooseNumber?
    var total_bandwidth: LooseNumber?
    var lan_bandwidth: LooseNumber?
    var wan_bandwidth: LooseNumber?
    var sessions: [TautulliSession]?
}

struct TautulliLibrary: Decodable, Sendable {
    var section_id: LooseNumber
    var section_name: String
    var section_type: String
    var count: LooseNumber?
    var parent_count: LooseNumber?
    var child_count: LooseNumber?
    var is_active: LooseNumber?

    var countSummary: String {
        let count = self.count?.int ?? 0
        switch section_type {
        case "show": return "\(count.formatted()) shows · \((child_count?.int ?? 0).formatted()) episodes"
        case "artist": return "\(count.formatted()) artists · \((child_count?.int ?? 0).formatted()) tracks"
        case "movie": return "\(count.formatted()) movies"
        case "photo": return "\(count.formatted()) photo albums"
        default: return "\(count.formatted()) items"
        }
    }
}

struct TautulliHistory: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        var row_id: LooseNumber?
        var full_title: String?
        var friendly_name: String?
        var player: String?
        var started: LooseNumber?
        var percent_complete: LooseNumber?
        var transcode_decision: String?
    }
    var data: [Row]
    var recordsTotal: Int?
}

/// One block of `get_home_stats`; rows differ per stat, so only shared fields are read.
struct TautulliHomeStat: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        var title: String?
        var friendly_name: String?
        var user: String?
        var platform: String?
        var total_plays: LooseNumber?
        var total_duration: LooseNumber?
    }
    var stat_id: String
    var rows: [Row]?
}

struct TautulliPlaysByDate: Decodable, Sendable {
    struct Series: Decodable, Sendable {
        var name: String
        var data: [LooseNumber]
    }
    var categories: [String]
    var series: [Series]
}

/// Watch history over a period, from Tautulli's graph and home-stat commands.
struct WatchStatistics: Sendable {
    struct Day: Sendable, Identifiable {
        var date: Date
        var plays: Int
        var id: Date { date }
    }
    struct Ranked: Sendable, Identifiable, Hashable {
        var name: String
        var plays: Int
        var duration: TimeInterval?
        var id: String { name }
    }
    var days: [Day]
    var playsByType: [(type: String, plays: Int)]
    var topMovies: [Ranked]
    var topShows: [Ranked]
    var topUsers: [Ranked]
    var topPlatforms: [Ranked]

    var totalPlays: Int { days.reduce(0) { $0 + $1.plays } }
    var busiestDay: Day? { days.max { $0.plays < $1.plays } }

    static func make(plays: TautulliPlaysByDate?, stats: [TautulliHomeStat], calendar: Calendar = .current) -> WatchStatistics {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let series = plays?.series ?? []
        let days = (plays?.categories ?? []).enumerated().compactMap { index, category in
            formatter.date(from: category).map { Day(date: $0, plays: series.reduce(0) { $0 + ($1.data.indices.contains(index) ? $1.data[index].int ?? 0 : 0) }) }
        }
        let byType = series.map { ($0.name, $0.data.reduce(0) { $0 + ($1.int ?? 0) }) }.filter { $0.1 > 0 }
        func ranked(_ id: String, name: (TautulliHomeStat.Row) -> String?) -> [Ranked] {
            (stats.first { $0.stat_id == id }?.rows ?? []).compactMap { row in
                name(row)?.nilIfEmpty.map { Ranked(name: $0, plays: row.total_plays?.int ?? 0, duration: row.total_duration?.value) }
            }
        }
        return WatchStatistics(days: days, playsByType: byType,
                               topMovies: ranked("top_movies") { $0.title }, topShows: ranked("top_tv") { $0.title },
                               topUsers: ranked("top_users") { $0.friendly_name ?? $0.user }, topPlatforms: ranked("top_platforms") { $0.platform })
    }
}

struct WatchUser: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// One person's totals from `get_user_watch_time_stats` and `get_user_player_stats`.
struct WatchUserSummary: Sendable, Equatable {
    struct Period: Sendable, Equatable, Identifiable {
        var days: Int
        var plays: Int
        var seconds: TimeInterval
        var id: Int { days }
        var title: String {
            switch days {
            case 0: "All time"
            case 1: "Last 24 hours"
            default: "Last \(days) days"
            }
        }
    }
    var periods: [Period]
    var players: [WatchStatistics.Ranked]
}

struct TautulliUser: Decodable, Sendable {
    var user_id: LooseNumber?
    var username: String?
    var is_active: LooseNumber?
}

struct TautulliWatchTime: Decodable, Sendable {
    var query_days: LooseNumber?
    var total_plays: LooseNumber?
    var total_time: LooseNumber?
}

struct TautulliPlayerStat: Decodable, Sendable {
    var player_name: String?
    var platform: String?
    var total_plays: LooseNumber?
    var total_time: LooseNumber?
}

protocol WatchStatisticsSource: Sendable {
    /// `days` is the look-back window; `userID` limits everything to one person.
    func statistics(days: Int, userID: String?) async throws -> WatchStatistics
    func watchUsers() async throws -> [WatchUser]
    func userSummary(userID: String) async throws -> WatchUserSummary
}

extension WatchUserSummary {
    static func make(watchTime: [TautulliWatchTime], players: [TautulliPlayerStat]) -> WatchUserSummary {
        WatchUserSummary(
            periods: watchTime.compactMap { row in
                row.query_days?.int.map { Period(days: $0, plays: row.total_plays?.int ?? 0, seconds: row.total_time?.value ?? 0) }
            },
            players: players.compactMap { row in
                (row.player_name?.nilIfEmpty ?? row.platform?.nilIfEmpty).map { WatchStatistics.Ranked(name: $0, plays: row.total_plays?.int ?? 0, duration: row.total_time?.value) }
            }
        )
    }

    static func users(_ rows: [TautulliUser]) -> [WatchUser] {
        rows.compactMap { row in
            guard let id = row.user_id?.int, id != 0, row.is_active?.int != 0, let name = row.username?.nilIfEmpty else { return nil }
            return WatchUser(id: String(id), name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// `get_logs` line. Messages are redacted before display: without Tautulli's log blacklist they can contain tokens.
struct TautulliLogLine: Decodable, Sendable, Equatable {
    var loglevel: String?
    var msg: String?
    var time: String?

    var isProblem: Bool { ["ERROR", "WARNING", "CRITICAL"].contains(loglevel?.uppercased() ?? "") }
}

/// `get_notification_log` rows; only delivery fields are decoded, never the notification text or the user.
struct TautulliNotificationLog: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        var agent_name: String?
        var notify_action: String?
        var success: LooseNumber?
        var timestamp: LooseNumber?
    }
    var data: [Row]
}

struct TautulliDeliveryFailure: Sendable, Equatable {
    var agent: String
    var failures: Int
    var attempts: Int
    var lastFailure: Date?

    /// Groups the most recent notifications by agent and keeps the agents with at least one failure.
    static func summarize(_ rows: [TautulliNotificationLog.Row]) -> [TautulliDeliveryFailure] {
        Dictionary(grouping: rows) { $0.agent_name?.nilIfEmpty ?? "unknown" }
            .compactMap { agent, rows in
                let failed = rows.filter { $0.success?.int == 0 }
                guard !failed.isEmpty else { return nil }
                return TautulliDeliveryFailure(agent: agent, failures: failed.count, attempts: rows.count,
                                               lastFailure: failed.compactMap { $0.timestamp?.value }.max().map { Date(timeIntervalSince1970: $0) })
            }
            .sorted { $0.failures > $1.failures }
    }
}

struct TautulliOverview: Sendable {
    var version: String?
    var server: TautulliServerInfo?
    var plexReachable: Bool
    var activity: TautulliActivity
    var libraries: [TautulliLibrary]
    var history: [TautulliHistory.Row]
    var stats: [TautulliHomeStat] = []
    /// nil when the log couldn't be read.
    var problems: [TautulliLogLine]?
    var deliveryFailures: [TautulliDeliveryFailure]?
}

enum TautulliMaintenance: String, Sendable {
    case refreshLibraries = "refresh_libraries_list"
    case refreshUsers = "refresh_users_list"
    case backupDatabase = "backup_db"
}

protocol TautulliOperations: Sendable {
    func terminate(sessionID: String, message: String) async throws
    func run(_ maintenance: TautulliMaintenance) async throws
}

/// Tautulli API v2 (`/api/v2?cmd=…`). The key goes in the `apikey` parameter, which every 2.x release accepts.
struct TautulliClient: DashboardService, TautulliOperations, WatchStatisticsSource {
    let kind = IntegrationKind.tautulli
    static let terminationMessage = "The server owner has ended this stream."
    private let rest: RESTClient
    private let apiKey: String

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint)
        self.apiKey = apiKey
    }

    private func command<Value: Decodable & Sendable>(_ name: String, _ parameters: [String: String] = [:], as type: Value.Type) async throws -> Value? {
        let query = [URLQueryItem(name: "apikey", value: apiKey), URLQueryItem(name: "cmd", value: name)]
            + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await rest.raw(.get("api/v2", query: query))
        let envelope = try? JSONDecoder().decode(TautulliEnvelope<Value>.self, from: data)
        if response.statusCode == 401 { throw NetworkError.unauthorized }
        if let envelope, envelope.response.result == "error" {
            let message = envelope.response.message ?? "Tautulli reported an error."
            throw response.statusCode == 404 ? NetworkError.unsupportedByServer("\(message). Turn on the API in Tautulli › Settings › Web Interface.") : NetworkError.graphQL([message])
        }
        try RESTClient.validate(response, data: data)
        return try RESTClient.decode(TautulliEnvelope<Value>.self, from: data).response.data
    }

    private struct Empty: Decodable, Sendable {}

    func overview() async throws -> TautulliOverview {
        async let info = command("get_tautulli_info", as: TautulliInfo.self)
        async let server = command("get_server_info", as: TautulliServerInfo.self)
        async let status = command("server_status", as: TautulliServerStatus.self)
        async let activity = command("get_activity", as: TautulliActivity.self)
        async let libraries = command("get_libraries", as: [TautulliLibrary].self)
        async let history = command("get_history", ["length": "10", "order_column": "date", "order_dir": "desc"], as: TautulliHistory.self)
        async let stats = try? command("get_home_stats", ["time_range": "30", "stats_count": "5", "stats_type": "plays"], as: [TautulliHomeStat].self)
        // Filtering happens here rather than with `regex`, whose ordering against slicing changed between releases.
        async let logs = try? command("get_logs", ["order": "desc", "start": "0", "end": "200"], as: [TautulliLogLine].self)
        async let notifications = try? command("get_notification_log", ["order_column": "timestamp", "order_dir": "desc", "length": "50"], as: TautulliNotificationLog.self)
        let problems = (await logs ?? nil).map { Array($0.filter(\.isProblem).prefix(10)) }
        let deliveries = (await notifications ?? nil).map { TautulliDeliveryFailure.summarize($0.data) }
        return try await TautulliOverview(
            version: info?.tautulli_version,
            server: server,
            plexReachable: status?.connected ?? false,
            activity: activity ?? TautulliActivity(),
            libraries: libraries ?? [],
            history: history?.data ?? [],
            stats: (await stats ?? nil) ?? [],
            problems: problems,
            deliveryFailures: deliveries
        )
    }

    func dashboard() async throws -> DashboardSnapshot {
        TautulliDashboard.snapshot(try await overview(), operations: self)
    }

    func statistics(days: Int, userID: String?) async throws -> WatchStatistics {
        let user = userID.map { ["user_id": $0] } ?? [:]
        async let plays = command("get_plays_by_date", ["time_range": String(days), "y_axis": "plays"].merging(user) { $1 }, as: TautulliPlaysByDate.self)
        async let stats = command("get_home_stats", ["time_range": String(days), "stats_count": "5", "stats_type": "plays"].merging(user) { $1 }, as: [TautulliHomeStat].self)
        return try await WatchStatistics.make(plays: plays, stats: stats ?? [])
    }

    func watchUsers() async throws -> [WatchUser] {
        WatchUserSummary.users(try await command("get_users", as: [TautulliUser].self) ?? [])
    }

    func userSummary(userID: String) async throws -> WatchUserSummary {
        async let watchTime = command("get_user_watch_time_stats", ["user_id": userID, "query_days": "1,7,30,0"], as: [TautulliWatchTime].self)
        async let players = command("get_user_player_stats", ["user_id": userID], as: [TautulliPlayerStat].self)
        return try await WatchUserSummary.make(watchTime: watchTime ?? [], players: players ?? [])
    }

    func terminate(sessionID: String, message: String) async throws {
        _ = try await command("terminate_session", ["session_id": sessionID, "message": message], as: Empty.self)
    }

    func run(_ maintenance: TautulliMaintenance) async throws {
        _ = try await command(maintenance.rawValue, as: Empty.self)
    }
}

enum TautulliDashboard {
    static func statSection(_ overview: TautulliOverview, id: String, title: String, systemImage: String, name: (TautulliHomeStat.Row) -> String?) -> DashboardSection {
        let rows = overview.stats.first { $0.stat_id == id }?.rows ?? []
        return DashboardSection(id: id, title: title, systemImage: systemImage, emptyText: "No plays in the last 30 days.",
                                rows: rows.enumerated().map { index, row in
                                    DashboardRow(id: "\(id):\(index)", title: name(row) ?? "Unknown",
                                                 detail: row.total_duration?.value.map { "\(Format.duration($0)) watched" },
                                                 badge: row.total_plays?.int.map { "\($0) plays" })
                                })
    }

    static func mbps(_ kbps: Double?) -> String {
        String(format: "%.1f Mbps", (kbps ?? 0) / 1000)
    }

    static func snapshot(_ overview: TautulliOverview, operations: some TautulliOperations) -> DashboardSnapshot {
        let activity = overview.activity
        let sessions = activity.sessions ?? []
        let transcodes = activity.stream_count_transcode?.int ?? 0

        return DashboardSnapshot(
            version: overview.version,
            health: overview.plexReachable ? .ok : .critical,
            headline: overview.plexReachable ? "\(sessions.count) stream\(sessions.count == 1 ? "" : "s") · \(mbps(activity.total_bandwidth?.value))" : "Plex server unreachable",
            detail: overview.server.map { [$0.pms_name, $0.pms_version.map { "Plex \($0)" }].compactMap { $0 }.joined(separator: " · ") }?.nilIfEmpty,
            notice: overview.plexReachable ? nil : "Tautulli can't reach its Plex Media Server, so activity may be out of date.",
            metrics: [
                DashboardMetric(title: "Streams", value: "\(sessions.count)", systemImage: "play.tv"),
                DashboardMetric(title: "Direct play / stream", value: "\(activity.stream_count_direct_play?.int ?? 0) / \(activity.stream_count_direct_stream?.int ?? 0)", systemImage: "arrow.right.circle"),
                DashboardMetric(title: "Transcodes", value: "\(transcodes)", systemImage: "cpu"),
                DashboardMetric(title: "Bandwidth (LAN / WAN)", value: "\(mbps(activity.lan_bandwidth?.value)) / \(mbps(activity.wan_bandwidth?.value))", systemImage: "network"),
            ],
            actions: [
                DashboardAction(id: "refresh-libraries", title: "Refresh Libraries List", systemImage: "books.vertical", targetKind: "Tautulli", targetName: "Libraries list",
                                consequence: "Tautulli reads the current library list from Plex.", confirmation: .none) { try await operations.run(.refreshLibraries) },
                DashboardAction(id: "refresh-users", title: "Refresh Users List", systemImage: "person.2", targetKind: "Tautulli", targetName: "Users list",
                                consequence: "Tautulli reads the current list of users who can access your Plex server.", confirmation: .none) { try await operations.run(.refreshUsers) },
                DashboardAction(id: "backup-db", title: "Back Up Database…", systemImage: "archivebox", targetKind: "Tautulli", targetName: "plexpy.db",
                                consequence: "Tautulli writes a backup copy of its database to its backup folder.") { try await operations.run(.backupDatabase) },
            ],
            sections: [
                DashboardSection(id: "sessions", title: "Now Playing", systemImage: "play.circle", trailing: "\(sessions.count)", emptyText: "Nothing is playing.",
                                 rows: sessions.enumerated().map { index, session in
                                     let title = session.full_title ?? session.title ?? "Unknown"
                                     let who = session.friendly_name ?? session.user ?? "Someone"
                                     let quality = [session.stream_video_full_resolution?.nilIfEmpty, session.quality_profile].compactMap { $0 }.joined(separator: " ")
                                     return DashboardRow(
                                         id: session.session_id ?? "session-\(index)",
                                         title: title,
                                         subtitle: [who, session.player, session.product ?? session.platform].compactMap { $0 }.joined(separator: " · "),
                                         detail: [session.decisionName, quality.nilIfEmpty, session.location?.uppercased(), session.bandwidth?.value.map { mbps($0) }].compactMap { $0 }.joined(separator: " · "),
                                         health: session.transcode_decision == "transcode" ? .unknown : .ok,
                                         badge: session.state?.capitalizedFirst,
                                         progress: session.progress_percent?.value.map { $0 / 100 },
                                         message: session.tracks,
                                         actions: session.session_id.map { sessionID in
                                             [DashboardAction(id: "stop:\(sessionID)", title: "Stop Stream…", systemImage: "stop.circle", targetKind: "Stream", targetName: "\(who) — \(title)",
                                                              consequence: "Plex stops playback on \(session.player ?? "the viewer's device") and shows “\(TautulliClient.terminationMessage)” Plex allows this only on servers with an active Plex Pass.",
                                                              confirmation: .destructive) {
                                                 try await operations.terminate(sessionID: sessionID, message: TautulliClient.terminationMessage)
                                             }]
                                         } ?? []
                                     )
                                 }),
                DashboardSection(id: "history", title: "Recently Watched", systemImage: "clock.arrow.circlepath", emptyText: "No plays recorded yet.",
                                 rows: overview.history.enumerated().map { index, row in
                                     DashboardRow(id: "h\(row.row_id?.int ?? index)", title: row.full_title ?? "Unknown",
                                                  subtitle: [row.friendly_name, row.player].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                  detail: [row.started?.value.map { Format.relative(Date(timeIntervalSince1970: $0)) }, row.percent_complete?.int.map { "\($0)% watched" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
                                 }),
                DashboardSection(id: "problems", title: "Recent Problems", systemImage: "exclamationmark.triangle", trailing: overview.problems.map { "\($0.count)" },
                                 emptyText: overview.problems == nil ? "Tautulli's log couldn't be read with this key." : "No warnings or errors in the latest 200 log lines.",
                                 rows: (overview.problems ?? []).enumerated().map { index, line in
                                     DashboardRow(id: "log\(index)", title: LogRedactor.redact(line.msg ?? "").trimmingCharacters(in: .whitespaces),
                                                  subtitle: line.time?.trimmingCharacters(in: .whitespaces),
                                                  health: line.loglevel?.uppercased() == "WARNING" ? .warning : .critical, badge: line.loglevel?.capitalized)
                                 }),
                DashboardSection(id: "notifications", title: "Notification Delivery", systemImage: "bell.badge",
                                 emptyText: overview.deliveryFailures == nil ? "The notification log isn't available with this key." : "The latest 50 notifications were all delivered.",
                                 rows: (overview.deliveryFailures ?? []).map { failure in
                                     DashboardRow(id: "agent:\(failure.agent)", title: failure.agent.capitalizedFirst,
                                                  subtitle: "\(failure.failures) of the latest \(failure.attempts) failed",
                                                  detail: failure.lastFailure.map { "Last failure \(Format.relative($0))" }, health: .warning)
                                 }),
                statSection(overview, id: "top_users", title: "Top Users (30 Days)", systemImage: "person.2") { $0.friendly_name ?? $0.user },
                statSection(overview, id: "top_platforms", title: "Top Platforms (30 Days)", systemImage: "rectangle.on.rectangle") { $0.platform },
                DashboardSection(id: "libraries", title: "Libraries", systemImage: "books.vertical", trailing: "\(overview.libraries.count)", emptyText: "Tautulli hasn't loaded any libraries.",
                                 rows: overview.libraries.map { library in
                                     DashboardRow(id: "l\(library.section_id.int ?? 0)", title: library.section_name, subtitle: library.countSummary,
                                                  badge: library.is_active?.int == 0 ? "Inactive" : nil)
                                 }),
            ]
        )
    }
}
