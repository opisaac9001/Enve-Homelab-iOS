import Foundation

struct PortainerEnvironment: Decodable, Sendable, Hashable, Identifiable {
    var Id: Int
    var Name: String
    var `Type`: Int
    var Status: Int
    var URL: String?

    var id: Int { Id }
    var isUp: Bool { Status == 1 }

    /// 1 Docker, 2 Agent on Docker, 4 Edge agent on Docker; the rest are Kubernetes or Azure.
    var isDocker: Bool { [1, 2, 4].contains(Type) }

    var typeName: String {
        switch Type {
        case 1: "Docker"
        case 2: "Docker agent"
        case 3: "Azure ACI"
        case 4: "Docker edge agent"
        case 5, 6, 7: "Kubernetes"
        default: "Environment"
        }
    }
}

struct PortainerContainer: Decodable, Sendable, Hashable, Identifiable {
    var Id: String
    var Names: [String]?
    var Image: String?
    var State: String?
    var Status: String?
    var Created: Int64?
    var Labels: [String: String]?

    var id: String { Id }
    var name: String { Names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(Id.prefix(12)) }
    var stack: String? { Labels?["com.docker.compose.project"] ?? Labels?["com.docker.stack.namespace"] }

    var health: Health {
        switch State {
        case "running": Status?.contains("unhealthy") == true ? .warning : .ok
        case "restarting", "paused": .warning
        case "dead": .critical
        default: .unknown
        }
    }

    var lifecycleActions: [PortainerContainerAction] {
        switch State {
        case "running": [.restart, .stop]
        case "paused": [.stop]
        default: [.start]
        }
    }
}

struct PortainerStack: Decodable, Sendable, Hashable, Identifiable {
    var Id: Int
    var Name: String
    var `Type`: Int
    var EndpointId: Int
    var Status: Int

    var id: Int { Id }
    var isActive: Bool { Status == 1 }
    var typeName: String { Type == 1 ? "Swarm" : (Type == 2 ? "Compose" : "Kubernetes") }
}

enum PortainerContainerAction: String, Sendable, Identifiable {
    case start, stop, restart

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        }
    }

    var consequence: String {
        switch self {
        case .start: "The container starts."
        case .stop: "The container is stopped. Anything it serves is unavailable until it's started again."
        case .restart: "The container stops and starts again. Active connections drop."
        }
    }
}

enum DockerLogStream {
    /// Splits the Docker Engine log payload. Non-TTY containers multiplex stdout/stderr in frames with an 8-byte header.
    static func lines(from data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] <= 2, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 else {
            return split(String(decoding: bytes, as: UTF8.self))
        }
        var text = ""
        var offset = 0
        while offset + 8 <= bytes.count {
            let length = bytes[(offset + 4)..<(offset + 8)].reduce(0) { $0 << 8 | Int($1) }
            let start = offset + 8
            let end = min(start + length, bytes.count)
            text += String(decoding: bytes[start..<end], as: UTF8.self)
            offset = end
        }
        return split(text)
    }

    private static func split(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
}

/// The Docker Engine `ContainerInspect` fields that explain restarts and health. Only these are decoded: the response also carries
/// the container's environment variables, which often hold secrets.
struct PortainerInspection: Decodable, Sendable, Equatable {
    struct State: Decodable, Sendable, Equatable {
        struct HealthState: Decodable, Sendable, Equatable {
            struct Check: Decodable, Sendable, Equatable {
                var Start: String?
                var ExitCode: Int?
                var Output: String?
            }
            var Status: String?
            var FailingStreak: Int?
            var Log: [Check]?
        }
        var Status: String?
        var OOMKilled: Bool?
        var ExitCode: Int?
        var Error: String?
        var StartedAt: String?
        var FinishedAt: String?
        var Health: HealthState?
    }
    struct Policy: Decodable, Sendable, Equatable { var Name: String?; var MaximumRetryCount: Int? }
    struct Host: Decodable, Sendable, Equatable {
        var RestartPolicy: Policy?
    }

    var state: State?
    var restartCount: Int?
    var hostConfig: Host?

