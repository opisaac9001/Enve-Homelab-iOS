import Foundation
import os

struct DelugeTorrent: Decodable, Sendable {
    var name: String
    var state: String
    var progress: Double
    var total_wanted: Int64?
    var total_remaining: Int64?
    var download_payload_rate: Int64?
    var upload_payload_rate: Int64?
    var eta: Int64?
    var label: String?
    var message: String?

    var transferState: TransferState {
        switch state {
        case "Downloading": .downloading
        case "Seeding": .seeding
        case "Paused": progress >= 100 ? .completed : .paused
        case "Queued": .queued
        case "Checking", "Allocating", "Moving": .checking
        case "Error": .failed
        default: .unknown
        }
    }

    func transferItem(id: String) -> TransferItem {
        TransferItem(
            id: id,
            name: name,
            state: transferState,
            progress: progress / 100,
            size: total_wanted,
            remaining: total_remaining,
            downloadRate: download_payload_rate,
            uploadRate: upload_payload_rate,
            eta: eta.flatMap { $0 > 0 ? TimeInterval($0) : nil },
            category: label?.nilIfEmpty,
            message: state == "Error" ? message?.nilIfEmpty : nil
        )
    }
}

struct DelugeUpdate: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        var download_rate: Double?
        var upload_rate: Double?
    }

    var connected: Bool
    var torrents: [String: DelugeTorrent]?
    var stats: Stats?
}

/// Deluge 2.x Web UI JSON-RPC (`POST /json`): password login sets a session cookie; `core.*` calls need the web UI connected to a daemon.
final class DelugeClient: DownloadClientService {
    let kind = IntegrationKind.deluge
    static let torrentKeys = ["name", "state", "progress", "total_wanted", "total_remaining", "download_payload_rate", "upload_payload_rate", "eta", "label", "message"]
    private let rest: RESTClient
    private let password: String
    private let requestID = OSAllocatedUnfairLock(initialState: 0)

    init(url: URL, password: String?, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, acceptsCookies: true)
        self.password = password ?? ""
    }

    private struct Envelope<Result: Decodable>: Decodable {
        struct RPCError: Decodable { var message: String; var code: Int }
        var result: Result?
        var error: RPCError?
    }

    private struct RPCFailure: Error {
        var code: Int
        var message: String
    }

    private func send<Result: Decodable>(_ method: String, _ params: [Any], as type: Result.Type) async throws -> Result? {
        let id = requestID.withLock { $0 += 1; return $0 }
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": id])
        let envelope = try await rest.json(RESTRequest(method: "POST", path: "json", body: .json(body)), as: Envelope<Result>.self)
        if let error = envelope.error { throw RPCFailure(code: error.code, message: error.message) }
        return envelope.result
    }

    private func login() async throws {
        guard try await send("auth.login", [password], as: Bool.self) == true else { throw NetworkError.unauthorized }
    }

    /// Signs in again when the hour-long session has expired, then retries once.
    private func call<Result: Decodable>(_ method: String, _ params: [Any] = [], as type: Result.Type) async throws -> Result? {
        do {
            return try await send(method, params, as: type)
        } catch let failure as RPCFailure where failure.code == 1 {
            try await login()
            do {
                return try await send(method, params, as: type)
            } catch let failure as RPCFailure {
                throw NetworkError.graphQL([failure.message])
            }
        } catch let failure as RPCFailure {
            throw NetworkError.graphQL([failure.message])
        }
    }

    private struct Nothing: Decodable {}

    /// Connects the web UI to a daemon only if it isn't connected, as the web UI itself does on start.
    private func ensureConnected() async throws {
        if try await call("web.connected", as: Bool.self) == true { return }
        let hosts = try await call("web.get_hosts", as: [[JSONScalar]].self) ?? []
        for host in hosts {
            guard case .string(let hostID) = host.first else { continue }
            let status = try await call("web.get_host_status", [hostID], as: [JSONScalar].self) ?? []
            guard status.count > 1, case .string("Online") = status[1] else { continue }
            if try await call("web.connect", [hostID], as: [String].self) != nil { return }
        }
        throw NetworkError.unsupportedByServer("Deluge's web UI isn't connected to a daemon and none of its saved daemons are online. Open Connection Manager in the Deluge web UI.")
    }

    func overview() async throws -> DownloadOverview {
        try await ensureConnected()
        async let version = call("daemon.get_version", as: String.self)
        async let paused = call("core.is_session_paused", as: Bool.self)
        async let update = call("web.update_ui", [Self.torrentKeys, [String: String]()], as: DelugeUpdate.self)
        guard let update = try await update else { throw NetworkError.unexpectedResponse("Deluge returned no torrent list.") }
        let items = (update.torrents ?? [:])
            .map { $0.value.transferItem(id: $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return try await DownloadOverview(
            version: version,
            downloadRate: Int64(update.stats?.download_rate ?? 0),
            uploadRate: Int64(update.stats?.upload_rate ?? 0),
            isPaused: paused,
            items: items
        )
    }

    func pause(_ ids: [String]) async throws {
        try await ensureConnected()
        _ = try await call("core.pause_torrent", [ids], as: Nothing.self)
    }

    func resume(_ ids: [String]) async throws {
        try await ensureConnected()
        _ = try await call("core.resume_torrent", [ids], as: Nothing.self)
    }

    func pauseAll() async throws {
        try await ensureConnected()
        _ = try await call("core.pause_session", as: Nothing.self)
    }

    func resumeAll() async throws {
        try await ensureConnected()
        _ = try await call("core.resume_session", as: Nothing.self)
    }

    func remove(_ ids: [String], deleteData: Bool) async throws {
        try await ensureConnected()
        let failures = try await call("core.remove_torrents", [ids, deleteData], as: [[String]].self) ?? []
        if let failure = failures.first, failure.count > 1 { throw NetworkError.graphQL([failure[1]]) }
    }
}

/// A loosely typed JSON value; objects and arrays decode as `.null` so mixed payloads still decode.
enum JSONScalar: Decodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .null }
    }
}
