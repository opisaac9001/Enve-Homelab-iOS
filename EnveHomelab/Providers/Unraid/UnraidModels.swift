import Foundation

protocol ResilientEnum: RawRepresentable<String>, Decodable, Sendable, Hashable {
    static var unknown: Self { get }
}

extension ResilientEnum {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

extension KeyedDecodingContainer {
    /// The API's `BigInt` scalar may arrive as a number or a string.
    func decodeBigIntIfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return Int64(value) }
        let string = try decode(String.self, forKey: key)
        return Int64(string) ?? Double(string).flatMap { $0.isFinite ? Int64($0) : nil }
    }
}

struct UnraidIdentity: Sendable, Hashable {
    var name: String
    var unraidVersion: String?
}

struct SystemOverview: Sendable, Hashable {
    var hostname: String?
    var bootTime: Date?
    var kernel: String?
    var cpuBrand: String?
    var cores: Int?
    var threads: Int?
    var unraidVersion: String?
    var apiVersion: String?
}

struct MemoryUsage: Sendable, Hashable {
    var total: Int64
    var used: Int64
    var available: Int64
    var percent: Double
    var swapTotal: Int64
    var swapUsed: Int64
}

extension MemoryUsage: Decodable {
    private enum CodingKeys: String, CodingKey { case total, used, available, percentTotal, swapTotal, swapUsed }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeBigIntIfPresent(forKey: .total) ?? 0
        used = try c.decodeBigIntIfPresent(forKey: .used) ?? 0
        available = try c.decodeBigIntIfPresent(forKey: .available) ?? 0
        percent = try c.decode(Double.self, forKey: .percentTotal)
        swapTotal = try c.decodeBigIntIfPresent(forKey: .swapTotal) ?? 0
        swapUsed = try c.decodeBigIntIfPresent(forKey: .swapUsed) ?? 0
    }
}

struct SystemMetrics: Sendable, Hashable {
    var cpuPercent: Double?
    var memory: MemoryUsage?
}

enum ArrayState: String, ResilientEnum {
    case started = "STARTED"
    case stopped = "STOPPED"
    case newArray = "NEW_ARRAY"
    case reconstructingDisk = "RECON_DISK"
    case disableDisk = "DISABLE_DISK"
    case swapDisabled = "SWAP_DSBL"
    case invalidExpansion = "INVALID_EXPANSION"
    case parityNotBiggest = "PARITY_NOT_BIGGEST"
    case tooManyMissingDisks = "TOO_MANY_MISSING_DISKS"
    case newDiskTooSmall = "NEW_DISK_TOO_SMALL"
    case noDataDisks = "NO_DATA_DISKS"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .started: "Started"
        case .stopped: "Stopped"
        case .newArray: "New array"
        case .reconstructingDisk: "Rebuilding disk"
        case .disableDisk: "Disk disabled"
        case .swapDisabled: "Swapping disabled disk"
        case .invalidExpansion: "Invalid expansion"
        case .parityNotBiggest: "Parity disk too small"
        case .tooManyMissingDisks: "Too many missing disks"
        case .newDiskTooSmall: "New disk too small"
        case .noDataDisks: "No data disks"
        case .unknown: "Unknown"
        }
    }

    var health: Health {
        switch self {
        case .started: .ok
        case .stopped, .newArray, .reconstructingDisk, .swapDisabled: .warning
        case .unknown: .unknown
        default: .critical
        }
    }
}

enum ArrayDiskStatus: String, ResilientEnum {
    case ok = "DISK_OK"
    case notPresent = "DISK_NP"
    case missing = "DISK_NP_MISSING"
    case invalid = "DISK_INVALID"
    case wrong = "DISK_WRONG"
    case disabled = "DISK_DSBL"
    case notPresentDisabled = "DISK_NP_DSBL"
    case disabledNew = "DISK_DSBL_NEW"
    case new = "DISK_NEW"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .ok: "Normal"
        case .notPresent: "Not installed"
        case .missing: "Missing"
        case .invalid: "Invalid"
        case .wrong: "Wrong disk"
        case .disabled: "Disabled"
        case .notPresentDisabled: "Disabled, not present"
        case .disabledNew: "Disabled, replacement"
        case .new: "New"
        case .unknown: "Unknown"
        }
    }

    var health: Health {
        switch self {
        case .ok: .ok
        case .notPresent: .unknown
        case .new, .disabledNew: .warning
        case .unknown: .unknown
        default: .critical
        }
    }
}

