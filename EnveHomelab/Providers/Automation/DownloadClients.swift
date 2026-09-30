import Foundation
import os

struct DownloadOverview: Sendable {
    var version: String?
    var downloadRate: Int64
    var uploadRate: Int64?
    var isPaused: Bool?
    var items: [TransferItem]
}

protocol DownloadClientService: IntegrationService {
    var kind: IntegrationKind { get }
    func overview() async throws -> DownloadOverview
    func pause(_ ids: [String]) async throws
    func resume(_ ids: [String]) async throws
    func remove(_ ids: [String], deleteData: Bool) async throws
    func pauseAll() async throws
    func resumeAll() async throws
}

/// One tracker's announce state for a torrent. Only the host is kept: private trackers put the user's passkey in the announce URL.
struct TorrentTracker: Sendable, Equatable, Identifiable {
    enum Status: Sendable, Equatable {
        case working, notContacted, updating, notWorking, disabled

        var title: String {
            switch self {
            case .working: "Working"
            case .notContacted: "Not contacted yet"
            case .updating: "Updating"
            case .notWorking: "Not working"
            case .disabled: "Disabled"
            }
        }

        var health: Health {
            switch self {
            case .working: .ok
            case .notWorking: .critical
            case .notContacted, .updating: .warning
            case .disabled: .unknown
            }
        }
    }

    var id: String
    var host: String
    var status: Status
    var message: String?
    var seeds: Int?
    var peers: Int?

    static func host(of announce: String) -> String {
        guard let url = URL(string: announce), let host = url.host() else {
            // DHT, PeX and LSD appear as bracketed pseudo-entries.
            return announce.hasPrefix("**") ? announce.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) : "Tracker"
        }
        return host
    }
}

/// Tracker status and data verification for one torrent; both clients document these per torrent.
protocol TorrentDiagnosticsService: DownloadClientService {
    func trackers(for itemID: String) async throws -> [TorrentTracker]
    /// Re-hashes the torrent's data on disk; nothing is deleted, but the torrent is busy until it finishes.
    func verify(_ itemID: String) async throws
}

extension DownloadClientService {
    func summary() async throws -> IntegrationSummary {
        let overview = try await overview()
        let active = overview.items.filter { $0.state == .downloading }.count
        let failed = overview.items.filter { $0.state == .failed }.count
        var headline = overview.items.isEmpty ? "Nothing queued" : "\(active) downloading of \(overview.items.count)"
        if overview.isPaused == true { headline = "Paused · " + headline }
        return IntegrationSummary(
            product: kind.displayName,
            version: overview.version,
            health: failed > 0 ? .warning : .ok,
            headline: headline,
            detail: "↓ \(Format.rate(overview.downloadRate))" + (overview.uploadRate.map { " · ↑ \(Format.rate($0))" } ?? "")
        )
    }
}

extension Format {
    static func rate(_ bytesPerSecond: Int64) -> String {
        bytes(bytesPerSecond) + "/s"
    }
}

struct QBittorrentTorrent: Decodable, Sendable {
    var hash: String
    var name: String
    var size: Int64?
    var progress: Double
    var dlspeed: Int64
    var upspeed: Int64
    var eta: Int64?
    var state: String
    var category: String?
    var amount_left: Int64?

    static let infiniteETA: Int64 = 8_640_000

    var transferState: TransferState {
        switch state {
        case "downloading", "forcedDL", "metaDL", "forcedMetaDL": .downloading
        case "uploading", "forcedUP", "stalledUP": .seeding
        case "pausedDL", "stoppedDL": .paused
        case "pausedUP", "stoppedUP": .completed
        case "queuedDL", "queuedUP", "allocating": .queued
        case "stalledDL": .stalled
        case "checkingDL", "checkingUP", "checkingResumeData", "moving": .checking
        case "error", "missingFiles": .failed
        default: .unknown
        }
    }

