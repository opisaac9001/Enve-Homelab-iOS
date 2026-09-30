import Foundation

struct ServiceCheck: Codable, Sendable, Hashable, Identifiable {
    enum AcceptedStatus: String, Codable, Sendable, CaseIterable, Identifiable {
        case successOrRedirect
        case successOnly
        case anyResponse

        var id: String { rawValue }

        var title: String {
            switch self {
            case .successOrRedirect: "2xx or 3xx"
            case .successOnly: "2xx only"
            case .anyResponse: "Any HTTP response"
            }
        }

        func accepts(_ status: Int) -> Bool {
            switch self {
            case .successOrRedirect: (200..<400).contains(status)
            case .successOnly: (200..<300).contains(status)
            case .anyResponse: (100..<600).contains(status)
            }
        }
    }

    var id = UUID()
    var name: String
    var url: URL
    var acceptedStatus: AcceptedStatus = .successOrRedirect
    var intervalSeconds: Int = 60
    var timeoutSeconds: Int = 10
    var serverID: UUID?
    var pinnedCertificateSHA256: String?
    var pinnedCertificateSubject: String?

    static let intervalChoices = [30, 60, 300, 900]
    static let slowResponseThreshold: Duration = .seconds(2)

    enum URLFailure: Error, Equatable, LocalizedError {
        case empty
        case unsupportedScheme
        case missingHost

        var errorDescription: String? {
            switch self {
            case .empty: "Enter a URL."
            case .unsupportedScheme: "Use an http or https URL."
            case .missingHost: "The URL needs a host name or IP address."
            }
        }
    }

    /// Unlike server endpoints, health checks keep their path and query.
    static func parseURL(_ input: String) -> Result<URL, URLFailure> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text) else { return .failure(.missingHost) }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        guard let url = components.url else { return .failure(.missingHost) }
        return .success(url)
    }
}

enum TrustSource: Equatable, Sendable, Codable {
    case system
    case pinned
    case reused(String)
    case none
}

struct ServiceCheckResult: Sendable, Equatable, Codable {
    enum Outcome: Equatable, Sendable, Codable {
        case responded(status: Int, accepted: Bool)
        case failed(NetworkError)
    }

    var checkedAt: Date
    var outcome: Outcome
    var responseTime: Duration?
    var certificate: CertificateSummary?
    var trust: TrustSource
    var finalURL: URL?

    static let expiryWarningDays = 14
    static let expiryCriticalDays = 3

    var isUp: Bool {
        if case .responded(_, true) = outcome { true } else { false }
    }

    func daysUntilExpiry(now: Date = .now) -> Int? {
        guard let notAfter = certificate?.notValidAfter else { return nil }
        return Int((notAfter.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    func health(now: Date = .now) -> Health {
        guard isUp else { return .critical }
        if let days = daysUntilExpiry(now: now) {
            if days < Self.expiryCriticalDays { return .critical }
            if days < Self.expiryWarningDays { return .warning }
        }
        if let responseTime, responseTime > ServiceCheck.slowResponseThreshold { return .warning }
        return .ok
    }

    var summary: String {
        switch outcome {
        case .responded(let status, true): "HTTP \(status)"
        case .responded(let status, false): "Unexpected HTTP \(status)"
        case .failed(let error): error.errorDescription ?? "Failed"
        }
    }
}

enum TrustReuse {
    /// Fingerprints the user already reviewed for the same host name, keyed to where they were reviewed.
    /// Only an identical certificate on an identical host qualifies; other hosts never share trust.
    static func reviewedFingerprints(
        forHost host: String,
        servers: [ServerProfile],
        checks: [ServiceCheck],
        excluding checkID: UUID?
    ) -> [String: String] {
        let host = host.lowercased()
        var result: [String: String] = [:]
        for server in servers {
            for endpoint in server.endpoints where endpoint.url.host()?.lowercased() == host {
                if let pin = endpoint.pinnedCertificateSHA256 {
                    result[pin] = "\(server.name) (\(endpoint.kind.displayName.lowercased()))"
                }
            }
        }
        for check in checks where check.id != checkID && check.url.host()?.lowercased() == host {
            if let pin = check.pinnedCertificateSHA256 {
                result[pin] = check.name
            }
        }
        return result
    }
}
