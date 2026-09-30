import Foundation

/// Technitium answers errors with HTTP 200 and a `status` field.
struct TechnitiumEnvelope<Response: Decodable & Sendable>: Decodable, Sendable {
    var status: String
    var errorMessage: String?
    var response: Response?
}

struct TechnitiumStats: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        var totalQueries: Int
        var totalBlocked: Int
        var totalCached: Int?
        var totalClients: Int?
        var blockListZones: Int?
    }
    var stats: Stats
}

/// Only the fields the app needs; the full settings response also carries proxy credentials and TSIG keys.
struct TechnitiumSettings: Decodable, Sendable {
    var version: String?
    var enableBlocking: Bool
    var temporaryDisableBlockingTill: String?
}

/// Technitium DNS Server HTTP API (9.0+). The API token goes in the POST form, which every version accepts, and as a Bearer header for 15.0+.
struct TechnitiumClient: DNSFilterService {
    let kind = IntegrationKind.technitium
    private let rest: RESTClient
    private let token: String

    init(url: URL, token: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(token)"])
        self.token = token
    }

    private func call<Response: Decodable & Sendable>(_ path: String, _ fields: [String: String] = [:], as type: Response.Type) async throws -> Response? {
        let envelope = try await rest.json(.post("api/\(path)", form: fields.merging(["token": token]) { $1 }), as: TechnitiumEnvelope<Response>.self)
        switch envelope.status {
        case "ok": return envelope.response
        case "invalid-token": throw NetworkError.unauthorized
        case "2fa-required": throw NetworkError.forbidden("This account needs two-factor sign-in. Create an API token in Technitium instead of using a session.")
        default: throw NetworkError.graphQL([envelope.errorMessage ?? "Technitium reported an error."])
        }
    }

    private struct Ignored: Decodable, Sendable {}

    func overview() async throws -> DNSFilterOverview {
        async let settings = call("settings/get", as: TechnitiumSettings.self)
        async let stats = call("dashboard/stats/get", ["type": "LastDay", "utc": "true"], as: TechnitiumStats.self)
        guard let settings = try await settings, let stats = try await stats?.stats else {
            throw NetworkError.unexpectedResponse("Technitium returned no dashboard data.")
        }
        let resumesAt = settings.enableBlocking ? nil : APIDate.parse(settings.temporaryDisableBlockingTill)
        return DNSFilterOverview(
            version: settings.version,
            blockingEnabled: settings.enableBlocking,
            pauseRemaining: resumesAt.map { max($0.timeIntervalSinceNow, 0) },
            totalQueries: stats.totalQueries,
            blockedQueries: stats.totalBlocked,
            cachedQueries: stats.totalCached,
            activeClients: stats.totalClients,
            blocklistDomains: stats.blockListZones
        )
    }

    func setBlocking(_ enabled: Bool, for duration: TimeInterval?) async throws {
        if !enabled, let duration {
            _ = try await call("settings/temporaryDisableBlocking", ["minutes": String(Int((duration / 60).rounded(.up)))], as: Ignored.self)
        } else {
            // Passing only enableBlocking leaves every other setting untouched; turning it on also cancels a timed pause.
            _ = try await call("settings/set", ["enableBlocking": String(enabled)], as: Ignored.self)
        }
    }
}
