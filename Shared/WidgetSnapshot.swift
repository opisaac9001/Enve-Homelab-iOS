import Foundation

/// The last-known status the app hands to its widgets through the shared app group.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        enum Level: Int, Codable, Sendable, Comparable {
            case ok, unknown, warning, critical

            static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        var id: String
        /// Deep-link route: `check` or `integration`.
        var kind: String
        var name: String
        var detail: String
        var level: Level
    }

    var updatedAt: Date
    var items: [Item]
    var unreadAlerts: Int

    static let appGroup = "group.com.isaaclamb.EnveHomelab"
    static let fileName = "widget-snapshot.json"

    var attentionCount: Int { items.filter { $0.level >= .warning }.count }

    /// Worst first, then by name, so small widgets show what matters.
    var ranked: [Item] {
        items.sorted { $0.level != $1.level ? $0.level > $1.level : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
