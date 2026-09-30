import Foundation

/// TrueNAS middleware encodes datetimes as `{"$date": milliseconds}`.
struct TrueNASDate: Decodable, Sendable, Hashable {
    var date: Date

    private enum CodingKeys: String, CodingKey { case date = "$date" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .date) / 1000)
    }
}

struct TrueNASSystemInfo: Decodable, Sendable {
    var version: String
    var hostname: String
    var uptime_seconds: Double?
    var model: String?
    var cores: Int?
    var physmem: Int64?
    var system_product: String?
}

struct TrueNASPool: Decodable, Sendable, Hashable, Identifiable {
    struct Scan: Decodable, Sendable, Hashable {
        var function: String?
        var state: String?
        var percentage: Double?
        var errors: Int?
        var end_time: TrueNASDate?
    }

    var id: Int
    var name: String
    var status: String
    var healthy: Bool
    var warning: Bool?
    var status_detail: String?
    var size: Int64?
    var allocated: Int64?
    var free: Int64?
    var scan: Scan?

    var usedFraction: Double? {
        guard let size, let allocated, size > 0 else { return nil }
        return Double(allocated) / Double(size)
    }

    var health: Health {
        if !healthy || status != "ONLINE" { return .critical }
        return warning == true ? .warning : .ok
    }

    var isScrubbing: Bool { scan?.function == "SCRUB" && scan?.state == "SCANNING" }
}

struct TrueNASDisk: Decodable, Sendable, Hashable, Identifiable {
    var identifier: String
    var name: String
    var serial: String?
    var size: Int64?
    var model: String?
    var type: String?
    var pool: String?
    var rotationrate: Int?

    var id: String { identifier }
}

struct TrueNASAlert: Decodable, Sendable, Hashable, Identifiable {
    var uuid: String
    var level: String
    var klass: String?
    var formatted: String?
    var text: String?
    var dismissed: Bool
    var datetime: TrueNASDate?

    var id: String { uuid }

    var message: String {
        let raw = formatted ?? text ?? klass ?? "Alert"
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var health: Health {
        switch level {
        case "CRITICAL", "ALERT", "EMERGENCY", "ERROR": .critical
        case "WARNING": .warning
        default: .unknown
        }
    }
}

struct TrueNASDataset: Decodable, Sendable, Hashable, Identifiable {
    struct Property: Decodable, Sendable, Hashable {
        var parsed: JSONValue?
        var value: String?

        var bytes: Int64? {
            if case .number(let number)? = parsed { return Int64(number) }
            return nil
        }
    }

    var id: String
    var type: String
    var name: String
    var pool: String
    var encrypted: Bool
    var locked: Bool
    var used: Property?
    var available: Property?
    var mountpoint: String?
}

struct TrueNASJob: Decodable, Sendable, Hashable, Identifiable {
    struct Progress: Decodable, Sendable, Hashable {
        var percent: Double?
        var description: String?
    }

    var id: Int
    var method: String
    var description: String?
    var state: String
    var progress: Progress?
    var error: String?
    var time_started: TrueNASDate?
    var time_finished: TrueNASDate?

    var title: String { description?.nilIfEmpty ?? method }

    var health: Health {
        switch state {
        case "SUCCESS": .ok
        case "FAILED": .critical
        case "ABORTED": .warning
        default: .unknown
        }
    }
}

struct TrueNASSnapshot: Sendable {
    var system: TrueNASSystemInfo
    var pools: [TrueNASPool]
    var disks: [TrueNASDisk]
    var alerts: [TrueNASAlert]
    var datasets: [TrueNASDataset]
    var jobs: [TrueNASJob]
}

enum TrueNASScrubAction: String, Sendable, Identifiable {
    case start = "START"
    case pause = "PAUSE"
    case stop = "STOP"

    var id: String { rawValue }
    var title: String { self == .start ? "Start Scrub" : (self == .pause ? "Pause Scrub" : "Stop Scrub") }

