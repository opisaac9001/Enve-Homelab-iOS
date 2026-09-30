import Foundation

/// Template and housekeeping details of one container (`docker.container(id:)`, Unraid API 4.29+).
struct ContainerDetails: Sendable, Equatable, Decodable {
    var id: String
    var templatePath: String?
    var projectUrl: String?
    var registryUrl: String?
    var supportUrl: String?
    var isOrphaned: Bool?
    var isUpdateAvailable: Bool?
    var isRebuildReady: Bool?
    var lanIpPorts: [String]?
    var sizeRootFs: Int64?
    var sizeRw: Int64?
    var sizeLog: Int64?
    var autoStart: Bool?
    var autoStartOrder: Int?
    var autoStartWait: Int?

    /// Only web links are opened; anything else in a template is shown as text.
    static func webLink(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    var templateName: String? {
        templatePath.map { ($0 as NSString).lastPathComponent }
    }

    private enum CodingKeys: String, CodingKey {
        case id, templatePath, projectUrl, registryUrl, supportUrl, isOrphaned, isUpdateAvailable, isRebuildReady, lanIpPorts
        case sizeRootFs, sizeRw, sizeLog, autoStart, autoStartOrder, autoStartWait
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        templatePath = try c.decodeIfPresent(String.self, forKey: .templatePath)?.nilIfEmpty
        projectUrl = try c.decodeIfPresent(String.self, forKey: .projectUrl)?.nilIfEmpty
        registryUrl = try c.decodeIfPresent(String.self, forKey: .registryUrl)?.nilIfEmpty
        supportUrl = try c.decodeIfPresent(String.self, forKey: .supportUrl)?.nilIfEmpty
        isOrphaned = try c.decodeIfPresent(Bool.self, forKey: .isOrphaned)
        isUpdateAvailable = try c.decodeIfPresent(Bool.self, forKey: .isUpdateAvailable)
        isRebuildReady = try c.decodeIfPresent(Bool.self, forKey: .isRebuildReady)
        lanIpPorts = try c.decodeIfPresent([String].self, forKey: .lanIpPorts)
        sizeRootFs = try c.decodeBigIntIfPresent(forKey: .sizeRootFs)
        sizeRw = try c.decodeBigIntIfPresent(forKey: .sizeRw)
        sizeLog = try c.decodeBigIntIfPresent(forKey: .sizeLog)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart)
        autoStartOrder = try c.decodeIfPresent(Int.self, forKey: .autoStartOrder)
        autoStartWait = try c.decodeIfPresent(Int.self, forKey: .autoStartWait)
    }

    init(id: String, templatePath: String? = nil, projectUrl: String? = nil, registryUrl: String? = nil, supportUrl: String? = nil,
         isOrphaned: Bool? = nil, isUpdateAvailable: Bool? = nil, isRebuildReady: Bool? = nil, lanIpPorts: [String]? = nil,
         sizeRootFs: Int64? = nil, sizeRw: Int64? = nil, sizeLog: Int64? = nil, autoStart: Bool? = nil, autoStartOrder: Int? = nil, autoStartWait: Int? = nil) {
        self.id = id
        self.templatePath = templatePath
        self.projectUrl = projectUrl
        self.registryUrl = registryUrl
        self.supportUrl = supportUrl
        self.isOrphaned = isOrphaned
        self.isUpdateAvailable = isUpdateAvailable
        self.isRebuildReady = isRebuildReady
        self.lanIpPorts = lanIpPorts
        self.sizeRootFs = sizeRootFs
        self.sizeRw = sizeRw
        self.sizeLog = sizeLog
        self.autoStart = autoStart
        self.autoStartOrder = autoStartOrder
        self.autoStartWait = autoStartWait
    }
}

/// Published ports claimed by more than one container (`docker.portConflicts`, Unraid API 4.29+).
struct DockerPortConflicts: Sendable, Equatable, Decodable {
    struct Container: Sendable, Equatable, Decodable, Hashable {
        var id: String
        var name: String
    }
    struct ContainerPortConflict: Sendable, Equatable, Decodable {
        var privatePort: Int
        var type: String
        var containers: [Container]
    }
    struct LanPortConflict: Sendable, Equatable, Decodable {
        var lanIpPort: String
        var publicPort: Int?
        var type: String
        var containers: [Container]
    }
    var containerPorts: [ContainerPortConflict]
    var lanPorts: [LanPortConflict]

