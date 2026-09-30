import Foundation

struct ProxmoxNode: Decodable, Sendable, Hashable, Identifiable {
    var node: String
    var status: String?
    var cpu: Double?
    var maxcpu: Int?
    var mem: Int64?
    var maxmem: Int64?
    var uptime: Int64?

    var id: String { node }
    var isOnline: Bool { status == "online" }
    var memoryFraction: Double? {
        guard let mem, let maxmem, maxmem > 0 else { return nil }
        return Double(mem) / Double(maxmem)
    }
}

enum ProxmoxGuestType: String, Decodable, Sendable {
    case qemu, lxc

    var displayName: String { self == .qemu ? "Virtual machine" : "Container" }
}

struct ProxmoxGuest: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var type: ProxmoxGuestType
    var node: String
    var vmid: Int
    var name: String?
    var status: String?
    var cpu: Double?
    var maxcpu: Int?
    var mem: Int64?
    var maxmem: Int64?
    var uptime: Int64?
    var template: Int?
    var lock: String?
    var tags: String?

    var displayName: String { name ?? "\(vmid)" }
    var isRunning: Bool { status == "running" }
    var isTemplate: Bool { template == 1 }

    var health: Health {
        switch status {
        case "running": .ok
        case "paused", "suspended": .warning
        default: .unknown
        }
    }
}

struct ProxmoxTask: Decodable, Sendable, Hashable, Identifiable {
    var upid: String
    var node: String?
    var type: String?
    var target: String?
    var user: String?
    var starttime: Int64?
    var endtime: Int64?
    var status: String?

    private enum CodingKeys: String, CodingKey {
        case upid, node, type, user, starttime, endtime, status
        case target = "id"
    }

    var id: String { upid }
    var isRunning: Bool { endtime == nil }
    var succeeded: Bool { status == "OK" }

    var health: Health {
        if isRunning { return .unknown }
        if succeeded { return .ok }
        return status?.hasPrefix("WARNINGS") == true ? .warning : .critical
    }
}

struct ProxmoxTaskStatus: Decodable, Sendable {
    var status: String
    var exitstatus: String?
}

enum ProxmoxPowerAction: String, Sendable, CaseIterable, Identifiable {
    case start, shutdown, reboot, suspend, resume, stop, reset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
        case .shutdown: "Shut Down"
        case .reboot: "Reboot"
        case .suspend: "Suspend"
        case .resume: "Resume"
        case .stop: "Stop"
        case .reset: "Reset"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .suspend: "pause.fill"
        case .resume: "playpause.fill"
        case .stop: "bolt.slash.fill"
        case .reset: "exclamationmark.arrow.circlepath"
        }
    }

    var isDestructive: Bool { self == .stop || self == .reset }

    func consequence(for type: ProxmoxGuestType) -> String {
        switch self {
        case .start: "The \(type == .qemu ? "VM" : "container") boots on its node."
        case .shutdown: "The guest OS is asked to shut down cleanly. Proxmox waits for it and does not force it off."
        case .reboot: "The guest OS is asked to restart cleanly."
        case .suspend: "The guest is paused in memory until resumed."
        case .resume: "The paused guest continues running."
        case .stop: "The guest is stopped immediately, like pulling the plug. Unsaved data inside it is lost."
        case .reset: "The VM is hard reset without warning the guest. Unsaved data inside it is lost."
        }
    }

    static func available(for guest: ProxmoxGuest) -> [ProxmoxPowerAction] {
        guard !guest.isTemplate, guest.lock == nil else { return [] }
        switch (guest.type, guest.status) {
        case (_, "stopped"): return [.start]
        case (.qemu, "running"): return [.shutdown, .reboot, .suspend, .stop, .reset]
        case (.lxc, "running"): return [.shutdown, .reboot, .stop]
        case (_, "paused"), (_, "suspended"): return [.resume, .stop]
        default: return []
        }
    }
}

struct ProxmoxSnapshot: Sendable {
    var version: String
    var nodes: [ProxmoxNode]
    var guests: [ProxmoxGuest]
    var tasks: [ProxmoxTask]
}

