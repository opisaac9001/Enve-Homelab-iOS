import Foundation

struct ABSStatus: Decodable, Sendable {
    var app: String?
    var serverVersion: String?
}

struct ABSUser: Decodable, Sendable {
    var username: String
    var type: String

    var isAdmin: Bool { type == "root" || type == "admin" }
}

struct ABSLibrary: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        var totalItems: Int?
        var totalSize: Int64?
        var totalDuration: Double?
    }

    var id: String
    var name: String
    var mediaType: String
    var lastScan: Double?
    var stats: Stats?
}

struct ABSItem: Decodable, Sendable {
    struct Media: Decodable, Sendable {
        struct Metadata: Decodable, Sendable {
            var title: String?
            var authorName: String?
        }
        var metadata: Metadata?
        var duration: Double?
    }

    var id: String
    var libraryId: String
    var addedAt: Double?
    var isMissing: Bool?
    var isInvalid: Bool?
    var path: String?
    var media: Media?

    var title: String { media?.metadata?.title ?? (path as NSString?)?.lastPathComponent ?? "Untitled" }
}

struct ABSItemsPage: Decodable, Sendable {
    var results: [ABSItem]
    var total: Int
}

struct ABSSession: Decodable, Sendable {
    struct User: Decodable, Sendable { var username: String }
    struct Device: Decodable, Sendable {
        var clientName: String?
        var deviceName: String?
        var osName: String?
    }

    var id: String
    var displayTitle: String?
    var displayAuthor: String?
    var duration: Double?
    var currentTime: Double?
    var playMethod: Int?
    var mediaPlayer: String?
    var deviceInfo: Device?
    var user: User?
    var updatedAt: Double?

    var playMethodName: String? {
        switch playMethod {
        case 0: "Direct play"
        case 1: "Direct stream"
        case 2: "Transcode"
        case 3: "Local"
        default: nil
        }
    }
}

struct ABSTask: Decodable, Sendable {
    var id: String
    var action: String?
    var title: String?
    var description: String?
    var isFailed: Bool?
    var error: String?
}

struct ABSOverview: Sendable {
    var version: String?
    var user: ABSUser
    var libraries: [ABSLibrary]
    var tasks: [ABSTask]
    var recent: [ABSItem]
    var issues: [String: ABSItemsPage]
    /// Admin-only; nil for other users.
    var sessions: [ABSSession]?
    /// Admin-only backup list from `GET /api/backups`.
    var backups: [ServerMaintenance.Backup]?
}

/// `GET /api/backups`; only the file name, size and time are read, not the server paths beside them.
struct ABSBackups: Decodable, Sendable {
    struct Backup: Decodable, Sendable { var filename: String?; var fileSize: Int64?; var createdAt: Double? }
    var backups: [Backup]

    var maintenanceBackups: [ServerMaintenance.Backup] {
        backups.map { ServerMaintenance.Backup(name: $0.filename ?? "Backup", date: $0.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) }, size: $0.fileSize) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

protocol AudiobookshelfOperations: Sendable {
    func scan(libraryID: String, force: Bool) async throws
    func removeItemsWithIssues(libraryID: String) async throws
    /// Audiobookshelf answers only once the backup file is written.
    func createBackup() async throws
}

/// Audiobookshelf REST API with an API key (2.26+) as a Bearer token.
struct AudiobookshelfClient: DashboardService, AudiobookshelfOperations {
    let kind = IntegrationKind.audiobookshelf
    private let rest: RESTClient
    private let slowRest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(apiKey)"])
        slowRest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(apiKey)"], timeout: 300)
    }

    private struct Libraries: Decodable { var libraries: [ABSLibrary] }
    private struct Tasks: Decodable { var tasks: [ABSTask] }
    private struct Sessions: Decodable { var sessions: [ABSSession] }

    private func items(_ libraryID: String, _ query: [URLQueryItem]) async throws -> ABSItemsPage {
        try await rest.json(.get("api/libraries/\(libraryID)/items", query: query), as: ABSItemsPage.self)
    }