enum ArrayDiskType: String, ResilientEnum {
    case data = "DATA"
    case parity = "PARITY"
    case boot = "BOOT"
    case flash = "FLASH"
    case cache = "CACHE"
    case unknown = "UNKNOWN"
}

struct ArrayDisk: Sendable, Hashable, Identifiable {
    var id: String
    var slot: Int
    var name: String?
    var device: String?
    var sizeKB: Int64?
    var status: ArrayDiskStatus?
    var rotational: Bool?
    var temperature: Int?
    var reads: Int64?
    var writes: Int64?
    var errors: Int64?
    var filesystemSizeKB: Int64?
    var filesystemFreeKB: Int64?
    var filesystemUsedKB: Int64?
    var filesystemType: String?
    var type: ArrayDiskType
    /// Utilisation percentages at which Unraid warns about this disk filling up (`warning`/`critical` in the API).
    var usageWarningPercent: Int?
    var usageCriticalPercent: Int?
    var isSpinning: Bool?
    var transport: String?
    var comment: String?

    var displayName: String {
        guard let name, !name.isEmpty else { return "Slot \(slot)" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    var usedFraction: Double? {
        guard let used = filesystemUsedKB, let size = filesystemSizeKB, size > 0 else { return nil }
        return Double(used) / Double(size)
    }

    /// Unraid's default temperature alerts (45/55 °C for hard drives, 60/70 °C for SSDs); the API doesn't expose per-disk overrides.
    var temperatureLimits: (warning: Int, critical: Int) {
        rotational == false ? (60, 70) : (45, 55)
    }

    var temperatureHealth: Health {
        guard let temperature, isSpinning != false else { return .unknown }
        if temperature >= temperatureLimits.critical { return .critical }
        if temperature >= temperatureLimits.warning { return .warning }
        return .ok
    }

    var usageHealth: Health {
        guard let usedFraction else { return .unknown }
        let percent = usedFraction * 100
        if let usageCriticalPercent, usageCriticalPercent > 0, percent >= Double(usageCriticalPercent) { return .critical }
        if let usageWarningPercent, usageWarningPercent > 0, percent >= Double(usageWarningPercent) { return .warning }
        return .ok
    }

    var health: Health {
        let statusHealth = status?.health ?? .unknown
        if (errors ?? 0) > 0 { return .critical }
        return [statusHealth, temperatureHealth == .unknown ? .ok : temperatureHealth, usageHealth == .unknown ? .ok : usageHealth].max() ?? statusHealth
    }
}

extension ArrayDisk: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, idx, name, device, size, status, rotational, temp, numReads, numWrites, numErrors
        case fsSize, fsFree, fsUsed, fsType, type, warning, critical, isSpinning, transport, comment
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slot = try c.decode(Int.self, forKey: .idx)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        sizeKB = try c.decodeBigIntIfPresent(forKey: .size)
        status = try c.decodeIfPresent(ArrayDiskStatus.self, forKey: .status)
        rotational = try c.decodeIfPresent(Bool.self, forKey: .rotational)
        // Temperature is NaN (serialized as null or a non-integer) when the array is stopped.
        temperature = try? c.decodeIfPresent(Int.self, forKey: .temp)
        reads = try c.decodeBigIntIfPresent(forKey: .numReads)
        writes = try c.decodeBigIntIfPresent(forKey: .numWrites)
        errors = try c.decodeBigIntIfPresent(forKey: .numErrors)
        filesystemSizeKB = try c.decodeBigIntIfPresent(forKey: .fsSize)
        filesystemFreeKB = try c.decodeBigIntIfPresent(forKey: .fsFree)
        filesystemUsedKB = try c.decodeBigIntIfPresent(forKey: .fsUsed)
        filesystemType = try c.decodeIfPresent(String.self, forKey: .fsType)
        type = try c.decode(ArrayDiskType.self, forKey: .type)
        usageWarningPercent = try c.decodeIfPresent(Int.self, forKey: .warning)
        usageCriticalPercent = try c.decodeIfPresent(Int.self, forKey: .critical)
        isSpinning = try c.decodeIfPresent(Bool.self, forKey: .isSpinning)
        transport = try c.decodeIfPresent(String.self, forKey: .transport)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
    }
}

