import Foundation

struct ArcaneEnvironment: Decodable, Sendable {
    var id: String
    var name: String?
    var status: String
    var enabled: Bool
    var connected: Bool?
}

struct ArcaneContainer: Decodable, Sendable {
    var id: String
    var names: [String]
    var image: String
    var state: String
    var status: String

    var name: String { names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(id.prefix(12)) }
    /// Arcane only reports health inside Docker's status text, e.g. "Up 3 hours (unhealthy)".
    var dockerHealth: String? {
        ["unhealthy", "healthy", "starting"].first { status.localizedCaseInsensitiveContains("(\($0))") }
    }
}

/// The list also carries compose and `.env` contents, which may hold secrets; they aren't decoded.
struct ArcaneProject: Decodable, Sendable {
    var id: String
    var name: String
    var status: String
    var runningCount: Int
    var serviceCount: Int
    var statusReason: String?
}

struct ArcaneOverview: Sendable {
    struct Environment: Sendable {
        var environment: ArcaneEnvironment
        var containers: [ArcaneContainer]
        var projects: [ArcaneProject]
        var error: String?
    }
    var version: String?
    var environments: [Environment]
}

protocol ArcaneOperations: Sendable {
    func container(_ action: DockerAction, id: String, environment: String) async throws
    func project(_ action: DockerAction, id: String, environment: String) async throws
}

/// Arcane REST API with an `X-Api-Key` (scoped keys can be limited per environment). Local Docker is environment "0".
struct ArcaneClient: DashboardService, ArcaneOperations {
    let kind = IntegrationKind.arcane
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: ["X-Api-Key": apiKey], timeout: 120)
    }

    private struct Wrapped<Value: Decodable>: Decodable { var data: Value }
    private struct AppVersion: Decodable { var displayVersion: String?; var currentVersion: String? }

    private func list<Item: Decodable>(_ path: String, as type: Item.Type) async throws -> [Item] {
        try await rest.json(.get(path, query: [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "limit", value: "200")]), as: Wrapped<[Item]>.self).data
    }

    func overview() async throws -> ArcaneOverview {
        async let version = try? rest.json(.get("app-version"), as: AppVersion.self)
        let environments = try await list("environments", as: ArcaneEnvironment.self).filter(\.enabled)
        var result: [ArcaneOverview.Environment] = []
        for environment in environments {
            do {
                async let containers = list("environments/\(environment.id)/containers", as: ArcaneContainer.self)
                async let projects = list("environments/\(environment.id)/projects", as: ArcaneProject.self)
                result.append(try await .init(environment: environment, containers: containers, projects: projects))
            } catch NetworkError.forbidden(let message) {
                // Scoped keys may be granted only some environments.
                result.append(.init(environment: environment, containers: [], projects: [], error: message.nilIfEmpty ?? "This key has no access to this environment."))
            }
        }
        let info = await version
        return ArcaneOverview(version: info?.displayVersion ?? info?.currentVersion, environments: result)
    }

    func dashboard() async throws -> DashboardSnapshot {
        ArcaneDashboard.snapshot(try await overview(), operations: self)
    }

    func container(_ action: DockerAction, id: String, environment: String) async throws {
        _ = try await rest.data(.post("environments/\(environment)/containers/\(id)/\(action.rawValue)"))
    }

    /// `up` streams newline-delimited JSON and always answers 200; a failure is an `{"error": …}` line.
    func project(_ action: DockerAction, id: String, environment: String) async throws {
        let path = "environments/\(environment)/projects/\(id)/" + (action == .start ? "up" : (action == .stop ? "down" : "restart"))
        let data = try await rest.data(.post(path))
        if action == .start, let message = Self.streamError(data) { throw NetworkError.graphQL([message]) }
    }

    static func streamError(_ data: Data) -> String? {
        struct Line: Decodable { var error: String? }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)).error?.nilIfEmpty }
            .last
    }
}

enum ArcaneDashboard {
    static func projectHealth(_ status: String) -> Health {
        switch status {
        case "running": .ok
        case "partially running", "restarting": .warning
        default: .unknown
        }
    }