    func overview() async throws -> ABSOverview {
        async let status = rest.json(.get("status"), as: ABSStatus.self)
        async let user = rest.json(.get("api/me"), as: ABSUser.self)
        async let libraries = rest.json(.get("api/libraries", query: [URLQueryItem(name: "include", value: "stats")]), as: Libraries.self).libraries
        async let tasks = rest.json(.get("api/tasks"), as: Tasks.self).tasks
        let (me, libraryList) = try await (user, libraries)

        var recent: [ABSItem] = []
        var issues: [String: ABSItemsPage] = [:]
        for library in libraryList {
            recent += try await items(library.id, [URLQueryItem(name: "sort", value: "addedAt"), URLQueryItem(name: "desc", value: "1"),
                                                   URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "page", value: "0")]).results
            issues[library.id] = try await items(library.id, [URLQueryItem(name: "filter", value: "issues"), URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "page", value: "0")])
        }
        recent.sort { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }

        let sessions = me.isAdmin ? try await rest.json(.get("api/sessions/open"), as: Sessions.self).sessions : nil
        let backups = me.isAdmin ? (try? await rest.json(.get("api/backups"), as: ABSBackups.self))?.maintenanceBackups : nil
        return try await ABSOverview(version: status.serverVersion, user: me, libraries: libraryList, tasks: tasks,
                                     recent: Array(recent.prefix(10)), issues: issues, sessions: sessions, backups: backups)
    }

    func dashboard() async throws -> DashboardSnapshot {
        AudiobookshelfDashboard.snapshot(try await overview(), operations: self)
    }

    func scan(libraryID: String, force: Bool) async throws {
        _ = try await rest.data(.post("api/libraries/\(libraryID)/scan", query: force ? [URLQueryItem(name: "force", value: "1")] : []))
    }

    func removeItemsWithIssues(libraryID: String) async throws {
        _ = try await rest.data(.delete("api/libraries/\(libraryID)/issues"))
    }

    func createBackup() async throws {
        _ = try await slowRest.data(.post("api/backups"))
    }
}