    var transferItem: TransferItem {
        TransferItem(
            id: hash,
            name: name,
            state: transferState,
            progress: progress,
            size: size,
            remaining: amount_left,
            downloadRate: dlspeed,
            uploadRate: upspeed,
            eta: eta.flatMap { $0 >= Self.infiniteETA || $0 < 0 ? nil : TimeInterval($0) },
            category: category?.nilIfEmpty
        )
    }
}

struct QBittorrentTransferInfo: Decodable, Sendable {
    var dl_info_speed: Int64
    var up_info_speed: Int64
    var connection_status: String?
}

/// WebUI API v2. Logs in with a cookie session; WebAPI 2.11 (qBittorrent 5) renamed pause/resume to stop/start.
final class QBittorrentClient: DownloadClientService {
    let kind = IntegrationKind.qbittorrent
    private let rest: RESTClient
    private let username: String?
    private let password: String?
    private let state = OSAllocatedUnfairLock<(loggedIn: Bool, apiVersion: String?)>(initialState: (false, nil))

    init(url: URL, username: String?, password: String?, pinnedFingerprint: String?) {
        var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        origin.path = ""
        let originURL = origin.url?.absoluteString ?? url.absoluteString
        rest = RESTClient(
            baseURL: url,
            pinnedFingerprint: pinnedFingerprint,
            headers: ["Referer": originURL, "Origin": originURL],
            acceptsCookies: true
        )
        self.username = username?.nilIfEmpty
        self.password = password
    }

