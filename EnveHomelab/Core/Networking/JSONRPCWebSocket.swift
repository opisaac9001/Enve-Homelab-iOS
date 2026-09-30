import Foundation

enum JSONRPCMessage {
    static func request(id: Int, method: String, params: [Any]) throws -> String {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Returns the `result` payload for `id`, `nil` for unrelated messages (notifications, other ids).
    static func result(for id: Int, in text: String) throws -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw NetworkError.unexpectedResponse("Malformed JSON-RPC message.")
        }
        guard (object["id"] as? Int) == id else { return nil }
        if let error = object["error"] as? [String: Any] {
            throw classify(error)
        }
        return try JSONSerialization.data(withJSONObject: object["result"] ?? NSNull(), options: [.fragmentsAllowed])
    }

    static func classify(_ error: [String: Any]) -> NetworkError {
        let code = error["code"] as? Int
        let data = error["data"] as? [String: Any]
        let message = (data?["reason"] as? String) ?? (error["message"] as? String) ?? "The server reported an error."
        let errname = data?["errname"] as? String
        switch (code, errname) {
        case (-32601, _): return .unsupportedByServer(message)
        case (_, "ENOTAUTHENTICATED"): return .unauthorized
        case (_, "EACCES"), (_, "EPERM"): return .forbidden(message)
        default: return .graphQL([message])
        }
    }
}

/// One authenticated JSON-RPC 2.0 WebSocket, used for a batch of sequential calls then closed.
final class JSONRPCWebSocketSession: @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private let delegate: SessionDelegate
    private var nextID = 1

    private init(socket: URLSessionWebSocketTask, delegate: SessionDelegate) {
        self.socket = socket
        self.delegate = delegate
    }

    static func withSession<Result>(
        url: URL,
        pinnedFingerprint: String?,
        timeout: TimeInterval = 20,
        _ body: (JSONRPCWebSocketSession) async throws -> Result
    ) async throws -> Result {
        let delegate = SessionDelegate(pinnedFingerprints: pinnedFingerprint.map { [$0] } ?? [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { urlSession.invalidateAndCancel() }
        let socket = urlSession.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        return try await body(JSONRPCWebSocketSession(socket: socket, delegate: delegate))
    }

    func call(_ method: String, _ params: [Any] = []) async throws -> Data {
        let id = nextID
        nextID += 1
        do {
            try await socket.send(.string(try JSONRPCMessage.request(id: id, method: method, params: params)))
            while true {
                let message = try await withTaskCancellationHandler {
                    try await socket.receive()
                } onCancel: { [socket] in
                    socket.cancel(with: .goingAway, reason: nil)
                }
                let text: String = switch message {
                case .string(let text): text
                case .data(let data): String(decoding: data, as: UTF8.self)
                @unknown default: ""
                }
                if let result = try JSONRPCMessage.result(for: id, in: text) { return result }
            }
        } catch let error as NetworkError {
            throw error
        } catch {
            if let trustError = delegate.trustError(for: error) { throw trustError }
            if let urlError = error as? URLError { throw urlError.networkError }
            throw NetworkError.from(error)
        }
    }

    func call<Result: Decodable>(_ method: String, _ params: [Any] = [], as type: Result.Type) async throws -> Result {
        try RESTClient.decode(Result.self, from: try await call(method, params))
    }
}
