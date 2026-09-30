import Foundation

enum AlertSeverity: Int, Codable, Sendable, Comparable, CaseIterable, Identifiable {
    case info, warning, critical

    var id: Int { rawValue }

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    init?(_ health: Health) {
        switch health {
        case .warning: self = .warning
        case .critical: self = .critical
        case .ok, .unknown: return nil
        }
    }

    var title: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var health: Health {
        switch self {
        case .info: .unknown
        case .warning: .warning
        case .critical: .critical
        }
    }

    /// ntfy priorities 1–5.
    var ntfyPriority: Int {
        switch self {
        case .info: 3
        case .warning: 4
        case .critical: 5
        }
    }
}

enum AlertSourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case serviceCheck
    case integration
    case ntfy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serviceCheck: "Service checks"
        case .integration: "Integrations"
        case .ntfy: "ntfy topic"
        }
    }
}

struct AlertEvent: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var severity: AlertSeverity
    var sourceKind: AlertSourceKind
    var sourceID: String
    var sourceName: String
    var title: String
    var body: String
    var isRecovery = false
    var isRead = false

    func matches(_ query: String) -> Bool {
        query.isEmpty || [title, body, sourceName].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct NotificationRule: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var sourceKind: AlertSourceKind
    /// `nil` applies the rule to every source of that kind.
    var sourceID: String?
    var minimumSeverity: AlertSeverity = .warning
    var includeRecoveries = true
    var notifyOnDevice = true
    var forwardToNtfy = false
    var isEnabled = true

    func matches(_ event: AlertEvent) -> Bool {
        guard isEnabled, event.sourceKind == sourceKind else { return false }
        if let sourceID, sourceID != event.sourceID { return false }
        if event.isRecovery { return includeRecoveries }
        return event.severity >= minimumSeverity
    }
}

/// A health observation from any source; the alert center turns changes into events.
struct HealthObservation: Sendable, Equatable {
    var sourceKind: AlertSourceKind
    var sourceID: String
    var sourceName: String
    var health: Health
    var detail: String
}

enum AlertTransition {
    /// Emits an event when a source becomes warning/critical or worsens, and a recovery when it returns to OK.
    /// Unknown health (e.g. not yet checked) never produces events.
    static func event(previous: Health?, observation: HealthObservation, now: Date = .now) -> AlertEvent? {
        let current = observation.health
        if current == .unknown { return nil }
        if let severity = AlertSeverity(current) {
            if let previous, previous >= current, previous != .unknown { return nil }
            return AlertEvent(
                date: now,
                severity: severity,
                sourceKind: observation.sourceKind,
                sourceID: observation.sourceID,
                sourceName: observation.sourceName,
                title: "\(observation.sourceName): \(severity.title.lowercased())",
                body: observation.detail
            )
        }
        guard let previous, previous == .warning || previous == .critical else { return nil }
        return AlertEvent(
            date: now,
            severity: .info,
            sourceKind: observation.sourceKind,
            sourceID: observation.sourceID,
            sourceName: observation.sourceName,
            title: "\(observation.sourceName) recovered",
            body: observation.detail,
            isRecovery: true
        )
    }
}

/// A daily window when rules don't notify this device; alerts still reach the inbox and ntfy.
struct QuietHours: Codable, Sendable, Hashable {
    /// Minutes after midnight, local time.
    var startMinute = 22 * 60
    var endMinute = 7 * 60
    var allowCritical = true

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute { return false }
        // A window like 22:00–07:00 wraps past midnight.
        return startMinute < endMinute ? (minute >= startMinute && minute < endMinute) : (minute >= startMinute || minute < endMinute)
    }

    func silences(_ event: AlertEvent, at date: Date = .now) -> Bool {
        contains(date) && !(allowCritical && event.severity == .critical && !event.isRecovery)
    }
}

struct NtfyConfiguration: Codable, Sendable, Hashable {
    var serverURL: URL
    var topic: String
    var subscribe = true
    var pinnedCertificateSHA256: String?
    var lastMessageID: String?

    static func isValidTopic(_ topic: String) -> Bool {
        !topic.isEmpty && topic.count <= 64 && topic.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && topic.allSatisfy(\.isASCII)
    }
}
