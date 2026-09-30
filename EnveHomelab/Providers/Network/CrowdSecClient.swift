import Foundation

struct CrowdSecDecision: Decodable, Sendable {
    var id: Int64?
    var origin: String?
    var type: String
    var scope: String
    var value: String
    var duration: String?
    var scenario: String?

    /// Remaining lifetime from Go's duration format, e.g. "3h51m57.36s".
    var remaining: TimeInterval? { duration.flatMap(GoDuration.seconds) }
}

enum GoDuration {
    static func seconds(_ text: String) -> TimeInterval? {
        let sign: Double = text.hasPrefix("-") ? -1 : 1
        let body = text.drop { $0 == "-" || $0 == "+" }
        let parts = body.matches(of: /(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)/)
        guard !parts.isEmpty, parts.map({ $0.output.0.count }).reduce(0, +) == body.count else { return nil }
        return sign * parts.reduce(0) { total, part in
            let scale: Double = switch part.output.2 {
            case "h": 3_600
            case "m": 60
            case "s": 1
            case "ms": 0.001
            case "us", "µs": 0.000_001
            default: 0.000_000_001
            }
            return total + (Double(part.output.1) ?? 0) * scale
        }
    }
}

struct CrowdSecOverview: Sendable {
    var lapiUp: Bool
    var decisions: [CrowdSecDecision]
}

/// CrowdSec Local API with a bouncer key, which can only read decisions. Only locally made decisions are listed; community blocklists can hold tens of thousands.
struct CrowdSecClient: DashboardService {
    let kind = IntegrationKind.crowdsec
    static let localOrigins = "crowdsec,cscli,console"
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        // LAPI records the bouncer's type and version from a "name/version" User-Agent.
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-Api-Key": apiKey, "User-Agent": "EnveHomelab/1.0"])
    }

    func overview() async throws -> CrowdSecOverview {
        let (_, health) = try await rest.raw(.get("health"))
        let data = try await rest.data(.get("v1/decisions", query: [URLQueryItem(name: "origins", value: Self.localOrigins)]))
        // An empty list is sent as `null`.
        let decisions = try RESTClient.decode([CrowdSecDecision]?.self, from: data) ?? []
        return CrowdSecOverview(lapiUp: health.statusCode == 200, decisions: decisions)
    }

    func dashboard() async throws -> DashboardSnapshot {
        CrowdSecDashboard.snapshot(try await overview())
    }
}

enum CrowdSecDashboard {
    static func snapshot(_ overview: CrowdSecOverview) -> DashboardSnapshot {
        let decisions = overview.decisions.sorted { ($0.remaining ?? 0) > ($1.remaining ?? 0) }
        let bans = decisions.filter { $0.type == "ban" }
        let byScenario = Dictionary(grouping: decisions) { $0.scenario ?? "Unknown scenario" }.sorted { $0.value.count > $1.value.count }

        return DashboardSnapshot(
            version: nil,
            health: overview.lapiUp ? .ok : .critical,
            headline: overview.lapiUp ? "\(decisions.count) active decision\(decisions.count == 1 ? "" : "s")" : "Local API unhealthy",
            detail: byScenario.first.map { "Most common: \($0.key)" },
            notice: "A bouncer key can read decisions only. Alerts and removing decisions need CrowdSec machine credentials, which this app doesn't use.",
            metrics: [
                DashboardMetric(title: "Active decisions", value: decisions.count.formatted(), systemImage: "shield.lefthalf.filled"),
                DashboardMetric(title: "Bans", value: bans.count.formatted(), systemImage: "hand.raised"),
                DashboardMetric(title: "Scenarios", value: "\(byScenario.count)", systemImage: "list.bullet.rectangle"),
            ],
            sections: [
                DashboardSection(id: "decisions", title: "Active Decisions", systemImage: "shield.lefthalf.filled", trailing: decisions.count.formatted(),
                                 emptyText: "CrowdSec hasn't made any local decisions.",
                                 rows: decisions.enumerated().map { index, decision in
                                     DashboardRow(id: decision.id.map(String.init) ?? "d\(index)", title: decision.value,
                                                  subtitle: [decision.scope, decision.scenario].compactMap { $0 }.joined(separator: " · "),
                                                  detail: [decision.origin, decision.remaining.map { "expires in \(Format.duration(max($0, 0)))" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                  health: decision.type == "ban" ? .warning : .unknown, badge: decision.type.capitalizedFirst)
                                 }, limit: 100),
                DashboardSection(id: "scenarios", title: "By Scenario", systemImage: "list.bullet.rectangle", trailing: "\(byScenario.count)", emptyText: "No scenarios have triggered.",
                                 rows: byScenario.map { scenario, items in
                                     DashboardRow(id: scenario, title: scenario, badge: "\(items.count)")
                                 }),
            ]
        )
    }
}
