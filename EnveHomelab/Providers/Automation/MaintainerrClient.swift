import Foundation

struct MaintainerrStatus: Decodable, Sendable {
    var version: String
    var updateAvailable: Bool?
}

struct MaintainerrHealth: Decodable, Sendable {
    var status: String
    var database: String?
}

struct MaintainerrExecution: Decodable, Sendable {
    var processingQueue: Bool
    var executingRuleGroupId: Int?
    var pendingRuleGroupIds: [Int]?
}

struct MaintainerrTaskStatus: Decodable, Sendable {
    var running: Bool
    var runningSince: String?
    var time: String?
}

struct MaintainerrCollection: Decodable, Sendable {
    var id: Int
    var title: String
    var isActive: Bool
    var arrAction: Int
    var deleteAfterDays: Int?
    var type: String?
    var mediaServerType: String?
    var mediaCount: Int?
    var totalSizeBytes: LooseNumber?

    /// Mirrors Maintainerr's `ServarrAction` enum.
    var actionDescription: String {
        switch arrAction {
        case 0: "delete the files"
        case 1: "unmonitor and delete every file"
        case 2: "unmonitor and delete existing files"
        case 3: "unmonitor in Radarr/Sonarr"
        case 4: "do nothing"
        case 5: "delete the show if it's empty"
        case 6: "unmonitor the show if it's empty"
        case 7: "change the quality profile"
        default: "run its configured action"
        }
    }

    var deletesFiles: Bool { [0, 1, 2, 5].contains(arrAction) }
}

struct MaintainerrMember: Decodable, Sendable {
    var id: Int
    var addDate: String?
}

struct MaintainerrOverview: Sendable {
    var status: MaintainerrStatus
    var health: MaintainerrHealth?
    var execution: MaintainerrExecution
    var handlerRunning: Bool
    /// nil when Maintainerr can't reach its media server (it then answers with an empty body).
    var collections: [MaintainerrCollection]?
    var dueCounts: [Int: Int]
}

protocol MaintainerrOperations: Sendable {
    func runRules() async throws
    func stopRules() async throws
    func handleCollections() async throws
}

/// Maintainerr's documented API. Maintainerr has no authentication of its own; credentials are only sent for a reverse proxy in front of it.
struct MaintainerrClient: DashboardService, MaintainerrOperations {
    let kind = IntegrationKind.maintainerr
    private let rest: RESTClient

