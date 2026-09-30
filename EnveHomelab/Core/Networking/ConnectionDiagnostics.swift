import Foundation
import Network
import os

struct DiagnosticStep: Sendable, Identifiable, Equatable {
    enum Status: Sendable, Equatable {
        case passed, warning, failed, skipped
    }

    var id: String { title }
    var title: String
    var status: Status
    var detail: String
    var duration: Duration?
}

/// Walks a connection layer by layer so a failure points at the right cause (name, network, TLS, HTTP or credentials).
enum ConnectionDiagnostics {
    static func run(
        url: URL,
        pinnedFingerprint: String?,
        authenticate: (@Sendable () async throws -> String)?
    ) async -> [DiagnosticStep] {
        var steps: [DiagnosticStep] = []
        guard let host = url.host(), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return [DiagnosticStep(title: "Address", status: .failed, detail: "“\(url.absoluteString)” isn't an http or https address.")]
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        steps.append(DiagnosticStep(title: "Address", status: .passed, detail: "\(scheme)://\(host):\(port)"))

        let clock = ContinuousClock()
        var start = clock.now
        switch await resolve(host) {
        case .success(let addresses):
            steps.append(DiagnosticStep(title: "Name lookup", status: .passed, detail: addresses.prefix(4).joined(separator: ", "), duration: clock.now - start))
        case .failure(let message):
            steps.append(DiagnosticStep(title: "Name lookup", status: .failed, detail: message, duration: clock.now - start))
            return steps + skipped(after: "Name lookup", secure: scheme == "https", authenticate: authenticate != nil)
        }

        start = clock.now
        if let failure = await connect(host: host, port: port) {
            steps.append(DiagnosticStep(title: "Network connection", status: .failed, detail: failure, duration: clock.now - start))
            return steps + skipped(after: "Network connection", secure: scheme == "https", authenticate: authenticate != nil)
        }
        steps.append(DiagnosticStep(title: "Network connection", status: .passed, detail: "TCP port \(port) accepted the connection.", duration: clock.now - start))

        start = clock.now
        let http = await httpProbe(url: url, pinnedFingerprint: pinnedFingerprint)
        let elapsed = clock.now - start
        if scheme == "https" {
            steps.append(http.tls.map { DiagnosticStep(title: "TLS certificate", status: $0.0, detail: $0.1, duration: elapsed) }
                ?? DiagnosticStep(title: "TLS certificate", status: .failed, detail: "No certificate was presented.", duration: elapsed))
        }
        steps.append(DiagnosticStep(title: "HTTP", status: http.status, detail: http.detail, duration: elapsed))
        if http.status == .failed {
            return steps + (authenticate == nil ? [] : [DiagnosticStep(title: "Sign-in", status: .skipped, detail: "Skipped because the server didn't answer.")])
        }

        if let authenticate {
            start = clock.now
            do {
                let summary = try await authenticate()
                steps.append(DiagnosticStep(title: "Sign-in", status: .passed, detail: summary, duration: clock.now - start))
            } catch {
                let failure = NetworkError.from(error)
                steps.append(DiagnosticStep(title: "Sign-in", status: .failed, detail: [failure.errorDescription, failure.recoverySuggestion].compactMap { $0 }.joined(separator: " "), duration: clock.now - start))
            }
        }
        return steps
    }

    private static func skipped(after step: String, secure: Bool, authenticate: Bool) -> [DiagnosticStep] {
        (["Name lookup", "Network connection"] + (secure ? ["TLS certificate"] : []) + ["HTTP"] + (authenticate ? ["Sign-in"] : []))
            .drop { $0 != step }.dropFirst()
            .map { DiagnosticStep(title: $0, status: .skipped, detail: "Skipped because an earlier step failed.") }
    }

    private enum Lookup {
        case success([String])
        case failure(String)
    }

    private static func resolve(_ host: String) async -> Lookup {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            guard status == 0, let first = result else {
                return .failure(String(cString: gai_strerror(status)))
            }
            defer { freeaddrinfo(result) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !addresses.contains(text) { addresses.append(text) }
                }
                cursor = info.pointee.ai_next
            }
            return .success(addresses)
        }.value
    }

    private static func connect(host: String, port: Int) async -> String? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return "Invalid port." }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLockBox(false)
            let finish: @Sendable (String?) -> Void = { message in
                if finished.claim() {
                    connection.cancel()
                    continuation.resume(returning: message)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed(let error), .waiting(let error): finish(error.localizedDescription)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { finish("No answer within 6 seconds.") }
        }
    }

    private struct HTTPResult {
        var status: DiagnosticStep.Status
        var detail: String
        var tls: (DiagnosticStep.Status, String)?
    }

    private static func httpProbe(url: URL, pinnedFingerprint: String?) async -> HTTPResult {
        let delegate = SessionDelegate(pinnedFingerprints: pinnedFingerprint.map { [$0] } ?? [], followsRedirects: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var tls: (DiagnosticStep.Status, String)? {
            guard let certificate = delegate.presentedCertificate else { return nil }
            var parts = [certificate.subject]
            if let notAfter = certificate.notValidAfter {
                let days = Int(notAfter.timeIntervalSinceNow / 86_400)
                parts.append(days < 0 ? "expired" : "expires in \(days) days")
            }
            if certificate.evaluationFailure == nil {
                return (.passed, "Trusted by the system · " + parts.joined(separator: " · "))
            }
            if certificate.sha256Fingerprint == pinnedFingerprint {
                return (.passed, "Matches the fingerprint you trusted · " + parts.joined(separator: " · "))
            }
            return (.failed, "Not trusted: \(certificate.evaluationFailure ?? "unknown reason"). Review it from the connection's editor. · " + parts.joined(separator: " · "))
        }
        do {
            let (_, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let status: DiagnosticStep.Status = code < 500 ? .passed : .warning
            return HTTPResult(status: status, detail: "Answered HTTP \(code)" + (code == 401 || code == 403 ? " (sign-in required — expected)" : ""), tls: tls)
        } catch {
            let failure = delegate.trustError(for: error) ?? (error as? URLError)?.networkError ?? .from(error)
            return HTTPResult(status: .failed, detail: failure.errorDescription ?? "No HTTP response.", tls: tls)
        }
    }
}

/// A one-shot flag for callbacks that may fire more than once.
final class OSAllocatedUnfairLockBox: Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>

    init(_ value: Bool) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    /// Returns true the first time only.
    func claim() -> Bool {
        lock.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
