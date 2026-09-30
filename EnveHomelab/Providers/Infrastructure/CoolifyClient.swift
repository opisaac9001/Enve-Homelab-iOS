import Foundation

/// Coolify statuses look like `running:healthy`, `degraded:unhealthy`, bare `exited`, sometimes with `:excluded`.
struct CoolifyStatus: Sendable, Equatable {
    var state: String
    var health: String?

    init(_ raw: String?) {
        let parts = (raw ?? "unknown").split(separator: ":").map(String.init)
        state = parts.first ?? "unknown"
        health = parts.count > 1 && parts[1] != "excluded" ? parts[1] : nil
    }

    var isRunning: Bool { ["running", "degraded", "restarting", "starting"].contains(state) }

    var appHealth: Health {
        if state == "degraded" || health == "unhealthy" { return .warning }
        if state == "running" { return .ok }
        return .unknown
    }

    var label: String { health.map { "\(state.capitalizedFirst) · \($0)" } ?? state.capitalizedFirst }
}

struct CoolifyServer: Decodable, Sendable {
    var uuid: String
    var name: String
    var ip: String?
    var is_reachable: Bool?
    var is_usable: Bool?
}

struct CoolifyResource: Decodable, Sendable {
    var uuid: String
    var name: String
    var status: String?
    var fqdn: String?
    var database_type: String?
    var service_type: String?
}

struct CoolifyDeployment: Decodable, Sendable {
    var deployment_uuid: String
    var application_name: String?
    var server_name: String?
    var status: String
    var commit_message: String?
    var created_at: String?
}

/// `GET /deployments` can come back as an object keyed by index instead of an array.
struct CoolifyDeploymentList: Decodable, Sendable {
    var items: [CoolifyDeployment]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let array = try? container.decode([CoolifyDeployment].self) {
            items = array
        } else {
            items = try container.decode([String: CoolifyDeployment].self).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.value)
        }
    }
}

enum CoolifyResourceKind: String, Sendable {
    case applications, services, databases

    var noun: String {
        switch self {
        case .applications: "Application"
        case .services: "Service"
        case .databases: "Database"
        }
    }
}

struct CoolifyOverview: Sendable {
    var version: String?
    var servers: [CoolifyServer]
    var applications: [CoolifyResource]
    var services: [CoolifyResource]
    var databases: [CoolifyResource]
    var deployments: [CoolifyDeployment]
}

protocol CoolifyOperations: Sendable {
    func perform(_ action: DockerAction, on kind: CoolifyResourceKind, uuid: String) async throws
    func deploy(uuid: String) async throws
    func cancel(deployment uuid: String) async throws
}

/// Coolify v4 API (`/api/v1`, Sanctum Bearer token). A `read` + `deploy` token covers everything here.
struct CoolifyClient: DashboardService, CoolifyOperations {
    let kind = IntegrationKind.coolify
    private let rest: RESTClient

    init(url: URL, token: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api/v1"), pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(token)"])
    }

    func overview() async throws -> CoolifyOverview {
        // /version is plain text, not JSON.
        let version = String(decoding: try await rest.data(.get("version")), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        async let servers = rest.json(.get("servers"), as: [CoolifyServer].self)
        async let applications = rest.json(.get("applications"), as: [CoolifyResource].self)
        async let services = rest.json(.get("services"), as: [CoolifyResource].self)
        async let databases = rest.json(.get("databases"), as: [CoolifyResource].self)
        async let deployments = rest.json(.get("deployments"), as: CoolifyDeploymentList.self)
        return try await CoolifyOverview(version: version, servers: servers, applications: applications, services: services, databases: databases, deployments: deployments.items)
    }

    func dashboard() async throws -> DashboardSnapshot {
        CoolifyDashboard.snapshot(try await overview(), operations: self)
    }

    /// Stop defaults to pruning networks and volumes on the server; the app always opts out.
    func perform(_ action: DockerAction, on kind: CoolifyResourceKind, uuid: String) async throws {
        let query = action == .stop ? [URLQueryItem(name: "docker_cleanup", value: "false")] : []
        _ = try await rest.data(.post("\(kind.rawValue)/\(uuid)/\(action.rawValue)", query: query))
    }

    func deploy(uuid: String) async throws {
        _ = try await rest.data(.post("deploy", query: [URLQueryItem(name: "uuid", value: uuid)]))
    }

    func cancel(deployment uuid: String) async throws {
        _ = try await rest.data(.post("deployments/\(uuid)/cancel"))
    }
}