    init(url: URL, username: String?, password: String?, pinnedFingerprint: String?) {
        var headers: [String: String] = [:]
        if let username = username?.nilIfEmpty {
            headers["Authorization"] = "Basic " + Data("\(username):\(password ?? "")".utf8).base64EncodedString()
        }
        rest = RESTClient(baseURL: url.lastPathComponent == "api" ? url : url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    /// Many reads report failure as an empty 200 body.
    private func optional<T: Decodable>(_ request: RESTRequest, as type: T.Type) async throws -> T? {
        let data = try await rest.data(request)
        return data.isEmpty ? nil : try RESTClient.decode(T.self, from: data)
    }

    func overview() async throws -> MaintainerrOverview {
        async let status = rest.json(.get("app/status"), as: MaintainerrStatus.self)
        async let execution = rest.json(.get("rules/execute/status"), as: MaintainerrExecution.self)
        async let handler = try? rest.json(.get("tasks/Collection Handler/status"), as: MaintainerrTaskStatus.self)
        async let collections = optional(.get("collections"), as: [MaintainerrCollection].self)
        // `/health` answers 503 with a body when the database is unreachable, and doesn't exist before 3.20.
        let (healthData, healthResponse) = try await rest.raw(.get("health"))
        let health = [200, 503].contains(healthResponse.statusCode) ? try? JSONDecoder().decode(MaintainerrHealth.self, from: healthData) : nil

        let list = try await collections
        var due: [Int: Int] = [:]
        for collection in list ?? [] where collection.isActive {
            let members = try await optional(.get("collections/media", query: [URLQueryItem(name: "collectionId", value: String(collection.id))]), as: [MaintainerrMember].self) ?? []
            due[collection.id] = MaintainerrDashboard.dueCount(members, deleteAfterDays: collection.deleteAfterDays)
        }
        return try await MaintainerrOverview(status: status, health: health, execution: execution, handlerRunning: handler?.running ?? false, collections: list, dueCounts: due)
    }

    func dashboard() async throws -> DashboardSnapshot {
        MaintainerrDashboard.snapshot(try await overview(), operations: self)
    }

    func runRules() async throws {
        _ = try await rest.data(.post("rules/execute"))
    }

    func stopRules() async throws {
        _ = try await rest.data(.post("rules/execute/stop"))
    }

    func handleCollections() async throws {
        _ = try await rest.data(.post("collections/handle"))
    }
}

enum MaintainerrDashboard {
    /// Maintainerr's handler treats a missing `deleteAfterDays` as zero, so those members are due immediately.
    static func dueCount(_ members: [MaintainerrMember], deleteAfterDays: Int?, now: Date = .now) -> Int {
        members.filter { member in
            guard let added = APIDate.parse(member.addDate) else { return false }
            return added.addingTimeInterval(Double(deleteAfterDays ?? 0) * 86_400) <= now
        }.count
    }

    static func snapshot(_ overview: MaintainerrOverview, operations: some MaintainerrOperations) -> DashboardSnapshot {
        let collections = overview.collections ?? []
        let active = collections.filter(\.isActive)
        let totalDue = overview.dueCounts.values.reduce(0, +)
        let destructiveDue = active.filter { $0.deletesFiles && overview.dueCounts[$0.id, default: 0] > 0 }
        let databaseDown = overview.health?.status == "degraded"
        let health: Health = databaseDown ? .critical : (overview.collections == nil ? .warning : .ok)

        var actions: [DashboardAction] = []
        if overview.execution.processingQueue {
            actions.append(DashboardAction(id: "stop-rules", title: "Stop Rule Run", systemImage: "stop.fill", targetKind: "Rules", targetName: "Running rule groups",
                                           consequence: "Maintainerr stops after the current rule group. Changes it already made to collections stay.") {
                try await operations.stopRules()
            })
        } else {
            actions.append(DashboardAction(id: "run-rules", title: "Run All Rules", systemImage: "play.fill", targetKind: "Rules", targetName: "All active rule groups",
                                           consequence: "Maintainerr re-evaluates every active rule group now. Matching media is added to its collection and its deletion countdown starts; media that no longer matches is removed. No files are deleted by this step.") {
                try await operations.runRules()
            })
        }
        if !overview.handlerRunning, totalDue > 0 {
            let plan = active.filter { overview.dueCounts[$0.id, default: 0] > 0 }
                .map { "\($0.title): \(overview.dueCounts[$0.id, default: 0]) due — will \($0.actionDescription)" }
                .joined(separator: "\n")
            actions.append(DashboardAction(id: "handle", title: "Handle Due Media Now…", systemImage: "trash", targetKind: "Collection handler", targetName: "Handle collections",
                                           consequence: "Maintainerr runs each collection's action on every item whose countdown has ended:\n\(plan)" + (destructiveDue.isEmpty ? "" : "\nFiles deleted this way are gone permanently."),
                                           confirmation: .typed) {
                try await operations.handleCollections()
            })
        }

        return DashboardSnapshot(
            version: overview.status.version,
            health: health,
            headline: overview.collections == nil ? "Collections unavailable" : "\(active.count) active collection\(active.count == 1 ? "" : "s") · \(totalDue) due",
            detail: [overview.execution.processingQueue ? "Rules running" : nil, overview.handlerRunning ? "Handling collections" : nil,
                     overview.status.updateAvailable == true ? "Update available" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            notice: databaseDown ? "Maintainerr reports its database is unreachable." : (overview.collections == nil ? "Maintainerr couldn't load collections, usually because it can't reach its media server." : nil),
            metrics: [
                DashboardMetric(title: "Active collections", value: "\(active.count)", systemImage: "rectangle.stack"),
                DashboardMetric(title: "Media in collections", value: active.compactMap(\.mediaCount).reduce(0, +).formatted(), systemImage: "film.stack"),
                DashboardMetric(title: "Due for action", value: "\(totalDue)", systemImage: "clock.badge.exclamationmark", health: totalDue > 0 ? .unknown : .ok),
            ],
            actions: actions,
            sections: [
                DashboardSection(id: "collections", title: "Collections", systemImage: "rectangle.stack", trailing: "\(collections.count)", emptyText: "No collections are set up.",
                                 rows: collections.map { collection in
                                     let due = overview.dueCounts[collection.id]
                                     var detail = ["\(collection.mediaCount ?? 0) item\(collection.mediaCount == 1 ? "" : "s")"]
                                     if let size = collection.totalSizeBytes?.value { detail.append(Format.bytes(Int64(size))) }
                                     detail.append(collection.deleteAfterDays.map { "action after \($0) day\($0 == 1 ? "" : "s")" } ?? "no waiting period")
                                     return DashboardRow(id: "c\(collection.id)", title: collection.title,
                                                         subtitle: [collection.type?.capitalizedFirst, collection.mediaServerType?.capitalizedFirst, "Will \(collection.actionDescription)"].compactMap { $0 }.joined(separator: " · "),
                                                         detail: detail.joined(separator: " · "),
                                                         health: !collection.isActive ? nil : ((due ?? 0) > 0 ? .unknown : .ok),
                                                         badge: collection.isActive ? ((due ?? 0) > 0 ? "\(due ?? 0) due" : "Active") : "Inactive",
                                                         message: collection.isActive && collection.deleteAfterDays == nil ? "No waiting period is set, so members are handled on the next run." : nil)
                                 }),
            ]
        )
    }
}