enum ParityCheckStatus: String, ResilientEnum {
    case neverRun = "NEVER_RUN"
    case running = "RUNNING"
    case paused = "PAUSED"
    case completed = "COMPLETED"
    case cancelled = "CANCELLED"
    case failed = "FAILED"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .neverRun: "Never run"
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

struct ParityCheck: Sendable, Hashable {
    var status: ParityCheckStatus
    var date: Date?
    var durationSeconds: Int?
    var speed: String?
    var errors: Int?
    var progress: Int?
    var correcting: Bool?
    var paused: Bool?
    var running: Bool?

    var isActive: Bool { status == .running || status == .paused || running == true }

    var health: Health {
        switch status {
        case .failed: .critical
        case .cancelled, .neverRun: .warning
        case .completed: (errors ?? 0) > 0 ? .critical : .ok
        case .running, .paused: .ok
        case .unknown: .unknown
        }
    }
}

extension ParityCheck: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, date, duration, speed, errors, progress, correcting, paused, running
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(ParityCheckStatus.self, forKey: .status)
        date = APIDate.parse(try c.decodeIfPresent(String.self, forKey: .date))
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .duration)
        speed = try c.decodeIfPresent(String.self, forKey: .speed)
        errors = try c.decodeIfPresent(Int.self, forKey: .errors)
        progress = try c.decodeIfPresent(Int.self, forKey: .progress)
        correcting = try c.decodeIfPresent(Bool.self, forKey: .correcting)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
        running = try c.decodeIfPresent(Bool.self, forKey: .running)
    }
}

struct ArrayCapacity: Sendable, Hashable {
    var totalKB: Int64
    var usedKB: Int64
    var freeKB: Int64

    var usedFraction: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) : 0 }
}

struct ArrayStatus: Sendable, Hashable {
    var state: ArrayState
    var capacity: ArrayCapacity
    var parityCheck: ParityCheck?
    var parities: [ArrayDisk]
    var disks: [ArrayDisk]
    var caches: [ArrayDisk]
    var boot: ArrayDisk?

    var allDevices: [ArrayDisk] { parities + disks + caches + (boot.map { [$0] } ?? []) }

    var installedDevices: [ArrayDisk] { allDevices.filter { $0.status != .notPresent } }

    var devicesNeedingAttention: [ArrayDisk] { installedDevices.filter { $0.health >= .warning } }
}

enum ContainerState: String, ResilientEnum {
    case running = "RUNNING"
    case paused = "PAUSED"
    case exited = "EXITED"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .exited: "Stopped"
        case .unknown: "Unknown"
        }
    }

    var health: Health {
        switch self {
        case .running: .ok
        case .paused: .warning
        case .exited, .unknown: .unknown
        }
    }
}

struct ContainerPort: Sendable, Hashable, Decodable {
    var ip: String?
    var privatePort: Int?
    var publicPort: Int?
    var type: String

    var displayValue: String {
        let proto = type.lowercased()
        switch (publicPort, privatePort) {
        case let (host?, inner?): return "\(host) → \(inner)/\(proto)"
        case let (nil, inner?): return "\(inner)/\(proto)"
        case let (host?, nil): return "\(host)/\(proto)"
        case (nil, nil): return proto
        }
    }
}

struct ContainerMount: Sendable, Hashable {
    var source: String
    var destination: String
    var readOnly: Bool
}

struct DockerContainer: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var image: String
    var state: ContainerState
    var status: String
    var created: Date?
    var autoStart: Bool
    var ports: [ContainerPort]
    var networkMode: String?
    var mounts: [ContainerMount]
    var webUIURL: URL?
    var iconURL: URL?
    var isUpdateAvailable: Bool?
    var sizeRootFs: Int64?
}