    static func snapshot(_ overview: ArcaneOverview, operations: some ArcaneOperations) -> DashboardSnapshot {
        let multiple = overview.environments.count > 1
        func label(_ environment: ArcaneEnvironment) -> String { environment.name ?? (environment.id == "0" ? "Local" : environment.id) }
        let containers = overview.environments.flatMap { env in env.containers.map { (env.environment, $0) } }
        let projects = overview.environments.flatMap { env in env.projects.map { (env.environment, $0) } }
        let running = containers.filter { $0.1.state == "running" }.count
        let unhealthy = containers.filter { ContainerLifecycle.health(state: $0.1.state, health: $0.1.dockerHealth) >= .warning }
        let offline = overview.environments.filter { $0.environment.status != "online" && $0.environment.connected == false }

        return DashboardSnapshot(
            version: overview.version,
            health: !offline.isEmpty ? .critical : (unhealthy.isEmpty ? .ok : .warning),
            headline: "\(running) of \(containers.count) containers running",
            detail: "\(projects.count) project\(projects.count == 1 ? "" : "s") · \(overview.environments.count) environment\(overview.environments.count == 1 ? "" : "s")",
            notice: overview.environments.compactMap { env in env.error.map { "\(label(env.environment)): \($0)" } }.joined(separator: "\n").nilIfEmpty,
            metrics: [
                DashboardMetric(title: "Running", value: "\(running)/\(containers.count)", systemImage: "shippingbox"),
                DashboardMetric(title: "Unhealthy", value: "\(unhealthy.count)", systemImage: "cross.case", health: unhealthy.isEmpty ? .ok : .warning),
                DashboardMetric(title: "Projects", value: "\(projects.count)", systemImage: "square.stack.3d.up"),
            ],
            sections: [
                DashboardSection(id: "environments", title: "Environments", systemImage: "network", trailing: "\(overview.environments.count)", emptyText: "No enabled environments.",
                                 rows: overview.environments.map { env in
                                     DashboardRow(id: "env:\(env.environment.id)", title: label(env.environment),
                                                  detail: "\(env.containers.count) containers · \(env.projects.count) projects",
                                                  health: env.environment.status == "online" ? .ok : .warning, badge: env.environment.status.capitalizedFirst, message: env.error)
                                 }),
                DashboardSection(id: "projects", title: "Projects", systemImage: "square.stack.3d.up", trailing: "\(projects.count)", emptyText: "No compose projects.",
                                 rows: projects.map { environment, project in
                                     let rowID = "project:\(environment.id):\(project.id)"
                                     let actions = ContainerLifecycle.actions(name: project.name, running: project.status != "stopped", environmentName: label(environment), targetKind: "Project",
                                                                                     stopConsequence: "Arcane runs docker compose down for \(project.name) on \(label(environment)): its containers and networks are removed (volumes are kept) and stay down until you start the project again.") { action in
                                         try await operations.project(action, id: project.id, environment: environment.id)
                                     }
                                     return DashboardRow(id: rowID, title: project.name, subtitle: multiple ? label(environment) : nil,
                                                         detail: "\(project.runningCount) of \(project.serviceCount) services running",
                                                         health: projectHealth(project.status), badge: project.status.capitalizedFirst, message: project.statusReason?.nilIfEmpty,
                                                         actions: ContainerLifecycle.prefixed(actions, rowID))
                                 }),
                DashboardSection(id: "containers", title: "Containers", systemImage: "shippingbox", trailing: "\(containers.count)", emptyText: "No containers.",
                                 rows: containers.sorted { ($0.1.state == "running" ? 1 : 0, $0.1.name) < ($1.1.state == "running" ? 1 : 0, $1.1.name) }.map { environment, container in
                                     let rowID = "container:\(environment.id):\(container.id)"
                                     let actions = ContainerLifecycle.actions(name: container.name, running: container.state == "running", environmentName: label(environment)) { action in
                                         try await operations.container(action, id: container.id, environment: environment.id)
                                     }
                                     return DashboardRow(id: rowID, title: container.name,
                                                         subtitle: [multiple ? label(environment) : nil, container.image].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: container.status, health: ContainerLifecycle.health(state: container.state, health: container.dockerHealth),
                                                         badge: container.dockerHealth?.capitalizedFirst ?? container.state.capitalizedFirst,
                                                         actions: ContainerLifecycle.prefixed(actions, rowID))
                                 }, limit: 100),
            ]
        )
    }
}
