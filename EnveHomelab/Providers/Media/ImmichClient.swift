import Foundation

struct ImmichVersion: Decodable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    var text: String { "\(major).\(minor).\(patch)" }
}

struct ImmichStorage: Decodable, Sendable {
    var diskSizeRaw: Int64
    var diskUseRaw: Int64
    var diskAvailableRaw: Int64
    var diskUsagePercentage: Double
}

struct ImmichStatistics: Decodable, Sendable {
    struct UserUsage: Decodable, Sendable {
        var userId: String
        var userName: String
        var photos: Int
        var videos: Int
        var usage: Int64
        var quotaSizeInBytes: Int64?
    }

    var photos: Int
    var videos: Int
    var usage: Int64
    var usageByUser: [UserUsage]
}

struct ImmichQueue: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        var active: Int
        var completed: Int
        var failed: Int
        var delayed: Int
        var waiting: Int
        var paused: Int
    }

    struct Status: Decodable, Sendable {
        var isActive: Bool
        var isPaused: Bool
    }

    var jobCounts: Counts
    var queueStatus: Status
}

struct ImmichOverview: Sendable {
    var version: String
    var storage: ImmichStorage
    /// Admin-only; nil when the key's owner isn't an admin or the key lacks the permission.
    var statistics: ImmichStatistics?
    var queues: [String: ImmichQueue]?
    var maintenance = ServerMaintenance()
}

/// `GET /server/version-check` (permission `server.versionCheck`).
struct ImmichVersionCheck: Decodable, Sendable {
    var releaseVersion: String?
}

/// `GET /admin/database-backups` (admin, Immich 2.5+, marked alpha).
struct ImmichDatabaseBackups: Decodable, Sendable {
    struct Backup: Decodable, Sendable { var filename: String; var filesize: Int64? }
    var backups: [Backup]
}

enum ImmichQueueCommand: String, Sendable {
    case start, pause, resume, empty
    case clearFailed = "clear-failed"
}

protocol ImmichOperations: Sendable {
    func send(_ command: ImmichQueueCommand, to queue: String) async throws
}

/// Immich 1.113+ REST API with an `x-api-key` header. Queues use the `/jobs` endpoints, which every version since supports.
struct ImmichClient: DashboardService, ImmichOperations {
    let kind = IntegrationKind.immich
    /// Queues that accept `start`; others answer 400.
    static let startable: Set<String> = ["videoConversion", "storageTemplateMigration", "migration", "smartSearch", "duplicateDetection", "metadataExtraction",
                                         "sidecar", "thumbnailGeneration", "faceDetection", "facialRecognition", "library", "backupDatabase", "ocr"]
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.lastPathComponent == "api" ? url : url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: ["x-api-key": apiKey])
    }

    private func adminOnly<T: Decodable>(_ path: String, as type: T.Type) async throws -> T? {
        do {
            return try await rest.json(.get(path), as: T.self)
        } catch NetworkError.forbidden {
            return nil
        }
    }

    func overview() async throws -> ImmichOverview {
        async let version = rest.json(.get("server/version"), as: ImmichVersion.self)
        async let storage = rest.json(.get("server/storage"), as: ImmichStorage.self)
        async let statistics = adminOnly("server/statistics", as: ImmichStatistics.self)
        async let queues = adminOnly("jobs", as: [String: ImmichQueue].self)
        async let check = try? rest.json(.get("server/version-check"), as: ImmichVersionCheck.self)
        async let backups = try? adminOnly("admin/database-backups", as: ImmichDatabaseBackups.self)
        let current = try await version.text
        let maintenance = ServerMaintenance(update: Self.update(latest: await check?.releaseVersion, current: current),
                                            backups: (await backups ?? nil)?.backups.map { ServerMaintenance.Backup(name: $0.filename, size: $0.filesize) })
        return try await ImmichOverview(version: current, storage: storage, statistics: statistics, queues: queues, maintenance: maintenance)
    }

    static func update(latest: String?, current: String) -> ServerMaintenance.Update {
        guard let latest = latest?.nilIfEmpty else { return .unknown }
        return SemanticVersion.isNewer(latest, than: current) ? .available(latest.hasPrefix("v") ? String(latest.dropFirst()) : latest) : .upToDate
    }

    func dashboard() async throws -> DashboardSnapshot {
        ImmichDashboard.snapshot(try await overview(), operations: self)
    }

    private struct Command: Encodable {
        var command: String
        var force: Bool
    }

    func send(_ command: ImmichQueueCommand, to queue: String) async throws {
        _ = try await rest.data(RESTRequest(method: "PUT", path: "jobs/\(queue)", body: .json(try JSONEncoder().encode(Command(command: command.rawValue, force: false)))))
    }
}

