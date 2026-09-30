import Foundation
import os

/// Beszel's docs warn the record structure may change in minor releases, so every metric is optional.
struct BeszelSystem: Decodable, Sendable {
    struct Info: Decodable, Sendable {
        var u: Double?
        var cpu: Double?
        var mp: Double?
        var dp: Double?
        var bb: Double?
        var v: String?
        var la: [Double]?
        var dt: Double?
        var sv: [Int]?
    }

    var id: String
    var name: String
    var status: String
    var host: String?
    var info: Info?

    var health: Health {
        switch status {
        case "up": .ok
        case "down": .critical
        case "paused": .unknown
        default: .unknown
        }
    }
}

struct BeszelContainer: Decodable, Sendable {
    var id: String
    var name: String
    var system: String
    var status: String?
    var health: Int?
    var cpu: Double?
    var memory: Double?
}

struct BeszelAlert: Decodable, Sendable {
    var id: String
    var name: String
    var system: String
    var triggered: Bool?
}

struct BeszelOverview: Sendable {
    var version: String?
    var systems: [BeszelSystem]
    var containers: [BeszelContainer]
    var alerts: [BeszelAlert]
}

protocol BeszelOperations: Sendable {
    func setPaused(_ paused: Bool, systemID: String) async throws
}

/// Beszel hub through its PocketBase REST API, which Beszel's docs endorse. PocketBase sends the raw token in `Authorization`.
final class BeszelClient: DashboardService, BeszelOperations {
    let kind = IntegrationKind.beszel
    private let rest: RESTClient
    private let email: String
    private let password: String
    private let token = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(url: URL, email: String, password: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint)
        self.email = email
        self.password = password
    }

    private struct Login: Encodable { var identity: String; var password: String }
    private struct Auth: Decodable { var token: String }
    private struct MFA: Decodable { var mfaId: String }

    private func login() async throws -> String {
        let (data, response) = try await rest.raw(try .post("api/collections/users/auth-with-password", json: Login(identity: email, password: password)))
        if response.statusCode == 401, (try? JSONDecoder().decode(MFA.self, from: data)) != nil {
            throw NetworkError.forbidden("This Beszel hub requires a one-time code at sign-in, which the app doesn't support.")
        }
        // PocketBase answers wrong credentials with 400; hubs with password sign-in turned off refuse it.
        if response.statusCode == 400 { throw NetworkError.unauthorized }
        if response.statusCode == 403 { throw NetworkError.forbidden(RESTClient.serverMessage(data) ?? "This hub doesn't allow password sign-in.") }
        try RESTClient.validate(response, data: data)
        let auth = try RESTClient.decode(Auth.self, from: data)
        token.withLock { $0 = auth.token }
        return auth.token
    }

    private func authorized(_ request: RESTRequest) async throws -> Data {
        var current: String
        if let cached = token.withLock({ $0 }) { current = cached } else { current = try await login() }
        for attempt in 0..<2 {
            var signed = request
            signed.headers["Authorization"] = current
            let (data, response) = try await rest.raw(signed)
            if response.statusCode == 401, attempt == 0 {
                current = try await login()
                continue
            }
            try RESTClient.validate(response, data: data)
            return data
        }
        throw NetworkError.unauthorized
    }

    private struct Page<Item: Decodable>: Decodable { var items: [Item] }
    private struct Info: Decodable { var v: String? }

    private func list<Item: Decodable>(_ collection: String, _ query: [URLQueryItem], as type: Item.Type) async throws -> [Item] {
        try RESTClient.decode(Page<Item>.self, from: try await authorized(.get("api/collections/\(collection)/records", query: query + [URLQueryItem(name: "skipTotal", value: "1")]))).items
    }

    func overview() async throws -> BeszelOverview {
        let systems = try await list("systems", [URLQueryItem(name: "perPage", value: "500"), URLQueryItem(name: "sort", value: "name")], as: BeszelSystem.self)
        let version = try? RESTClient.decode(Info.self, from: try await authorized(.get("api/beszel/info"))).v
        // Older hubs lack these collections; their absence isn't an error.
        let containers = (try? await list("containers", [URLQueryItem(name: "perPage", value: "500"), URLQueryItem(name: "fields", value: "id,name,system,status,health,cpu,memory")], as: BeszelContainer.self)) ?? []
        let alerts = (try? await list("alerts", [URLQueryItem(name: "perPage", value: "500"), URLQueryItem(name: "filter", value: "triggered=true")], as: BeszelAlert.self)) ?? []
        return BeszelOverview(version: version, systems: systems, containers: containers, alerts: alerts)
    }

    func dashboard() async throws -> DashboardSnapshot {
        BeszelDashboard.snapshot(try await overview(), operations: self)
    }

    func setPaused(_ paused: Bool, systemID: String) async throws {
        // The web UI resumes a system by setting it back to pending; the hub then reconnects.
        _ = try await authorized(try RESTRequest(method: "PATCH", path: "api/collections/systems/records/\(systemID)",
                                                 body: .json(JSONEncoder().encode(["status": paused ? "paused" : "pending"]))))
    }
}

