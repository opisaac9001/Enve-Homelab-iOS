import Foundation

struct JackettIndexer: Sendable, Equatable {
    var id: String
    var title: String
    var configured: Bool
    var type: String?
    var language: String?
    var link: String?
}

/// Parses Jackett's Torznab XML: the `t=indexers` inventory, search results, and `<error code description>` replies.
final class TorznabXMLParser: NSObject, XMLParserDelegate {
    struct Result: Sendable {
        var indexers: [JackettIndexer] = []
        var itemCount = 0
        var error: (code: String, description: String)?
    }

    private var result = Result()
    private var current: JackettIndexer?
    private var text = ""

    static func parse(_ data: Data) throws -> Result {
        let delegate = TorznabXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw NetworkError.decoding("Jackett returned XML that couldn't be read.") }
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "indexer":
            current = JackettIndexer(id: attributes["id"] ?? "", title: attributes["id"] ?? "", configured: attributes["configured"] == "true")
        case "item":
            result.itemCount += 1
        case "error":
            result.error = (attributes["code"] ?? "", attributes["description"] ?? "Jackett reported an error.")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title" where current != nil: current?.title = value
        case "type" where current != nil: current?.type = value
        case "language" where current != nil: current?.language = value
        case "link" where current != nil: current?.link = value
        case "indexer":
            if let current { result.indexers.append(current) }
            current = nil
        default:
            break
        }
        text = ""
    }
}

struct JackettOverview: Sendable {
    var indexers: [JackettIndexer]
}

protocol JackettOperations: Sendable {
    func test(indexerID: String) async throws -> Int
}

/// Jackett's documented API is Torznab with the key as `apikey`; version and per-indexer error state need the undocumented admin session and aren't used.
struct JackettClient: DashboardService, JackettOperations {
    let kind = IntegrationKind.jackett
    private let rest: RESTClient
    private let apiKey: String

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint)
        self.apiKey = apiKey
    }

    private func torznab(_ indexer: String, _ query: [URLQueryItem]) async throws -> TorznabXMLParser.Result {
        let data = try await rest.data(.get("api/v2.0/indexers/\(indexer)/results/torznab/api", query: [URLQueryItem(name: "apikey", value: apiKey)] + query))
        let result = try TorznabXMLParser.parse(data)
        if let error = result.error {
            throw error.code == "100" ? NetworkError.unauthorized : NetworkError.graphQL(["\(error.description) (Torznab error \(error.code))"])
        }
        return result
    }

    func overview() async throws -> JackettOverview {
        let result = try await torznab("all", [URLQueryItem(name: "t", value: "indexers"), URLQueryItem(name: "configured", value: "true")])
        return JackettOverview(indexers: result.indexers.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    func dashboard() async throws -> DashboardSnapshot {
        JackettDashboard.snapshot(try await overview(), operations: self)
    }

    /// An empty search is how Jackett itself tests an indexer: it reaches the tracker and fails if the site or login is broken.
    func test(indexerID: String) async throws -> Int {
        try await torznab(indexerID, [URLQueryItem(name: "t", value: "search")]).itemCount
    }
}

enum JackettDashboard {
    static func snapshot(_ overview: JackettOverview, operations: some JackettOperations) -> DashboardSnapshot {
        let byType = Dictionary(grouping: overview.indexers) { $0.type ?? "unknown" }
        return DashboardSnapshot(
            version: nil,
            health: overview.indexers.isEmpty ? .warning : .ok,
            headline: overview.indexers.isEmpty ? "No indexers configured" : "\(overview.indexers.count) indexer\(overview.indexers.count == 1 ? "" : "s") configured",
            notice: "Jackett's API reports which indexers are configured, not whether they work. Test an indexer to check it against its site.",
            metrics: [
                DashboardMetric(title: "Configured", value: "\(overview.indexers.count)", systemImage: "magnifyingglass.circle", health: overview.indexers.isEmpty ? .warning : nil),
                DashboardMetric(title: "Private", value: "\(byType["private", default: []].count)", systemImage: "lock"),
                DashboardMetric(title: "Public", value: "\(byType["public", default: []].count)", systemImage: "globe"),
            ],
            sections: [
                DashboardSection(id: "indexers", title: "Indexers", systemImage: "magnifyingglass.circle", trailing: "\(overview.indexers.count)",
                                 emptyText: "Add indexers in the Jackett web UI; they appear here once configured.",
                                 rows: overview.indexers.map { indexer in
                                     DashboardRow(id: indexer.id, title: indexer.title,
                                                  subtitle: [indexer.type?.replacingOccurrences(of: "-", with: " ").capitalizedFirst, indexer.language].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                  detail: indexer.link.flatMap { URL(string: $0)?.host() },
                                                  actions: [DashboardAction(id: "test:\(indexer.id)", title: "Test", systemImage: "checkmark.circle", targetKind: "Indexer", targetName: indexer.title,
                                                                            consequence: "Jackett runs an empty search on this indexer's site, the same check as its Test button.", confirmation: .none) {
                                                      _ = try await operations.test(indexerID: indexer.id)
                                                  }])
                                 }),
            ]
        )
    }
}
