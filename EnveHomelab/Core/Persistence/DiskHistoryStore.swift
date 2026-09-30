import Foundation
import Observation

/// Error counts and temperatures for array devices, recorded on this device whenever storage is viewed. The Unraid API has no history of its own for these.
@MainActor
@Observable
final class DiskHistoryStore {
    struct Sample: Codable, Sendable, Equatable {
        var date: Date
        var errors: Int64?
        var temperature: Int?
    }

    static let minimumInterval: TimeInterval = 10 * 60
    static let limit = 288

    private(set) var samples: [String: [Sample]]
    private let file: JSONFile<[String: [Sample]]>?

    init(file: JSONFile<[String: [Sample]]>?) {
        self.file = file
        samples = (try? file?.load()) ?? [:]
    }

    static func key(server: UUID, disk: ArrayDisk) -> String { "\(server.uuidString)/\(disk.id)" }

    /// Adds a sample when enough time has passed or the error count changed, keeping the newest `limit` per device.
    func record(_ disks: [ArrayDisk], server: UUID, now: Date = .now) {
        var changed = false
        for disk in disks where disk.errors != nil || disk.temperature != nil {
            let key = Self.key(server: server, disk: disk)
            var history = samples[key] ?? []
            let sample = Sample(date: now, errors: disk.errors, temperature: disk.isSpinning == false ? nil : disk.temperature)
            if let last = history.last, now.timeIntervalSince(last.date) < Self.minimumInterval, last.errors == sample.errors { continue }
            history.append(sample)
            samples[key] = Array(history.suffix(Self.limit))
            changed = true
        }
        if changed { try? file?.save(samples) }
    }

    func history(server: UUID, disk: ArrayDisk) -> [Sample] {
        samples[Self.key(server: server, disk: disk)] ?? []
    }

    /// Errors reported since the first sample this device kept. A drop (counters cleared on the server) restarts the count.
    static func newErrors(in history: [Sample]) -> Int64 {
        var total: Int64 = 0
        var previous: Int64?
        for errors in history.compactMap(\.errors) {
            if let previous, errors > previous { total += errors - previous }
            previous = errors
        }
        return total
    }
}