    private func login() async throws {
        guard let username else { return }
        let (data, response) = try await rest.raw(.post("api/v2/auth/login", form: ["username": username, "password": password ?? ""]))
        if response.statusCode == 403 {
            throw NetworkError.forbidden("qBittorrent has temporarily banned this device after failed logins.")
        }
        try RESTClient.validate(response, data: data)
        guard response.statusCode == 204 ||
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Ok." else {
            throw NetworkError.unauthorized
        }
        state.withLock { $0.loggedIn = true }
    }

    private func authorized(_ request: RESTRequest) async throws -> Data {
        if username != nil, !state.withLock({ $0.loggedIn }) {
            try await login()
        }
        let (data, response) = try await rest.raw(request)
        if response.statusCode == 403, username != nil {
            state.withLock { $0.loggedIn = false }
            try await login()
            return try await rest.data(request)
        }
        try RESTClient.validate(response, data: data)
        return data
    }

    private func apiVersion() async throws -> String {
        if let cached = state.withLock({ $0.apiVersion }) { return cached }
        let version = String(decoding: try await authorized(.get("api/v2/app/webapiVersion")), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.withLock { $0.apiVersion = version }
        return version
    }

    static func usesStartStop(webAPIVersion: String) -> Bool {
        webAPIVersion.compare("2.11", options: .numeric) != .orderedAscending
    }

    func overview() async throws -> DownloadOverview {
        let versionData = try await authorized(.get("api/v2/app/version"))
        let transfer = try RESTClient.decode(QBittorrentTransferInfo.self, from: try await authorized(.get("api/v2/transfer/info")))
        let torrents = try RESTClient.decode([QBittorrentTorrent].self, from: try await authorized(.get("api/v2/torrents/info", query: [URLQueryItem(name: "sort", value: "added_on"), URLQueryItem(name: "reverse", value: "true")])))
        return DownloadOverview(
            version: String(decoding: versionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            downloadRate: transfer.dl_info_speed,
            uploadRate: transfer.up_info_speed,
            isPaused: nil,
            items: torrents.map(\.transferItem)
        )
    }

    private func action(_ modern: String, legacy: String, ids: [String], extra: [String: String] = [:]) async throws {
        let endpoint = Self.usesStartStop(webAPIVersion: try await apiVersion()) ? modern : legacy
        _ = try await authorized(.post("api/v2/torrents/\(endpoint)", form: extra.merging(["hashes": ids.joined(separator: "|")]) { $1 }))
    }

    func pause(_ ids: [String]) async throws { try await action("stop", legacy: "pause", ids: ids) }
    func resume(_ ids: [String]) async throws { try await action("start", legacy: "resume", ids: ids) }
    func pauseAll() async throws { try await action("stop", legacy: "pause", ids: ["all"]) }
    func resumeAll() async throws { try await action("start", legacy: "resume", ids: ["all"]) }

    func remove(_ ids: [String], deleteData: Bool) async throws {
        _ = try await authorized(.post("api/v2/torrents/delete", form: ["hashes": ids.joined(separator: "|"), "deleteFiles": String(deleteData)]))
    }
}

extension QBittorrentClient: TorrentDiagnosticsService {
    struct Tracker: Decodable {
        var url: String
        var status: Int
        var num_seeds: Int?
        var num_peers: Int?
        var msg: String?
    }

    static func tracker(_ raw: Tracker, index: Int) -> TorrentTracker {
        let status: TorrentTracker.Status = switch raw.status {
        case 2: .working
        case 3: .updating
        case 4: .notWorking
        case 0: .disabled
        default: .notContacted
        }
        return TorrentTracker(id: "\(index)", host: TorrentTracker.host(of: raw.url), status: status, message: raw.msg?.nilIfEmpty,
                              seeds: raw.num_seeds.flatMap { $0 >= 0 ? $0 : nil }, peers: raw.num_peers.flatMap { $0 >= 0 ? $0 : nil })
    }

    func trackers(for itemID: String) async throws -> [TorrentTracker] {
        let data = try await authorized(.get("api/v2/torrents/trackers", query: [URLQueryItem(name: "hash", value: itemID)]))
        return try RESTClient.decode([Tracker].self, from: data).enumerated().map { Self.tracker($1, index: $0) }
    }

    func verify(_ itemID: String) async throws {
        _ = try await authorized(.post("api/v2/torrents/recheck", form: ["hashes": itemID]))
    }
}

struct SABQueueResponse: Decodable, Sendable {
    struct Queue: Decodable, Sendable {
        struct Slot: Decodable, Sendable {
            var nzo_id: String
            var filename: String
            var status: String
            var percentage: String?
            var mb: String?
            var mbleft: String?
            var timeleft: String?
            var cat: String?
        }

        var status: String?
        var paused: Bool?
        var kbpersec: String?
        var version: String?
        var slots: [Slot]
    }

    var queue: Queue
}

struct SABStatusResponse: Decodable, Sendable {
    var status: Bool?
    var error: String?
}

extension SABQueueResponse.Queue.Slot {
    var transferState: TransferState {
        switch status {
        case "Downloading", "Fetching", "Grabbing", "Propagating": .downloading
        case "Paused": .paused
        case "Queued": .queued
        case "Checking", "QuickCheck", "Verifying", "Repairing": .checking
        case "Extracting", "Moving", "Running": .importing
        case "Completed": .completed
        case "Failed": .failed
        default: .unknown
        }
    }

    var transferItem: TransferItem {
        let total = Double(mb ?? "") ?? 0
        let left = Double(mbleft ?? "") ?? 0
        let megabyte = 1_048_576.0
        return TransferItem(
            id: nzo_id,
            name: filename,
            state: transferState,
            progress: (Double(percentage ?? "") ?? 0) / 100,
            size: Int64(total * megabyte),
            remaining: Int64(left * megabyte),
            eta: Durations.timeSpan(timeleft),
            category: cat.flatMap { $0 == "*" ? nil : $0 }
        )
    }
}

/// SABnzbd `api?mode=…` with the key as a query parameter, as the SABnzbd API requires.
struct SABnzbdClient: DownloadClientService {
    let kind = IntegrationKind.sabnzbd
    private let rest: RESTClient
    private let apiKey: String

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint)
        self.apiKey = apiKey
    }

    private func call(_ parameters: [String: String]) async throws -> Data {
        let query = (parameters.merging(["output": "json", "apikey": apiKey]) { $1 })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await rest.data(.get("api", query: query))
        if let status = try? JSONDecoder().decode(SABStatusResponse.self, from: data), status.status == false {
            let message = status.error ?? "SABnzbd reported a failure."
            throw message.localizedCaseInsensitiveContains("api key") ? NetworkError.unauthorized : NetworkError.graphQL([message])
        }
        return data
    }

    func overview() async throws -> DownloadOverview {
        let queue = try RESTClient.decode(SABQueueResponse.self, from: try await call(["mode": "queue", "limit": "100"])).queue
        return DownloadOverview(
            version: queue.version,
            downloadRate: Int64((Double(queue.kbpersec ?? "") ?? 0) * 1024),
            uploadRate: nil,
            isPaused: queue.paused,
            items: queue.slots.map(\.transferItem)
        )
    }

    func pause(_ ids: [String]) async throws { _ = try await call(["mode": "queue", "name": "pause", "value": ids.joined(separator: ",")]) }
    func resume(_ ids: [String]) async throws { _ = try await call(["mode": "queue", "name": "resume", "value": ids.joined(separator: ",")]) }
    func pauseAll() async throws { _ = try await call(["mode": "pause"]) }
    func resumeAll() async throws { _ = try await call(["mode": "resume"]) }

    func remove(_ ids: [String], deleteData: Bool) async throws {
        _ = try await call(["mode": "queue", "name": "delete", "value": ids.joined(separator: ","), "del_files": deleteData ? "1" : "0"])
    }
}

