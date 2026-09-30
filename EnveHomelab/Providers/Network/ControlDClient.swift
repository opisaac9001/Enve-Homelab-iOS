import Foundation

/// On failure Control D sends `body` as an empty array, so it's decoded only when `success` is true.
struct ControlDEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    struct APIError: Decodable, Sendable { var message: String?; var code: Int? }
    var success: Bool
    var body: Body?
    var error: APIError?

    enum CodingKeys: String, CodingKey { case success, body, error }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        error = try container.decodeIfPresent(APIError.self, forKey: .error)
        body = success ? try container.decodeIfPresent(Body.self, forKey: .body) : nil
    }
}

struct ControlDProfile: Decodable, Sendable {
    var PK: String
    var name: String
    var updated: Double?
}

struct ControlDDevice: Decodable, Sendable {
    struct ProfileRef: Decodable, Sendable { var PK: String; var name: String? }
    var PK: String
    var name: String
    var status: Int
    var desc: String?
    var profile: ProfileRef?

    var statusName: String {
        switch status {
        case 0: "Pending"
        case 1: "Active"
        case 2: "Filtering off"
        case 3: "Disabled"
        default: "Unknown"
        }
    }

    var health: Health {
        switch status {
        case 1: .ok
        case 2: .warning
        case 3: .critical
        default: .unknown
        }
    }
}

struct ControlDOverview: Sendable {
    var profiles: [ControlDProfile]
    var devices: [ControlDDevice]
}

protocol ControlDOperations: Sendable {
    func pause(profileID: String, until: Date) async throws
    func resume(profileID: String) async throws
}

/// Control D's documented API (`api.controld.com`, Bearer token). It has no query statistics, and a profile's pause state can't be read back.
struct ControlDClient: DashboardService, ControlDOperations {
    let kind = IntegrationKind.controld
    static let baseURL = URL(string: "https://api.controld.com")!
    static let pauseLength: TimeInterval = 3_600
    private let rest: RESTClient

    init(token: String, baseURL: URL = ControlDClient.baseURL) {
        rest = RESTClient(baseURL: baseURL, pinnedFingerprint: nil, headers: ["Authorization": "Bearer \(token)"])
    }

    private func body<Body: Decodable & Sendable>(_ request: RESTRequest, as type: Body.Type) async throws -> Body? {
        let (data, response) = try await rest.raw(request)
        let envelope = try? JSONDecoder().decode(ControlDEnvelope<Body>.self, from: data)
        if let envelope, !envelope.success {
            let message = envelope.error?.message ?? "Control D reported an error."
            switch response.statusCode {
            case 401: throw NetworkError.unauthorized
            case 403: throw NetworkError.forbidden(message)
            default: throw NetworkError.graphQL([message])
            }
        }
        try RESTClient.validate(response, data: data)
        return try RESTClient.decode(ControlDEnvelope<Body>.self, from: data).body
    }

    private struct Profiles: Decodable, Sendable { var profiles: [ControlDProfile] }
    private struct Devices: Decodable, Sendable { var devices: [ControlDDevice] }
    private struct Ignored: Decodable, Sendable {}

    func overview() async throws -> ControlDOverview {
        async let profiles = body(.get("profiles"), as: Profiles.self)
        async let devices = body(.get("devices"), as: Devices.self)
        return try await ControlDOverview(profiles: profiles?.profiles ?? [], devices: devices?.devices ?? [])
    }

    func dashboard() async throws -> DashboardSnapshot {
        ControlDDashboard.snapshot(try await overview(), operations: self)
    }

    func pause(profileID: String, until: Date) async throws {
        _ = try await body(RESTRequest(method: "PUT", path: "profiles/\(profileID)", body: .form(["disable_ttl": String(Int(until.timeIntervalSince1970))])), as: Ignored.self)
    }

    func resume(profileID: String) async throws {
        _ = try await body(RESTRequest(method: "PUT", path: "profiles/\(profileID)", body: .form(["disable_ttl": "0"])), as: Ignored.self)
    }
}

enum ControlDDashboard {
    static func snapshot(_ overview: ControlDOverview, operations: some ControlDOperations) -> DashboardSnapshot {
        let devices = overview.devices
        let problems = devices.filter { $0.status == 2 || $0.status == 3 }
        return DashboardSnapshot(
            version: nil,
            health: problems.isEmpty ? .ok : .warning,
            headline: "\(devices.filter { $0.status == 1 }.count) of \(devices.count) endpoints active",
            detail: "\(overview.profiles.count) profile\(overview.profiles.count == 1 ? "" : "s")",
            notice: "Control D's API doesn't report query statistics or whether a profile is paused. Pausing here lasts one hour; check the Control D dashboard for current state.",
            metrics: [
                DashboardMetric(title: "Endpoints", value: "\(devices.count)", systemImage: "iphone"),
                DashboardMetric(title: "Active", value: "\(devices.filter { $0.status == 1 }.count)", systemImage: "checkmark.shield"),
                DashboardMetric(title: "Filtering off or disabled", value: "\(problems.count)", systemImage: "exclamationmark.shield", health: problems.isEmpty ? .ok : .warning),
            ],
            sections: [
                DashboardSection(id: "profiles", title: "Profiles", systemImage: "slider.horizontal.3", trailing: "\(overview.profiles.count)", emptyText: "No profiles.",
                                 rows: overview.profiles.map { profile in
                                     let users = devices.filter { $0.profile?.PK == profile.PK }.map(\.name)
                                     return DashboardRow(id: profile.PK, title: profile.name,
                                                         subtitle: users.isEmpty ? "Not used by any endpoint" : "Used by " + users.joined(separator: ", "),
                                                         actions: [
                                                             DashboardAction(id: "pause:\(profile.PK)", title: "Pause for 1 Hour…", systemImage: "pause.circle", targetKind: "Profile", targetName: profile.name,
                                                                             consequence: "Every endpoint using \(profile.name)\(users.isEmpty ? "" : " (\(users.joined(separator: ", ")))") stops filtering for one hour. Ads, trackers and anything else the profile blocks will load.",
                                                                             confirmation: .destructive) {
                                                                 try await operations.pause(profileID: profile.PK, until: .now.addingTimeInterval(ControlDClient.pauseLength))
                                                             },
                                                             DashboardAction(id: "resume:\(profile.PK)", title: "Resume Filtering", systemImage: "play.circle", targetKind: "Profile", targetName: profile.name,
                                                                             consequence: "Control D cancels any pause on this profile.", confirmation: .none) {
                                                                 try await operations.resume(profileID: profile.PK)
                                                             },
                                                         ])
                                 }),
                DashboardSection(id: "devices", title: "Endpoints", systemImage: "iphone", trailing: "\(devices.count)", emptyText: "No endpoints are set up.",
                                 rows: devices.map { device in
                                     DashboardRow(id: device.PK, title: device.name, subtitle: [device.profile?.name.map { "Profile \($0)" }, device.desc?.nilIfEmpty].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                  health: device.health, badge: device.statusName)
                                 }),
            ]
        )
    }
}
