import Foundation

/// `envehomelab://alerts`, `envehomelab://upcoming`, `envehomelab://statistics`, `envehomelab://integration/<id>`, `envehomelab://check/<id>`; used by the widgets.
enum DeepLink: Hashable, Identifiable {
    case alerts
    case upcoming
    case statistics
    case integration(UUID)
    case serviceCheck(UUID)

    static let scheme = "envehomelab"

    var id: String { url.absoluteString }

    var url: URL {
        switch self {
        case .alerts: URL(string: "\(Self.scheme)://alerts")!
        case .upcoming: URL(string: "\(Self.scheme)://upcoming")!
        case .statistics: URL(string: "\(Self.scheme)://statistics")!
        case .integration(let id): URL(string: "\(Self.scheme)://integration/\(id.uuidString)")!
        case .serviceCheck(let id): URL(string: "\(Self.scheme)://check/\(id.uuidString)")!
        }
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let identifier = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
        switch (url.host(), identifier) {
        case ("alerts", _): self = .alerts
        case ("upcoming", _): self = .upcoming
        case ("statistics", _): self = .statistics
        case ("integration", let id?): self = .integration(id)
        case ("check", let id?): self = .serviceCheck(id)
        default: return nil
        }
    }
}
