import Foundation

/// A recent DNS query as the filter recorded it. Shown on request only and never stored by the app.
struct DNSQueryLogEntry: Sendable, Equatable, Identifiable {
    enum Outcome: String, Sendable {
        case blocked, allowed, cached, rewritten, other

        var title: String {
            switch self {
            case .blocked: "Blocked"
            case .allowed: "Allowed"
            case .cached: "Cached"
            case .rewritten: "Rewritten"
            case .other: "Other"
            }
        }
    }

    var id: String
    var date: Date?
    var domain: String
    var client: String
    var type: String?
    var outcome: Outcome
    var detail: String?
}

/// Why a domain is (or isn't) filtered, from Pi-hole's `/search` or AdGuard Home's `/filtering/check_host`.
struct DNSDomainCheck: Sendable, Equatable {
    enum Verdict: Sendable, Equatable {
        case blocked, allowed, notListed, rewritten

        var title: String {
            switch self {
            case .blocked: "Blocked"
            case .allowed: "Explicitly allowed"
            case .notListed: "Not on any list"
            case .rewritten: "Rewritten"
            }
        }
    }

    var domain: String
    var verdict: Verdict
    var reasons: [String]
}

struct DNSDiagnosticMessage: Sendable, Equatable, Identifiable {
    var id: String
    var date: Date?
    var text: String
}

enum DNSMaintenance: String, Sendable, CaseIterable, Identifiable {
    case updateGravity, restartDNS, refreshFilters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updateGravity: "Update Blocklists"
        case .restartDNS: "Restart DNS Resolver"
        case .refreshFilters: "Refresh Filter Lists"
        }
    }

    var systemImage: String {
        switch self {
        case .updateGravity, .refreshFilters: "arrow.triangle.2.circlepath"
        case .restartDNS: "arrow.clockwise.circle"
        }
    }

    var consequence: String {
        switch self {
        case .updateGravity: "Pi-hole downloads every blocklist again and rebuilds its database (pihole -g). Filtering keeps working, but it can take a few minutes and uses bandwidth on the server."
        case .restartDNS: "pihole-FTL restarts. DNS stops answering for a few seconds, so every device using this Pi-hole briefly can't resolve names."
        case .refreshFilters: "AdGuard Home checks every enabled blocklist for updates and reloads the ones that changed. Filtering keeps working."
        }
    }

    var isDisruptive: Bool { self == .restartDNS }
}

struct DNSDiagnosticsCapabilities: Sendable, Equatable {
    var queryLog: Bool
    var domainCheck: Bool
    var messages: Bool
    var allowDomain: Bool
    var maintenance: [DNSMaintenance]
}

/// Read-only diagnostics and narrowly scoped maintenance for DNS filters whose APIs document them.
protocol DNSDiagnosticsService: DNSFilterService {
    var diagnostics: DNSDiagnosticsCapabilities { get }
    func recentQueries(limit: Int) async throws -> [DNSQueryLogEntry]
    func check(domain: String) async throws -> DNSDomainCheck
    func messages() async throws -> [DNSDiagnosticMessage]
    func perform(_ maintenance: DNSMaintenance) async throws -> String?
    /// Adds one exact domain to the allowlist; nothing else on the list changes.
    func allow(domain: String) async throws
}

enum DNSDomainInput {
    /// Lowercased host name without scheme, path or port; nil when it can't be a DNS name.
    static func normalized(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: value), let host = url.host(), url.scheme != nil { value = host }
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.count <= 253, value.contains("."),
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }),
              !value.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.count > 63 }) else { return nil }
        return value
    }
}

extension PiholeClient: DNSDiagnosticsService {
    var diagnostics: DNSDiagnosticsCapabilities {
        DNSDiagnosticsCapabilities(queryLog: true, domainCheck: true, messages: true, allowDomain: true, maintenance: [.updateGravity, .restartDNS])
    }

    struct QueryPage: Decodable {
        struct Query: Decodable {
            struct Client: Decodable { var ip: String?; var name: String? }
            struct Reply: Decodable { var type: String? }
            var id: Int?
            var time: Double?
            var type: String?
            var domain: String
            var status: String?
            var client: Client?
            var reply: Reply?
            var upstream: String?
        }
        var queries: [Query]
    }

    struct SearchResult: Decodable {
        struct Search: Decodable {
            struct Domain: Decodable { var domain: String; var type: String; var kind: String; var enabled: Bool? }
            struct Gravity: Decodable { var domain: String; var address: String?; var type: String? }
            var domains: [Domain]?
            var gravity: [Gravity]?
        }
        var search: Search
    }