enum CoolifyDashboard {
    static func resourceRow(_ resource: CoolifyResource, kind: CoolifyResourceKind, operations: some CoolifyOperations) -> DashboardRow {
        let status = CoolifyStatus(resource.status)
        let rowID = "\(kind.rawValue):\(resource.uuid)"
        var actions: [DashboardAction] = []
        if status.isRunning {
            actions.append(DashboardAction(id: "\(rowID):restart", title: "Restart", systemImage: "arrow.clockwise", targetKind: kind.noun, targetName: resource.name,
                                           consequence: "Coolify restarts \(resource.name) without rebuilding it; it's briefly unavailable.") {
                try await operations.perform(.restart, on: kind, uuid: resource.uuid)
            })
            actions.append(DashboardAction(id: "\(rowID):stop", title: "Stop…", systemImage: "stop.fill", targetKind: kind.noun, targetName: resource.name,
                                           consequence: "Coolify stops \(resource.name) and it stays offline until started again. Its volumes and networks are kept.", confirmation: .destructive) {
                try await operations.perform(.stop, on: kind, uuid: resource.uuid)
            })
        } else {
            actions.append(DashboardAction(id: "\(rowID):start", title: "Start", systemImage: "play.fill", targetKind: kind.noun, targetName: resource.name,
                                           consequence: kind == .applications ? "Coolify queues a full deployment of \(resource.name): it builds and then starts it." : "Coolify starts \(resource.name).",
                                           confirmation: kind == .applications ? .confirm : .none) {
                try await operations.perform(.start, on: kind, uuid: resource.uuid)
            })
        }
        if kind == .applications {
            actions.append(DashboardAction(id: "\(rowID):deploy", title: "Redeploy", systemImage: "hammer", targetKind: kind.noun, targetName: resource.name,
                                           consequence: "Coolify rebuilds \(resource.name) from its source and replaces the running version. It may be briefly unavailable, and a failed build leaves the old version running.") {
                try await operations.deploy(uuid: resource.uuid)
            })
        }
        return DashboardRow(id: rowID, title: resource.name,
                            subtitle: resource.fqdn?.split(separator: ",").first.map(String.init) ?? resource.database_type?.replacingOccurrences(of: "standalone-", with: "") ?? resource.service_type,
                            health: status.appHealth, badge: status.label, actions: actions)
    }

    static func snapshot(_ overview: CoolifyOverview, operations: some CoolifyOperations) -> DashboardSnapshot {
        let resources = overview.applications + overview.services + overview.databases
        let statuses = resources.map { CoolifyStatus($0.status) }
        let running = statuses.filter(\.isRunning).count
        let degraded = statuses.filter { $0.appHealth == .warning }.count
        let unreachable = overview.servers.filter { $0.is_reachable == false || $0.is_usable == false }
        let failedDeployments = overview.deployments.filter { $0.status == "failed" }

        func section(_ id: String, _ title: String, _ image: String, _ items: [CoolifyResource], _ kind: CoolifyResourceKind) -> DashboardSection {
            DashboardSection(id: id, title: title, systemImage: image, trailing: "\(items.count)", emptyText: "None.",
                             rows: items.map { resourceRow($0, kind: kind, operations: operations) })
        }

        return DashboardSnapshot(
            version: overview.version,
            health: !unreachable.isEmpty ? .critical : (degraded > 0 || !failedDeployments.isEmpty ? .warning : .ok),
            headline: "\(running) of \(resources.count) resources running" + (overview.deployments.isEmpty ? "" : " · \(overview.deployments.count) deploying"),
            detail: unreachable.isEmpty ? nil : "Unreachable: " + unreachable.map(\.name).joined(separator: ", "),
            metrics: [
                DashboardMetric(title: "Servers reachable", value: "\(overview.servers.count - unreachable.count)/\(overview.servers.count)", systemImage: "server.rack", health: unreachable.isEmpty ? .ok : .critical),
                DashboardMetric(title: "Running", value: "\(running)/\(resources.count)", systemImage: "play.circle"),
                DashboardMetric(title: "Degraded", value: "\(degraded)", systemImage: "cross.case", health: degraded == 0 ? .ok : .warning),
                DashboardMetric(title: "Deployments in progress", value: "\(overview.deployments.count)", systemImage: "hammer"),
            ],
            sections: [
                DashboardSection(id: "deployments", title: "Deployments in Progress", systemImage: "hammer", trailing: "\(overview.deployments.count)", emptyText: "Nothing is deploying.",
                                 rows: overview.deployments.map { deployment in
                                     DashboardRow(id: "deployment:\(deployment.deployment_uuid)", title: deployment.application_name ?? "Deployment",
                                                  subtitle: [deployment.server_name, deployment.commit_message?.split(separator: "\n").first.map(String.init)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                  detail: APIDate.parse(deployment.created_at).map { "Started \(Format.relative($0))" },
                                                  badge: deployment.status.replacingOccurrences(of: "_", with: " ").capitalizedFirst,
                                                  actions: [DashboardAction(id: "cancel:\(deployment.deployment_uuid)", title: "Cancel Deployment…", systemImage: "xmark.octagon", targetKind: "Deployment",
                                                                            targetName: deployment.application_name ?? deployment.deployment_uuid,
                                                                            consequence: "Coolify kills the build immediately. The previously running version stays up.", confirmation: .destructive) {
                                                      try await operations.cancel(deployment: deployment.deployment_uuid)
                                                  }])
                                 }),
                section("applications", "Applications", "app.connected.to.app.below.fill", overview.applications, .applications),
                section("services", "Services", "square.stack.3d.up", overview.services, .services),
                section("databases", "Databases", "cylinder", overview.databases, .databases),
                DashboardSection(id: "servers", title: "Servers", systemImage: "server.rack", trailing: "\(overview.servers.count)", emptyText: "No servers.",
                                 rows: overview.servers.map { server in
                                     let ok = server.is_reachable != false && server.is_usable != false
                                     return DashboardRow(id: "server:\(server.uuid)", title: server.name, subtitle: server.ip, health: ok ? .ok : .critical, badge: ok ? "Reachable" : "Unreachable")
                                 }),
            ]
        )
    }
}