struct TransmissionTorrent: Decodable, Sendable {
    var id: Int
    var hashString: String
    var name: String
    var status: Int
    var percentDone: Double
    var totalSize: Int64?
    var leftUntilDone: Int64?
    var rateDownload: Int64
    var rateUpload: Int64
    var eta: Int64?
    var error: Int?
    var errorString: String?
    var labels: [String]?

    var transferState: TransferState {
        if let error, error != 0 { return .failed }
        switch status {
        case 0: return percentDone >= 1 ? .completed : .paused
        case 1, 2: return .checking
        case 3, 5: return .queued
        case 4: return .downloading
        case 6: return .seeding
        default: return .unknown
        }
    }

    var transferItem: TransferItem {
        TransferItem(
            id: hashString,
            name: name,
            state: transferState,
            progress: percentDone,
            size: totalSize,
            remaining: leftUntilDone,
            downloadRate: rateDownload,
            uploadRate: rateUpload,
            eta: eta.flatMap { $0 < 0 ? nil : TimeInterval($0) },
            category: labels?.first,
            message: errorString?.nilIfEmpty
        )
    }
}

/// Transmission's RPC as documented through 4.0.x; 4.1 still accepts it. Requires the session-id handshake.
final class TransmissionClient: DownloadClientService {
    let kind = IntegrationKind.transmission
    private let rest: RESTClient
    private let sessionID = OSAllocatedUnfairLock<String?>(initialState: nil)
    static let sessionHeader = "X-Transmission-Session-Id"

    init(url: URL, username: String?, password: String?, pinnedFingerprint: String?) {
        var headers: [String: String] = [:]
        if let username = username?.nilIfEmpty {
            headers["Authorization"] = "Basic " + Data("\(username):\(password ?? "")".utf8).base64EncodedString()
        }
        let rpcURL = url.path.hasSuffix("/rpc") ? url : url.appending(path: "transmission/rpc")
        rest = RESTClient(baseURL: rpcURL, pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    private struct Envelope<Arguments: Decodable>: Decodable {
        var result: String
        var arguments: Arguments?
    }

    private struct Empty: Decodable {}

    private func call<Arguments: Decodable>(_ method: String, _ arguments: [String: Any] = [:], as type: Arguments.Type) async throws -> Arguments {
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments])
        for _ in 0..<2 {
            var request = RESTRequest(method: "POST", path: "", body: .json(body))
            if let id = sessionID.withLock({ $0 }) { request.headers[Self.sessionHeader] = id }
            let (data, response) = try await rest.raw(request)
            if response.statusCode == 409, let id = response.value(forHTTPHeaderField: Self.sessionHeader) {
                sessionID.withLock { $0 = id }
                continue
            }
            try RESTClient.validate(response, data: data)
            let envelope = try RESTClient.decode(Envelope<Arguments>.self, from: data)
            guard envelope.result == "success" else { throw NetworkError.graphQL([envelope.result]) }
            guard let arguments = envelope.arguments else { throw NetworkError.unexpectedResponse("Transmission returned no arguments.") }
            return arguments
        }
        throw NetworkError.unexpectedResponse("Transmission kept rejecting the session ID.")
    }

