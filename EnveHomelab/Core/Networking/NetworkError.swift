import Foundation

struct CertificateSummary: Sendable, Hashable, Codable {
    let host: String
    let subject: String
    let sha256Fingerprint: String
    let notValidBefore: Date?
    let notValidAfter: Date?
    let evaluationFailure: String?
}

enum NetworkError: Error, Sendable, Equatable, Codable {
    case invalidURL
    case offline
    case unreachable(String)
    case timedOut
    case untrustedCertificate(CertificateSummary)
    case certificateChanged(CertificateSummary, pinnedFingerprint: String)
    case tlsFailure(String)
    case redirected(URL)
    case unauthorized
    case forbidden(String)
    case apiNotFound
    case httpStatus(Int)
    case unexpectedResponse(String)
    case unsupportedByServer(String)
    case graphQL([String])
    case decoding(String)
    case missingCredentials
    case subscriptionUnavailable(String)
    case cancelled

    static func from(_ error: any Error) -> NetworkError {
        switch error {
        case let error as NetworkError: error
        case is CancellationError: .cancelled
        case let error as URLError where error.code == .cancelled: .cancelled
        default: .unexpectedResponse(error.localizedDescription)
        }
    }

    var isCancellation: Bool { self == .cancelled }

    /// The endpoint answered, so trying a different endpoint will not help.
    var isDefinitiveForEndpoint: Bool {
        switch self {
        case .untrustedCertificate, .certificateChanged, .redirected, .unauthorized, .forbidden, .apiNotFound:
            true
        default:
            false
        }
    }

    var isUnsupported: Bool {
        if case .unsupportedByServer = self { true } else { false }
    }

    var suggestsEditing: Bool {
        switch self {
        case .invalidURL, .redirected, .unauthorized, .forbidden, .apiNotFound, .missingCredentials: true
        default: false
        }
    }

    var suggestsDiagnosis: Bool {
        switch self {
        case .unreachable, .timedOut, .tlsFailure, .redirected, .apiNotFound, .httpStatus, .unexpectedResponse: true
        default: false
        }
    }

    var reviewableCertificate: CertificateSummary? {
        switch self {
        case .untrustedCertificate(let summary), .certificateChanged(let summary, _): summary
        default: nil
        }
    }
}

extension NetworkError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL: "The server address isn't a valid URL."
        case .offline: "This device is offline."
        case .unreachable: "The server couldn't be reached."
        case .timedOut: "The server didn't respond in time."
        case .untrustedCertificate(let summary): "The certificate presented by \(summary.host) isn't trusted."
        case .certificateChanged(let summary, _): "The certificate for \(summary.host) has changed since you trusted it."
        case .tlsFailure: "A secure connection couldn't be established."
        case .redirected(let url): "The server redirected to \(Self.withoutCredentials(url))."
        case .unauthorized: "The credentials were rejected."
        case .forbidden(let detail): detail.nilIfEmpty.map(LogRedactor.redact) ?? "Access denied."
        case .apiNotFound: "No compatible API was found at this address."
        case .httpStatus(let code): "The server returned HTTP \(code)."
        case .unexpectedResponse: "The server sent an unexpected response."
        case .unsupportedByServer: "This server doesn't support this."
        case .graphQL(let messages): messages.first.map(LogRedactor.redact) ?? "The server reported an error."
        case .decoding: "The server's response couldn't be read."
        case .missingCredentials: "No credentials are saved for this connection."
        case .subscriptionUnavailable: "Live updates aren't available."
        case .cancelled: "The request was cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .offline: "Check your Wi-Fi or cellular connection."
        case .unreachable(let detail): "\(detail) Check the address and that you're on the right network."
        case .timedOut: "The server may be busy or unreachable from this network."
        case .untrustedCertificate: "Review the certificate fingerprint and trust it only if it matches your server."
        case .certificateChanged: "If you didn't replace the server's certificate, don't trust the new one."
        case .tlsFailure(let detail): detail
        case .redirected: "Update the endpoint to the redirected address. Unraid redirects when SSL is enforced."
        case .unauthorized: "Check the API key, token or password, and that it hasn't been revoked."
        case .forbidden(let detail): "\(detail) Use credentials that are allowed to do this.".trimmingCharacters(in: .whitespaces)
        case .apiNotFound: "Check the address and port. For Unraid, 7.2 and later include the API; earlier releases need the Unraid Connect plugin."
        case .httpStatus: "Check the server's web interface is running normally."
        case .unexpectedResponse(let detail), .decoding(let detail): detail
        case .unsupportedByServer(let detail): detail
        case .graphQL(let messages): messages.dropFirst().joined(separator: "\n").nilIfEmpty
        case .missingCredentials: "Edit the connection and enter its credentials."
        case .subscriptionUnavailable(let detail): "\(detail) Values refresh periodically instead."
        case .invalidURL, .cancelled: nil
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension NetworkError {
    /// Redirect targets can echo the request's query, which carries the API key for some services.
    static func withoutCredentials(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "another address" }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "another address"
    }
}
