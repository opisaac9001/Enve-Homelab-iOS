import Foundation

struct DockhandEnvironment: Decodable, Sendable {
    var id: Int
    var name: String
}

struct DockhandContainer: Decodable, Sendable {
    var id: String
    var name: String
    var image: String?
    var state: String
    var status: String?
    var health: String?
    var restartCount: Int?
}

struct DockhandStack: Decodable, Sendable {
    var name: String
    var status: String
    var containers: [String]?
}

struct DockhandOverview: Sendable {
    struct Environment: Sendable {
        var environment: DockhandEnvironment
        var containers: [DockhandContainer]
        var stacks: [DockhandStack]
    }
    var environments: [Environment]
}

protocol DockhandOperations: Sendable {
    func container(_ action: DockerAction, id: String, environment: Int) async throws
    func stack(_ action: DockerAction, name: String, environment: Int) async throws
}

/// Dockhand REST API (1.0.25+) with a `dh_` Bearer token. Every Docker call is scoped with `?env=`.
struct DockhandClient: DashboardService, DockhandOperations {
    let kind = IntegrationKind.dockhand
    private let rest: RESTClient

    init(url: URL, token: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(token)"], timeout: 120)
    }

    private func env(_ id: Int) -> [URLQueryItem] { [URLQueryItem(name: "env", value: String(id))] }

    func overview() async throws -> DockhandOverview {
        let environments = try await rest.json(.get("environments"), as: [DockhandEnvironment].self)
        var result: [DockhandOverview.Environment] = []
        for environment in environments {
            async let containers = rest.json(.get("containers", query: env(environment.id) + [URLQueryItem(name: "all", value: "true")]), as: [DockhandContainer].self)
            async let stacks = rest.json(.get("stacks", query: env(environment.id)), as: [DockhandStack].self)
            result.append(try await .init(environment: environment, containers: containers, stacks: stacks))
        }
        return DockhandOverview(environments: result)
    }

    func dashboard() async throws -> DashboardSnapshot {
        DockhandDashboard.snapshot(try await overview(), operations: self)
    }

    private struct Outcome: Decodable { var success: Bool?; var error: String? }

    private func run(_ path: String, environment: Int) async throws {
        let data = try await rest.data(.post(path, query: env(environment)))
        if let outcome = try? JSONDecoder().decode(Outcome.self, from: data), outcome.success == false {
            throw NetworkError.graphQL([outcome.error ?? "Dockhand reported that the action failed."])
        }
    }

    func container(_ action: DockerAction, id: String, environment: Int) async throws {
        try await run("containers/\(id)/\(action.rawValue)", environment: environment)
    }

    /// With `Accept: application/json` Dockhand waits for the stack job and returns its result instead of a job ID.
    func stack(_ action: DockerAction, name: String, environment: Int) async throws {
        try await run("stacks/\(name)/\(action.rawValue)", environment: environment)
    }
}

enum DockhandDashboard {
    static func stackHealth(_ status: String) -> Health {
        switch status {
        case "running": .ok
        case "partial", "restarting": .warning
        default: .unknown
        }
    }

    static func snapshot(_ overview: DockhandOverview, operations: some DockhandOperations) -> DashboardSnapshot {
        let all = overview.environments.flatMap { env in env.containers.map { (env.environment, $0) } }
        let running = all.filter { $0.1.state == "running" }.count
        let unhealthy = all.filter { ContainerLifecycle.health(state: $0.1.state, health: $0.1.health) >= .warning }
        let stacks = overview.environments.flatMap { env in env.stacks.map { (env.environment, $0) } }
        let degraded = stacks.filter { stackHealth($0.1.status) == .warning }
        let multiple = overview.environments.count > 1

        return DashboardSnapshot(
            version: nil,
            health: unhealthy.contains { ContainerLifecycle.health(state: $0.1.state, health: $0.1.health) == .critical } ? .critical : (unhealthy.isEmpty && degraded.isEmpty ? .ok : .warning),
            headline: "\(running) of \(all.count) containers running" + (unhealthy.isEmpty ? "" : " · \(unhealthy.count) need attention"),
            detail: "\(overview.environments.count) environment\(overview.environments.count == 1 ? "" : "s") · \(stacks.count) stack\(stacks.count == 1 ? "" : "s")",
            notice: all.isEmpty ? "Dockhand lists no containers. It also reports an empty list when it can't reach Docker, so check the environment in Dockhand if you expected some." : nil,
            metrics: [
                DashboardMetric(title: "Running", value: "\(running)/\(all.count)", systemImage: "shippingbox"),
                DashboardMetric(title: "Unhealthy or restarting", value: "\(unhealthy.count)", systemImage: "cross.case", health: unhealthy.isEmpty ? .ok : .warning),
                DashboardMetric(title: "Stacks", value: "\(stacks.count)", systemImage: "square.stack.3d.up", health: degraded.isEmpty ? nil : .warning),
            ],
            sections: [
                DashboardSection(id: "stacks", title: "Stacks", systemImage: "square.stack.3d.up", trailing: "\(stacks.count)", emptyText: "No compose stacks.",
                                 rows: stacks.map { environment, stack in
                                     let rowID = "stack:\(environment.id):\(stack.name)"
                                     let actions = ContainerLifecycle.actions(name: stack.name, running: stack.status != "stopped" && stack.status != "created", environmentName: environment.name, targetKind: "Stack") { action in
                                         try await operations.stack(action, name: stack.name, environment: environment.id)
                                     }
                                     return DashboardRow(id: rowID, title: stack.name, subtitle: multiple ? environment.name : nil,
                                                         detail: stack.containers.map { "\($0.count) container\($0.count == 1 ? "" : "s")" },
                                                         health: stackHealth(stack.status), badge: stack.status.capitalizedFirst, actions: ContainerLifecycle.prefixed(actions, rowID))
                                 }),
                DashboardSection(id: "containers", title: "Containers", systemImage: "shippingbox", trailing: "\(all.count)", emptyText: "No containers.",
                                 rows: all.sorted { ($0.1.state == "running" ? 1 : 0, $0.1.name) < ($1.1.state == "running" ? 1 : 0, $1.1.name) }.map { environment, container in
                                     let rowID = "container:\(environment.id):\(container.id)"
                                     let actions = ContainerLifecycle.actions(name: container.name, running: container.state == "running", environmentName: environment.name) { action in
                                         try await operations.container(action, id: container.id, environment: environment.id)
                                     }
                                     return DashboardRow(id: rowID, title: container.name,
                                                         subtitle: [multiple ? environment.name : nil, container.image].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: [container.status, (container.restartCount ?? 0) > 0 ? "\(container.restartCount ?? 0) restarts" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         health: ContainerLifecycle.health(state: container.state, health: container.health),
                                                         badge: container.health?.capitalizedFirst ?? container.state.capitalizedFirst, actions: ContainerLifecycle.prefixed(actions, rowID))
                                 }, limit: 100),
            ]
        )
    }
}
