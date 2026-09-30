import Foundation

struct NtfyMessage: Decodable, Sendable, Hashable {
    var id: String
    var time: Int64
    var event: String
    var topic: String?
    var title: String?
    var message: String?
    var priority: Int?
    var tags: [String]?

    var severity: AlertSeverity {
        switch priority ?? 3 {
        case 5: .critical
        case 4: .warning
        default: .info
        }
    }
}

/// ntfy publish (`POST /<topic>`) and poll (`GET /<topic>/json?poll=1&since=`), as documented at docs.ntfy.sh.
struct NtfyClient: Sendable {
    let configuration: NtfyConfiguration
    private let rest: RESTClient

    init(configuration: NtfyConfiguration, token: String?) {
        self.configuration = configuration
        var headers: [String: String] = [:]
        if let token = token?.nilIfEmpty { headers["Authorization"] = "Bearer \(token)" }
        rest = RESTClient(baseURL: configuration.serverURL, pinnedFingerprint: configuration.pinnedCertificateSHA256, headers: headers)
    }

    static func parse(_ data: Data) -> [NtfyMessage] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? JSONDecoder().decode(NtfyMessage.self, from: Data($0.utf8)) }
            .filter { $0.event == "message" }
    }

    /// Messages after `since`; a first poll only asks for the last hour so an old cache isn't replayed.
    func poll(since: String?) async throws -> [NtfyMessage] {
        let query = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since ?? "1h")]
        return Self.parse(try await rest.data(.get("\(configuration.topic)/json", query: query)))
    }

    func publish(_ event: AlertEvent) async throws {
        var request = RESTRequest(method: "POST", path: configuration.topic)
        request.body = .json(Data(event.body.utf8))
        request.headers = [
            "Title": event.title,
            "Priority": String(event.severity.ntfyPriority),
            "Tags": event.isRecovery ? "white_check_mark" : (event.severity == .critical ? "rotating_light" : "warning"),
        ]
        _ = try await rest.data(request)
    }
}
