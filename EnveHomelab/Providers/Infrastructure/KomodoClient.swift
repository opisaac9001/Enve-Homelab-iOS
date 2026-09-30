import Foundation

struct KomodoListItem<Info: Decodable & Sendable>: Decodable, Sendable {
    var id: String
    var name: String
    var info: Info
}

struct KomodoServerInfo: Decodable, Sendable {
    struct Stats: Decodable, Sendable { var cpu_perc: Double?; var mem_used_gb: Double?; var mem_total_gb: Double? }
    var state: String
    var region: String?
    var version: String?
    var stats: Stats?
}

struct KomodoStackInfo: Decodable, Sendable {
    struct Service: Decodable, Sendable { var service: String; var update_available: Bool? }
    var state: String
    var status: String?
    var server_name: String?
    var server_id: String?
    var services: [Service]?
}

struct KomodoDeploymentInfo: Decodable, Sendable {
    var state: String
    var status: String?
    var image: String?
    var update_available: Bool?
    var server_name: String?
    var server_id: String?
}

struct KomodoAlert: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        var type: String
        var data: [String: JSONScalar]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            // Variant payloads differ; only their scalar fields (e.g. name) are read.
            data = try container.decodeIfPresent([String: JSONScalar].self, forKey: .data)
        }

        enum CodingKeys: String, CodingKey { case type, data }
    }
    var level: String
    var ts: Double?
    var data: Payload

    var targetName: String? { if case .string(let name) = data.data?["name"] { name } else { nil } }
}

typealias KomodoServer = KomodoListItem<KomodoServerInfo>
typealias KomodoStack = KomodoListItem<KomodoStackInfo>
typealias KomodoDeployment = KomodoListItem<KomodoDeploymentInfo>

struct KomodoOverview: Sendable {
    var version: String?
    var servers: [KomodoServer]
    var stacks: [KomodoStack]
    var deployments: [KomodoDeployment]
    var alerts: [KomodoAlert]
}

protocol KomodoOperations: Sendable {
    func stack(_ action: DockerAction, id: String) async throws
    func deployment(_ action: DockerAction, id: String) async throws
}

/// Komodo Core API: `POST /read` and `/execute` with `{type, params}` and the `X-Api-Key`/`X-Api-Secret` pair.
struct KomodoClient: DashboardService, KomodoOperations {
    let kind = IntegrationKind.komodo
    static let pollLimit = 60
    private let rest: RESTClient

    init(url: URL, apiKey: String, apiSecret: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-Api-Key": apiKey, "X-Api-Secret": apiSecret])
    }

    private struct Request<Params: Encodable>: Encodable { var type: String; var params: Params }
    private struct NoParams: Encodable {}
    private struct Paging: Encodable { var limit = 0 }

    private func read<Response: Decodable>(_ type: String, _ params: some Encodable = NoParams(), as response: Response.Type) async throws -> Response {
        try await rest.json(try .post("read", json: Request(type: type, params: params)), as: Response.self)
    }

    private struct Version: Decodable { var version: String }
    private struct Alerts: Decodable { var alerts: [KomodoAlert] }
    private struct AlertQuery: Encodable { struct Query: Encodable { var resolved = false }; var query = Query() }

    func overview() async throws -> KomodoOverview {
        // limit 0 turns off pagination on 2.3+; older Cores ignore it and return everything.
        async let version = try? read("GetVersion", as: Version.self)
        async let servers = read("ListServers", Paging(), as: [KomodoServer].self)
        async let stacks = read("ListStacks", Paging(), as: [KomodoStack].self)
        async let deployments = read("ListDeployments", Paging(), as: [KomodoDeployment].self)
        async let alerts = try? read("ListAlerts", AlertQuery(), as: Alerts.self)
        return try await KomodoOverview(version: version?.version, servers: servers, stacks: stacks, deployments: deployments, alerts: alerts?.alerts ?? [])
    }

    func dashboard() async throws -> DashboardSnapshot {
        KomodoDashboard.snapshot(try await overview(), operations: self)
    }

    private struct Update: Decodable {
        struct ObjectID: Decodable { var oid: String; enum CodingKeys: String, CodingKey { case oid = "$oid" } }
        struct Log: Decodable { var stage: String?; var stderr: String?; var success: Bool? }
        var _id: ObjectID?
        var status: String
        var success: Bool
        var logs: [Log]?
    }

    /// Komodo answers 200 before it checks permissions or runs the action, so the update is followed until it completes.
    private func execute(_ type: String, _ params: some Encodable) async throws {
        var update = try await rest.json(try .post("execute", json: Request(type: type, params: params)), as: Update.self)
        guard let id = update._id?.oid else { return }
        for _ in 0..<Self.pollLimit where update.status != "Complete" {
            try await Task.sleep(for: .seconds(1))
            update = try await read("GetUpdate", ["id": id], as: Update.self)
        }
        guard update.status == "Complete" else { throw NetworkError.timedOut }
        if !update.success {
            let failure = update.logs?.last { $0.success == false }
            throw NetworkError.graphQL([failure?.stderr?.nilIfEmpty ?? "Komodo reported that \(type) failed."])
        }
    }

    func stack(_ action: DockerAction, id: String) async throws {
        try await execute("\(action.rawValue.capitalizedFirst)Stack", ["stack": id])
    }

    func deployment(_ action: DockerAction, id: String) async throws {
        try await execute("\(action.rawValue.capitalizedFirst)Deployment", ["deployment": id])
    }
}

enum KomodoDashboard {
    static func serverHealth(_ state: String) -> Health {
        switch state {
        case "Ok": .ok
        case "NotOk": .critical
        default: .unknown
        }
    }