enum BeszelDashboard {
    static func snapshot(_ overview: BeszelOverview, operations: some BeszelOperations) -> DashboardSnapshot {
        let systems = overview.systems
        let down = systems.filter { $0.status == "down" }
        let names = Dictionary(systems.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let unhealthy = overview.containers.filter { $0.health == 3 }
        let health: Health = !down.isEmpty ? .critical : (overview.alerts.isEmpty && unhealthy.isEmpty ? .ok : .warning)

        func percent(_ value: Double?) -> String? { value.map { Format.percent($0 / 100) } }

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: "\(systems.filter { $0.status == "up" }.count) of \(systems.count) systems up" + (overview.alerts.isEmpty ? "" : " · \(overview.alerts.count) alert\(overview.alerts.count == 1 ? "" : "s")"),
            detail: down.isEmpty ? nil : "Down: " + down.map(\.name).joined(separator: ", "),
            metrics: [
                DashboardMetric(title: "Systems up", value: "\(systems.filter { $0.status == "up" }.count)/\(systems.count)", systemImage: "server.rack", health: down.isEmpty ? .ok : .critical),
                DashboardMetric(title: "Triggered alerts", value: "\(overview.alerts.count)", systemImage: "bell", health: overview.alerts.isEmpty ? .ok : .warning),
                DashboardMetric(title: "Containers", value: "\(overview.containers.count)", systemImage: "shippingbox", health: unhealthy.isEmpty ? nil : .warning),
            ],
            sections: [
                DashboardSection(id: "systems", title: "Systems", systemImage: "server.rack", trailing: "\(systems.count)", emptyText: "No systems are added to this hub.",
                                 rows: systems.map { system in
                                     let info = system.info
                                     var detail = [percent(info?.cpu).map { "CPU \($0)" }, percent(info?.mp).map { "Mem \($0)" }, percent(info?.dp).map { "Disk \($0)" }]
                                     detail.append(info?.la.flatMap { $0.first }.map { String(format: "Load %.2f", $0) })
                                     detail.append(info?.dt.map { String(format: "%.0f°C", $0) })
                                     if let services = info?.sv, services.count > 1, services[1] > 0 { detail.append("\(services[1]) failed service\(services[1] == 1 ? "" : "s")") }
                                     var actions: [DashboardAction] = []
                                     if system.status == "paused" {
                                         actions.append(DashboardAction(id: "resume:\(system.id)", title: "Resume Monitoring", systemImage: "play.fill", targetKind: "System", targetName: system.name,
                                                                        consequence: "Beszel reconnects to \(system.name)'s agent and turns its alerts back on.", confirmation: .none) {
                                             try await operations.setPaused(false, systemID: system.id)
                                         })
                                     } else {
                                         actions.append(DashboardAction(id: "pause:\(system.id)", title: "Pause Monitoring", systemImage: "pause.fill", targetKind: "System", targetName: system.name,
                                                                        consequence: "Beszel stops collecting stats from \(system.name) and turns off its alerts until you resume it, so outages won't be reported.") {
                                             try await operations.setPaused(true, systemID: system.id)
                                         })
                                     }
                                     return DashboardRow(id: system.id, title: system.name,
                                                         subtitle: [system.host, info?.v.map { "agent \($0)" }, info?.u.map { "up \(Format.duration($0))" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: detail.compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         health: system.health, badge: system.status.capitalizedFirst, progress: info?.mp.map { $0 / 100 }, actions: actions)
                                 }),
                DashboardSection(id: "alerts", title: "Triggered Alerts", systemImage: "bell", trailing: "\(overview.alerts.count)", emptyText: "No alerts are triggered.",
                                 rows: overview.alerts.map { DashboardRow(id: $0.id, title: $0.name, subtitle: names[$0.system], health: .warning) }),
                DashboardSection(id: "containers", title: "Containers", systemImage: "shippingbox", trailing: "\(overview.containers.count)", emptyText: "No containers reported.",
                                 rows: overview.containers.sorted { ($0.health == 3 ? 0 : 1, $0.name) < ($1.health == 3 ? 0 : 1, $1.name) }.map { container in
                                     let healthText: String? = switch container.health {
                                     case 1: "Starting"
                                     case 2: "Healthy"
                                     case 3: "Unhealthy"
                                     default: nil
                                     }
                                     return DashboardRow(id: "\(container.system):\(container.id)", title: container.name,
                                                         subtitle: [names[container.system], container.status].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: [container.cpu.map { "CPU " + Format.percent($0 / 100) }, container.memory.map { "Mem \(Format.bytes(Int64($0 * 1_048_576)))" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         health: container.health == 3 ? .warning : nil, badge: healthText)
                                 }, limit: 100),
            ]
        )
    }
}
