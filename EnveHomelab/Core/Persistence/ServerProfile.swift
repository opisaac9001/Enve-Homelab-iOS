import Foundation

enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case unraid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unraid: "Unraid"
        }
    }
}

struct ServerEndpoint: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case local
        case remote

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .local: "Local network"
            case .remote: "Remote"
            }
        }

        var systemImage: String {
            switch self {
            case .local: "wifi.router"
            case .remote: "globe"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var url: URL
    var pinnedCertificateSHA256: String?
    var pinnedCertificateSubject: String?

    var usesPlainHTTP: Bool { url.scheme?.lowercased() == "http" }
}

enum EndpointSelection: Codable, Sendable, Hashable {
    case automatic
    case pinned(UUID)
}

struct ServerProfile: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var provider: ProviderKind = .unraid
    var endpoints: [ServerEndpoint]
    var selection: EndpointSelection = .automatic

    /// Automatic mode tries local endpoints before remote ones.
    var connectionOrder: [ServerEndpoint] {
        switch selection {
        case .automatic:
            endpoints.filter { $0.kind == .local } + endpoints.filter { $0.kind == .remote }
        case .pinned(let id):
            endpoints.filter { $0.id == id }
        }
    }

    mutating func trust(_ certificate: CertificateSummary, for endpointID: UUID) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpointID }) else { return }
        endpoints[index].pinnedCertificateSHA256 = certificate.sha256Fingerprint
        endpoints[index].pinnedCertificateSubject = certificate.subject
    }
}

enum EndpointURLParser {
    enum Failure: Error, Equatable, LocalizedError {
        case empty
        case unsupportedScheme(String)
        case missingHost

        var errorDescription: String? {
            switch self {
            case .empty: "Enter an address."
            case .unsupportedScheme(let scheme): "“\(scheme)” isn't supported. Use http or https."
            case .missingHost: "The address needs a host name or IP address."
            }
        }
    }

    /// Accepts `tower.local`, `192.168.1.10:8443`, or a full URL; strips a trailing `/graphql`.
    static func parse(_ input: String) -> Result<URL, Failure> {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text) else { return .failure(.missingHost) }
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme(scheme)) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }

        components.scheme = scheme
        components.host = host.lowercased()
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/graphql") { path.removeLast("/graphql".count) }
        components.path = path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil

        guard let url = components.url else { return .failure(.missingHost) }
        return .success(url)
    }
}
