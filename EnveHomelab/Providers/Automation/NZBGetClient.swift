import Foundation

/// NZBGet splits 64-bit values into unsigned 32-bit `…Lo`/`…Hi` fields.
private func combine(_ high: UInt32?, _ low: UInt32?) -> Int64 {
    Int64(UInt64(high ?? 0) << 32 | UInt64(low ?? 0))
}

struct NZBGetStatus: Decodable, Sendable {
    var DownloadRate: Int64?
    var DownloadRateLo: UInt32?
    var DownloadRateHi: UInt32?
    var DownloadPaused: Bool
    var FreeDiskSpaceLo: UInt32?
    var FreeDiskSpaceHi: UInt32?

    /// `DownloadRateLo/Hi` replaced `DownloadRate` in 24.2.
    var downloadRate: Int64 {
        DownloadRateLo != nil ? combine(DownloadRateHi, DownloadRateLo) : DownloadRate ?? 0
    }
}

struct NZBGetGroup: Decodable, Sendable {
    var NZBID: Int
    var NZBName: String
    var Status: String
    var Category: String?
    var FileSizeLo: UInt32
    var FileSizeHi: UInt32
    var RemainingSizeLo: UInt32
    var RemainingSizeHi: UInt32
    var PausedSizeLo: UInt32
    var PausedSizeHi: UInt32
    var Health: Int?
    var CriticalHealth: Int?
    var PostInfoText: String?
    var PostStageProgress: Int?
    var PostStageTimeSec: Int?

    var size: Int64 { combine(FileSizeHi, FileSizeLo) }
    var remaining: Int64 { combine(RemainingSizeHi, RemainingSizeLo) }
    var pausedSize: Int64 { combine(PausedSizeHi, PausedSizeLo) }
    var isPostProcessing: Bool { !["QUEUED", "PAUSED", "DOWNLOADING", "FETCHING"].contains(Status) }
    var isFailing: Bool { if let Health, let CriticalHealth { Health < CriticalHealth } else { false } }

    var transferState: TransferState {
        if isFailing { return .failed }
        switch Status {
        case "DOWNLOADING", "FETCHING": return .downloading
        case "PAUSED": return .paused
        case "QUEUED", "PP_QUEUED", "QS_QUEUED": return .queued
        case "LOADING_PARS", "VERIFYING_SOURCES", "REPAIRING", "VERIFYING_REPAIRED": return .checking
        case "RENAMING", "UNPACKING", "MOVING", "POST_UNPACK_RENAMING", "POST_DOWNLOAD_RENAMING", "EXECUTING_SCRIPT", "QS_EXECUTING": return .importing
        case "PP_FINISHED": return .completed
        default: return .unknown
        }
    }

    /// Mirrors the official web UI: paused parts don't count, and post-processing reports its own stage progress.
    func transferItem(globalRate: Int64) -> TransferItem {
        let total = size - pausedSize
        let left = remaining - pausedSize
        let progress: Double
        var eta: TimeInterval?
        if isPostProcessing, let stage = PostStageProgress {
            progress = Double(stage) / 1000
            if stage > 0, let seconds = PostStageTimeSec { eta = Double(seconds) / Double(stage) * Double(1000 - stage) }
        } else {
            progress = total > 0 ? Double(total - left) / Double(total) : 0
            if Status != "PAUSED", globalRate > 0 { eta = Double(left) / Double(globalRate) }
        }
        return TransferItem(
            id: String(NZBID),
            name: NZBName,
            state: transferState,
            progress: progress,
            size: size,
            remaining: remaining,
            downloadRate: nil,
            eta: eta,
            category: Category?.nilIfEmpty,
            message: isFailing ? "Too many missing articles to repair" : (isPostProcessing ? PostInfoText?.nilIfEmpty : nil)
        )
    }
}

/// NZBGet JSON-RPC (`POST /jsonrpc`, positional params, HTTP Basic auth with the Control or Restricted user).
struct NZBGetClient: DownloadClientService {
    let kind = IntegrationKind.nzbget
    private let rest: RESTClient

    init(url: URL, username: String?, password: String?, pinnedFingerprint: String?) {
        var headers: [String: String] = [:]
        if let password = password?.nilIfEmpty {
            headers["Authorization"] = "Basic " + Data("\(username ?? ""):\(password)".utf8).base64EncodedString()
        }
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    private struct Envelope<Result: Decodable>: Decodable {
        struct RPCError: Decodable { var code: Int; var message: String }
        var result: Result?
        var error: RPCError?
    }

    private struct Call: Encodable {
        var method: String
        var params: [Param]
        var id = 1
    }

    enum Param: Encodable, Sendable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case ints([Int])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .ints(let value): try container.encode(value)
            }
        }
    }

    private func call<Result: Decodable>(_ method: String, _ params: [Param] = [], as type: Result.Type) async throws -> Result {
        let envelope = try await rest.json(try .post("jsonrpc", json: Call(method: method, params: params)), as: Envelope<Result>.self)
        if let error = envelope.error {
            throw error.code == 401 ? NetworkError.forbidden(error.message) : NetworkError.graphQL([error.message])
        }
        guard let result = envelope.result else { throw NetworkError.unexpectedResponse("NZBGet returned no result for \(method).") }
        return result
    }

    func overview() async throws -> DownloadOverview {
        async let version = call("version", as: String.self)
        async let status = call("status", as: NZBGetStatus.self)
        async let groups = call("listgroups", [.int(0)], as: [NZBGetGroup].self)
        let rate = try await status.downloadRate
        return try await DownloadOverview(
            version: version,
            downloadRate: rate,
            uploadRate: nil,
            isPaused: status.DownloadPaused,
            items: groups.map { $0.transferItem(globalRate: rate) }
        )
    }

    private func edit(_ command: String, _ ids: [String]) async throws {
        let ok = try await call("editqueue", [.string(command), .string(""), .ints(ids.compactMap { Int($0) })], as: Bool.self)
        guard ok else { throw NetworkError.unexpectedResponse("NZBGet didn't find that item in its queue.") }
    }

    func pause(_ ids: [String]) async throws { try await edit("GroupPause", ids) }
    func resume(_ ids: [String]) async throws { try await edit("GroupResume", ids) }
    func pauseAll() async throws { _ = try await call("pausedownload", as: Bool.self) }
    func resumeAll() async throws { _ = try await call("resumedownload", as: Bool.self) }

    /// Parking keeps already-downloaded files; `GroupDelete` removes them from the intermediate folder.
    func remove(_ ids: [String], deleteData: Bool) async throws {
        try await edit(deleteData ? "GroupDelete" : "GroupParkDelete", ids)
    }
}
