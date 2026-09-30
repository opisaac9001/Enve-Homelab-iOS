import Foundation

struct KomgaUser: Decodable, Sendable {
    var email: String
    var roles: [String]

    var isAdmin: Bool { roles.contains("ADMIN") }
}

struct KomgaLibrary: Decodable, Sendable {
    var id: String
    var name: String
    var unavailable: Bool
}

struct KomgaBook: Decodable, Sendable {
    struct Media: Decodable, Sendable {
        var status: String
        var comment: String?
    }

    var id: String
    var name: String
    var seriesTitle: String
    var libraryId: String
    var created: String?
    var sizeBytes: Int64?
    var media: Media
}

struct KomgaPage<Item: Decodable & Sendable>: Decodable, Sendable {
    var content: [Item]
    var totalElements: Int
}

struct KomgaOverview: Sendable {
    var user: KomgaUser
    var version: String?
    var libraries: [KomgaLibrary]
    var seriesCount: Int
    var bookCount: Int
    var recentBooks: [KomgaBook]
    var brokenBooks: KomgaPage<KomgaBook>
    var maintenance = ServerMaintenance()
}

/// `GET /api/v1/releases` (admin, Komga 1.16+).
struct KomgaRelease: Decodable, Sendable {
    var version: String
    var latest: Bool?
    var preRelease: Bool?
}

protocol KomgaOperations: Sendable {
    func scan(libraryID: String, deep: Bool) async throws
    func analyze(libraryID: String) async throws
    func emptyTrash(libraryID: String) async throws
    func analyze(bookID: String) async throws
    func cancelQueuedTasks() async throws -> Int
}

/// Komga 1.20+ REST API with an API key in `X-API-Key`; the ephemeral session never stores a Komga session cookie.
struct KomgaClient: DashboardService, KomgaOperations {
    let kind = IntegrationKind.komga
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-API-Key": apiKey])
    }

    private struct Info: Decodable {
        struct Build: Decodable { var version: String? }
        var build: Build?
    }

    private struct Search: Encodable {
        var condition: Condition?
    }

    private enum Condition: Encodable {
        case anyOfMediaStatus([String])

        func encode(to encoder: any Encoder) throws {
            struct Operator: Encodable { var `operator` = "is"; var value: String }
            struct MediaStatus: Encodable { var mediaStatus: Operator }
            struct AnyOf: Encodable { var anyOf: [MediaStatus] }
            switch self {
            case .anyOfMediaStatus(let statuses):
                try AnyOf(anyOf: statuses.map { MediaStatus(mediaStatus: Operator(value: $0)) }).encode(to: encoder)
            }
        }
    }

    private func list<Item: Decodable & Sendable>(_ path: String, size: Int, sort: String? = nil, condition: Condition? = nil, as type: Item.Type) async throws -> KomgaPage<Item> {
        var query = [URLQueryItem(name: "size", value: String(size))]
        if let sort { query.append(URLQueryItem(name: "sort", value: sort)) }
        return try await rest.json(try .post(path, query: query, json: Search(condition: condition)), as: KomgaPage<Item>.self)
    }

    private struct Series: Decodable, Sendable { var id: String }

    func overview() async throws -> KomgaOverview {
        let user = try await rest.json(.get("api/v2/users/me"), as: KomgaUser.self)
        async let libraries = rest.json(.get("api/v1/libraries"), as: [KomgaLibrary].self)
        async let series = list("api/v1/series/list", size: 1, as: Series.self)
        async let books = list("api/v1/books/list", size: 1, as: KomgaBook.self)
        async let recent = list("api/v1/books/list", size: 10, sort: "createdDate,desc", as: KomgaBook.self)
        async let broken = list("api/v1/books/list", size: 25, sort: "lastModifiedDate,desc", condition: .anyOfMediaStatus(["ERROR", "UNSUPPORTED"]), as: KomgaBook.self)
        let version = user.isAdmin ? try await rest.json(.get("actuator/info"), as: Info.self).build?.version : nil
        let releases = user.isAdmin ? try? await rest.json(.get("api/v1/releases"), as: [KomgaRelease].self) : nil
        return try await KomgaOverview(user: user, version: version, libraries: libraries, seriesCount: series.totalElements, bookCount: books.totalElements,
                                       recentBooks: recent.content, brokenBooks: broken, maintenance: ServerMaintenance(update: Self.update(releases, current: version)))
    }

    static func update(_ releases: [KomgaRelease]?, current: String?) -> ServerMaintenance.Update {
        guard let releases, let current, let latest = releases.first(where: { $0.latest == true && $0.preRelease != true }) else { return .unknown }
        return SemanticVersion.isNewer(latest.version, than: current) ? .available(latest.version) : .upToDate
    }

    func dashboard() async throws -> DashboardSnapshot {
        KomgaDashboard.snapshot(try await overview(), operations: self)
    }

    func scan(libraryID: String, deep: Bool) async throws {
        _ = try await rest.data(.post("api/v1/libraries/\(libraryID)/scan", query: deep ? [URLQueryItem(name: "deep", value: "true")] : []))
    }

    func analyze(libraryID: String) async throws {
        _ = try await rest.data(.post("api/v1/libraries/\(libraryID)/analyze"))
    }

    func emptyTrash(libraryID: String) async throws {
        _ = try await rest.data(.post("api/v1/libraries/\(libraryID)/empty-trash"))
    }

    func analyze(bookID: String) async throws {
        _ = try await rest.data(.post("api/v1/books/\(bookID)/analyze"))
    }

    func cancelQueuedTasks() async throws -> Int {
        try await rest.json(.delete("api/v1/tasks"), as: Int.self)
    }
}