    struct Messages: Decodable {
        struct Message: Decodable { var id: Int; var timestamp: Double?; var type: String?; var plain: String? }
        var messages: [Message]
    }

    static func outcome(_ status: String?) -> DNSQueryLogEntry.Outcome {
        switch status ?? "" {
        case "GRAVITY", "REGEX", "DENYLIST", "EXTERNAL_BLOCKED_IP", "EXTERNAL_BLOCKED_NULL", "EXTERNAL_BLOCKED_NXRA", "EXTERNAL_BLOCKED_EDE15",
             "GRAVITY_CNAME", "REGEX_CNAME", "DENYLIST_CNAME", "SPECIAL_DOMAIN": .blocked
        case "CACHE", "CACHE_STALE": .cached
        case "FORWARDED", "RETRIED", "RETRIED_DNSSEC", "IN_PROGRESS": .allowed
        default: .other
        }
    }

    static func check(domain: String, result: SearchResult) -> DNSDomainCheck {
        let enabled = (result.search.domains ?? []).filter { $0.enabled != false }
        let gravity = result.search.gravity ?? []
        var reasons = enabled.map { "\($0.type == "allow" ? "Allowlist" : "Denylist") (\($0.kind)): \($0.domain)" }
        reasons += gravity.map { "\($0.type == "allow" ? "Allow list" : "Blocklist"): \($0.address ?? "unknown list")" }
        // Allow entries win over deny entries and gravity in Pi-hole's own resolution order.
        let verdict: DNSDomainCheck.Verdict = enabled.contains { $0.type == "allow" } || gravity.contains { $0.type == "allow" } ? .allowed
            : (enabled.contains { $0.type == "deny" } || gravity.contains { $0.type == "block" } ? .blocked : .notListed)
        return DNSDomainCheck(domain: domain, verdict: verdict, reasons: reasons)
    }

    private func sessioned(_ request: RESTRequest, headers: [String: String]) -> RESTRequest {
        var request = request
        request.headers.merge(headers) { $1 }
        return request
    }

    func recentQueries(limit: Int) async throws -> [DNSQueryLogEntry] {
        try await withSession { headers in
            let page = try await rest.json(sessioned(.get("queries", query: [URLQueryItem(name: "length", value: String(limit))]), headers: headers), as: QueryPage.self)
            return page.queries.enumerated().map { index, query in
                DNSQueryLogEntry(id: query.id.map(String.init) ?? "q\(index)", date: query.time.map { Date(timeIntervalSince1970: $0) }, domain: query.domain,
                                 client: query.client?.name?.nilIfEmpty ?? query.client?.ip ?? "Unknown", type: query.type,
                                 outcome: Self.outcome(query.status), detail: query.status?.replacingOccurrences(of: "_", with: " ").lowercased())
            }
        }
    }

    func check(domain: String) async throws -> DNSDomainCheck {
        try await withSession { headers in
            let path = "search/" + (domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? domain)
            let result = try await rest.json(sessioned(.get(path, query: [URLQueryItem(name: "partial", value: "false"), URLQueryItem(name: "N", value: "20")]), headers: headers), as: SearchResult.self)
            return Self.check(domain: domain, result: result)
        }
    }

    func messages() async throws -> [DNSDiagnosticMessage] {
        try await withSession { headers in
            try await rest.json(sessioned(.get("info/messages"), headers: headers), as: Messages.self).messages.map { message in
                DNSDiagnosticMessage(id: String(message.id), date: message.timestamp.map { Date(timeIntervalSince1970: $0) },
                                     text: message.plain?.nilIfEmpty ?? message.type ?? "Message \(message.id)")
            }
        }
    }

    func perform(_ maintenance: DNSMaintenance) async throws -> String? {
        try await withSession { headers in
            switch maintenance {
            case .updateGravity:
                // The endpoint streams `pihole -g` output; its last line says how it went. The update carries on server-side if the stream stalls.
                do {
                    let data = try await rest.data(sessioned(.post("action/gravity"), headers: headers))
                    return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
                } catch NetworkError.timedOut {
                    return "Still running on the server; check back in a few minutes."
                }
            case .restartDNS:
                _ = try await rest.data(sessioned(.post("action/restartdns"), headers: headers))
                return nil
            case .refreshFilters:
                throw NetworkError.unsupportedByServer("Pi-hole updates blocklists with Update Blocklists.")
            }
        }
    }

    func allow(domain: String) async throws {
        struct Body: Encodable {
            var domain: String
            var comment: String
            var enabled = true
        }
        try await withSession { headers in
            _ = try await rest.data(sessioned(try .post("domains/allow/exact", json: Body(domain: domain, comment: "Allowed from Enve Homelab")), headers: headers))
        }
    }
}