    static func resourceHealth(_ state: String) -> Health {
        switch state {
        case "running": .ok
        case "unhealthy", "dead", "restarting": .warning
        case "deploying", "removing", "stopping", "created": .unknown
        default: .unknown
        }
    }

    static func isRunning(_ state: String) -> Bool { ["running", "unhealthy", "restarting", "paused"].contains(state) }

    static func snapshot(_ overview: KomodoOverview, operations: some KomodoOperations) -> DashboardSnapshot {
        let unreachable = overview.servers.filter { $0.info.state == "NotOk" }
        let unhealthyStacks = overview.stacks.filter { resourceHealth($0.info.state) == .warning }
        let critical = overview.alerts.filter { $0.level == "CRITICAL" }
        let updates = overview.stacks.filter { $0.info.services?.contains { $0.update_available == true } == true }.count
            + overview.deployments.filter { $0.info.update_available == true }.count
        let health: Health = !unreachable.isEmpty || !critical.isEmpty ? .critical : (unhealthyStacks.isEmpty && overview.alerts.isEmpty ? .ok : .warning)

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: "\(overview.servers.count - unreachable.count) of \(overview.servers.count) servers reachable · \(overview.stacks.filter { $0.info.state == "running" }.count) stacks running",
            detail: overview.alerts.isEmpty ? nil : "\(overview.alerts.count) open alert\(overview.alerts.count == 1 ? "" : "s")",
            metrics: [
                DashboardMetric(title: "Servers OK", value: "\(overview.servers.count - unreachable.count)/\(overview.servers.count)", systemImage: "server.rack", health: unreachable.isEmpty ? .ok : .critical),
                DashboardMetric(title: "Stacks running", value: "\(overview.stacks.filter { $0.info.state == "running" }.count)/\(overview.stacks.count)", systemImage: "square.stack.3d.up"),
                DashboardMetric(title: "Open alerts", value: "\(overview.alerts.count)", systemImage: "bell", health: overview.alerts.isEmpty ? .ok : (critical.isEmpty ? .warning : .critical)),
                DashboardMetric(title: "Image updates", value: "\(updates)", systemImage: "arrow.down.circle"),
            ],
            sections: [
                DashboardSection(id: "alerts", title: "Open Alerts", systemImage: "bell", trailing: "\(overview.alerts.count)", emptyText: "No unresolved alerts.",
                                 rows: overview.alerts.enumerated().map { index, alert in
                                     DashboardRow(id: "alert:\(index)", title: alert.data.type.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2.lowercased())" },
                                                  subtitle: alert.targetName, detail: alert.ts.map { Format.relative(Date(timeIntervalSince1970: $0 / 1000)) },
                                                  health: alert.level == "CRITICAL" ? .critical : .warning, badge: alert.level.capitalized)
                                 }),
                DashboardSection(id: "servers", title: "Servers", systemImage: "server.rack", trailing: "\(overview.servers.count)", emptyText: "No servers are connected.",
                                 rows: overview.servers.map { server in
                                     let stats = server.info.stats
                                     return DashboardRow(id: "server:\(server.id)", title: server.name,
                                                         subtitle: [server.info.region?.nilIfEmpty, server.info.version.map { "Periphery \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: [stats?.cpu_perc.map { "CPU " + Format.percent($0 / 100) },
                                                                  stats.flatMap { s in s.mem_used_gb.flatMap { used in s.mem_total_gb.map { String(format: "Mem %.1f/%.1f GB", used, $0) } } }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         health: serverHealth(server.info.state), badge: server.info.state == "NotOk" ? "Unreachable" : server.info.state)
                                 }),
                DashboardSection(id: "stacks", title: "Stacks", systemImage: "square.stack.3d.up", trailing: "\(overview.stacks.count)", emptyText: "No stacks.",
                                 rows: overview.stacks.map { stack in
                                     let rowID = "stack:\(stack.id)"
                                     let actions = ContainerLifecycle.actions(name: stack.name, running: isRunning(stack.info.state), environmentName: stack.info.server_name ?? "its server", targetKind: "Stack") { action in
                                         try await operations.stack(action, id: stack.id)
                                     }
                                     let updates = stack.info.services?.filter { $0.update_available == true }.map(\.service) ?? []
                                     return DashboardRow(id: rowID, title: stack.name, subtitle: stack.info.server_name,
                                                         detail: stack.info.status, health: resourceHealth(stack.info.state), badge: stack.info.state.replacingOccurrences(of: "_", with: " ").capitalizedFirst,
                                                         message: updates.isEmpty ? nil : "Image update available: " + updates.joined(separator: ", "),
                                                         actions: ContainerLifecycle.prefixed(actions, rowID))
                                 }),
                DashboardSection(id: "deployments", title: "Deployments", systemImage: "shippingbox", trailing: "\(overview.deployments.count)", emptyText: "No deployments.",
                                 rows: overview.deployments.map { deployment in
                                     let rowID = "deployment:\(deployment.id)"
                                     let actions = deployment.info.state == "not_deployed" ? [] : ContainerLifecycle.actions(name: deployment.name, running: isRunning(deployment.info.state),
                                                                                                                          environmentName: deployment.info.server_name ?? "its server") { action in
                                         try await operations.deployment(action, id: deployment.id)
                                     }
                                     return DashboardRow(id: rowID, title: deployment.name, subtitle: [deployment.info.server_name, deployment.info.image].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: deployment.info.status, health: resourceHealth(deployment.info.state),
                                                         badge: deployment.info.state.replacingOccurrences(of: "_", with: " ").capitalizedFirst,
                                                         message: deployment.info.update_available == true ? "Image update available" : nil,
                                                         actions: ContainerLifecycle.prefixed(actions, rowID))
                                 }),
            ]
        )
    }
}
