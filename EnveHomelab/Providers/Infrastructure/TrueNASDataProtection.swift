import Foundation

/// zettarepl's per-task state: a dict (`state`, `datetime`, `error`) in every release, or a bare state string.
struct TrueNASTaskState: Decodable, Sendable, Equatable {
    var state: String
    var date: Date?
    var error: String?

    init(state: String, date: Date? = nil, error: String? = nil) {
        self.state = state
        self.date = date
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case state, datetime, error }

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            state = text
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "UNKNOWN"
        date = try c.decodeIfPresent(TrueNASDate.self, forKey: .datetime)?.date
        error = try c.decodeIfPresent(String.self, forKey: .error)?.nilIfEmpty
    }

    var health: Health {
        switch state {
        case "FINISHED": .ok
        case "ERROR": .critical
        case "RUNNING", "PENDING", "WAITING", "HOLD": .unknown
        default: .unknown
        }
    }

    var title: String {
        switch state {
        case "FINISHED": "Succeeded"
        case "ERROR": "Failed"
        case "RUNNING": "Running"
        case "PENDING": "Not run yet"
        case "WAITING": "Waiting"
        case "HOLD": "On hold"
        default: state.capitalized
        }
    }
}

/// `pool.snapshottask.query` (role SNAPSHOT_TASK_READ).
struct TrueNASSnapshotTask: Decodable, Sendable, Equatable, Identifiable {
    struct Schedule: Decodable, Sendable, Equatable { var minute: String?; var hour: String?; var dom: String?; var month: String?; var dow: String? }
    var id: Int
    var dataset: String
    var recursive: Bool
    var enabled: Bool
    var lifetime_value: Int
    var lifetime_unit: String
    var naming_schema: String?
    var schedule: Schedule?
    var state: TrueNASTaskState?

    var retention: String { "\(lifetime_value) \(lifetime_unit.lowercased())\(lifetime_value == 1 ? "" : "s")" }
}

/// `replication.query` (role REPLICATION_TASK_READ).
struct TrueNASReplicationTask: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var direction: String
    var transport: String
    var source_datasets: [String]
    var target_dataset: String
    var enabled: Bool
    var auto: Bool
    var state: TrueNASTaskState?
}

struct TrueNASDataProtection: Sendable, Equatable {
    /// nil when the key's role can't read that kind of task.
    var snapshotTasks: [TrueNASSnapshotTask]?
    var replicationTasks: [TrueNASReplicationTask]?

    var health: Health {
        let states = (snapshotTasks ?? []).filter(\.enabled).compactMap(\.state) + (replicationTasks ?? []).filter(\.enabled).compactMap(\.state)
        return states.contains { $0.state == "ERROR" } ? .critical : .ok
    }
}

extension TrueNASClient {
    func dataProtection() async throws -> TrueNASDataProtection {
        try await session { rpc in
            // A key without the task-read roles is refused per method, so each list is optional.
            TrueNASDataProtection(
                snapshotTasks: try await Self.readable { try await rpc.call("pool.snapshottask.query", as: [TrueNASSnapshotTask].self) },
                replicationTasks: try await Self.readable { try await rpc.call("replication.query", as: [TrueNASReplicationTask].self) }
            )
        }
    }

    /// A refusal for this method becomes nil; losing the connection still fails the whole read.
    private static func readable<Value>(_ read: () async throws -> Value) async throws -> Value? {
        do {
            return try await read()
        } catch let error as NetworkError {
            switch error {
            case .offline, .unreachable, .timedOut, .cancelled, .tlsFailure, .untrustedCertificate, .certificateChanged: throw error
            default: return nil
            }
        }
    }

    func runSnapshotTask(_ task: TrueNASSnapshotTask) async throws {
        _ = try await session { rpc in try await rpc.call("pool.snapshottask.run", [task.id]) }
    }
}
