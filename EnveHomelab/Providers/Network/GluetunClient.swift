import Foundation

struct GluetunLoopStatus: Decodable, Sendable {
    var status: String

    var health: Health {
        switch status {
        case "running", "completed": .ok
        case "starting", "stopping": .unknown
        case "crashed": .critical
        default: .warning
        }
    }
}

struct GluetunPublicIP: Decodable, Sendable {
    var public_ip: String
    var country: String?
    var region: String?
    var city: String?
    var organization: String?
    var hostname: String?
    var timezone: String?

    var place: String? { [city, region, country].compactMap { $0?.nilIfEmpty }.joined(separator: ", ").nilIfEmpty }
}

struct GluetunPortForward: Decodable, Sendable {
    var port: Int
    var ports: [Int]?

    var all: [Int] { (ports ?? [port]).filter { $0 > 0 } }
}

struct GluetunVersion: Decodable, Sendable {
    var version: String
}

struct GluetunOverview: Sendable {
    var version: String?
    var vpn: GluetunLoopStatus?
    var publicIP: GluetunPublicIP?
    var portForward: GluetunPortForward?
    var dns: GluetunLoopStatus?
    var updater: GluetunLoopStatus?
    /// Routes the configured role doesn't allow; Gluetun authorizes per route.
    var forbiddenRoutes: [String]
}

enum GluetunLoop: String, Sendable {
    case vpn, dns, updater
}

protocol GluetunOperations: Sendable {
    func set(_ loop: GluetunLoop, running: Bool) async throws
}

/// Gluetun's HTTP control server. Roles may use no auth, HTTP Basic, or an `X-API-Key`, and can grant only some routes.
struct GluetunClient: DashboardService, GluetunOperations {
    let kind = IntegrationKind.gluetun
    private let rest: RESTClient

