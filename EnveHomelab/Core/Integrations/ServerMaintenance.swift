import Foundation

/// Update and backup status that several library servers document, shown as one "Maintenance" section.
struct ServerMaintenance: Sendable, Equatable {
    enum Update: Sendable, Equatable {
        /// The server wasn't asked: the key isn't an admin, or the release predates the endpoint.
        case unknown
        case upToDate
        case available(String)
    }

    struct Backup: Sendable, Equatable {
        var name: String
        var date: Date?
        var size: Int64?
    }

    var update: Update = .unknown
    /// nil when the server doesn't list backups (or not to this key).
    var backups: [Backup]?

    static let staleAfter: TimeInterval = 14 * 86_400

    var latestBackup: Date? { backups?.compactMap(\.date).max() }

    func section(backupsNote: String? = nil) -> DashboardSection {
        var rows: [DashboardRow] = []
        switch update {
        case .available(let version): rows.append(DashboardRow(id: "update", title: "Version \(version) is available", subtitle: "Install it on the server; the app doesn't start updates.", health: .warning))
        case .upToDate: rows.append(DashboardRow(id: "update", title: "Up to date", health: .ok))
        case .unknown: break
        }
        if let backups {
            let latest = latestBackup
            let stale = backups.isEmpty || latest.map { Date.now.timeIntervalSince($0) > Self.staleAfter } == true
            rows.append(DashboardRow(id: "backups", title: latest.map { "Last backup \(Format.relative($0))" } ?? (backups.isEmpty ? "No backups yet" : "\(backups.count) backup\(backups.count == 1 ? "" : "s")"),
                                     subtitle: backupsNote, health: stale ? .warning : .ok))
            rows += backups.prefix(3).enumerated().map { index, backup in
                DashboardRow(id: "backup\(index)", title: backup.name, detail: [backup.size.map(Format.bytes), backup.date.map(Format.relative)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            }
        }
        return DashboardSection(id: "maintenance", title: "Maintenance", systemImage: "wrench.and.screwdriver", emptyText: "Update and backup status aren't available with this key.", rows: rows)
    }
}

enum SemanticVersion {
    /// Compares dotted numeric versions ("v2.1.0", "0.8.7.3"); non-numeric suffixes are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
