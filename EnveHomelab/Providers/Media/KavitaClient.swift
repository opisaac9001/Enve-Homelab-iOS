import Foundation
import os

struct KavitaLibrary: Decodable, Sendable {
    var id: Int
    var name: String
    var type: Int
    var lastScanned: String?

    var typeName: String {
        switch type {
        case 0: "Manga"
        case 1, 5: "Comics"
        case 2: "Books"
        case 3: "Images"
        case 4: "Light novels"
        default: "Library"
        }
    }
}

struct KavitaServerStats: Decodable, Sendable {
    var seriesCount: Int64
    var volumeCount: Int64
    var chapterCount: Int64
    var totalFiles: Int64
    var totalSize: Int64
}

struct KavitaSeries: Decodable, Sendable {
    var id: Int
    var name: String
    var libraryName: String?
    var created: String?
}

struct KavitaMediaError: Decodable, Sendable {
    var filePath: String
    var comment: String?
}

struct KavitaReadingSession: Decodable, Sendable {
    struct Activity: Decodable, Sendable {
        var seriesName: String?
        var chapterTitle: String?
        var libraryName: String?
        var endPage: Int?
        var totalPages: Int?
        var clientInfo: KavitaClientInfo?
    }

    var id: Int
    var username: String?
    var isActive: Bool
    var activityData: [Activity]
}

/// Only the optional descriptive fields are read; the rest of the object varies by client.
struct KavitaClientInfo: Decodable, Sendable {
    var platform: String?
    var browser: String?
}

struct KavitaRecurringJob: Decodable, Sendable {
    var id: String
    var title: String
    var lastExecutionUtc: String?
    var cron: String?
}

struct KavitaOverview: Sendable {
    var version: String?
    var libraries: [KavitaLibrary]
    var recentSeries: [KavitaSeries]
    var totalSeries: Int?
    /// Admin-only data; nil when the key's user isn't an admin.
    var admin: Admin?

    struct Admin: Sendable {
        var stats: KavitaServerStats
        var mediaErrors: [KavitaMediaError]
        var sessions: [KavitaReadingSession]
        var jobs: [KavitaRecurringJob]
        var update: ServerMaintenance.Update = .unknown
    }
}

/// `GET /api/Server/check-update` (admin); empty when Kavita couldn't reach GitHub.
struct KavitaUpdateNotification: Decodable, Sendable {
    var currentVersion: String?
    var updateVersion: String?
    var isReleaseNewer: Bool?
}

protocol KavitaOperations: Sendable {
    func scan(libraryID: Int, force: Bool) async throws
    func scanAll() async throws
    /// Runs Kavita's own backup job once; it only adds a file to the backup folder.
    func backUpDatabase() async throws
}