enum KomgaDashboard {
    static func snapshot(_ overview: KomgaOverview, operations: some KomgaOperations) -> DashboardSnapshot {
        let admin = overview.user.isAdmin
        let broken = overview.brokenBooks
        let unavailable = overview.libraries.filter(\.unavailable)
        let health: Health = !unavailable.isEmpty ? .critical : (broken.totalElements > 0 ? .warning : .ok)
        let libraryNames = Dictionary(overview.libraries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var headline = "\(overview.seriesCount.formatted()) series · \(overview.bookCount.formatted()) books"
        if !unavailable.isEmpty { headline = "\(unavailable.count) librar\(unavailable.count == 1 ? "y" : "ies") unavailable" }

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: headline,
            detail: broken.totalElements > 0 ? "\(broken.totalElements) book\(broken.totalElements == 1 ? "" : "s") can't be read" : nil,
            notice: admin ? nil : "This API key's user isn't an admin, so the server version and library maintenance aren't available.",
            metrics: [
                DashboardMetric(title: "Libraries", value: "\(overview.libraries.count)", systemImage: "books.vertical", health: unavailable.isEmpty ? nil : .critical),
                DashboardMetric(title: "Series", value: overview.seriesCount.formatted(), systemImage: "square.stack"),
                DashboardMetric(title: "Books", value: overview.bookCount.formatted(), systemImage: "book.closed"),
                DashboardMetric(title: "Unreadable books", value: broken.totalElements.formatted(), systemImage: "exclamationmark.triangle", health: broken.totalElements > 0 ? .warning : .ok),
            ],
            actions: admin ? [
                DashboardAction(id: "cancel-tasks", title: "Cancel Queued Tasks", systemImage: "xmark.circle", targetKind: "Task queue", targetName: "All queued tasks",
                                consequence: "Komga drops every task that hasn't started yet, such as scans, analysis and thumbnail generation. Tasks already running finish normally.") {
                    _ = try await operations.cancelQueuedTasks()
                },
            ] : [],
            sections: [
                overview.maintenance.section(),
                DashboardSection(id: "libraries", title: "Libraries", systemImage: "books.vertical", trailing: "\(overview.libraries.count)", emptyText: "No libraries are shared with this user.",
                                 rows: overview.libraries.map { library in
                                     DashboardRow(id: library.id, title: library.name, health: library.unavailable ? .critical : nil,
                                                  badge: library.unavailable ? "Unavailable" : nil,
                                                  message: library.unavailable ? "Komga can't reach this library's folder." : nil,
                                                  actions: admin ? libraryActions(library, operations: operations) : [])
                                 }),
                DashboardSection(id: "broken", title: "Unreadable Books", systemImage: "exclamationmark.triangle", trailing: broken.totalElements.formatted(),
                                 emptyText: "Every analysed book can be read.",
                                 rows: broken.content.map { book in
                                     DashboardRow(id: book.id, title: book.name, subtitle: [book.seriesTitle, libraryNames[book.libraryId]].compactMap { $0 }.joined(separator: " · "),
                                                  health: .warning, badge: book.media.status.capitalized, message: book.media.comment?.nilIfEmpty,
                                                  actions: admin ? [DashboardAction(id: "analyze-book:\(book.id)", title: "Analyze Again", systemImage: "stethoscope", targetKind: "Book", targetName: book.name,
                                                                                    consequence: "Komga re-reads this file to check whether it can be opened.", confirmation: .none) {
                                                      try await operations.analyze(bookID: book.id)
                                                  }] : [])
                                 }, limit: 25),
                DashboardSection(id: "recent", title: "Recently Added", systemImage: "sparkles", emptyText: "Nothing has been added yet.",
                                 rows: overview.recentBooks.map { book in
                                     DashboardRow(id: "r\(book.id)", title: book.name, subtitle: book.seriesTitle,
                                                  detail: [APIDate.parse(book.created).map { "Added \(Format.relative($0))" }, book.sizeBytes.map(Format.bytes)].compactMap { $0 }.joined(separator: " · "))
                                 }),
            ]
        )
    }

    private static func libraryActions(_ library: KomgaLibrary, operations: some KomgaOperations) -> [DashboardAction] {
        [
            DashboardAction(id: "scan:\(library.id)", title: "Scan", systemImage: "arrow.clockwise", targetKind: "Library", targetName: library.name,
                            consequence: "Komga looks for new, changed and removed files in this library.", confirmation: .none) {
                try await operations.scan(libraryID: library.id, deep: false)
            },
            DashboardAction(id: "deep:\(library.id)", title: "Deep Scan…", systemImage: "arrow.triangle.2.circlepath", targetKind: "Library", targetName: library.name,
                            consequence: "Komga re-checks every file in this library even if it looks unchanged. This takes much longer than a normal scan.") {
                try await operations.scan(libraryID: library.id, deep: true)
            },
            DashboardAction(id: "analyze:\(library.id)", title: "Analyze All Books…", systemImage: "stethoscope", targetKind: "Library", targetName: library.name,
                            consequence: "Komga queues every book in this library for analysis. On large libraries this keeps the server busy for a long time.") {
                try await operations.analyze(libraryID: library.id)
            },
            DashboardAction(id: "trash:\(library.id)", title: "Empty Trash…", systemImage: "trash", targetKind: "Library", targetName: library.name,
                            consequence: "Komga permanently removes books and series whose files are missing, including their read progress and edited metadata. If the files come back later they're imported as new.",
                            confirmation: .typed) {
                try await operations.emptyTrash(libraryID: library.id)
            },
        ]
    }
}