extension AdGuardHomeClient: DNSDiagnosticsService {
    var diagnostics: DNSDiagnosticsCapabilities {
        // Allowing a domain would mean rewriting the whole user-rules list (`/filtering/set_rules`), so it isn't offered.
        DNSDiagnosticsCapabilities(queryLog: true, domainCheck: true, messages: false, allowDomain: false, maintenance: [.refreshFilters])
    }

    struct QueryLog: Decodable {
        struct Item: Decodable {
            struct Question: Decodable { var name: String?; var unicode_name: String?; var type: String? }
            struct ClientInfo: Decodable { var name: String? }
            var time: String?
            var client: String?
            var client_info: ClientInfo?
            var question: Question?
            var reason: String?
            var cached: Bool?
            var status: String?
        }
        var data: [Item]
    }

    struct CheckHost: Decodable {
        struct Rule: Decodable { var text: String?; var filter_list_id: Int64? }
        var reason: String
        var rules: [Rule]?
        var rule: String?
        var service_name: String?
        var cname: String?
        var ip_addrs: [String]?
    }

    static func outcome(reason: String?, cached: Bool?) -> DNSQueryLogEntry.Outcome {
        switch reason ?? "" {
        case let reason where reason.hasPrefix("Filtered"): .blocked
        case "Rewrite", "RewriteEtcHosts", "RewriteRule": .rewritten
        default: cached == true ? .cached : .allowed
        }
    }

    static func check(domain: String, result: CheckHost) -> DNSDomainCheck {
        let verdict: DNSDomainCheck.Verdict = switch result.reason {
        case let reason where reason.hasPrefix("Filtered"): .blocked
        case "NotFilteredWhiteList": .allowed
        case "Rewrite", "RewriteEtcHosts", "RewriteRule": .rewritten
        default: .notListed
        }
        var reasons = (result.rules ?? []).compactMap { rule in rule.text?.nilIfEmpty.map { "Rule \($0)" + (rule.filter_list_id.map { $0 == 0 ? " (custom rules)" : " (list \($0))" } ?? "") } }
        if reasons.isEmpty, let rule = result.rule?.nilIfEmpty { reasons.append("Rule \(rule)") }
        if let service = result.service_name?.nilIfEmpty { reasons.append("Blocked service: \(service)") }
        if let cname = result.cname?.nilIfEmpty { reasons.append("Rewritten to \(cname)") }
        if let addresses = result.ip_addrs, !addresses.isEmpty { reasons.append("Answers \(addresses.joined(separator: ", "))") }
        if result.reason == "FilteredSafeBrowsing" { reasons.append("Safe Browsing") }
        if result.reason == "FilteredParental" { reasons.append("Parental control") }
        return DNSDomainCheck(domain: domain, verdict: verdict, reasons: reasons)
    }

    func recentQueries(limit: Int) async throws -> [DNSQueryLogEntry] {
        let log = try await rest.json(.get("querylog", query: [URLQueryItem(name: "limit", value: String(limit))]), as: QueryLog.self)
        return log.data.enumerated().map { index, item in
            DNSQueryLogEntry(id: "\(item.time ?? "")-\(index)", date: APIDate.parse(item.time), domain: item.question?.unicode_name?.nilIfEmpty ?? item.question?.name ?? "?",
                             client: item.client_info?.name?.nilIfEmpty ?? item.client ?? "Unknown", type: item.question?.type,
                             outcome: Self.outcome(reason: item.reason, cached: item.cached), detail: item.reason)
        }
    }

    func check(domain: String) async throws -> DNSDomainCheck {
        Self.check(domain: domain, result: try await rest.json(.get("filtering/check_host", query: [URLQueryItem(name: "name", value: domain)]), as: CheckHost.self))
    }

    func messages() async throws -> [DNSDiagnosticMessage] { [] }

    func perform(_ maintenance: DNSMaintenance) async throws -> String? {
        guard maintenance == .refreshFilters else { throw NetworkError.unsupportedByServer("AdGuard Home refreshes filter lists with Refresh Filter Lists.") }
        struct Body: Encodable { var whitelist = false }
        struct Response: Decodable { var updated: Int? }
        let response = try await rest.json(try .post("filtering/refresh", json: Body()), as: Response.self)
        return response.updated.map { "\($0) list\($0 == 1 ? "" : "s") updated." }
    }

    func allow(domain: String) async throws {
        throw NetworkError.unsupportedByServer("AdGuard Home can only allow a domain by rewriting all custom rules, which this app doesn't do.")
    }
}