/// Kavita's documented plugin flow: exchange the user's auth key for a JWT, then use Bearer auth.
final class KavitaClient: DashboardService, KavitaOperations {
    let kind = IntegrationKind.kavita
    static let pluginName = "Enve Homelab"
    private let rest: RESTClient
    private let apiKey: String
    private let session = OSAllocatedUnfairLock<(token: String?, version: String?)>(initialState: (nil, nil))

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint)
        self.apiKey = apiKey
    }

    private struct PluginUser: Decodable {
        var token: String
        var kavitaVersion: String?
    }

    private func authenticate() async throws -> String {
        let user = try await rest.json(.post("api/Plugin/authenticate", query: [
            URLQueryItem(name: "apiKey", value: apiKey), URLQueryItem(name: "pluginName", value: Self.pluginName),
        ]), as: PluginUser.self)
        session.withLock { $0 = (user.token, user.kavitaVersion) }
        return user.token
    }

    /// Sends a request with the cached token, signing in again once if it has expired.
    private func authorized(_ request: RESTRequest) async throws -> (Data, HTTPURLResponse) {
        var token: String
        if let cached = session.withLock(\.token) {
            token = cached
        } else {
            token = try await authenticate()
        }
        for attempt in 0..<2 {
            var signed = request
            signed.headers["Authorization"] = "Bearer \(token)"
            let (data, response) = try await rest.raw(signed)
            if response.statusCode == 401, attempt == 0 {
                token = try await authenticate()
                continue
            }
            try RESTClient.validate(response, data: data)
            return (data, response)
        }
        throw NetworkError.unauthorized
    }

    private func json<T: Decodable>(_ request: RESTRequest, as type: T.Type) async throws -> T {
        try RESTClient.decode(T.self, from: try await authorized(request).0)
    }

    func overview() async throws -> KavitaOverview {
        let libraries = try await json(.get("api/Library/libraries"), as: [KavitaLibrary].self)
        let filter = try RESTRequest.post("api/Series/recently-added-v2", query: [URLQueryItem(name: "PageNumber", value: "1"), URLQueryItem(name: "PageSize", value: "10")],
                                          json: KavitaFilter())
        let (recentData, recentResponse) = try await authorized(filter)
        let recent = try RESTClient.decode([KavitaSeries].self, from: recentData)
        let total = Self.totalItems(fromPagination: recentResponse.value(forHTTPHeaderField: "Pagination"))

        var admin: KavitaOverview.Admin?
        do {
            async let stats = json(.get("api/Stats/server/stats"), as: KavitaServerStats.self)
            async let errors = json(.get("api/Server/media-errors"), as: [KavitaMediaError].self)
            async let sessions = json(.get("api/Activity/current"), as: [KavitaReadingSession].self)
            async let jobs = json(.get("api/Server/jobs"), as: [KavitaRecurringJob].self)
            admin = try await KavitaOverview.Admin(stats: stats, mediaErrors: errors, sessions: sessions, jobs: jobs, update: checkUpdate())
        } catch NetworkError.forbidden {
            admin = nil
        }
        return KavitaOverview(version: session.withLock(\.version), libraries: libraries, recentSeries: recent, totalSeries: total, admin: admin)
    }

    private func checkUpdate() async -> ServerMaintenance.Update {
        guard let (data, _) = try? await authorized(.get("api/Server/check-update")), !data.isEmpty,
              let notice = try? RESTClient.decode(KavitaUpdateNotification.self, from: data) else { return .unknown }
        return Self.update(notice)
    }

    static func update(_ notice: KavitaUpdateNotification) -> ServerMaintenance.Update {
        guard let version = notice.updateVersion?.nilIfEmpty else { return .unknown }
        return notice.isReleaseNewer == true ? .available(version) : .upToDate
    }

    static func totalItems(fromPagination header: String?) -> Int? {
        struct Pagination: Decodable { var totalItems: Int }
        return header.flatMap { try? JSONDecoder().decode(Pagination.self, from: Data($0.utf8)).totalItems }
    }

    func dashboard() async throws -> DashboardSnapshot {
        KavitaDashboard.snapshot(try await overview(), operations: self)
    }

    func scan(libraryID: Int, force: Bool) async throws {
        _ = try await authorized(.post("api/Library/scan", query: [URLQueryItem(name: "libraryId", value: String(libraryID)), URLQueryItem(name: "force", value: String(force))]))
    }

    func scanAll() async throws {
        _ = try await authorized(.post("api/Library/scan-all", query: [URLQueryItem(name: "force", value: "false")]))
    }

    func backUpDatabase() async throws {
        _ = try await authorized(.post("api/Server/backup-db"))
    }
}

/// The minimal `SeriesFilterV2Dto` Kavita accepts for "all series".
struct KavitaFilter: Encodable, Sendable {
    var statements: [String] = []
    var combination = 1
    var limitTo = 0
}