enum AudiobookshelfDashboard {
    static func snapshot(_ overview: ABSOverview, operations: some AudiobookshelfOperations) -> DashboardSnapshot {
        let admin = overview.user.isAdmin
        let issueCount = overview.issues.values.map(\.total).reduce(0, +)
        let listening = overview.sessions ?? []
        let totalItems = overview.libraries.compactMap(\.stats?.totalItems).reduce(0, +)
        let totalDuration = overview.libraries.compactMap(\.stats?.totalDuration).reduce(0, +)
        let libraryNames = Dictionary(overview.libraries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var metrics = [
            DashboardMetric(title: "Items", value: totalItems.formatted(), systemImage: "books.vertical"),
            DashboardMetric(title: "Total listening time", value: Format.duration(totalDuration), systemImage: "clock"),
            DashboardMetric(title: "Missing or invalid", value: "\(issueCount)", systemImage: "exclamationmark.triangle", health: issueCount > 0 ? .warning : .ok),
        ]
        if admin { metrics.insert(DashboardMetric(title: "Listening now", value: "\(listening.count)", systemImage: "headphones"), at: 0) }

        var sections: [DashboardSection] = []
        if let sessions = overview.sessions {
            sections.append(DashboardSection(id: "sessions", title: "Listening Now", systemImage: "headphones", trailing: "\(sessions.count)", emptyText: "Nobody is listening right now.",
                                             rows: sessions.map { session in
                                                 let device = [session.deviceInfo?.clientName, session.deviceInfo?.deviceName ?? session.deviceInfo?.osName].compactMap { $0 }.joined(separator: " on ").nilIfEmpty
                                                 return DashboardRow(id: session.id, title: session.displayTitle ?? "Unknown title",
                                                                     subtitle: [session.user?.username, session.displayAuthor].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                                     detail: [device ?? session.mediaPlayer, session.playMethodName, session.currentTime.map { "at \(Format.duration($0))" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                                     progress: session.duration.flatMap { duration in duration > 0 ? (session.currentTime ?? 0) / duration : nil })
                                             }))
        }
        sections.append(DashboardSection(id: "libraries", title: "Libraries", systemImage: "books.vertical", trailing: "\(overview.libraries.count)", emptyText: "No libraries are shared with this user.",
                                         rows: overview.libraries.map { library in
                                             let issues = overview.issues[library.id]?.total ?? 0
                                             var detail = [library.stats?.totalItems.map { "\($0.formatted()) items" }, library.stats?.totalSize.map(Format.bytes)].compactMap { $0 }
                                             if let scan = library.lastScan { detail.append("Scanned \(Format.relative(Date(timeIntervalSince1970: scan / 1000)))") }
                                             return DashboardRow(id: library.id, title: library.name, subtitle: library.mediaType == "podcast" ? "Podcasts" : "Books",
                                                                 detail: detail.joined(separator: " · ").nilIfEmpty, health: issues > 0 ? .warning : nil,
                                                                 message: issues > 0 ? "\(issues) missing or invalid item\(issues == 1 ? "" : "s")" : nil,
                                                                 actions: admin ? libraryActions(library, issues: issues, operations: operations) : [])
                                         }))
        let problemItems = overview.issues.values.flatMap(\.results)
        sections.append(DashboardSection(id: "issues", title: "Missing or Invalid", systemImage: "exclamationmark.triangle", trailing: "\(issueCount)",
                                         emptyText: "Every item's files were found and could be read.",
                                         rows: problemItems.map { item in
                                             DashboardRow(id: "i\(item.id)", title: item.title, subtitle: [libraryNames[item.libraryId], item.path].compactMap { $0 }.joined(separator: " · "),
                                                          health: .warning, badge: item.isMissing == true ? "Missing" : "Invalid")
                                         }))
        sections.append(DashboardSection(id: "tasks", title: "Running Tasks", systemImage: "gearshape.2", trailing: "\(overview.tasks.count)", emptyText: "No tasks are running.",
                                         rows: overview.tasks.map { task in
                                             DashboardRow(id: task.id, title: task.title ?? task.action?.replacingOccurrences(of: "-", with: " ").capitalizedFirst ?? "Task",
                                                          subtitle: task.description, health: task.isFailed == true ? .warning : nil, message: task.error)
                                         }))
        sections.append(DashboardSection(id: "recent", title: "Recently Added", systemImage: "sparkles", emptyText: "Nothing has been added yet.",
                                         rows: overview.recent.map { item in
                                             DashboardRow(id: "r\(item.id)", title: item.title,
                                                          subtitle: [item.media?.metadata?.authorName, libraryNames[item.libraryId]].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                          detail: [item.addedAt.map { "Added \(Format.relative(Date(timeIntervalSince1970: $0 / 1000)))" }, item.media?.duration.map(Format.duration)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
                                         }))

        return DashboardSnapshot(
            version: overview.version,
            health: issueCount > 0 || overview.tasks.contains { $0.isFailed == true } ? .warning : .ok,
            headline: admin ? "\(listening.count) listening · \(overview.libraries.count) librar\(overview.libraries.count == 1 ? "y" : "ies")" : "\(overview.libraries.count) librar\(overview.libraries.count == 1 ? "y" : "ies")",
            detail: issueCount > 0 ? "\(issueCount) missing or invalid item\(issueCount == 1 ? "" : "s")" : nil,
            notice: admin ? nil : "This API key's user isn't an admin, so listening sessions and library scans aren't available.",
            metrics: metrics,
            actions: admin ? [DashboardAction(id: "backup", title: "Create Backup…", systemImage: "archivebox", targetKind: "Audiobookshelf", targetName: "Database and settings",
                                              consequence: "Audiobookshelf writes a new backup file to its backup folder and answers when it's finished. Nothing is restored; the oldest backups are removed by Audiobookshelf's own limit.") {
                try await operations.createBackup()
            }] : [],
            sections: sections + (overview.backups.map { [ServerMaintenance(backups: $0).section(backupsNote: "Stored in Audiobookshelf's backup folder")] } ?? [])
        )
    }

    private static func libraryActions(_ library: ABSLibrary, issues: Int, operations: some AudiobookshelfOperations) -> [DashboardAction] {
        var actions = [
            DashboardAction(id: "scan:\(library.id)", title: "Scan", systemImage: "arrow.clockwise", targetKind: "Library", targetName: library.name,
                            consequence: "Audiobookshelf looks for new, changed and removed files in this library.", confirmation: .none) {
                try await operations.scan(libraryID: library.id, force: false)
            },
            DashboardAction(id: "force:\(library.id)", title: "Force Rescan…", systemImage: "arrow.triangle.2.circlepath", targetKind: "Library", targetName: library.name,
                            consequence: "Audiobookshelf re-reads every item in this library, including metadata and audio file details. This can take a long time.") {
                try await operations.scan(libraryID: library.id, force: true)
            },
        ]
        if issues > 0 {
            actions.append(DashboardAction(id: "issues:\(library.id)", title: "Remove Missing or Invalid Items…", systemImage: "trash", targetKind: "Library", targetName: library.name,
                                           consequence: "Audiobookshelf permanently removes \(issues) item\(issues == 1 ? "" : "s") whose files are missing or unreadable, including their listening progress and bookmarks. Files on disk aren't touched.",
                                           confirmation: .typed) {
                try await operations.removeItemsWithIssues(libraryID: library.id)
            })
        }
        return actions
    }
}