protocol ProxmoxService: IntegrationService {
    func snapshot() async throws -> ProxmoxSnapshot
    /// Starts the action and waits for its task; returns the task's exit status.
    func perform(_ action: ProxmoxPowerAction, on guest: ProxmoxGuest) async throws -> String
    func nodeStatus(_ node: String) async throws -> ProxmoxNodeStatus
    func storage(_ node: String) async throws -> [ProxmoxStorage]
    /// Needs Sys.Audit on the node (PVEAuditor has it).
    func disks(_ node: String) async throws -> [ProxmoxDisk]
    /// Needs Sys.Audit on `/`.
    func smart(_ node: String, disk: String) async throws -> ProxmoxSMART
    func taskLog(_ task: ProxmoxTask, limit: Int) async throws -> [String]
}

extension ProxmoxService {
    func summary() async throws -> IntegrationSummary {
        let snapshot = try await snapshot()
        let offline = snapshot.nodes.filter { !$0.isOnline }.count
        let running = snapshot.guests.filter(\.isRunning).count
        let failed = snapshot.tasks.filter { !$0.isRunning && !$0.succeeded }.count
        return IntegrationSummary(
            product: "Proxmox VE",
            version: snapshot.version,
            health: offline > 0 ? .critical : (failed > 0 ? .warning : .ok),
            headline: "\(running)/\(snapshot.guests.filter { !$0.isTemplate }.count) guests running",
            detail: "\(snapshot.nodes.count) node\(snapshot.nodes.count == 1 ? "" : "s")" + (offline > 0 ? " · \(offline) offline" : "")
        )
    }
}

/// Proxmox VE `api2/json` with an API token (`PVEAPIToken=ID=SECRET`); tokens don't need CSRF tickets.
struct ProxmoxClient: ProxmoxService {
    let rest: RESTClient

    init(url: URL, tokenID: String, secret: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api2/json"), pinnedFingerprint: pinnedFingerprint, headers: [
            "Authorization": Self.authorization(tokenID: tokenID, secret: secret),
        ])
    }

    static func authorization(tokenID: String, secret: String) -> String {
        "PVEAPIToken=\(tokenID.trimmingCharacters(in: .whitespaces))=\(secret.trimmingCharacters(in: .whitespaces))"
    }

    struct Envelope<Payload: Decodable>: Decodable {
        var data: Payload
    }

    func get<Payload: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: Payload.Type) async throws -> Payload {
        try await rest.json(.get(path, query: query), as: Envelope<Payload>.self).data
    }

    func snapshot() async throws -> ProxmoxSnapshot {
        struct Version: Decodable { var version: String; var release: String? }
        async let version = get("version", as: Version.self)
        async let nodes = get("nodes", as: [ProxmoxNode].self)
        async let guests = get("cluster/resources", query: [URLQueryItem(name: "type", value: "vm")], as: [ProxmoxGuest].self)
        async let tasks = get("cluster/tasks", as: [ProxmoxTask].self)
        return ProxmoxSnapshot(
            version: try await version.version,
            nodes: try await nodes.sorted { $0.node < $1.node },
            guests: try await guests.sorted { $0.vmid < $1.vmid },
            tasks: Array(try await tasks.sorted { ($0.starttime ?? 0) > ($1.starttime ?? 0) }.prefix(30))
        )
    }

    func perform(_ action: ProxmoxPowerAction, on guest: ProxmoxGuest) async throws -> String {
        let path = "nodes/\(guest.node)/\(guest.type.rawValue)/\(guest.vmid)/status/\(action.rawValue)"
        let upid = try await rest.json(.post(path), as: Envelope<String>.self).data
        for _ in 0..<60 {
            let status = try await get("nodes/\(guest.node)/tasks/\(upid)/status", as: ProxmoxTaskStatus.self)
            if status.status == "stopped" {
                let exit = status.exitstatus ?? "unknown"
                guard exit == "OK" || exit.hasPrefix("WARNINGS") else { throw NetworkError.graphQL(["Proxmox task failed: \(exit)"]) }
                return exit
            }
            try await Task.sleep(for: .seconds(1))
        }
        return "Still running — check the task log in Proxmox."
    }
}