    func overview() async throws -> DownloadOverview {
        struct Session: Decodable { var version: String? }
        struct Stats: Decodable { var downloadSpeed: Int64; var uploadSpeed: Int64 }
        struct Torrents: Decodable { var torrents: [TransmissionTorrent] }
        let session = try await call("session-get", ["fields": ["version"]], as: Session.self)
        let stats = try await call("session-stats", as: Stats.self)
        let fields = ["id", "hashString", "name", "status", "percentDone", "totalSize", "leftUntilDone", "rateDownload", "rateUpload", "eta", "error", "errorString", "labels"]
        let torrents = try await call("torrent-get", ["fields": fields], as: Torrents.self).torrents
        return DownloadOverview(
            version: session.version,
            downloadRate: stats.downloadSpeed,
            uploadRate: stats.uploadSpeed,
            isPaused: nil,
            items: torrents.map(\.transferItem)
        )
    }

    func pause(_ ids: [String]) async throws { _ = try await call("torrent-stop", ["ids": ids], as: Empty.self) }
    func resume(_ ids: [String]) async throws { _ = try await call("torrent-start", ["ids": ids], as: Empty.self) }
    func pauseAll() async throws { _ = try await call("torrent-stop", as: Empty.self) }
    func resumeAll() async throws { _ = try await call("torrent-start", as: Empty.self) }

    func remove(_ ids: [String], deleteData: Bool) async throws {
        _ = try await call("torrent-remove", ["ids": ids, "delete-local-data": deleteData], as: Empty.self)
    }
}

extension TransmissionClient: TorrentDiagnosticsService {
    struct TrackerStat: Decodable {
        var id: Int?
        var announce: String?
        var host: String?
        var hasAnnounced: Bool?
        var lastAnnounceSucceeded: Bool?
        var lastAnnounceResult: String?
        var announceState: Int?
        var seederCount: Int?
        var leecherCount: Int?
    }

    static func tracker(_ raw: TrackerStat, index: Int) -> TorrentTracker {
        // announceState: 0 inactive, 1 waiting, 2 queued, 3 announcing (tr_tracker_state).
        let status: TorrentTracker.Status = if raw.announceState == 3 { .updating }
            else if raw.hasAnnounced != true { .notContacted }
            else if raw.lastAnnounceSucceeded == true { .working }
            else { .notWorking }
        return TorrentTracker(id: "\(raw.id ?? index)", host: raw.announce.map(TorrentTracker.host(of:)) ?? raw.host ?? "Tracker", status: status,
                              message: raw.lastAnnounceSucceeded == true ? nil : raw.lastAnnounceResult?.nilIfEmpty,
                              seeds: raw.seederCount.flatMap { $0 >= 0 ? $0 : nil }, peers: raw.leecherCount.flatMap { $0 >= 0 ? $0 : nil })
    }

    func trackers(for itemID: String) async throws -> [TorrentTracker] {
        struct Torrent: Decodable { var trackerStats: [TrackerStat]? }
        struct Torrents: Decodable { var torrents: [Torrent] }
        let torrents = try await call("torrent-get", ["ids": [itemID], "fields": ["trackerStats"]], as: Torrents.self).torrents
        return (torrents.first?.trackerStats ?? []).enumerated().map { Self.tracker($1, index: $0) }
    }

    func verify(_ itemID: String) async throws {
        _ = try await call("torrent-verify", ["ids": [itemID]], as: Empty.self)
    }
}
