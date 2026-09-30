import Foundation

/// Plex Media Server local API with an `X-Plex-Token`; responses are requested as JSON `MediaContainer`s.
struct PlexClient: MediaServerService {
    let kind = IntegrationKind.plex
    private let rest: RESTClient

    var capabilities: MediaCapabilities {
        MediaCapabilities(sessionCommands: false, terminateSessions: true, refreshPerLibrary: true, resumeNeedsUser: false, libraryMaintenance: true)
    }

    init(url: URL, token: String, clientID: UUID, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: [
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": clientID.uuidString,
            "X-Plex-Product": "Petty: Homelab",
        ])
    }

    struct Container<Payload: Decodable>: Decodable {
        var MediaContainer: Payload
    }

    struct Identity: Decodable {
        var machineIdentifier: String?
        var version: String?
    }

    struct ServerRoot: Decodable {
        var friendlyName: String?
        var version: String?
    }

    struct Directory: Decodable {
        var key: String
        var title: String
        var type: String?
        var refreshing: Bool?
    }

    struct Metadata: Decodable {
        struct UserInfo: Decodable { var title: String? }
        struct PlayerInfo: Decodable { var title: String?; var product: String?; var state: String? }
        struct SessionInfo: Decodable { var id: String?; var bandwidth: Int?; var location: String? }
        /// Only descriptive fields; parts also carry file paths.
        struct MediaInfo: Decodable {
            struct PartInfo: Decodable {
                struct StreamInfo: Decodable {
                    var id: Int?
                    var index: Int?
                    var streamType: Int?
                    var displayTitle: String?
                    var extendedDisplayTitle: String?
                    var selected: Bool?
                }
                var Stream: [StreamInfo]?
            }
            var selected: Bool?
            var Part: [PartInfo]?
        }
        struct TranscodeInfo: Decodable {
            var videoDecision: String?
            var audioDecision: String?
            var progress: Double?
            var speed: Double?
            var throttled: Bool?
            var transcodeHwFullPipeline: Bool?
            var transcodeHwRequested: Bool?
            var sourceVideoCodec: String?
            var sourceAudioCodec: String?
        }

        var ratingKey: String?
        var sessionKey: String?
        var title: String?
        var type: String?
        var grandparentTitle: String?
        var parentTitle: String?
        var parentIndex: Int?
        var index: Int?
        var year: Int?
        var addedAt: Int?
        var viewOffset: Double?
        var duration: Double?
        var User: UserInfo?
        var Player: PlayerInfo?
        var Session: SessionInfo?
        var TranscodeSession: TranscodeInfo?
        var Media: [MediaInfo]?
        var viewedAt: Int?

        var streams: [MediaStreamInfo] {
            let media = Media?.first { $0.selected == true } ?? Media?.first
            return (media?.Part ?? []).flatMap { $0.Stream ?? [] }.compactMap { stream in
                let kind: MediaStreamInfo.Kind
                switch stream.streamType {
                case 1: kind = .video
                case 2: kind = .audio
                case 3: kind = .subtitle
                default: return nil
                }
                return MediaStreamInfo(index: stream.index ?? stream.id ?? 0, kind: kind,
                                       title: stream.extendedDisplayTitle ?? stream.displayTitle ?? kind.rawValue.capitalizedFirst,
                                       isSelected: kind == .video || stream.selected == true)
            }
        }

        var headline: String {
            switch type {
            case "episode": grandparentTitle ?? title ?? "Episode"
            case "track": title ?? "Track"
            default: title ?? "Untitled"
            }
        }

        var detail: String? {
            switch type {
            case "episode":
                let code = parentIndex.flatMap { season in index.map { "S\(String(format: "%02d", season))E\(String(format: "%02d", $0))" } }
                return [code, title].compactMap { $0 }.joined(separator: " · ")
            case "track": return [grandparentTitle, parentTitle].compactMap { $0 }.joined(separator: " — ")
            case "season": return parentTitle.map { "\($0) · \(title ?? "")" } ?? title
            default: return year.map(String.init)
            }
        }

        var mediaItem: MediaItem {
            MediaItem(
                id: ratingKey ?? UUID().uuidString,
                title: headline,
                subtitle: detail,
                addedAt: addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                progress: viewOffset.flatMap { offset in duration.map { $0 > 0 ? offset / $0 : 0 } }
            )
        }

        var mediaSession: MediaSession {
            let transcode = TranscodeSession
            let method: MediaPlayMethod
            if transcode?.videoDecision == "transcode" || transcode?.audioDecision == "transcode" {
                method = .transcode
            } else if transcode != nil {
                method = .directStream
            } else {
                method = .directPlay
            }
            return MediaSession(
                id: Session?.id ?? sessionKey ?? ratingKey ?? UUID().uuidString,
                user: User?.title,
                client: Player?.product,
                device: Player?.title,
                title: headline,
                subtitle: detail,
                isPaused: Player?.state == "paused",
                position: viewOffset.map { $0 / 1000 },
                duration: duration.map { $0 / 1000 },
                playMethod: method,
                transcode: method == .transcode ? MediaTranscode(
                    videoCodec: transcode?.videoDecision == "transcode" ? "video" : nil,
                    audioCodec: transcode?.audioDecision == "transcode" ? "audio" : nil,
                    reasons: [transcode?.videoDecision.map { "Video: \($0)" }, transcode?.audioDecision.map { "Audio: \($0)" }].compactMap { $0 },
                    progress: transcode?.progress.map { $0 / 100 },
                    speed: transcode?.speed,
                    hardwareAccelerated: transcode?.transcodeHwFullPipeline ?? transcode?.transcodeHwRequested,
                    throttled: transcode?.throttled
                ) : nil,
                supportsRemoteControl: false,
                streams: streams,
                location: Session?.location,
                bandwidthKbps: Session?.bandwidth
            )
        }
    }

    struct MetadataList: Decodable {
        var Metadata: [Metadata]?
    }

    struct DirectoryList: Decodable {
        var Directory: [Directory]?
    }

    struct HubList: Decodable {
        struct HubInfo: Decodable { var Metadata: [Metadata]? }
        var Hub: [HubInfo]?
    }

    func info() async throws -> MediaServerInfo {
        let data = try await rest.data(.get(""))
        let root: ServerRoot
        if let wrapped = try? RESTClient.decode(Container<ServerRoot>.self, from: data).MediaContainer {
            root = wrapped
        } else {
            root = try RESTClient.decode(ServerRoot.self, from: data)
        }
        return MediaServerInfo(name: root.friendlyName ?? "Plex Media Server", version: root.version, updateAvailable: nil)
    }

    func libraries() async throws -> [MediaLibrary] {
        let list: DirectoryList
        do {
            list = try await rest.json(.get("library/sections"), as: Container<DirectoryList>.self).MediaContainer
        } catch NetworkError.apiNotFound {
            list = try await rest.json(.get("library/sections/all"), as: Container<DirectoryList>.self).MediaContainer
        }
        return (list.Directory ?? []).map {
            MediaLibrary(id: $0.key, name: $0.title, kind: MediaLibraryKind(collectionType: $0.type), isRefreshing: $0.refreshing ?? false)
        }
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        let query = [URLQueryItem(name: "X-Plex-Container-Start", value: "0"), URLQueryItem(name: "X-Plex-Container-Size", value: String(limit))]
        return (try await rest.json(.get("library/recentlyAdded", query: query), as: Container<MetadataList>.self).MediaContainer.Metadata ?? [])
            .map(\.mediaItem)
    }

    func continueWatching(userID: String?, limit: Int) async throws -> [MediaItem] {
        let hubs = try await rest.json(.get("hubs/continueWatching"), as: Container<HubList>.self).MediaContainer.Hub ?? []
        return Array(hubs.flatMap { $0.Metadata ?? [] }.prefix(limit)).map(\.mediaItem)
    }

    func sessions() async throws -> [MediaSession] {
        (try await rest.json(.get("status/sessions"), as: Container<MetadataList>.self).MediaContainer.Metadata ?? []).map(\.mediaSession)
    }

    func users() async throws -> [MediaUser] { [] }

    func send(_ command: MediaSessionCommand, to sessionID: String) async throws {
        throw NetworkError.unsupportedByServer("Plex doesn't accept playback commands for other devices' sessions.")
    }

    func terminate(sessionID: String, reason: String) async throws {
        let query = [URLQueryItem(name: "sessionId", value: sessionID), URLQueryItem(name: "reason", value: reason)]
        let (data, response) = try await rest.raw(RESTRequest(method: "POST", path: "status/sessions/terminate", query: query))
        if response.statusCode == 401 {
            throw NetworkError.forbidden("Plex only allows stopping streams on servers with an active Plex Pass.")
        }
        try RESTClient.validate(response, data: data)
    }

    func refresh(libraryID: String?) async throws {
        guard let libraryID else { throw NetworkError.unsupportedByServer("Choose a library to scan.") }
        _ = try await rest.data(RESTRequest(method: "POST", path: "library/sections/\(libraryID)/refresh"))
    }

    struct UpdaterStatus: Decodable {
        struct Release: Decodable { var version: String?; var state: String? }
        var Release: [Release]?
    }

    struct ButlerList: Decodable {
        struct Task: Decodable {
            var name: String
            var title: String?
            var description: String?
            var enabled: Bool?
            var interval: Int?
        }
        struct Tasks: Decodable { var ButlerTask: [Task]? }
        var ButlerTasks: Tasks
    }

    struct ActivityList: Decodable {
        struct Activity: Decodable {
            var uuid: String
            var type: String?
            var title: String?
            var subtitle: String?
            var progress: Double?
            var cancellable: Bool?
        }
        var Activity: [Activity]?
    }

    func management() async throws -> MediaManagement {
        var management = MediaManagement()
        // Some servers wrap the updater status in a MediaContainer and some don't.
        if let data = try await MediaManagement.section("Updates", into: &management.unavailable, { try await rest.data(.get("updater/status")) }) {
            let status = (try? RESTClient.decode(Container<UpdaterStatus>.self, from: data).MediaContainer) ?? (try? RESTClient.decode(UpdaterStatus.self, from: data))
            // A listed release means a newer version than the one running is available.
            management.health.updateVersion = status?.Release?.first?.version
        }
        management.tasks = try await MediaManagement.section("Scheduled tasks", into: &management.unavailable) {
            (try await rest.json(.get("butler"), as: ButlerList.self).ButlerTasks.ButlerTask ?? []).map { task in
                MediaTask(id: task.name, name: task.title ?? task.name, detail: [task.description, task.interval.map { "Every \($0) day\($0 == 1 ? "" : "s")" }, task.enabled == false ? "Disabled" : nil]
                    .compactMap { $0 }.joined(separator: " · ").nilIfEmpty, state: .idle)
            }
        }
        management.activities = try await MediaManagement.section("Background activity", into: &management.unavailable) {
            (try await rest.json(.get("activities"), as: Container<ActivityList>.self).MediaContainer.Activity ?? []).map { activity in
                MediaTask(id: activity.uuid, name: activity.title ?? activity.type ?? "Activity", detail: activity.subtitle, state: .running,
                          progress: activity.progress.map { $0 / 100 }, cancellable: activity.cancellable ?? false)
            }
        }
        management.history = try await MediaManagement.section("Playback history", into: &management.unavailable) {
            let query = [URLQueryItem(name: "sort", value: "viewedAt:desc"), URLQueryItem(name: "X-Plex-Container-Start", value: "0"), URLQueryItem(name: "X-Plex-Container-Size", value: "25")]
            return (try await rest.json(.get("status/sessions/history/all", query: query), as: Container<MetadataList>.self).MediaContainer.Metadata ?? []).enumerated().map { offset, item in
                MediaHistoryEntry(id: "\(item.viewedAt ?? 0)-\(offset)", title: item.headline, detail: item.detail?.nilIfEmpty,
                                  date: item.viewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }
        }
        return management
    }

    func perform(_ action: MediaAdminAction) async throws {
        let request: RESTRequest
        switch action {
        case .runTask(let name): request = RESTRequest(method: "POST", path: "butler/\(name)")
        case .stopTask(let name): request = RESTRequest(method: "DELETE", path: "butler/\(name)")
        case .cancelActivity(let id): request = .delete("activities/\(id)")
        case .refreshMetadata(let library): request = .post("library/sections/\(library)/refresh", query: [URLQueryItem(name: "force", value: "1")])
        case .analyze(let library): request = RESTRequest(method: "PUT", path: "library/sections/\(library)/analyze")
        case .emptyTrash(let library): request = RESTRequest(method: "PUT", path: "library/sections/\(library)/emptyTrash")
        case .plex(.optimizeDatabase): request = RESTRequest(method: "PUT", path: "library/optimize")
        case .plex(.cleanBundles): request = RESTRequest(method: "PUT", path: "library/clean/bundles")
        case .plex(.checkForUpdates): request = RESTRequest(method: "PUT", path: "updater/check")
        case .restartServer, .removeDevice, .message, .setStream:
            throw NetworkError.unsupportedByServer("Plex doesn't offer this action through its server API.")
        }
        _ = try await rest.data(request)
    }
}
