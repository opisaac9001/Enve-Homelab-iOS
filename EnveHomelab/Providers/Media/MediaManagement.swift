import Foundation

struct MediaServerHealth: Sendable, Hashable {
    var pendingRestart: Bool?
    var canRestart: Bool?
    var updateVersion: String?
    var operatingSystem: String?
}

/// A scheduled task (Jellyfin, Emby, Plex butler) or a running background activity (Plex).
struct MediaTask: Sendable, Hashable, Identifiable {
    enum State: String, Sendable { case idle, running, cancelling }
    enum Outcome: String, Sendable { case completed, failed, cancelled, aborted }

    var id: String
    var name: String
    var category: String?
    var detail: String?
    var state: State
    var progress: Double?
    var lastRun: Date?
    var lastOutcome: Outcome?
    var lastError: String?
    var cancellable = false
}

struct MediaDevice: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var app: String?
    var lastUser: String?
    var lastActive: Date?
}

struct MediaHistoryEntry: Sendable, Hashable, Identifiable {
    enum Severity: Sendable { case info, warning, error }

    var id: String
    var title: String
    var detail: String?
    var date: Date?
    var severity: Severity = .info
}

/// Management data read with admin rights. A section is nil when the key may not read it or the server lacks it, and is named in `unavailable`.
struct MediaManagement: Sendable {
    var health = MediaServerHealth()
    var tasks: [MediaTask]?
    var activities: [MediaTask]?
    var devices: [MediaDevice]?
    var users: [MediaUser]?
    var history: [MediaHistoryEntry]?
    /// Jellyfin plugins with their load state, or Emby plugins that have an update.
    var plugins: [MediaPlugin]?
    var unavailable: [String] = []
}

struct MediaPlugin: Sendable, Hashable, Identifiable {
    var name: String
    var version: String?
    var status: String?
    var availableUpdate: String?
    var id: String { name }

    /// Jellyfin's `PluginStatus`: anything but Active means the plugin isn't running as installed.
    var needsAttention: Bool { (status.map { $0 != "Active" } ?? false) || availableUpdate != nil }

    var statusTitle: String {
        if let availableUpdate { return "Update \(availableUpdate)" }
        switch status {
        case "Restart": return "Needs restart"
        case "Malfunctioned": return "Failed to load"
        case "NotSupported": return "Not supported"
        case "Superseded", "Superceded": return "Superseded"
        case "Disabled": return "Disabled"
        case "Deleted": return "Removed on restart"
        default: return "Active"
        }
    }
}

/// A server log file and its most recent lines, redacted before display and never stored.
struct MediaLogFile: Sendable, Hashable, Identifiable {
    var name: String
    var size: Int64?
    var modified: Date?
    var id: String { name }
}

protocol ServerLogSource: Sendable {
    func logFiles() async throws -> [MediaLogFile]
    func logLines(_ file: MediaLogFile, limit: Int) async throws -> [String]
}

enum PlexMaintenance: String, Sendable {
    case optimizeDatabase, cleanBundles, checkForUpdates
}

enum MediaAdminAction: Sendable, Hashable {
    case runTask(id: String)
    case stopTask(id: String)
    case cancelActivity(id: String)
    case restartServer
    case removeDevice(id: String)
    case message(sessionID: String, text: String)
    case setStream(sessionID: String, kind: MediaStreamInfo.Kind, index: Int)
    case refreshMetadata(libraryID: String)
    case analyze(libraryID: String)
    case emptyTrash(libraryID: String)
    case plex(PlexMaintenance)
}

extension MediaManagement {
    /// Loads one management section; a permission refusal or missing endpoint marks it unavailable instead of failing the screen.
    static func section<T: Sendable>(_ name: String, into unavailable: inout [String], _ load: () async throws -> T) async throws -> T? {
        do {
            return try await load()
        } catch NetworkError.unauthorized {
            unavailable.append(name)
        } catch NetworkError.forbidden {
            unavailable.append(name)
        } catch NetworkError.apiNotFound {
            unavailable.append(name)
        }
        return nil
    }
}