    /// A username means Basic auth; a secret alone is sent as the role's API key.
    init(url: URL, username: String?, secret: String?, pinnedFingerprint: String?) {
        var headers: [String: String] = [:]
        if let username = username?.nilIfEmpty {
            headers["Authorization"] = "Basic " + Data("\(username):\(secret ?? "")".utf8).base64EncodedString()
        } else if let secret = secret?.nilIfEmpty {
            headers["X-API-Key"] = secret
        }
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    private func optional<T: Decodable>(_ path: String, as type: T.Type, forbidden: inout [String]) async throws -> T? {
        do {
            return try await rest.json(.get(path), as: T.self)
        } catch NetworkError.unauthorized {
            forbidden.append(path)
            return nil
        } catch NetworkError.apiNotFound where path == "v1/portforward" {
            // Before 3.41 the route was /v1/openvpn/portforwarded.
            return try? await rest.json(.get("v1/openvpn/portforwarded"), as: T.self)
        }
    }

    func overview() async throws -> GluetunOverview {
        var forbidden: [String] = []
        let version = try await optional("v1/version", as: GluetunVersion.self, forbidden: &forbidden)
        let vpn = try await optional("v1/vpn/status", as: GluetunLoopStatus.self, forbidden: &forbidden)
        let ip = try await optional("v1/publicip/ip", as: GluetunPublicIP.self, forbidden: &forbidden)
        let ports = try await optional("v1/portforward", as: GluetunPortForward.self, forbidden: &forbidden)
        let dns = try await optional("v1/dns/status", as: GluetunLoopStatus.self, forbidden: &forbidden)
        let updater = try await optional("v1/updater/status", as: GluetunLoopStatus.self, forbidden: &forbidden)
        if forbidden.count == 6 { throw NetworkError.unauthorized }
        return GluetunOverview(version: version?.version, vpn: vpn, publicIP: ip, portForward: ports, dns: dns, updater: updater, forbiddenRoutes: forbidden)
    }

    func dashboard() async throws -> DashboardSnapshot {
        GluetunDashboard.snapshot(try await overview(), operations: self)
    }

    func set(_ loop: GluetunLoop, running: Bool) async throws {
        _ = try await rest.data(RESTRequest(method: "PUT", path: "v1/\(loop.rawValue)/status",
                                            body: .json(try JSONEncoder().encode(["status": running ? "running" : "stopped"]))))
    }
}

enum GluetunDashboard {
    static func snapshot(_ overview: GluetunOverview, operations: some GluetunOperations) -> DashboardSnapshot {
        let vpn = overview.vpn
        let ip = overview.publicIP?.public_ip.nilIfEmpty
        let ports = overview.portForward?.all ?? []
        let health = vpn?.health ?? .unknown

        var actions: [DashboardAction] = []
        if let vpn {
            if vpn.status == "running" {
                actions.append(DashboardAction(id: "vpn:stop", title: "Stop VPN…", systemImage: "stop.fill", targetKind: "VPN tunnel", targetName: "Gluetun",
                                               consequence: "Gluetun closes the tunnel but keeps its firewall up, so every container that uses Gluetun's network loses internet access until the VPN is started again.",
                                               confirmation: .destructive) {
                    try await operations.set(.vpn, running: false)
                })
                actions.append(DashboardAction(id: "vpn:restart", title: "Reconnect VPN", systemImage: "arrow.clockwise", targetKind: "VPN tunnel", targetName: "Gluetun",
                                               consequence: "Gluetun stops and restarts the tunnel. Containers using it lose connectivity briefly and may get a new public IP and forwarded port.") {
                    try await operations.set(.vpn, running: false)
                    try await operations.set(.vpn, running: true)
                })
            } else if vpn.status != "starting" {
                actions.append(DashboardAction(id: "vpn:start", title: "Start VPN", systemImage: "play.fill", targetKind: "VPN tunnel", targetName: "Gluetun",
                                               consequence: "Gluetun opens the tunnel so containers using it regain internet access.", confirmation: .none) {
                    try await operations.set(.vpn, running: true)
                })
            }
        }
        if let updater = overview.updater, updater.status != "running" {
            actions.append(DashboardAction(id: "updater:run", title: "Update Server List", systemImage: "arrow.down.circle", targetKind: "Server list", targetName: "Gluetun",
                                           consequence: "Gluetun downloads the latest VPN server list from its providers.", confirmation: .none) {
                try await operations.set(.updater, running: true)
            })
        }

        func loopRow(_ id: String, _ title: String, _ loop: GluetunLoopStatus?) -> DashboardRow? {
            loop.map { DashboardRow(id: id, title: title, health: $0.health, badge: $0.status.capitalizedFirst) }
        }

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: vpn.map { "VPN \($0.status)" + (ip.map { " · \($0)" } ?? "") } ?? "VPN status unavailable",
            detail: overview.publicIP?.place,
            notice: overview.forbiddenRoutes.isEmpty ? nil : "Gluetun's role for these credentials doesn't allow: \(overview.forbiddenRoutes.map { "/" + $0 }.joined(separator: ", ")).",
            metrics: [
                DashboardMetric(title: "VPN", value: vpn?.status.capitalizedFirst ?? "—", systemImage: "lock.shield", health: vpn?.health),
                DashboardMetric(title: "Public IP", value: ip ?? "Unknown", systemImage: "globe"),
                DashboardMetric(title: "Forwarded port", value: ports.isEmpty ? "None" : ports.map(String.init).joined(separator: ", "), systemImage: "arrow.left.arrow.right"),
            ],
            actions: actions,
            sections: [
                DashboardSection(id: "loops", title: "Services", systemImage: "gearshape.2", emptyText: "No service status is available.",
                                 rows: [loopRow("vpn", "VPN tunnel", overview.vpn), loopRow("dns", "DNS server", overview.dns), loopRow("updater", "Server list updater", overview.updater)].compactMap { $0 }),
                DashboardSection(id: "exit", title: "Exit Location", systemImage: "mappin.and.ellipse", emptyText: "Gluetun hasn't looked up its public IP yet.",
                                 rows: ip == nil ? [] : [DashboardRow(id: "ip", title: ip ?? "", subtitle: overview.publicIP?.place,
                                                                      detail: [overview.publicIP?.organization, overview.publicIP?.hostname].compactMap { $0?.nilIfEmpty }.joined(separator: " · ").nilIfEmpty)]),
            ]
        )
    }
}
