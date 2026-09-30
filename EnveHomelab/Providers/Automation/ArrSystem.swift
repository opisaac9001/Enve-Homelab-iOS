import Foundation

/// `/system/task`: the app's own scheduled jobs.
struct ArrTask: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var taskName: String
    var interval: Int?
    var lastExecution: String?
    var nextExecution: String?
    var lastDuration: String?

    /// Tasks that only maintain the app itself; anything that searches, grabs, imports or updates isn't offered.
    static let runnable: Set<String> = ["Backup", "Housekeeping", "CheckHealth"]
    var isRunnable: Bool { Self.runnable.contains(taskName) }

    var consequence: String {
        switch taskName {
        case "Backup": "Writes a new backup of the database and settings to the app's backup folder. Older scheduled backups are pruned by the app's own retention setting."
        case "Housekeeping": "Runs the app's database clean-up (orphaned records, old history, cache). It changes nothing in your library."
        default: "Re-runs every health check now instead of waiting for the next scheduled check."
        }
    }
}

/// `/log`, filtered to warnings and worse.
struct ArrLogEntry: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var time: String?
    var level: String?
    var logger: String?
    var message: String?
    var exception: String?

    private enum CodingKeys: String, CodingKey { case id, time, level, logger, message, exception }

    init(id: Int, time: String? = nil, level: String? = nil, logger: String? = nil, message: String? = nil, exception: String? = nil) {
        (self.id, self.time, self.level, self.logger, self.message, self.exception) = (id, time, level, logger, message, exception)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        level = try c.decodeIfPresent(String.self, forKey: .level)
        logger = try c.decodeIfPresent(String.self, forKey: .logger)
        message = try c.decodeIfPresent(String.self, forKey: .message).map(LogRedactor.redact)
        exception = try c.decodeIfPresent(String.self, forKey: .exception).map(LogRedactor.redact)
    }

    var isProblem: Bool { ["warn", "error", "fatal"].contains(level?.lowercased() ?? "") }
}

/// `/update`.
struct ArrUpdate: Decodable, Sendable, Equatable {
    struct Changes: Decodable, Sendable, Equatable { var new: [String]?; var fixed: [String]? }
    var version: String
    var branch: String?
    var releaseDate: String?
    var installed: Bool?
    var installable: Bool?
    var latest: Bool?
    var changes: Changes?
}

/// `/system/backup`.
struct ArrBackup: Decodable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var type: String?
    var size: Int64?
    var time: String?
}

struct ArrSystemDiagnostics: Sendable, Equatable {
    var tasks: [ArrTask]
    var problems: [ArrLogEntry]
    var problemTotal: Int
    /// The newest release the app offers that isn't installed yet.
    var availableUpdate: ArrUpdate?
    /// nil when the backup list can't be read (older releases, or a reverse proxy blocking it).
    var backups: [ArrBackup]?

    static func availableUpdate(in updates: [ArrUpdate]) -> ArrUpdate? {
        guard !updates.contains(where: { $0.latest == true && $0.installed == true }) else { return nil }
        return updates.first { $0.latest == true && $0.installed != true && $0.installable == true }
    }
}

extension ArrClient {
    func systemDiagnostics() async throws -> ArrSystemDiagnostics {
        struct LogPage: Decodable { var totalRecords: Int?; var records: [ArrLogEntry] }
        let logQuery = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: "20"), URLQueryItem(name: "sortKey", value: "time"),
                        URLQueryItem(name: "sortDirection", value: "descending"), URLQueryItem(name: "level", value: "warn")]
        async let tasks = rest.json(.get("\(apiPath)/system/task"), as: [ArrTask].self)
        async let log = rest.json(.get("\(apiPath)/log", query: logQuery), as: LogPage.self)
        async let updates = try? rest.json(.get("\(apiPath)/update"), as: [ArrUpdate].self)
        async let backups = try? rest.json(.get("\(apiPath)/system/backup"), as: [ArrBackup].self)
        let page = try await log
        return ArrSystemDiagnostics(
            tasks: try await tasks.sorted { $0.name < $1.name },
            problems: page.records.filter(\.isProblem),
            problemTotal: page.totalRecords ?? page.records.count,
            availableUpdate: ArrSystemDiagnostics.availableUpdate(in: await updates ?? []),
            backups: await backups.map { $0.sorted { ($0.time ?? "") > ($1.time ?? "") } }
        )
    }

    func runTask(_ task: ArrTask) async throws {
        guard task.isRunnable else { throw NetworkError.unsupportedByServer("Only backup, housekeeping and health-check tasks can be run from here.") }
        struct Body: Encodable { let name: String }
        _ = try await rest.data(try .post("\(apiPath)/command", json: Body(name: task.taskName)))
    }
}