    var isEmpty: Bool { containerPorts.isEmpty && lanPorts.isEmpty }

    /// One line per conflict, naming the port and every container that wants it.
    var descriptions: [String] {
        lanPorts.map { "\($0.lanIpPort)/\($0.type.lowercased()): \($0.containers.map(\.name).joined(separator: ", "))" }
            + containerPorts.map { "Container port \($0.privatePort)/\($0.type.lowercased()): \($0.containers.map(\.name).joined(separator: ", "))" }
    }

    func involves(_ containerID: String) -> Bool {
        (lanPorts.flatMap(\.containers) + containerPorts.flatMap(\.containers)).contains { $0.id == containerID }
    }
}

/// `metrics.temperature` (Unraid API 4.32+). Readings are converted to Celsius so thresholds compare directly.
struct TemperatureReport: Sendable, Equatable {
    struct Reading: Sendable, Equatable, Hashable {
        var celsius: Double
        var date: Date?
    }
    struct Sensor: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var kind: String
        var location: String?
        var current: Reading
        var status: TemperatureLevel
        var minimum: Double?
        var maximum: Double?
        var warning: Double?
        var critical: Double?
        var history: [Reading]
    }
    var average: Double?
    var warningCount: Int
    var criticalCount: Int
    var sensors: [Sensor]

    var health: Health { criticalCount > 0 ? .critical : (warningCount > 0 ? .warning : .ok) }
}

enum TemperatureLevel: String, Sendable, Equatable {
    case normal = "NORMAL", warning = "WARNING", critical = "CRITICAL", unknown = "UNKNOWN"

    var health: Health {
        switch self {
        case .normal: .ok
        case .warning: .warning
        case .critical: .critical
        case .unknown: .unknown
        }
    }
}

extension TemperatureReport: Decodable {
    private struct RawReading: Decodable {
        var value: Double
        var unit: String?
        var timestamp: String?
        var status: String?

        var celsius: Double {
            switch unit {
            case "FAHRENHEIT": (value - 32) * 5 / 9
            case "KELVIN": value - 273.15
            case "RANKINE": (value - 491.67) * 5 / 9
            default: value
            }
        }
    }
    private struct RawSensor: Decodable {
        var id: String
        var name: String
        var type: String
        var location: String?
        var current: RawReading
        var min: RawReading?
        var max: RawReading?
        var warning: Double?
        var critical: Double?
        var history: [RawReading]?
    }
    private struct Summary: Decodable {
        var average: Double?
        var warningCount: Int?
        var criticalCount: Int?
    }
    private enum CodingKeys: String, CodingKey { case summary, sensors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
        let sensors = try container.decodeIfPresent([RawSensor].self, forKey: .sensors) ?? []
        average = summary?.average
        warningCount = summary?.warningCount ?? 0
        criticalCount = summary?.criticalCount ?? 0
        // Thresholds are configured in the sensor's own unit, which is Celsius unless Unraid is set otherwise.
        self.sensors = sensors.map { raw in
            let scale = { (value: Double?) in value.map { RawReading(value: $0, unit: raw.current.unit).celsius } }
            return Sensor(
                id: raw.id, name: raw.name, kind: raw.type, location: raw.location?.nilIfEmpty,
                current: Reading(celsius: raw.current.celsius, date: APIDate.parse(raw.current.timestamp)),
                status: TemperatureLevel(rawValue: raw.current.status ?? "") ?? .unknown,
                minimum: raw.min?.celsius, maximum: raw.max?.celsius,
                warning: scale(raw.warning), critical: scale(raw.critical),
                history: (raw.history ?? []).map { Reading(celsius: $0.celsius, date: APIDate.parse($0.timestamp)) }
            )
        }
        .sorted { ($0.status.health, $0.current.celsius) > ($1.status.health, $1.current.celsius) }
    }
}

struct LogFileInfo: Sendable, Equatable, Hashable, Identifiable, Decodable {
    var name: String
    var path: String
    var size: Int64
    var modifiedAt: String?
    var id: String { path }
}

struct LogFileText: Sendable, Equatable, Decodable {
    var path: String
    var content: String
    var totalLines: Int
    var startLine: Int?

    var lines: [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }.map(LogRedactor.redact)
    }
}