extension DockerContainer: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, names, image, state, status, created, autoStart, ports, hostConfig, mounts
        case webUiUrl, iconUrl, isUpdateAvailable, sizeRootFs
    }

    private struct HostConfig: Decodable {
        let networkMode: String?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let names = try c.decode([String].self, forKey: .names)
        name = names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? id
        image = try c.decode(String.self, forKey: .image)
        state = try c.decode(ContainerState.self, forKey: .state)
        status = try c.decode(String.self, forKey: .status)
        created = try c.decodeIfPresent(Int.self, forKey: .created).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        ports = try c.decodeIfPresent([ContainerPort].self, forKey: .ports) ?? []
        networkMode = try c.decodeIfPresent(HostConfig.self, forKey: .hostConfig)?.networkMode
        let rawMounts = try c.decodeIfPresent([JSONValue].self, forKey: .mounts) ?? []
        mounts = rawMounts.compactMap { mount in
            guard let source = mount["Source"]?.stringValue, let destination = mount["Destination"]?.stringValue else { return nil }
            return ContainerMount(source: source, destination: destination, readOnly: mount["RW"]?.boolValue == false)
        }
        webUIURL = try c.decodeIfPresent(String.self, forKey: .webUiUrl).flatMap(URL.init(string:))
        iconURL = try c.decodeIfPresent(String.self, forKey: .iconUrl).flatMap(URL.init(string:))
        isUpdateAvailable = try c.decodeIfPresent(Bool.self, forKey: .isUpdateAvailable)
        sizeRootFs = try c.decodeBigIntIfPresent(forKey: .sizeRootFs)
    }
}

struct ContainerLogLine: Sendable, Hashable, Identifiable {
    var id: String { "\(timestampRaw)|\(message)" }
    var timestampRaw: String
    var timestamp: Date?
    var message: String
}

extension ContainerLogLine: Decodable {
    private enum CodingKeys: String, CodingKey { case timestamp, message }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestampRaw = try c.decode(String.self, forKey: .timestamp)
        timestamp = APIDate.parse(timestampRaw)
        message = LogRedactor.redact(try c.decode(String.self, forKey: .message))
    }
}

struct ContainerLogBatch: Sendable, Hashable, Decodable {
    var lines: [ContainerLogLine]
    var cursor: String?
}

enum ContainerAction: String, Sendable, CaseIterable, Identifiable {
    case start, stop, restart, pause, unpause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .pause: "Pause"
        case .unpause: "Resume"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .pause: "pause.fill"
        case .unpause: "playpause.fill"
        }
    }

    var consequence: String {
        switch self {
        case .start: "The container starts and its services become available."
        case .stop: "The container is stopped. Anything it serves will be unavailable until it's started again."
        case .restart: "The container stops and starts again. Active connections to it will drop."
        case .pause: "All processes in the container are frozen. It keeps its memory but stops responding."
        case .unpause: "Frozen processes in the container resume."
        }
    }

    static func available(for state: ContainerState) -> [ContainerAction] {
        switch state {
        case .running: [.restart, .pause, .stop]
        case .paused: [.unpause, .stop]
        case .exited: [.start]
        case .unknown: [.start, .stop]
        }
    }
}

enum VMState: String, ResilientEnum {
    case noState = "NOSTATE"
    case running = "RUNNING"
    case idle = "IDLE"
    case paused = "PAUSED"
    case shutdown = "SHUTDOWN"
    case shutoff = "SHUTOFF"
    case crashed = "CRASHED"
    case suspended = "PMSUSPENDED"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .noState: "No state"
        case .running: "Running"
        case .idle: "Idle"
        case .paused: "Paused"
        case .shutdown: "Shutting down"
        case .shutoff: "Stopped"
        case .crashed: "Crashed"
        case .suspended: "Suspended"
        case .unknown: "Unknown"
        }
    }

    var health: Health {
        switch self {
        case .running, .idle: .ok
        case .paused, .suspended, .shutdown: .warning
        case .crashed: .critical
        case .noState, .shutoff, .unknown: .unknown
        }
    }

    var isActive: Bool { self == .running || self == .idle }
}

struct VirtualMachine: Sendable, Hashable, Identifiable, Decodable {
    var id: String
    var name: String?
    var state: VMState

