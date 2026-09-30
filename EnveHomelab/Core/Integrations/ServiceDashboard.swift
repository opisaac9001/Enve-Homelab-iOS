import Foundation

/// A provider's current state, mapped from its typed API responses into what the shared dashboard screen renders.
struct DashboardSnapshot: Sendable {
    var version: String?
    var health: Health
    var headline: String
    var detail: String?
    var notice: String?
    var metrics: [DashboardMetric] = []
    var actions: [DashboardAction] = []
    var sections: [DashboardSection] = []
}

struct DashboardMetric: Sendable, Identifiable, Equatable {
    var title: String
    var value: String
    var systemImage: String
    var health: Health?

    var id: String { title }
}

struct DashboardSection: Sendable, Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var trailing: String?
    var emptyText: String
    var rows: [DashboardRow]
    /// Rows beyond this are summarised as "and N more" so long lists stay light.
    var limit = 50
}

struct DashboardRow: Sendable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var detail: String?
    var health: Health?
    var badge: String?
    var progress: Double?
    var message: String?
    var actions: [DashboardAction] = []
}

struct DashboardAction: Sendable, Identifiable {
    enum Confirmation: Sendable, Equatable {
        /// Low-impact and reversible, e.g. a library scan; runs immediately.
        case none
        case confirm
        case destructive
        /// Irreversible or high-impact; the user types the target name.
        case typed
    }

    var id: String
    var title: String
    var systemImage: String
    var targetKind: String
    var targetName: String
    var consequence: String
    var confirmation: Confirmation = .confirm
    let perform: @Sendable () async throws -> Void
}

protocol DashboardService: IntegrationService {
    var kind: IntegrationKind { get }
    func dashboard() async throws -> DashboardSnapshot
}

extension DashboardService {
    func summary() async throws -> IntegrationSummary {
        let snapshot = try await dashboard()
        return IntegrationSummary(product: kind.displayName, version: snapshot.version, health: snapshot.health, headline: snapshot.headline, detail: snapshot.detail)
    }
}

extension DashboardSnapshot {
    func action(_ id: String) -> DashboardAction? {
        (actions + sections.flatMap { $0.rows.flatMap(\.actions) }).first { $0.id == id }
    }
}

enum DockerAction: String, Sendable {
    case start, stop, restart
}

/// Start, stop and restart for anything that behaves like a container or compose stack.
enum ContainerLifecycle {
    static func health(state: String, health: String?) -> Health {
        if health == "unhealthy" || state == "dead" { return .critical }
        if state == "restarting" { return .warning }
        return state == "running" ? .ok : .unknown
    }

    static func actions(name: String, running: Bool, environmentName: String, targetKind: String = "Container", stopConsequence: String? = nil,
                        perform: @escaping @Sendable (DockerAction) async throws -> Void) -> [DashboardAction] {
        if running {
            [
                DashboardAction(id: "restart", title: "Restart", systemImage: "arrow.clockwise", targetKind: targetKind, targetName: name,
                                consequence: "\(name) on \(environmentName) stops and starts again; anything using it is briefly unavailable.") { try await perform(.restart) },
                DashboardAction(id: "stop", title: "Stop…", systemImage: "stop.fill", targetKind: targetKind, targetName: name,
                                consequence: stopConsequence ?? "\(name) on \(environmentName) stops and stays stopped until started again.", confirmation: .destructive) { try await perform(.stop) },
            ]
        } else {
            [DashboardAction(id: "start", title: "Start", systemImage: "play.fill", targetKind: targetKind, targetName: name,
                             consequence: "\(name) on \(environmentName) starts.", confirmation: .none) { try await perform(.start) }]
        }
    }

    /// Gives lifecycle actions IDs that are unique across rows.
    static func prefixed(_ actions: [DashboardAction], _ prefix: String) -> [DashboardAction] {
        actions.map { var copy = $0; copy.id = "\(prefix):\($0.id)"; return copy }
    }
}
