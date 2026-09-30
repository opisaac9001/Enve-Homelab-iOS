import Foundation

struct UnraidShare: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var comment: String?
    var freeKB: Int64?
    var usedKB: Int64?
    var sizeKB: Int64?
    var usesCache: Bool?
    var includedDisks: [String]
    var excludedDisks: [String]
    var allocator: String?
    var splitLevel: String?
    var luksStatus: String?

    /// Unraid reports `size` as 0 for shares that span the array, so fall back to used + free.
    var totalKB: Int64? {
        if let sizeKB, sizeKB > 0 { return sizeKB }
        guard let usedKB, let freeKB else { return nil }
        return usedKB + freeKB
    }

    var usedFraction: Double? {
        guard let usedKB, let totalKB, totalKB > 0 else { return nil }
        return Double(usedKB) / Double(totalKB)
    }
}

extension UnraidShare: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, comment, free, used, size, cache, include, exclude, allocator, splitLevel, luksStatus
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        comment = try c.decodeIfPresent(String.self, forKey: .comment)?.nilIfEmpty
        freeKB = try c.decodeBigIntIfPresent(forKey: .free)
        usedKB = try c.decodeBigIntIfPresent(forKey: .used)
        sizeKB = try c.decodeBigIntIfPresent(forKey: .size)
        usesCache = try c.decodeIfPresent(Bool.self, forKey: .cache)
        includedDisks = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        excludedDisks = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        allocator = try c.decodeIfPresent(String.self, forKey: .allocator)?.nilIfEmpty
        splitLevel = try c.decodeIfPresent(String.self, forKey: .splitLevel)?.nilIfEmpty
        luksStatus = try c.decodeIfPresent(String.self, forKey: .luksStatus)?.nilIfEmpty
    }
}

enum DiskInterfaceType: String, ResilientEnum {
    case sas = "SAS"
    case sata = "SATA"
    case usb = "USB"
    case pcie = "PCIE"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .sas: "SAS"
        case .sata: "SATA"
        case .usb: "USB"
        case .pcie: "PCIe / NVMe"
        case .unknown: "Unknown"
        }
    }
}

/// The API only distinguishes a passing overall SMART assessment from everything else.
enum DiskSmartStatus: String, ResilientEnum {
    case ok = "OK"
    case unknown = "UNKNOWN"
}

struct DiskPartition: Sendable, Hashable, Decodable {
    var name: String
    var fsType: String
    var size: Double
}

struct PhysicalDisk: Sendable, Hashable, Identifiable, Decodable {
    var id: String
    var device: String
    var type: String
    var name: String
    var vendor: String
    var size: Double
    var firmwareRevision: String
    var serialNum: String
    var interfaceType: DiskInterfaceType
    var smartStatus: DiskSmartStatus
    var temperature: Double?
    var partitions: [DiskPartition]
    var isSpinning: Bool

    var deviceName: String {
        device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
    }

    func matches(_ arrayDisk: ArrayDisk) -> Bool {
        guard let device = arrayDisk.device, !device.isEmpty else { return false }
        return deviceName == device
    }
}

struct UPSBattery: Sendable, Hashable, Decodable {
    var chargeLevel: Int
    var estimatedRuntime: Int
    var health: String
}

struct UPSPower: Sendable, Hashable, Decodable {
    var inputVoltage: Double
    var outputVoltage: Double
    var loadPercentage: Int
    var nominalPower: Int?
    var currentPower: Double?
}

struct UPSDevice: Sendable, Hashable, Identifiable, Decodable {
    var id: String
    var name: String
    var model: String
    var status: String
    var battery: UPSBattery
    var power: UPSPower

    var isOnBattery: Bool {
        let value = status.lowercased()
        return value.contains("battery") && !value.contains("replace")
    }

    var health: Health {
        let value = status.lowercased()
        if value.contains("low") || value.contains("overload") || value.contains("offline") || battery.health.lowercased() == "replace" {
            return .critical
        }
        if isOnBattery || value.contains("replace") || battery.chargeLevel < 50 || power.loadPercentage >= 80 {
            return .warning
        }
        return value.contains("online") ? .ok : .unknown
    }

    static func merging(_ update: UPSDevice, into devices: [UPSDevice]) -> [UPSDevice] {
        var devices = devices
        if let index = devices.firstIndex(where: { $0.id == update.id }) {
            devices[index] = update
        } else {
            devices.append(update)
        }
        return devices
    }
}

enum ArrayStateAction: String, Sendable, Identifiable {
    case start = "START"
    case stop = "STOP"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start Array"
        case .stop: "Stop Array"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.circle.fill"
        case .stop: "stop.circle.fill"
        }
    }
}

/// Decides whether the app offers an array state change and what the user must be told first.
struct ArrayControlAssessment: Sendable, Equatable {
    var action: ArrayStateAction?
    var blockers: [String]
    var warnings: [String]

    var isAllowed: Bool { action != nil && blockers.isEmpty }

    static func assess(_ array: ArrayStatus, runningContainers: Int?, runningVMs: Int?) -> ArrayControlAssessment {
        switch array.state {
        case .started:
            var warnings = [
                "Every share on the array and pools becomes unavailable, including SMB and NFS mounts on other devices.",
            ]
            switch runningContainers {
            case .some(let count) where count > 0:
                warnings.append("\(count) running container\(count == 1 ? "" : "s") will be stopped.")
            case nil:
                warnings.append("Running containers will be stopped.")
            default:
                break
            }
            switch runningVMs {
            case .some(let count) where count > 0:
                warnings.append("\(count) running VM\(count == 1 ? "" : "s") will be shut down; guests that ignore the request may be forced off.")
            case nil:
                warnings.append("Running VMs will be shut down.")
            default:
                break
            }
            if array.parityCheck?.isActive == true {
                warnings.append("The parity check in progress will be cancelled.")
            }
            return ArrayControlAssessment(action: .stop, blockers: [], warnings: warnings)

        case .stopped:
            var blockers: [String] = []
            var warnings: [String] = []
            let slots = array.parities + array.disks
            let changed = slots.filter { [.missing, .wrong, .new, .disabledNew, .notPresentDisabled, .invalid].contains($0.status) }
            if !changed.isEmpty {
                blockers.append("Disk assignments need review (\(changed.map(\.displayName).joined(separator: ", "))). Starting now could begin a rebuild or parity sync — review them in the Unraid web interface.")
            }
            let disabled = slots.filter { $0.status == .disabled }
            if !disabled.isEmpty {
                warnings.append("\(disabled.map(\.displayName).joined(separator: ", ")) will run emulated from parity.")
            }
            warnings.append("Containers and VMs set to autostart will start with the array.")
            return ArrayControlAssessment(action: .start, blockers: blockers, warnings: warnings)

        default:
            return ArrayControlAssessment(
                action: nil,
                blockers: ["The array is in the “\(array.state.displayName)” state. Resolve it in the Unraid web interface."],
                warnings: []
            )
        }
    }
}

enum ContainerUpdateAvailability: Equatable, Sendable {
    case available
    case upToDate
    /// The server's API doesn't expose update status (`ENABLE_NEXT_DOCKER_RELEASE` is off or the API predates it).
    case notReported

    init(_ value: Bool?) {
        switch value {
        case true?: self = .available
        case false?: self = .upToDate
        case nil: self = .notReported
        }
    }
}
