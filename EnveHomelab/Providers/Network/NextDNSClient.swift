import Foundation

struct NextDNSEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    struct APIError: Decodable, Sendable { var code: String?; var detail: String? }
    var data: Value?
    var errors: [APIError]?
}

struct NextDNSProfile: Decodable, Sendable {
    struct Settings: Decodable, Sendable {
        struct Logs: Decodable, Sendable { var enabled: Bool? }
        var logs: Logs?
    }
    var name: String?
    var settings: Settings?
}

struct NextDNSStatusCount: Decodable, Sendable {
    var status: String
    var queries: Int
}

struct NextDNSDomain: Decodable, Sendable {
    var domain: String
    var root: String?
    var queries: Int
}

struct NextDNSReason: Decodable, Sendable {
    var id: String
    var name: String
    var queries: Int
}

struct NextDNSDevice: Decodable, Sendable {
    var id: String
    var name: String?
    var model: String?
    var localIp: String?
    var queries: Int
}

struct NextDNSOverview: Sendable {
    var profileID: String
    var profile: NextDNSProfile
    var statuses: [NextDNSStatusCount]
    var blockedDomains: [NextDNSDomain]
    var reasons: [NextDNSReason]
    var devices: [NextDNSDevice]

    var total: Int { statuses.map(\.queries).reduce(0, +) }
    var blocked: Int { statuses.first { $0.status == "blocked" }?.queries ?? 0 }
}

protocol NextDNSOperations: Sendable {
    func allow(domain: String) async throws
}

/// NextDNS public API (documented as beta) for one profile, with the account's `X-Api-Key`. It has no pause endpoint.
struct NextDNSClient: DashboardService, NextDNSOperations {
    let kind = IntegrationKind.nextdns
    static let baseURL = URL(string: "https://api.nextdns.io")!
    private let rest: RESTClient
    private let profileID: String

    init(profileID: String, apiKey: String, baseURL: URL = NextDNSClient.baseURL) {
        rest = RESTClient(baseURL: baseURL, pinnedFingerprint: nil, headers: ["X-Api-Key": apiKey])
        self.profileID = profileID
    }

    /// User-level errors arrive with HTTP 200 and an `errors` array.
    private func get<Value: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem] = [], as type: Value.Type) async throws -> Value {
        let envelope = try await rest.json(.get("profiles/\(profileID)\(path)", query: query), as: NextDNSEnvelope<Value>.self)
        if let error = envelope.errors?.first { throw NetworkError.graphQL([error.detail ?? error.code ?? "NextDNS reported an error."]) }
        guard let data = envelope.data else { throw NetworkError.unexpectedResponse("NextDNS returned no data.") }
        return data
    }

    func overview() async throws -> NextDNSOverview {
        let day = [URLQueryItem(name: "from", value: "-24h")]
        async let profile = get("", as: NextDNSProfile.self)
        async let statuses = get("/analytics/status", day, as: [NextDNSStatusCount].self)
        async let domains = get("/analytics/domains", day + [URLQueryItem(name: "status", value: "blocked"), URLQueryItem(name: "limit", value: "15")], as: [NextDNSDomain].self)
        async let reasons = get("/analytics/reasons", day + [URLQueryItem(name: "limit", value: "10")], as: [NextDNSReason].self)
        async let devices = get("/analytics/devices", day + [URLQueryItem(name: "limit", value: "20")], as: [NextDNSDevice].self)
        return try await NextDNSOverview(profileID: profileID, profile: profile, statuses: statuses, blockedDomains: domains, reasons: reasons, devices: devices)
    }

    func dashboard() async throws -> DashboardSnapshot {
        NextDNSDashboard.snapshot(try await overview(), operations: self)
    }

    private struct ListEntry: Encodable { var id: String; var active: Bool }

    func allow(domain: String) async throws {
        let data = try await rest.data(try .post("profiles/\(profileID)/allowlist", json: ListEntry(id: domain, active: true)))
        if let envelope = try? JSONDecoder().decode(NextDNSEnvelope<ListEntryEcho>.self, from: data), let error = envelope.errors?.first {
            throw NetworkError.graphQL([error.detail ?? error.code ?? "NextDNS didn't add the domain."])
        }
    }

    private struct ListEntryEcho: Decodable, Sendable {}
}

enum NextDNSDashboard {
    static func snapshot(_ overview: NextDNSOverview, operations: some NextDNSOperations) -> DashboardSnapshot {
        let total = overview.total
        let blocked = overview.blocked
        let fraction = total > 0 ? Double(blocked) / Double(total) : 0
        let logsOff = overview.profile.settings?.logs?.enabled == false

        return DashboardSnapshot(
            version: nil,
            health: logsOff ? .unknown : .ok,
            headline: "\(Format.percent(fraction)) blocked · \(total.formatted()) queries in 24 h",
            detail: overview.profile.name.map { "Profile \($0) (\(overview.profileID))" } ?? "Profile \(overview.profileID)",
            notice: logsOff ? "Logging is off for this profile, so NextDNS has no analytics to report." : "NextDNS's API has no way to pause filtering; change it at my.nextdns.io.",
            metrics: [
                DashboardMetric(title: "Queries (24 h)", value: total.formatted(), systemImage: "arrow.left.arrow.right"),
                DashboardMetric(title: "Blocked", value: blocked.formatted(), systemImage: "hand.raised"),
                DashboardMetric(title: "Blocked share", value: Format.percent(fraction), systemImage: "chart.pie"),
                DashboardMetric(title: "Devices", value: "\(overview.devices.filter { $0.id != "__UNIDENTIFIED__" }.count)", systemImage: "iphone"),
            ],
            sections: [
                DashboardSection(id: "domains", title: "Most Blocked Domains", systemImage: "hand.raised", emptyText: "Nothing was blocked in the last 24 hours.",
                                 rows: overview.blockedDomains.map { domain in
                                     DashboardRow(id: domain.domain, title: domain.domain, subtitle: domain.root.flatMap { $0 == domain.domain ? nil : $0 },
                                                  badge: domain.queries.formatted(),
                                                  actions: [DashboardAction(id: "allow:\(domain.domain)", title: "Allow Domain…", systemImage: "checkmark.shield", targetKind: "Domain", targetName: domain.domain,
                                                                            consequence: "NextDNS adds \(domain.domain) to this profile's allowlist, so it resolves on every device using the profile even if a blocklist or security setting would block it. Remove it again at my.nextdns.io.") {
                                                      try await operations.allow(domain: domain.domain)
                                                  }])
                                 }),
                DashboardSection(id: "reasons", title: "Why Queries Were Blocked", systemImage: "list.bullet.rectangle", emptyText: "No block reasons in the last 24 hours.",
                                 rows: overview.reasons.map { DashboardRow(id: $0.id, title: $0.name, badge: $0.queries.formatted()) }),
                DashboardSection(id: "devices", title: "Devices", systemImage: "iphone", emptyText: "No devices sent queries in the last 24 hours.",
                                 rows: overview.devices.map { device in
                                     DashboardRow(id: device.id, title: device.id == "__UNIDENTIFIED__" ? "Unidentified devices" : (device.name ?? device.id),
                                                  subtitle: [device.model, device.localIp].compactMap { $0 }.joined(separator: " · ").nilIfEmpty, badge: device.queries.formatted())
                                 }),
            ]
        )
    }
}
