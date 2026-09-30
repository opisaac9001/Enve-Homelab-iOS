import Foundation

/// Tdarr documents request bodies but few response fields, so everything beyond the node and worker keys is optional.
struct TdarrStatus: Decodable, Sendable {
    var version: String?
}

struct TdarrWorker: Decodable, Sendable {
    struct Job: Decodable, Sendable { var jobId: String? }
    var idle: Bool?
    var file: String?
    var job: Job?
}

struct TdarrNode: Decodable, Sendable {
    var nodeName: String?
    var nodePaused: Bool?
    var workers: [String: TdarrWorker]?
}

struct TdarrWorkerLimits: Decodable, Sendable {
    var queueLengths: [String: LooseNumber]?
    var workerLimits: [String: LooseNumber]?
}

struct TdarrOverview: Sendable {
    struct NodeState: Sendable {
        var id: String
        var node: TdarrNode
        var limits: TdarrWorkerLimits?
    }

    var version: String?
    var nodes: [NodeState]
}

protocol TdarrOperations: Sendable {
    func setPaused(_ paused: Bool, nodeID: String) async throws
}

/// Tdarr server API v2. Every POST body is wrapped in `{"data": …}`; an API key goes in `x-api-key` when auth is on.
struct TdarrClient: DashboardService, TdarrOperations {
    let kind = IntegrationKind.tdarr
    private let rest: RESTClient

    init(url: URL, apiKey: String?, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api/v2"), pinnedFingerprint: pinnedFingerprint,
                          headers: apiKey?.nilIfEmpty.map { ["x-api-key": $0] } ?? [:])
    }

    private struct Wrapped<Body: Encodable>: Encodable { var data: Body }

    func overview() async throws -> TdarrOverview {
        async let status = rest.json(.get("status"), as: TdarrStatus.self)
        let nodes = try await rest.json(.get("get-nodes"), as: [String: TdarrNode].self)
        var states: [TdarrOverview.NodeState] = []
        for (id, node) in nodes.sorted(by: { ($0.value.nodeName ?? $0.key) < ($1.value.nodeName ?? $1.key) }) {
            let limits = try? await rest.json(try .post("poll-worker-limits", json: Wrapped(data: ["nodeID": id])), as: TdarrWorkerLimits.self)
            states.append(.init(id: id, node: node, limits: limits))
        }
        return try await TdarrOverview(version: status.version, nodes: states)
    }

    func dashboard() async throws -> DashboardSnapshot {
        TdarrDashboard.snapshot(try await overview(), operations: self)
    }

    private struct NodeUpdate: Encodable {
        struct Updates: Encodable { var nodePaused: Bool }
        var nodeID: String
        var nodeUpdates: Updates
    }

    func setPaused(_ paused: Bool, nodeID: String) async throws {
        _ = try await rest.data(try .post("update-node", json: Wrapped(data: NodeUpdate(nodeID: nodeID, nodeUpdates: .init(nodePaused: paused)))))
    }
}

enum TdarrDashboard {
    static func workerTypeName(_ key: String) -> String {
        switch key {
        case "transcodecpu": "Transcode (CPU)"
        case "transcodegpu": "Transcode (GPU)"
        case "healthcheckcpu": "Health check (CPU)"
        case "healthcheckgpu": "Health check (GPU)"
        default: key
        }
    }

    static func snapshot(_ overview: TdarrOverview, operations: some TdarrOperations) -> DashboardSnapshot {
        let busy = overview.nodes.flatMap { state in (state.node.workers ?? [:]).filter { $0.value.idle == false }.map { (state, $0.key, $0.value) } }
        let queued = overview.nodes.compactMap(\.limits?.queueLengths).flatMap(\.values).compactMap(\.int).reduce(0, +)
        let paused = overview.nodes.filter { $0.node.nodePaused == true }

        let nodeRows = overview.nodes.map { state in
            let name = state.node.nodeName ?? state.id
            let workers = state.node.workers ?? [:]
            let active = workers.values.filter { $0.idle == false }.count
            let queues = (state.limits?.queueLengths ?? [:]).compactMap { key, value in value.int.map { "\(workerTypeName(key)) \($0)" } }.sorted()
            var actions: [DashboardAction] = []
            if state.node.nodePaused != true {
                actions.append(DashboardAction(id: "pause:\(state.id)", title: "Pause Node", systemImage: "pause.fill", targetKind: "Node", targetName: name,
                                               consequence: "\(name) stops taking new transcode and health-check work. Items it's already processing finish normally.") {
                    try await operations.setPaused(true, nodeID: state.id)
                })
            }
            if state.node.nodePaused != false {
                actions.append(DashboardAction(id: "resume:\(state.id)", title: "Resume Node", systemImage: "play.fill", targetKind: "Node", targetName: name,
                                               consequence: "\(name) starts taking new work again.", confirmation: .none) {
                    try await operations.setPaused(false, nodeID: state.id)
                })
            }
            return DashboardRow(id: state.id, title: name, subtitle: "\(active) of \(workers.count) worker\(workers.count == 1 ? "" : "s") busy",
                                detail: queues.isEmpty ? nil : "Queued: " + queues.joined(separator: " · "),
                                health: state.node.nodePaused == true ? .unknown : .ok,
                                badge: state.node.nodePaused.map { $0 ? "Paused" : "Running" }, actions: actions)
        }

        return DashboardSnapshot(
            version: overview.version,
            health: overview.nodes.isEmpty ? .warning : .ok,
            headline: overview.nodes.isEmpty ? "No nodes connected" : "\(busy.count) worker\(busy.count == 1 ? "" : "s") busy · \(queued.formatted()) queued",
            detail: paused.isEmpty ? nil : "\(paused.count) node\(paused.count == 1 ? "" : "s") paused",
            metrics: [
                DashboardMetric(title: "Nodes", value: "\(overview.nodes.count)", systemImage: "server.rack", health: overview.nodes.isEmpty ? .warning : nil),
                DashboardMetric(title: "Busy workers", value: "\(busy.count)", systemImage: "gearshape.2"),
                DashboardMetric(title: "Queued items", value: queued.formatted(), systemImage: "list.bullet"),
            ],
            sections: [
                DashboardSection(id: "nodes", title: "Nodes", systemImage: "server.rack", trailing: "\(overview.nodes.count)",
                                 emptyText: "No Tdarr nodes are connected to this server.", rows: nodeRows),
                DashboardSection(id: "workers", title: "Working On", systemImage: "film.stack", trailing: "\(busy.count)", emptyText: "Every worker is idle.",
                                 rows: busy.map { state, workerID, worker in
                                     DashboardRow(id: "\(state.id):\(workerID)", title: worker.file.map { ($0 as NSString).lastPathComponent } ?? "Unknown file",
                                                  subtitle: state.node.nodeName ?? state.id, detail: worker.file)
                                 }),
            ]
        )
    }
}
