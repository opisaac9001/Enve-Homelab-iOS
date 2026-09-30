import Foundation

/// Messages of the `graphql-transport-ws` protocol used by the Unraid API.
enum GraphQLWSMessage: Equatable, Sendable {
    case connectionInit(apiKey: String)
    case connectionAck
    case ping
    case pong
    case subscribe(id: String, query: String)
    case next(id: String, payload: Data)
    case error(id: String, payload: Data)
    case complete(id: String)

    static let subprotocol = "graphql-transport-ws"

    func encoded() throws -> String {
        let object: [String: Any] = switch self {
        case .connectionInit(let apiKey): ["type": "connection_init", "payload": ["x-api-key": apiKey]]
        case .connectionAck: ["type": "connection_ack"]
        case .ping: ["type": "ping"]
        case .pong: ["type": "pong"]
        case .subscribe(let id, let query): ["type": "subscribe", "id": id, "payload": ["query": query]]
        case .complete(let id): ["type": "complete", "id": id]
        case .next(let id, let payload), .error(let id, let payload):
            ["type": self.isNext ? "next" : "error", "id": id, "payload": try JSONSerialization.jsonObject(with: payload)]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> GraphQLWSMessage {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else {
            throw NetworkError.unexpectedResponse("Malformed subscription message.")
        }
        let id = object["id"] as? String
        func payload() throws -> Data {
            guard let payload = object["payload"] else { throw NetworkError.unexpectedResponse("Subscription message had no payload.") }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
                throw NetworkError.unexpectedResponse("Subscription payload wasn't valid JSON.")
            }
            return data
        }
        switch (type, id) {
        case ("connection_ack", _): return .connectionAck
        case ("ping", _): return .ping
        case ("pong", _): return .pong
        case ("next", let id?): return .next(id: id, payload: try payload())
        case ("error", let id?): return .error(id: id, payload: try payload())
        case ("complete", let id?): return .complete(id: id)
        default: throw NetworkError.unexpectedResponse("Unexpected subscription message “\(type)”.")
        }
    }

    private var isNext: Bool {
        if case .next = self { true } else { false }
    }
}

extension GraphQLClient {
    private static let acknowledgementTimeout: Duration = .seconds(8)

    var subscriptionURL: URL {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    /// One WebSocket per subscription; cancelling the consuming task closes it.
    func subscribe<Response: Decodable & Sendable>(
        _ query: String,
        as type: Response.Type = Response.self
    ) -> AsyncThrowingStream<Response, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var request = URLRequest(url: subscriptionURL)
                request.setValue(GraphQLWSMessage.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                let socket = session.webSocketTask(with: request)
                socket.resume()
                defer { socket.cancel(with: .normalClosure, reason: nil) }

                do {
                    try await socket.send(.string(GraphQLWSMessage.connectionInit(apiKey: apiKey).encoded()))
                    try await awaitAcknowledgement(on: socket)
                    let id = UUID().uuidString
                    try await socket.send(.string(GraphQLWSMessage.subscribe(id: id, query: query).encoded()))

                    while !Task.isCancelled {
                        switch try await receive(on: socket) {
                        case .next(id, let payload):
                            continuation.yield(try Self.decodeEnvelope(payload, as: Response.self))
                        case .error(id, let payload):
                            let errors = (try? JSONDecoder().decode([GraphQLErrorPayload].self, from: payload)) ?? []
                            throw Self.classify(errors, status: 200)
                        case .complete(id):
                            continuation.finish()
                            return
                        case .ping:
                            try await socket.send(.string(GraphQLWSMessage.pong.encoded()))
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: subscriptionError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func awaitAcknowledgement(on socket: URLSessionWebSocketTask) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    switch try await self.receive(on: socket) {
                    case .connectionAck: return
                    case .ping: try await socket.send(.string(GraphQLWSMessage.pong.encoded()))
                    default: continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.acknowledgementTimeout)
                throw NetworkError.subscriptionUnavailable("The server didn't acknowledge the live connection.")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) async throws -> GraphQLWSMessage {
        let message = try await withTaskCancellationHandler {
            try await socket.receive()
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
        switch message {
        case .string(let text): return try GraphQLWSMessage.decode(text)
        case .data(let data): return try GraphQLWSMessage.decode(String(decoding: data, as: UTF8.self))
        @unknown default: throw NetworkError.unexpectedResponse("Unknown WebSocket frame.")
        }
    }

    private func subscriptionError(_ error: any Error) -> NetworkError {
        if Task.isCancelled { return .cancelled }
        if let error = error as? NetworkError { return error }
        if let trustError = delegate.trustError(for: error) { return trustError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .badServerResponse: return .subscriptionUnavailable("The server refused the WebSocket upgrade.")
            default: return urlError.networkError
            }
        }
        if (error as NSError).domain == NSPOSIXErrorDomain {
            return .subscriptionUnavailable("The live connection closed: \(error.localizedDescription)")
        }
        return .subscriptionUnavailable(error.localizedDescription)
    }
}
