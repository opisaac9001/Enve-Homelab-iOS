import CryptoKit
import Foundation
import os
import Security

/// Runs system trust evaluation first; pinned fingerprints are only consulted when that fails.
final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private struct Observations {
        var presentedCertificate: CertificateSummary?
        var rejectedCertificate: CertificateSummary?
        var redirectTarget: URL?
    }

    let pinnedFingerprints: Set<String>
    let followsRedirects: Bool
    private let observations = OSAllocatedUnfairLock(initialState: Observations())

    init(pinnedFingerprints: Set<String>, followsRedirects: Bool = false) {
        self.pinnedFingerprints = pinnedFingerprints
        self.followsRedirects = followsRedirects
    }

    var presentedCertificate: CertificateSummary? { observations.withLock { $0.presentedCertificate } }
    var rejectedCertificate: CertificateSummary? { observations.withLock { $0.rejectedCertificate } }
    var redirectTarget: URL? { observations.withLock { $0.redirectTarget } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var evaluationError: CFError?
        let systemTrusted = SecTrustEvaluateWithError(trust, &evaluationError)
        let summary = CertificateInspector.summary(
            of: trust,
            host: challenge.protectionSpace.host,
            failure: systemTrusted ? nil : evaluationError
        )
        observations.withLock { $0.presentedCertificate = summary }

        if systemTrusted {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard let summary else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if pinnedFingerprints.contains(summary.sha256Fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        observations.withLock { $0.rejectedCertificate = summary }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // POST redirects silently become GETs, so API sessions surface them instead of following.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if followsRedirects {
            completionHandler(request)
            return
        }
        observations.withLock { $0.redirectTarget = request.url }
        completionHandler(nil)
    }

    /// Maps a transport failure, preferring what the delegate observed during the handshake.
    func trustError(for error: any Error) -> NetworkError? {
        if let rejected = rejectedCertificate {
            if let pinned = pinnedFingerprints.sorted().first {
                return .certificateChanged(rejected, pinnedFingerprint: pinned)
            }
            return .untrustedCertificate(rejected)
        }
        if let target = redirectTarget {
            return .redirected(target)
        }
        return nil
    }
}

enum CertificateInspector {
    static func summary(of trust: SecTrust, host: String, failure: CFError?) -> CertificateSummary? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }

        let data = SecCertificateCopyData(leaf) as Data
        let validity = X509Validity.parse(data)
        return CertificateSummary(
            host: host,
            subject: SecCertificateCopySubjectSummary(leaf) as String? ?? host,
            sha256Fingerprint: fingerprint(of: data),
            notValidBefore: validity?.notBefore,
            notValidAfter: validity?.notAfter,
            evaluationFailure: failure.map { ($0 as Error).localizedDescription }
        )
    }

    static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

extension URLError {
    var networkError: NetworkError {
        switch code {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: .offline
        case .cannotFindHost, .dnsLookupFailed: .unreachable("The host name couldn't be resolved.")
        case .cannotConnectToHost: .unreachable("The server refused the connection.")
        case .networkConnectionLost: .unreachable("The connection was lost.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            .tlsFailure(localizedDescription)
        case .badURL, .unsupportedURL: .invalidURL
        default: .unreachable(localizedDescription)
        }
    }
}