enum KavitaDashboard {
    static func snapshot(_ overview: KavitaOverview, operations: some KavitaOperations) -> DashboardSnapshot {
        let admin = overview.admin
        let reading = admin?.sessions.filter(\.isActive) ?? []
        let errors = admin?.mediaErrors ?? []
        var metrics = [DashboardMetric(title: "Libraries", value: "\(overview.libraries.count)", systemImage: "books.vertical")]
        if let stats = admin?.stats {
            metrics += [
                DashboardMetric(title: "Series", value: stats.seriesCount.formatted(), systemImage: "square.stack"),
                DashboardMetric(title: "Files", value: stats.totalFiles.formatted(), systemImage: "doc.on.doc"),
                DashboardMetric(title: "Library size", value: Format.bytes(stats.totalSize), systemImage: "internaldrive"),
            ]
        } else if let total = overview.totalSeries {
            metrics.append(DashboardMetric(title: "Series", value: total.formatted(), systemImage: "square.stack"))
        }
        if admin != nil {
            metrics.append(DashboardMetric(title: "Reading now", value: "\(reading.count)", systemImage: "book"))
            metrics.append(DashboardMetric(title: "Unreadable files", value: "\(errors.count)", systemImage: "exclamationmark.triangle", health: errors.isEmpty ? .ok : .warning))
        }

        var sections = [
            DashboardSection(id: "libraries", title: "Libraries", systemImage: "books.vertical", trailing: "\(overview.libraries.count)", emptyText: "No libraries are shared with this user.",
                             rows: overview.libraries.map { library in
                                 DashboardRow(id: "l\(library.id)", title: library.name, subtitle: library.typeName,
                                              detail: APIDate.parse(library.lastScanned).map { "Scanned \(Format.relative($0))" },
                                              actions: admin == nil ? [] : [
                                                  DashboardAction(id: "scan:\(library.id)", title: "Scan", systemImage: "arrow.clockwise", targetKind: "Library", targetName: library.name,
                                                                  consequence: "Kavita looks for new, changed and removed files in this library.", confirmation: .none) {
                                                      try await operations.scan(libraryID: library.id, force: false)
                                                  },
                                                  DashboardAction(id: "force:\(library.id)", title: "Full Rescan…", systemImage: "arrow.triangle.2.circlepath", targetKind: "Library", targetName: library.name,
                                                                  consequence: "Kavita re-reads every file in this library as if it were new. On large libraries this takes a long time and uses a lot of disk and CPU.") {
                                                      try await operations.scan(libraryID: library.id, force: true)
                                                  },
                                              ])
                             }),
        ]
        if let admin {
            sections.append(ServerMaintenance(update: admin.update).section())
            sections.append(DashboardSection(id: "reading", title: "Reading Now", systemImage: "book", trailing: "\(reading.count)", emptyText: "Nobody is reading right now.",
                                             rows: reading.map { session in
                                                 let activity = session.activityData.last
                                                 return DashboardRow(id: "r\(session.id)", title: activity?.seriesName ?? "Unknown series",
                                                                     subtitle: [session.username, activity?.chapterTitle?.nilIfEmpty, activity?.clientInfo?.platform].compactMap { $0 }.joined(separator: " · "),
                                                                     progress: activity.flatMap { a in a.totalPages.flatMap { $0 > 0 ? Double(a.endPage ?? 0) / Double($0) : nil } })
                                             }))
            sections.append(DashboardSection(id: "errors", title: "Unreadable Files", systemImage: "exclamationmark.triangle", trailing: "\(errors.count)", emptyText: "Kavita hasn't reported any broken files.",
                                             rows: errors.enumerated().map { DashboardRow(id: "x\($0.offset)", title: ($0.element.filePath as NSString).lastPathComponent, subtitle: $0.element.filePath, health: .warning, message: $0.element.comment?.nilIfEmpty) }))
            sections.append(DashboardSection(id: "jobs", title: "Scheduled Jobs", systemImage: "calendar.badge.clock", trailing: "\(admin.jobs.count)", emptyText: "No recurring jobs.",
                                             rows: admin.jobs.map { DashboardRow(id: $0.id, title: $0.title, subtitle: $0.cron.map { "Cron \($0)" },
                                                                                 detail: APIDate.parse($0.lastExecutionUtc).map { "Last ran \(Format.relative($0))" } ?? "Hasn't run yet") }))
        }
        sections.append(DashboardSection(id: "recent", title: "Recently Added", systemImage: "sparkles", emptyText: "Nothing has been added yet.",
                                         rows: overview.recentSeries.map { series in
                                             DashboardRow(id: "s\(series.id)", title: series.name, subtitle: series.libraryName,
                                                          detail: APIDate.parse(series.created).map { "Added \(Format.relative($0))" })
                                         }))

        return DashboardSnapshot(
            version: overview.version,
            health: errors.isEmpty ? .ok : .warning,
            headline: "\(overview.libraries.count) librar\(overview.libraries.count == 1 ? "y" : "ies")" + (admin.map { " · \($0.sessions.filter(\.isActive).count) reading" } ?? ""),
            detail: errors.isEmpty ? nil : "\(errors.count) unreadable file\(errors.count == 1 ? "" : "s")",
            notice: admin == nil ? "This auth key's user isn't an admin, so statistics, reading activity, file errors and scans aren't available." : nil,
            metrics: metrics,
            actions: admin == nil ? [] : [
                DashboardAction(id: "scan-all", title: "Scan All Libraries…", systemImage: "arrow.clockwise", targetKind: "Libraries", targetName: "All libraries",
                                consequence: "Kavita scans every library for new, changed and removed files. Series whose folders are missing can be removed from Kavita (files on disk aren't touched), and the server is busier until the scan finishes.") {
                    try await operations.scanAll()
                },
                DashboardAction(id: "backup", title: "Back Up Database…", systemImage: "archivebox", targetKind: "Kavita", targetName: "Database and settings",
                                consequence: "Kavita runs its backup job once and adds a new file to its backup folder. Nothing is restored or overwritten; older backups are pruned by Kavita's own retention.") {
                    try await operations.backUpDatabase()
                },
            ],
            sections: sections
        )
    }
}
