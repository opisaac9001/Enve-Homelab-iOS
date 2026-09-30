import Foundation

enum ServiceProbe {
    static func run(_ check: ServiceCheck, reusable: [String: String]) async -> ServiceCheckResult {
        var pins = Set(reusable.keys)
        if let pin = check.pinnedCertificateSHA256 { pins.insert(pin) }
        let delegate = SessionDelegate(pinnedFingerprints: pins, followsRedirects: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(check.timeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(check.timeoutSeconds)
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: check.url)
        request.httpMethod = "GET"
        request.setValue("EnveHomelab-HealthCheck", forHTTPHeaderField: "User-Agent")

        let clock = ContinuousClock()
        let start = clock.now
        do {
            // Headers are enough for a health check; the body is never downloaded.
            let (bytes, response) = try await session.bytes(for: request)
            let elapsed = clock.now - start
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else {
                return result(.failed(.unexpectedResponse("No HTTP response.")), elapsed: elapsed, delegate: delegate, check: check, reusable: reusable, finalURL: nil)
            }
            return result(
                .responded(status: http.statusCode, accepted: check.acceptedStatus.accepts(http.statusCode)),
                elapsed: elapsed,
                delegate: delegate,
                check: check,
                reusable: reusable,
                finalURL: http.url
            )
        } catch {
            var failure = delegate.trustError(for: error) ?? (error as? URLError)?.networkError ?? .from(error)
            // Reused pins belong to other entries; without its own pin this check has nothing that "changed".
            if case .certificateChanged(let summary, _) = failure, check.pinnedCertificateSHA256 == nil {
                failure = .untrustedCertificate(summary)
            }
            return result(.failed(failure), elapsed: nil, delegate: delegate, check: check, reusable: reusable, finalURL: nil)
        }
    }

    private static func result(
        _ outcome: ServiceCheckResult.Outcome,
        elapsed: Duration?,
        delegate: SessionDelegate,
        check: ServiceCheck,
        reusable: [String: String],
        finalURL: URL?
    ) -> ServiceCheckResult {
        let certificate = delegate.presentedCertificate
        return ServiceCheckResult(
            checkedAt: .now,
            outcome: outcome,
            responseTime: elapsed,
            certificate: certificate,
            trust: trustSource(certificate: certificate, check: check, reusable: reusable, succeeded: elapsed != nil),
            finalURL: finalURL
        )
    }

    static func trustSource(certificate: CertificateSummary?, check: ServiceCheck, reusable: [String: String], succeeded: Bool) -> TrustSource {
        guard let certificate, succeeded else { return .none }
        if certificate.evaluationFailure == nil { return .system }
        if certificate.sha256Fingerprint == check.pinnedCertificateSHA256 { return .pinned }
        if let source = reusable[certificate.sha256Fingerprint] { return .reused(source) }
        return .none
    }
}