    private enum CodingKeys: String, CodingKey { case state = "State", restartCount = "RestartCount", hostConfig = "HostConfig" }

    var restartPolicy: String {
        let policy = hostConfig?.RestartPolicy
        switch policy?.Name ?? "" {
        case "always": return "Always"
        case "unless-stopped": return "Unless stopped"
        case "on-failure": return "On failure" + ((policy?.MaximumRetryCount ?? 0) > 0 ? " (up to \(policy?.MaximumRetryCount ?? 0) tries)" : "")
        case "", "no": return "Never"
        default: return policy?.Name ?? "Never"
        }
    }

    var healthLevel: Health {
        switch state?.Health?.Status {
        case "healthy": .ok
        case "unhealthy": .critical
        case "starting": .warning
        default: .unknown
        }
    }
}

protocol PortainerService: IntegrationService {
    func environments() async throws -> [PortainerEnvironment]
    func containers(environmentID: Int) async throws -> [PortainerContainer]
    func stacks() async throws -> [PortainerStack]
    func logs(environmentID: Int, containerID: String, tail: Int) async throws -> [String]
    func inspect(environmentID: Int, containerID: String) async throws -> PortainerInspection
    func perform(_ action: PortainerContainerAction, environmentID: Int, containerID: String) async throws
    func setStack(_ stack: PortainerStack, active: Bool) async throws
    func version() async throws -> String?
}

extension PortainerService {
    func summary() async throws -> IntegrationSummary {
        async let version = version()
        let environments = try await environments()
        let down = environments.filter { !$0.isUp }.count
        return IntegrationSummary(
            product: "Portainer",
            version: try await version,
            health: down > 0 ? .warning : .ok,
            headline: "\(environments.count) environment\(environments.count == 1 ? "" : "s")",
            detail: down > 0 ? "\(down) unreachable" : nil
        )
    }
}

/// Portainer API with an access token; Docker calls go through Portainer's documented `/endpoints/{id}/docker` proxy.
struct PortainerClient: PortainerService {
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: ["X-API-Key": apiKey])
    }

    func version() async throws -> String? {
        struct Status: Decodable { var Version: String? }
        return try await rest.json(.get("system/status"), as: Status.self).Version
    }

    func environments() async throws -> [PortainerEnvironment] {
        try await rest.json(.get("endpoints"), as: [PortainerEnvironment].self).sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
    }

    func containers(environmentID: Int) async throws -> [PortainerContainer] {
        try await rest.json(.get("endpoints/\(environmentID)/docker/containers/json", query: [URLQueryItem(name: "all", value: "1")]), as: [PortainerContainer].self)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func stacks() async throws -> [PortainerStack] {
        try await rest.json(.get("stacks"), as: [PortainerStack].self).sorted { $0.Name < $1.Name }
    }

    func logs(environmentID: Int, containerID: String, tail: Int) async throws -> [String] {
        let query = ["stdout": "1", "stderr": "1", "tail": String(tail), "timestamps": "0"].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return DockerLogStream.lines(from: try await rest.data(.get("endpoints/\(environmentID)/docker/containers/\(containerID)/logs", query: query))).map(LogRedactor.redact)
    }

    func inspect(environmentID: Int, containerID: String) async throws -> PortainerInspection {
        try await rest.json(.get("endpoints/\(environmentID)/docker/containers/\(containerID)/json"), as: PortainerInspection.self)
    }

    func perform(_ action: PortainerContainerAction, environmentID: Int, containerID: String) async throws {
        let (data, response) = try await rest.raw(RESTRequest(method: "POST", path: "endpoints/\(environmentID)/docker/containers/\(containerID)/\(action.rawValue)"))
        // Docker answers 304 when the container is already in the requested state.
        if response.statusCode == 304 { return }
        try RESTClient.validate(response, data: data)
    }

    func setStack(_ stack: PortainerStack, active: Bool) async throws {
        _ = try await rest.data(RESTRequest(method: "POST", path: "stacks/\(stack.Id)/\(active ? "start" : "stop")", query: [URLQueryItem(name: "endpointId", value: String(stack.EndpointId))]))
    }
}
