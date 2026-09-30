enum Health: Int, Comparable, Sendable, Codable {
    case ok
    case unknown
    case warning
    case critical

    static func < (lhs: Health, rhs: Health) -> Bool { lhs.rawValue < rhs.rawValue }
}
