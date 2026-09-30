import Foundation

enum TransferState: String, Sendable, Hashable {
    case downloading, seeding, paused, queued, checking, completed, stalled, importing, failed, unknown

    var displayName: String {
        switch self {
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .paused: "Paused"
        case .queued: "Queued"
        case .checking: "Checking"
        case .completed: "Completed"
        case .stalled: "Stalled"
        case .importing: "Importing"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }

    var health: Health {
        switch self {
        case .downloading, .seeding, .completed, .importing: .ok
        case .paused, .queued, .checking, .unknown: .unknown
        case .stalled: .warning
        case .failed: .critical
        }
    }

    var systemImage: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .seeding: "arrow.up.circle.fill"
        case .paused: "pause.circle.fill"
        case .queued: "clock.fill"
        case .checking: "checkmark.arrow.trianglehead.counterclockwise"
        case .completed: "checkmark.circle.fill"
        case .stalled: "exclamationmark.circle.fill"
        case .importing: "square.and.arrow.down.fill"
        case .failed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var isPausable: Bool { [.downloading, .seeding, .queued, .stalled, .checking].contains(self) }
}

/// A download in any client or *arr queue, normalised for lists and the activity screen.
struct TransferItem: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var subtitle: String?
    var state: TransferState
    var progress: Double
    var size: Int64?
    var remaining: Int64?
    var downloadRate: Int64?
    var uploadRate: Int64?
    var eta: TimeInterval?
    var category: String?
    var message: String?
}

enum Durations {
    /// Parses .NET `TimeSpan` strings ("01:02:03", "2.01:02:03") and SABnzbd "H:MM:SS".
    static func timeSpan(_ text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        var days = 0.0
        var clock = Substring(text)
        if let dot = clock.firstIndex(of: "."), let colon = clock.firstIndex(of: ":"), dot < colon {
            days = Double(clock[..<dot]) ?? 0
            clock = clock[clock.index(after: dot)...]
        }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }
}