enum ImmichDashboard {
    static func queueTitle(_ name: String) -> String {
        switch name {
        case "thumbnailGeneration": "Thumbnails"
        case "metadataExtraction": "Metadata extraction"
        case "videoConversion": "Video transcoding"
        case "faceDetection": "Face detection"
        case "facialRecognition": "Facial recognition"
        case "smartSearch": "Smart search"
        case "duplicateDetection": "Duplicate detection"
        case "backgroundTask": "Background tasks"
        case "storageTemplateMigration": "Storage template migration"
        case "backupDatabase": "Database backup"
        case "ocr": "Text recognition (OCR)"
        default:
            name.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2.lowercased())" }.capitalizedFirst
        }
    }

    static func snapshot(_ overview: ImmichOverview, operations: some ImmichOperations) -> DashboardSnapshot {
        let storage = overview.storage
        let storageHealth: Health = storage.diskUsagePercentage >= 95 ? .critical : (storage.diskUsagePercentage >= 85 ? .warning : .ok)
        let queues = (overview.queues ?? [:]).sorted { queueTitle($0.key) < queueTitle($1.key) }
        let failed = queues.map(\.value.jobCounts.failed).reduce(0, +)
        let pending = queues.map { $0.value.jobCounts.waiting + $0.value.jobCounts.active }.reduce(0, +)
        let health = max(storageHealth, failed > 0 ? .warning : .ok)

        var metrics = [DashboardMetric(title: "Storage used", value: Format.percent(storage.diskUsagePercentage / 100), systemImage: "internaldrive", health: storageHealth)]
        if let stats = overview.statistics {
            metrics += [
                DashboardMetric(title: "Photos", value: stats.photos.formatted(), systemImage: "photo"),
                DashboardMetric(title: "Videos", value: stats.videos.formatted(), systemImage: "video"),
                DashboardMetric(title: "Library size", value: Format.bytes(stats.usage), systemImage: "photo.stack"),
            ]
        }
        if overview.queues != nil {
            metrics.append(DashboardMetric(title: "Jobs pending", value: pending.formatted(), systemImage: "hourglass"))
            metrics.append(DashboardMetric(title: "Failed jobs", value: failed.formatted(), systemImage: "xmark.octagon", health: failed > 0 ? .warning : .ok))
        }

        var sections = [
            DashboardSection(id: "storage", title: "Storage", systemImage: "internaldrive", emptyText: "",
                             rows: [DashboardRow(id: "disk", title: "Upload location", detail: "\(Format.bytes(storage.diskUseRaw)) of \(Format.bytes(storage.diskSizeRaw)) · \(Format.bytes(storage.diskAvailableRaw)) free",
                                                 health: storageHealth, progress: storage.diskUsagePercentage / 100)]),
        ]
        if overview.queues != nil {
            sections.append(DashboardSection(id: "queues", title: "Job Queues", systemImage: "list.bullet.rectangle", trailing: pending > 0 ? "\(pending.formatted()) pending" : "Idle",
                                             emptyText: "Immich reported no job queues.",
                                             rows: queues.map { name, queue in queueRow(name: name, queue: queue, operations: operations) }))
        }
        if let stats = overview.statistics {
            sections.append(DashboardSection(id: "users", title: "Usage by User", systemImage: "person.2", trailing: "\(stats.usageByUser.count)", emptyText: "No users.",
                                             rows: stats.usageByUser.map { user in
                                                 let quota = user.quotaSizeInBytes.flatMap { $0 > 0 ? $0 : nil }
                                                 let fraction = quota.map { Double(user.usage) / Double($0) }
                                                 return DashboardRow(id: user.userId, title: user.userName, subtitle: "\(user.photos.formatted()) photos · \(user.videos.formatted()) videos",
                                                                     detail: Format.bytes(user.usage) + (quota.map { " of \(Format.bytes($0)) quota" } ?? ""),
                                                                     health: fraction.map { $0 >= 1 ? .critical : ($0 >= 0.9 ? .warning : .ok) }, progress: fraction)
                                             }))
        }

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: overview.statistics.map { "\($0.photos.formatted()) photos · \($0.videos.formatted()) videos" } ?? "\(Format.percent(storage.diskUsagePercentage / 100)) of storage used",
            detail: [pending > 0 ? "\(pending.formatted()) jobs pending" : nil, failed > 0 ? "\(failed.formatted()) failed" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            notice: overview.queues == nil ? "Job queues and library statistics need an API key owned by an admin with the job.read, job.create and server.statistics permissions." : nil,
            metrics: metrics,
            sections: sections + [overview.maintenance.section(backupsNote: "Database backups made by Immich's backup job")]
        )
    }

    private static func queueRow(name: String, queue: ImmichQueue, operations: some ImmichOperations) -> DashboardRow {
        let counts = queue.jobCounts
        let title = queueTitle(name)
        var actions: [DashboardAction] = []
        if queue.queueStatus.isPaused {
            actions.append(DashboardAction(id: "resume:\(name)", title: "Resume", systemImage: "play.fill", targetKind: "Queue", targetName: title,
                                           consequence: "Immich continues processing this queue.", confirmation: .none) {
                try await operations.send(.resume, to: name)
            })
        } else {
            actions.append(DashboardAction(id: "pause:\(name)", title: "Pause", systemImage: "pause.fill", targetKind: "Queue", targetName: title,
                                           consequence: "Immich stops starting new \(title.lowercased()) jobs until you resume the queue. New uploads wait for this step.") {
                try await operations.send(.pause, to: name)
            })
        }
        if ImmichClient.startable.contains(name), !queue.queueStatus.isActive {
            actions.append(DashboardAction(id: "start:\(name)", title: "Process Missing", systemImage: "play.circle", targetKind: "Queue", targetName: title,
                                           consequence: "Immich queues \(title.lowercased()) for every asset that hasn't been processed yet. Already processed assets are left alone.", confirmation: .none) {
                try await operations.send(.start, to: name)
            })
        }
        if counts.failed > 0 {
            actions.append(DashboardAction(id: "clear-failed:\(name)", title: "Clear Failed Jobs", systemImage: "xmark.bin", targetKind: "Queue", targetName: title,
                                           consequence: "Immich forgets \(counts.failed.formatted()) failed \(title.lowercased()) job\(counts.failed == 1 ? "" : "s"). The affected assets stay unprocessed until the queue runs again.") {
                try await operations.send(.clearFailed, to: name)
            })
        }
        if counts.waiting > 0 {
            actions.append(DashboardAction(id: "empty:\(name)", title: "Empty Queue…", systemImage: "trash", targetKind: "Queue", targetName: title,
                                           consequence: "Immich drops \(counts.waiting.formatted()) waiting job\(counts.waiting == 1 ? "" : "s"). Those assets won't be processed until the queue is started again.",
                                           confirmation: .destructive) {
                try await operations.send(.empty, to: name)
            })
        }
        let state = queue.queueStatus.isPaused ? "Paused" : (queue.queueStatus.isActive ? "Running" : "Idle")
        return DashboardRow(id: name, title: title,
                            detail: "\(counts.active) active · \(counts.waiting.formatted()) waiting · \(counts.failed.formatted()) failed" + (counts.delayed > 0 ? " · \(counts.delayed) delayed" : ""),
                            health: counts.failed > 0 ? .warning : (queue.queueStatus.isPaused ? .unknown : .ok), badge: state, actions: actions)
    }
}
