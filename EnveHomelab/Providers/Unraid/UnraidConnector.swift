import Foundation

struct UnraidConnection: Sendable {
    let endpoint: ServerEndpoint
    let client: UnraidClient
    let identity: UnraidIdentity
}

struct ConnectionFailure: Error, Sendable {
    let endpoint: ServerEndpoint?
    let error: NetworkError
}

enum UnraidConnector {
    private static let probeTimeout: TimeInterval = 6

    /// Probes endpoints in connection order and returns the first that authenticates.
    static func connect(profile: ServerProfile, apiKey: String) async -> Result<UnraidConnection, ConnectionFailure> {
        let candidates = profile.connectionOrder
        guard !candidates.isEmpty else { return .failure(ConnectionFailure(endpoint: nil, error: .invalidURL)) }

        var lastFailure = ConnectionFailure(endpoint: nil, error: .unreachable(""))
        for (index, endpoint) in candidates.enumerated() {
            let isLast = index == candidates.count - 1
            let probe = UnraidClient(endpoint: endpoint, apiKey: apiKey, timeout: isLast ? 20 : probeTimeout)
            do {
                let identity = try await probe.identity()
                return .success(UnraidConnection(
                    endpoint: endpoint,
                    client: isLast ? probe : UnraidClient(endpoint: endpoint, apiKey: apiKey),
                    identity: identity
                ))
            } catch {
                let networkError = NetworkError.from(error)
                lastFailure = ConnectionFailure(endpoint: endpoint, error: networkError)
                if networkError.isCancellation || networkError.isDefinitiveForEndpoint {
                    return .failure(lastFailure)
                }
            }
        }
        return .failure(lastFailure)
    }
}
