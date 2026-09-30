import Foundation

struct DNSFilterOverview: Sendable, Equatable {
    var version: String?
    var blockingEnabled: Bool
    /// Seconds until the current pause ends, when the server reports one.
    var pauseRemaining: TimeInterval?
    var totalQueries: Int
    var blockedQueries: Int
    var cachedQueries: Int?
    var activeClients: Int?
    var blocklistDomains: Int?
    var averageResponseMilliseconds: Double?

    var blockedFraction: Double { totalQueries > 0 ? Double(blockedQueries) / Double(totalQueries) : 0 }
}

enum DNSPauseDuration: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case untilResumed = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .untilResumed: "Until turned back on"
        }
    }

    var seconds: TimeInterval? { self == .untilResumed ? nil : TimeInterval(rawValue) }
}

protocol DNSFilterService: IntegrationService {
    var kind: IntegrationKind { get }
    func overview() async throws -> DNSFilterOverview
    func setBlocking(_ enabled: Bool, for duration: TimeInterval?) async throws
}

extension DNSFilterService {
    func summary() async throws -> IntegrationSummary {
        let overview = try await overview()
        return IntegrationSummary(
            product: kind.displayName,
            version: overview.version,
            health: overview.blockingEnabled ? .ok : .warning,
            headline: overview.blockingEnabled ? "Blocking \(Format.percent(overview.blockedFraction)) of queries" : "Blocking paused",
            detail: "\(overview.totalQueries.formatted()) queries today"
        )
    }
}

/// Pi-hole v6 REST API. Sessions are limited on the server, so each call batch opens one and releases it.
struct PiholeClient: DNSFilterService {
    let kind = IntegrationKind.pihole
    let rest: RESTClient
    private let password: String

    init(url: URL, password: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint)
        self.password = password
    }

    struct Session: Decodable {
        struct Info: Decodable {
            var valid: Bool
            var sid: String?
            var message: String?
        }
        var session: Info
    }

    struct Summary: Decodable {
        struct Queries: Decodable {
            var total: Int
            var blocked: Int
            var cached: Int?
        }
        struct Clients: Decodable { var active: Int? }
        struct Gravity: Decodable { var domains_being_blocked: Int? }
        var queries: Queries
        var clients: Clients?
        var gravity: Gravity?
    }

    struct Blocking: Decodable {
        var blocking: String
        var timer: Double?
    }

    struct Version: Decodable {
        struct Component: Decodable {
            struct Local: Decodable { var version: String? }
            var local: Local?
        }
        struct Versions: Decodable { var core: Component? }
        var version: Versions
    }

    func withSession<Result>(_ body: ([String: String]) async throws -> Result) async throws -> Result {
        let (data, response) = try await rest.raw(try .post("auth", json: ["password": password]))
        if response.statusCode == 401 { throw NetworkError.unauthorized }
        try RESTClient.validate(response, data: data)
        let session = try RESTClient.decode(Session.self, from: data).session
        guard session.valid else { throw NetworkError.unauthorized }
        guard let sid = session.sid else { return try await body([:]) }
        let headers = ["X-FTL-SID": sid]
        do {
            let result = try await body(headers)
            _ = try? await rest.raw(RESTRequest(method: "DELETE", path: "auth", headers: headers))
            return result
        } catch {
            _ = try? await rest.raw(RESTRequest(method: "DELETE", path: "auth", headers: headers))
            throw error
        }
    }

    func overview() async throws -> DNSFilterOverview {
        try await withSession { headers in
            var summaryRequest = RESTRequest.get("stats/summary")
            summaryRequest.headers = headers
            var blockingRequest = RESTRequest.get("dns/blocking")
            blockingRequest.headers = headers
            var versionRequest = RESTRequest.get("info/version")
            versionRequest.headers = headers
            let summary = try await rest.json(summaryRequest, as: Summary.self)
            let blocking = try await rest.json(blockingRequest, as: Blocking.self)
            let version = try? await rest.json(versionRequest, as: Version.self)
            return DNSFilterOverview(
                version: version?.version.core?.local?.version,
                blockingEnabled: blocking.blocking == "enabled",
                pauseRemaining: blocking.timer,
                totalQueries: summary.queries.total,
                blockedQueries: summary.queries.blocked,
                cachedQueries: summary.queries.cached,
                activeClients: summary.clients?.active,
                blocklistDomains: summary.gravity?.domains_being_blocked
            )
        }
    }

    func setBlocking(_ enabled: Bool, for duration: TimeInterval?) async throws {
        struct Body: Encodable {
            var blocking: Bool
            var timer: Double?

            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(blocking, forKey: .blocking)
                try c.encode(timer, forKey: .timer)
            }

            private enum CodingKeys: String, CodingKey { case blocking, timer }
        }
        try await withSession { headers in
            var request = try RESTRequest.post("dns/blocking", json: Body(blocking: enabled, timer: enabled ? nil : duration))
            request.headers = headers
            _ = try await rest.data(request)
        }
    }
}

/// AdGuard Home `/control` API with optional HTTP basic auth.
struct AdGuardHomeClient: DNSFilterService {
    let kind = IntegrationKind.adguard
    let rest: RESTClient

    init(url: URL, username: String?, password: String?, pinnedFingerprint: String?) {
        var headers: [String: String] = [:]
        if let username = username?.nilIfEmpty {
            headers["Authorization"] = "Basic " + Data("\(username):\(password ?? "")".utf8).base64EncodedString()
        }
        rest = RESTClient(baseURL: url.appending(path: "control"), pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    struct Status: Decodable {
        var version: String?
        var protection_enabled: Bool
        var protection_disabled_duration: Int64?
        var running: Bool?
    }

    struct Stats: Decodable {
        var num_dns_queries: Int
        var num_blocked_filtering: Int
        var num_replaced_safebrowsing: Int?
        var num_replaced_parental: Int?
        var avg_processing_time: Double?
    }

    func overview() async throws -> DNSFilterOverview {
        async let status = rest.json(.get("status"), as: Status.self)
        async let stats = rest.json(.get("stats"), as: Stats.self)
        let current = try await status
        let totals = try await stats
        let blocked = totals.num_blocked_filtering + (totals.num_replaced_safebrowsing ?? 0) + (totals.num_replaced_parental ?? 0)
        return DNSFilterOverview(
            version: current.version,
            blockingEnabled: current.protection_enabled,
            pauseRemaining: current.protection_disabled_duration.flatMap { $0 > 0 ? TimeInterval($0) / 1000 : nil },
            totalQueries: totals.num_dns_queries,
            blockedQueries: blocked,
            averageResponseMilliseconds: totals.avg_processing_time.map { $0 * 1000 }
        )
    }

    func setBlocking(_ enabled: Bool, for duration: TimeInterval?) async throws {
        struct Body: Encodable {
            var enabled: Bool
            var duration: Int64?
        }
        let milliseconds = enabled ? nil : duration.map { Int64($0 * 1000) }
        _ = try await rest.data(try .post("protection", json: Body(enabled: enabled, duration: milliseconds)))
    }
}
