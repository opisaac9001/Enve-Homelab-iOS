import Foundation

struct TailscaleDevice: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var hostname: String?
    var os: String?
    var addresses: [String]?
    var clientVersion: String?
    var updateAvailable: Bool?
    var connectedToControl: Bool?
    var lastSeen: String?
    var expires: String?
    var keyExpiryDisabled: Bool?
    var authorized: Bool?
    var user: String?
    var tags: [String]?

    var displayName: String {
        hostname?.nilIfEmpty ?? name?.split(separator: ".").first.map(String.init) ?? id
    }

    var expiryDate: Date? {
        guard keyExpiryDisabled != true else { return nil }
        return APIDate.parse(expires)
    }

    func keyExpiresSoon(now: Date = .now) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSince(now) < 14 * 86_400
    }

    var health: Health {
        if authorized == false { return .warning }
        if keyExpiresSoon() { return .warning }
        return connectedToControl == true ? .ok : .unknown
    }
}

protocol TailscaleService: IntegrationService {
    func devices() async throws -> [TailscaleDevice]
}

extension TailscaleService {
    func summary() async throws -> IntegrationSummary {
        let devices = try await devices()
        let online = devices.filter { $0.connectedToControl == true }.count
        let expiring = devices.filter { $0.keyExpiresSoon() }.count
        return IntegrationSummary(
            product: "Tailscale",
            version: nil,
            health: expiring > 0 ? .warning : .ok,
            headline: "\(online) of \(devices.count) devices connected",
            detail: expiring > 0 ? "\(expiring) key\(expiring == 1 ? "" : "s") expiring within 14 days" : nil
        )
    }
}

/// Tailscale API v2 (`/tailnet/-/devices`, the token's own tailnet). Read-only.
struct TailscaleClient: TailscaleService {
    private let rest: RESTClient

    init(token: String, baseURL: URL = URL(string: "https://api.tailscale.com")!) {
        rest = RESTClient(baseURL: baseURL.appending(path: "api/v2"), pinnedFingerprint: nil, headers: ["Authorization": "Bearer \(token)"])
    }

    func devices() async throws -> [TailscaleDevice] {
        struct Response: Decodable { var devices: [TailscaleDevice] }
        return try await rest.json(.get("tailnet/-/devices"), as: Response.self).devices
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

struct CloudflareTunnel: Decodable, Sendable, Hashable, Identifiable {
    struct Connection: Decodable, Sendable, Hashable {
        var colo_name: String?
        var is_pending_reconnect: Bool?
        var opened_at: String?
    }

    var id: String
    var name: String
    var status: String?
    var connections: [Connection]?
    var conns_active_at: String?
    var created_at: String?

    var health: Health {
        switch status {
        case "healthy": .ok
        case "degraded": .warning
        case "down": .critical
        default: .unknown
        }
    }
}

struct CloudflareZone: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var status: String?
    var paused: Bool?
}

struct CloudflareSnapshot: Sendable {
    var tokenStatus: String
    var tunnels: [CloudflareTunnel]
    /// `nil` when the token isn't permitted to read zones.
    var zones: [CloudflareZone]?
}

protocol CloudflareService: IntegrationService {
    func snapshot() async throws -> CloudflareSnapshot
}

extension CloudflareService {
    func summary() async throws -> IntegrationSummary {
        let snapshot = try await snapshot()
        let unhealthy = snapshot.tunnels.filter { $0.health == .warning || $0.health == .critical }.count
        return IntegrationSummary(
            product: "Cloudflare",
            version: nil,
            health: unhealthy > 0 ? .warning : .ok,
            headline: "\(snapshot.tunnels.filter { $0.health == .ok }.count) of \(snapshot.tunnels.count) tunnels healthy",
            detail: snapshot.zones.map { "\($0.count) zone\($0.count == 1 ? "" : "s")" }
        )
    }
}

/// Cloudflare API v4 with a scoped API token. Read-only.
struct CloudflareClient: CloudflareService {
    private let rest: RESTClient
    private let accountID: String

    init(accountID: String, token: String, baseURL: URL = URL(string: "https://api.cloudflare.com")!) {
        rest = RESTClient(baseURL: baseURL.appending(path: "client/v4"), pinnedFingerprint: nil, headers: ["Authorization": "Bearer \(token)"])
        self.accountID = accountID.trimmingCharacters(in: .whitespaces)
    }

    struct Envelope<Result: Decodable>: Decodable {
        struct Message: Decodable { var code: Int?; var message: String }
        var success: Bool
        var errors: [Message]?
        var result: Result?
    }

    private func get<Result: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: Result.Type) async throws -> Result {
        let (data, response) = try await rest.raw(.get(path, query: query))
        let envelope = try? RESTClient.decode(Envelope<Result>.self, from: data)
        if let envelope, !envelope.success {
            let message = envelope.errors?.map(\.message).joined(separator: " ") ?? "Cloudflare rejected the request."
            throw response.statusCode == 403 ? NetworkError.forbidden(message) : (response.statusCode == 401 ? NetworkError.unauthorized : NetworkError.graphQL([message]))
        }
        try RESTClient.validate(response, data: data)
        guard let result = try RESTClient.decode(Envelope<Result>.self, from: data).result else {
            throw NetworkError.unexpectedResponse("Cloudflare returned no result.")
        }
        return result
    }

    func snapshot() async throws -> CloudflareSnapshot {
        struct Verify: Decodable { var status: String }
        // User-owned and account-owned tokens verify at different endpoints.
        let verify: Verify
        do {
            verify = try await get("user/tokens/verify", as: Verify.self)
        } catch NetworkError.unauthorized, NetworkError.graphQL {
            verify = try await get("accounts/\(accountID)/tokens/verify", as: Verify.self)
        }
        let tunnels = try await get("accounts/\(accountID)/cfd_tunnel", query: [URLQueryItem(name: "is_deleted", value: "false")], as: [CloudflareTunnel].self)
        var zones: [CloudflareZone]?
        do {
            zones = try await get("zones", query: [URLQueryItem(name: "account.id", value: accountID)], as: [CloudflareZone].self)
        } catch NetworkError.forbidden {
            zones = nil
        }
        return CloudflareSnapshot(tokenStatus: verify.status, tunnels: tunnels.sorted { $0.name < $1.name }, zones: zones)
    }
}
