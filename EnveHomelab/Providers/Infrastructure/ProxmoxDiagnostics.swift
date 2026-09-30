import Foundation

/// Proxmox returns many booleans as 0/1 and many numbers as strings; these read either form.
struct ProxmoxFlag: Decodable, Sendable, Hashable {
    var value: Bool

    init(_ value: Bool) { self.value = value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let bool = try? c.decode(Bool.self) { value = bool }
        else if let int = try? c.decode(Int.self) { value = int != 0 }
        else { value = (try? c.decode(String.self)).map { $0 == "1" || $0.lowercased() == "true" } ?? false }
    }
}

struct ProxmoxText: Decodable, Sendable, Hashable {
    var value: String

    init(_ value: String) { self.value = value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) { value = text }
        else if let int = try? c.decode(Int64.self) { value = String(int) }
        else if let double = try? c.decode(Double.self) { value = String(double) }
        else { value = "" }
    }
}

/// `GET /nodes/{node}/status`.
struct ProxmoxNodeStatus: Decodable, Sendable, Equatable {
    struct Usage: Decodable, Sendable, Equatable {
        var total: Int64?
        var used: Int64?
        var fraction: Double? { total.flatMap { total in used.map { total > 0 ? Double($0) / Double(total) : 0 } } }
    }
    struct CPUInfo: Decodable, Sendable, Equatable { var model: String?; var cores: Int?; var cpus: Int?; var sockets: Int? }
    struct BootInfo: Decodable, Sendable, Equatable { var mode: String?; var secureboot: ProxmoxFlag? }
    struct Kernel: Decodable, Sendable, Equatable { var release: String?; var version: String? }

    var cpu: Double?
    var loadavg: [ProxmoxText]?
    var uptime: Int64?
    var pveversion: String?
    var kversion: String?
    var memory: Usage?
    var swap: Usage?
    var rootfs: Usage?
    var cpuinfo: CPUInfo?
    var bootInfo: BootInfo?
    var currentKernel: Kernel?

    private enum CodingKeys: String, CodingKey {
        case cpu, loadavg, uptime, pveversion, kversion, memory, swap, rootfs, cpuinfo
        case bootInfo = "boot-info", currentKernel = "current-kernel"
    }

    var bootDescription: String? {
        guard let mode = bootInfo?.mode else { return nil }
        return mode == "efi" ? "UEFI" + (bootInfo?.secureboot?.value == true ? " · Secure Boot" : "") : "Legacy BIOS"
    }
}

/// `GET /nodes/{node}/storage`.
struct ProxmoxStorage: Decodable, Sendable, Equatable, Identifiable {
    var storage: String
    var type: String?
    var content: String?
    var active: ProxmoxFlag?
    var enabled: ProxmoxFlag?
    var shared: ProxmoxFlag?
    var total: Int64?
    var used: Int64?
    var avail: Int64?
    var id: String { storage }

    var usedFraction: Double? { total.flatMap { total in used.map { total > 0 ? Double($0) / Double(total) : 0 } } }
    /// An enabled storage that isn't accessible means guests on it can't start or back up.
    var isUnavailable: Bool { enabled?.value != false && active?.value == false }
}

/// `GET /nodes/{node}/disks/list`.
struct ProxmoxDisk: Decodable, Sendable, Equatable, Identifiable {
    var devpath: String
    var model: String?
    var vendor: String?
    var serial: String?
    var size: Int64?
    var health: String?
    var used: String?
    var mounted: ProxmoxFlag?
    var id: String { devpath }

    var healthLevel: Health {
        switch health?.uppercased() {
        case "PASSED", "OK": .ok
        case "FAILED": .critical
        case nil, "", "UNKNOWN": .unknown
        default: .warning
        }
    }
}

/// `GET /nodes/{node}/disks/smart`: ATA drives report an attribute table, others (e.g. NVMe) plain text.
struct ProxmoxSMART: Decodable, Sendable, Equatable {
    struct Attribute: Decodable, Sendable, Equatable {
        var id: ProxmoxText?
        var name: String?
        var value: ProxmoxText?
        var worst: ProxmoxText?
        var threshold: ProxmoxText?
        var raw: ProxmoxText?
        var fail: String?
        var flags: String?

        var identifier: String { [id?.value, name].compactMap { $0 }.joined(separator: "-") }
        /// smartctl marks attributes that are failing now or have failed before in its WHEN_FAILED column.
        var isFailing: Bool { !(fail ?? "-").trimmingCharacters(in: .whitespaces).isEmpty && fail?.trimmingCharacters(in: .whitespaces) != "-" }
        /// Attributes whose raw count rising means media is degrading.
        var isWearIndicator: Bool {
            ["5", "187", "188", "197", "198"].contains(id?.value.trimmingCharacters(in: .whitespaces) ?? "") && (Int64(raw?.value.split(separator: " ").first ?? "") ?? 0) > 0
        }
    }

    var health: String
    var type: String?
    var attributes: [Attribute]?
    var text: String?
}

extension ProxmoxClient {
    func nodeStatus(_ node: String) async throws -> ProxmoxNodeStatus {
        try await get("nodes/\(node)/status", as: ProxmoxNodeStatus.self)
    }

    func storage(_ node: String) async throws -> [ProxmoxStorage] {
        try await get("nodes/\(node)/storage", as: [ProxmoxStorage].self).sorted { $0.storage < $1.storage }
    }

    func disks(_ node: String) async throws -> [ProxmoxDisk] {
        try await get("nodes/\(node)/disks/list", as: [ProxmoxDisk].self).sorted { $0.devpath.localizedStandardCompare($1.devpath) == .orderedAscending }
    }

    func smart(_ node: String, disk: String) async throws -> ProxmoxSMART {
        try await get("nodes/\(node)/disks/smart", query: [URLQueryItem(name: "disk", value: disk)], as: ProxmoxSMART.self)
    }

    func taskLog(_ task: ProxmoxTask, limit: Int) async throws -> [String] {
        struct Line: Decodable { var n: Int; var t: String }
        guard let node = task.node else { throw NetworkError.unexpectedResponse("The task doesn't say which node ran it.") }
        return try await get("nodes/\(node)/tasks/\(task.upid)/log", query: [URLQueryItem(name: "limit", value: String(limit))], as: [Line].self)
            .sorted { $0.n < $1.n }.map { LogRedactor.redact($0.t) }
    }
}
