import Foundation

struct QuiInstance: Decodable, Sendable {
    var id: Int
    var name: String
    var isActive: Bool
    var connected: Bool?
    var connectionError: String?
}

struct QuiTransferInfo: Decodable, Sendable {
    var dl_info_speed: Int64
    var up_info_speed: Int64
}

struct QuiTorrents: Decodable, Sendable {
    var torrents: [QBittorrentTorrent]
}

struct QuiVersion: Decodable, Sendable {
    var version: String
}

/// qui (autobrr) REST API with an `X-API-Key`. Torrents are listed per instance, and item IDs carry `instance:hash`.
struct QuiClient: DownloadClientService {
    let kind = IntegrationKind.qui
    static let pageSize = 200
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: ["X-API-Key": apiKey])
    }

    static func itemID(instance: Int, hash: String) -> String { "\(instance):\(hash)" }

    static func split(_ ids: [String]) -> [Int: [String]] {
        var groups: [Int: [String]] = [:]
        for id in ids {
            let parts = id.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let instance = Int(parts[0]) else { continue }
            groups[instance, default: []].append(String(parts[1]))
        }
        return groups
    }

    func overview() async throws -> DownloadOverview {
        async let version = try? rest.json(.get("version"), as: QuiVersion.self)
        let instances = try await rest.json(.get("instances"), as: [QuiInstance].self)
        var items: [TransferItem] = []
        var down: Int64 = 0
        var up: Int64 = 0
        let active = instances.filter(\.isActive)
        let reachable = active.filter { $0.connected != false }
        if !active.isEmpty, reachable.isEmpty {
            throw NetworkError.graphQL(["qui can't reach any of its qBittorrent instances: " + active.map { "\($0.name) (\($0.connectionError?.nilIfEmpty ?? "disconnected"))" }.joined(separator: ", ")])
        }
        for instance in reachable {
            async let transfer = rest.json(.get("instances/\(instance.id)/transfer-info"), as: QuiTransferInfo.self)
            async let torrents = rest.json(.get("instances/\(instance.id)/torrents", query: [
                URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "sort", value: "added_on"), URLQueryItem(name: "order", value: "desc"),
            ]), as: QuiTorrents.self)
            let (info, list) = try await (transfer, torrents)
            down += info.dl_info_speed
            up += info.up_info_speed
            items += list.torrents.map { torrent in
                var item = torrent.transferItem
                item.id = Self.itemID(instance: instance.id, hash: torrent.hash)
                item.subtitle = instance.name
                return item
            }
        }
        return await DownloadOverview(version: version?.version, downloadRate: down, uploadRate: up, isPaused: nil, items: items)
    }

    private struct BulkAction: Encodable {
        var hashes: [String]
        var action: String
        var deleteFiles: Bool?
    }

    /// Always names the torrents explicitly; qui's `selectAll` would act on every matching torrent.
    private func act(_ action: String, _ ids: [String], deleteFiles: Bool? = nil) async throws {
        for (instance, hashes) in Self.split(ids) {
            _ = try await rest.data(try .post("instances/\(instance)/torrents/bulk-action", json: BulkAction(hashes: hashes, action: action, deleteFiles: deleteFiles)))
        }
    }

    func pause(_ ids: [String]) async throws { try await act("pause", ids) }
    func resume(_ ids: [String]) async throws { try await act("resume", ids) }

    func pauseAll() async throws {
        try await act("pause", try await overview().items.filter { $0.state.isPausable }.map(\.id))
    }

    func resumeAll() async throws {
        try await act("resume", try await overview().items.filter { $0.state == .paused }.map(\.id))
    }

    func remove(_ ids: [String], deleteData: Bool) async throws {
        try await act("delete", ids, deleteFiles: deleteData)
    }
}
