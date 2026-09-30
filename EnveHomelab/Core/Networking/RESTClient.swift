import Foundation

struct RESTRequest: Sendable {
    enum Body: Sendable {
        case json(Data)
        case form([String: String])
    }

    var method = "GET"
    var path: String
    var query: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Body?

    static func get(_ path: String, query: [URLQueryItem] = []) -> RESTRequest {
        RESTRequest(path: path, query: query)
    }

    static func post(_ path: String, query: [URLQueryItem] = [], json: some Encodable) throws -> RESTRequest {
        RESTRequest(method: "POST", path: path, query: query, body: .json(try JSONEncoder().encode(json)))
    }

    static func post(_ path: String, query: [URLQueryItem] = [], form: [String: String] = [:]) -> RESTRequest {
        RESTRequest(method: "POST", path: path, query: query, body: .form(form))
    }

    static func delete(_ path: String, query: [URLQueryItem] = []) -> RESTRequest {
        RESTRequest(method: "DELETE", path: path, query: query)
    }
}

/// JSON-over-HTTP transport shared by integrations; applies the same trust rules as the Unraid client.
final class RESTClient: Sendable {
    let baseURL: URL
    private let session: URLSession
    private let delegate: SessionDelegate
    private let headers: [String: String]

    init(
        baseURL: URL,
        pinnedFingerprint: String?,
        headers: [String: String] = [:],
        timeout: TimeInterval = 20,
        acceptsCookies: Bool = false
    ) {
        self.baseURL = baseURL
        self.headers = headers
        delegate = SessionDelegate(pinnedFingerprints: pinnedFingerprint.map { [$0] } ?? [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = acceptsCookies ? .onlyFromMainDocumentDomain : .never
        configuration.httpShouldSetCookies = acceptsCookies
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func url(for path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            // Some servers (Django) require the trailing slash and would redirect without it.
            let isDirectory = index == components.count - 1 && path.hasSuffix("/")
            url.append(path: String(component), directoryHint: isDirectory ? .isDirectory : .inferFromPath)
        }
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + query
        // `+` is legal in queries but many servers decode it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }

    /// Returns the raw response for any status; callers that need status-specific handling use this.
    func raw(_ request: RESTRequest) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: url(for: request.path, query: request.query))
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers.merging(request.headers, uniquingKeysWith: { $1 }) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        switch request.body {
        case .json(let data):
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = data
        case .form(let fields):
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = Data(Self.formEncode(fields).utf8)
        case nil:
            break
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw NetworkError.unexpectedResponse("No HTTP response.") }
            return (data, http)
        } catch let error as NetworkError {
            throw error
        } catch {
            if let trustError = delegate.trustError(for: error) { throw trustError }
            if let urlError = error as? URLError { throw urlError.networkError }
            throw NetworkError.from(error)
        }
    }

    /// Succeeds only for 2xx responses.
    func data(_ request: RESTRequest) async throws -> Data {
        let (data, response) = try await raw(request)
        try Self.validate(response, data: data)
        return data
    }

    func json<Response: Decodable>(_ request: RESTRequest, as type: Response.Type = Response.self) async throws -> Response {
        let data = try await data(request)
        return try Self.decode(Response.self, from: data)
    }

    static func validate(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 300..<400: throw NetworkError.redirected(response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) ?? response.url ?? URL(fileURLWithPath: "/"))
        case 401: throw NetworkError.unauthorized
        case 403: throw NetworkError.forbidden(serverMessage(data) ?? "")
        case 404: throw NetworkError.apiNotFound
        default:
            if let message = serverMessage(data) { throw NetworkError.graphQL(["HTTP \(response.statusCode): \(message)"]) }
            throw NetworkError.httpStatus(response.statusCode)
        }
    }

    static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as DecodingError {
            if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                throw NetworkError.apiNotFound
            }
            throw NetworkError.decoding(GraphQLClient.describe(error))
        }
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
    }

    /// Picks a human-readable message out of common error bodies (`message`, `error`, `errorMessage`).
    static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("<") ? nil : LogRedactor.redact(text)
        }
        if let dictionary = object as? [String: Any] {
            for key in ["message", "errorMessage", "error", "detail", "details", "Message", "err"] {
                if let value = dictionary[key] as? String, !value.isEmpty { return LogRedactor.redact(value) }
            }
        }
        if let array = object as? [[String: Any]], let first = array.first {
            return ((first["errorMessage"] ?? first["message"]) as? String).map(LogRedactor.redact)
        }
        return nil
    }
}