    var displayName: String { name ?? id }
}

enum VMAction: String, Sendable, CaseIterable, Identifiable {
    case start, stop, pause, resume, reboot, forceStop, reset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Shut Down"
        case .pause: "Pause"
        case .resume: "Resume"
        case .reboot: "Reboot"
        case .forceStop: "Force Stop"
        case .reset: "Reset"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "power"
        case .pause: "pause.fill"
        case .resume: "playpause.fill"
        case .reboot: "arrow.clockwise"
        case .forceStop: "bolt.slash.fill"
        case .reset: "exclamationmark.arrow.circlepath"
        }
    }

    var consequence: String {
        switch self {
        case .start: "The virtual machine boots."
        case .stop: "The guest OS is asked to shut down cleanly. It may ignore the request if it isn't responding."
        case .pause: "The virtual machine is frozen in memory until resumed."
        case .resume: "The frozen virtual machine continues running."
        case .reboot: "The guest OS is asked to restart cleanly."
        case .forceStop: "Power is cut immediately, like pulling the plug. Unsaved data in the guest is lost and its disks may be left inconsistent."
        case .reset: "The virtual machine is hard reset without warning the guest. Unsaved data in the guest is lost."
        }
    }

    var isDestructive: Bool { self == .forceStop || self == .reset }

    static func available(for state: VMState) -> [VMAction] {
        switch state {
        case .running, .idle: [.stop, .reboot, .pause, .forceStop, .reset]
        case .paused, .suspended: [.resume, .forceStop]
        case .shutdown: [.forceStop]
        case .shutoff, .crashed, .noState: [.start]
        case .unknown: []
        }
    }
}

enum ParityAction: String, Sendable, Identifiable {
    case startCheck, pause, resume, cancel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startCheck: "Start Parity Check"
        case .pause: "Pause Parity Check"
        case .resume: "Resume Parity Check"
        case .cancel: "Cancel Parity Check"
        }
    }

    var systemImage: String {
        switch self {
        case .startCheck: "checkmark.shield"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .cancel: "xmark"
        }
    }

    var consequence: String {
        switch self {
        case .startCheck: "A read-only parity check starts. Nothing is written to parity; errors are only reported. Array performance is reduced until it finishes, which can take many hours."
        case .pause: "The running parity check pauses at its current position."
        case .resume: "The paused parity check continues from where it stopped."
        case .cancel: "The parity check stops and its progress is discarded. The result is recorded as cancelled."
        }
    }
}

enum NotificationImportance: String, ResilientEnum, CaseIterable, Identifiable {
    case alert = "ALERT"
    case warning = "WARNING"
    case info = "INFO"
    case unknown = "UNKNOWN"

    static let allCases: [NotificationImportance] = [.alert, .warning, .info]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alert: "Alert"
        case .warning: "Warning"
        case .info: "Info"
        case .unknown: "Other"
        }
    }

    var health: Health {
        switch self {
        case .alert: .critical
        case .warning: .warning
        case .info, .unknown: .unknown
        }
    }
}

enum NotificationListType: String, Sendable, CaseIterable, Identifiable {
    case unread = "UNREAD"
    case archive = "ARCHIVE"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unread: "Unread"
        case .archive: "Archived"
        }
    }
}

struct NotificationCounts: Sendable, Hashable, Decodable {
    var info: Int
    var warning: Int
    var alert: Int
    var total: Int
}

struct NotificationOverview: Sendable, Hashable, Decodable {
    var unread: NotificationCounts
    var archive: NotificationCounts
}

struct UnraidNotification: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var subject: String
    var description: String
    var importance: NotificationImportance
    var link: String?
    var timestamp: Date?
    var formattedTimestamp: String?
}

extension UnraidNotification: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, subject, description, importance, link, timestamp, formattedTimestamp
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subject = try c.decode(String.self, forKey: .subject)
        description = try c.decode(String.self, forKey: .description)
        importance = try c.decode(NotificationImportance.self, forKey: .importance)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        timestamp = APIDate.parse(try c.decodeIfPresent(String.self, forKey: .timestamp))
        formattedTimestamp = try c.decodeIfPresent(String.self, forKey: .formattedTimestamp)
    }
}
