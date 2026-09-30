import Foundation

enum GraphQLVariable: Encodable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case object([String: GraphQLVariable])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One URLSession per endpoint so each carries its own pinned fingerprint.
final class GraphQLClient: Sendable {
    let endpointURL: URL
    let apiKey: String
    let session: URLSession
    let delegate: SessionDelegate
    private let timeout: TimeInterval

    init(baseURL: URL, apiKey: String, pinnedFingerprint: String?, timeout: TimeInterval = 20) {
        endpointURL = baseURL.appending(path: "graphql")
        self.apiKey = apiKey
        self.timeout = timeout
        delegate = SessionDelegate(pinnedFingerprints: pinnedFingerprint.map { [$0] } ?? [])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send<Response: Decodable & Sendable>(
        _ query: String,
        variables: [String: GraphQLVariable] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        var request = URLRequest(url: endpointURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(Body(query: query, variables: variables.isEmpty ? nil : variables))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.unexpectedResponse("No HTTP response.")
        }
        if (300..<400).contains(http.statusCode) {
            if let target = delegate.redirectTarget ?? http.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) {
                throw NetworkError.redirected(target)
            }
            throw NetworkError.httpStatus(http.statusCode)
        }

        let envelope: Envelope<Response>
        do {
            envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data)
        } catch let decodingError as DecodingError {
            throw classifyUndecodable(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), error: decodingError)
        }

        if let errors = envelope.errors, !errors.isEmpty {
            throw Self.classify(errors, status: http.statusCode)
        }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw NetworkError.unauthorized
        case 403: throw NetworkError.forbidden("")
        default: throw NetworkError.httpStatus(http.statusCode)
        }
        guard let payload = envelope.data else {
            throw NetworkError.unexpectedResponse("The response contained no data.")
        }
        return payload
    }

    /// Decodes a `{ data, errors }` envelope that arrived outside an HTTP response, e.g. a subscription event.
    static func decodeEnvelope<Response: Decodable>(_ data: Data, as type: Response.Type) throws -> Response {
        let envelope: Envelope<Response>
        do {
            envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data)
        } catch let error as DecodingError {
            throw NetworkError.decoding(describe(error))
        }
        if let errors = envelope.errors, !errors.isEmpty {
            throw classify(errors, status: 200)
        }
        guard let payload = envelope.data else {
            throw NetworkError.unexpectedResponse("The event contained no data.")
        }
        return payload
    }

    func mapTransportError(_ error: any Error) -> NetworkError {
        if let trustError = delegate.trustError(for: error) { return trustError }
        guard let urlError = error as? URLError else { return .from(error) }
        return urlError.networkError
    }

    private func classifyUndecodable(status: Int, contentType: String?, error: DecodingError) -> NetworkError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden("")
        case 404: return .apiNotFound
        case 200..<300:
            if let contentType, !contentType.contains("json") {
                return .apiNotFound
            }
            return .decoding(Self.describe(error))
        default: return .httpStatus(status)
        }
    }

    static func classify(_ errors: [GraphQLErrorPayload], status: Int) -> NetworkError {
        let messages = errors.map(\.message)
        let codes = Set(errors.compactMap { $0.extensions?.code?.uppercased() })

        if codes.contains("UNAUTHENTICATED") || status == 401 {
            return .unauthorized
        }
        if codes.contains("FORBIDDEN") || status == 403 || messages.contains(where: { $0.localizedCaseInsensitiveContains("forbidden") }) {
            return .forbidden(messages.first ?? "")
        }
        if codes.contains("GRAPHQL_VALIDATION_FAILED")
            || messages.contains(where: { $0.hasPrefix("Cannot query field") || $0.hasPrefix("Unknown argument") || $0.hasPrefix("Unknown type") }) {
            return .unsupportedByServer(messages.joined(separator: " ") + " Updating Unraid or the Unraid Connect plugin may add it.")
        }
        return .graphQL(messages)
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            "Missing “\(key.stringValue)” at \(context.codingPath.pathDescription)."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            "\(context.debugDescription) at \(context.codingPath.pathDescription)."
        @unknown default:
            error.localizedDescription
        }
    }

    private struct Body: Encodable {
        let query: String
        let variables: [String: GraphQLVariable]?
    }

    struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [GraphQLErrorPayload]?
    }
}

struct GraphQLErrorPayload: Decodable, Sendable {
    struct Extensions: Decodable, Sendable {
        let code: String?
    }

    let message: String
    let extensions: Extensions?
}

private extension [any CodingKey] {
    var pathDescription: String {
        isEmpty ? "root" : map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}