    var consequence: String {
        switch self {
        case .start: "ZFS reads and verifies every block in the pool. Disk activity is high and performance drops until it finishes, which can take hours."
        case .pause: "The scrub pauses at its current position and can be resumed by starting it again."
        case .stop: "The scrub is cancelled; its progress is discarded."
        }
    }
}

protocol TrueNASService: IntegrationService {
    func snapshot() async throws -> TrueNASSnapshot
    func setAlert(_ alert: TrueNASAlert, dismissed: Bool) async throws
    func scrub(_ pool: TrueNASPool, action: TrueNASScrubAction) async throws
    func dataProtection() async throws -> TrueNASDataProtection
    /// Takes the task's snapshot now; zettarepl then applies the task's retention as it would on schedule.
    func runSnapshotTask(_ task: TrueNASSnapshotTask) async throws
}

extension TrueNASService {
    func summary() async throws -> IntegrationSummary {
        let snapshot = try await snapshot()
        let active = snapshot.alerts.filter { !$0.dismissed }
        let worst = (snapshot.pools.map(\.health) + active.map(\.health)).max() ?? .ok
        return IntegrationSummary(
            product: "TrueNAS",
            version: snapshot.system.version,
            health: worst == .unknown ? .ok : worst,
            headline: "\(snapshot.pools.count) pool\(snapshot.pools.count == 1 ? "" : "s") · \(snapshot.pools.filter { $0.health == .ok }.count) healthy",
            detail: active.isEmpty ? snapshot.system.hostname : "\(active.count) active alert\(active.count == 1 ? "" : "s")"
        )
    }
}

/// TrueNAS SCALE 25.04+ JSON-RPC 2.0 over `wss://<host>/api/current`, authenticated with `auth.login_with_api_key`.
struct TrueNASClient: TrueNASService {
    let url: URL
    private let apiKey: String
    private let pinnedFingerprint: String?

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        self.url = url
        self.apiKey = apiKey
        self.pinnedFingerprint = pinnedFingerprint
    }

    static func socketURL(for url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https" else {
            throw NetworkError.forbidden("TrueNAS revokes API keys used over plain HTTP. Use an https:// address.")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = "/api/current"
        return components.url!
    }

    func session<Result>(_ body: (JSONRPCWebSocketSession) async throws -> Result) async throws -> Result {
        try await JSONRPCWebSocketSession.withSession(url: try Self.socketURL(for: url), pinnedFingerprint: pinnedFingerprint) { rpc in
            guard try await rpc.call("auth.login_with_api_key", [apiKey], as: Bool.self) else {
                throw NetworkError.unauthorized
            }
            return try await body(rpc)
        }
    }

    func snapshot() async throws -> TrueNASSnapshot {
        try await session { rpc in
            let jobFilters: [Any] = [[], ["order_by": ["-id"], "limit": 25]]
            let datasetOptions: [Any] = [[], ["extra": ["flat": true, "retrieve_children": false, "properties": ["used", "available", "mountpoint"]]]]
            return TrueNASSnapshot(
                system: try await rpc.call("system.info", as: TrueNASSystemInfo.self),
                pools: try await rpc.call("pool.query", as: [TrueNASPool].self),
                disks: try await rpc.call("disk.query", as: [TrueNASDisk].self).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                alerts: try await rpc.call("alert.list", as: [TrueNASAlert].self).sorted { ($0.datetime?.date ?? .distantPast) > ($1.datetime?.date ?? .distantPast) },
                datasets: try await rpc.call("pool.dataset.query", datasetOptions, as: [TrueNASDataset].self),
                jobs: try await rpc.call("core.get_jobs", jobFilters, as: [TrueNASJob].self)
            )
        }
    }

    func setAlert(_ alert: TrueNASAlert, dismissed: Bool) async throws {
        _ = try await session { rpc in try await rpc.call(dismissed ? "alert.dismiss" : "alert.restore", [alert.uuid]) }
    }

    func scrub(_ pool: TrueNASPool, action: TrueNASScrubAction) async throws {
        _ = try await session { rpc in try await rpc.call("pool.scrub.scrub", [pool.name, action.rawValue]) }
    }
}
