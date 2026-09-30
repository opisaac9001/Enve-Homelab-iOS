import Foundation

/// Jellyfin and Emby share the MediaBrowser API lineage; they differ in auth header, path prefix and a few list endpoints.
struct MediaBrowserClient: MediaServerService {
    let kind: IntegrationKind
    private let rest: RESTClient

    var capabilities: MediaCapabilities {
        MediaCapabilities(sessionCommands: true, terminateSessions: false, refreshPerLibrary: true, resumeNeedsUser: true)
    }

    init(kind: IntegrationKind, url: URL, apiKey: String, deviceID: UUID, pinnedFingerprint: String?) {
        self.kind = kind
        let headers: [String: String]
        var base = url
        if kind == .jellyfin {
            headers = ["Authorization": "MediaBrowser Client=\"Petty: Homelab\", Device=\"iOS\", DeviceId=\"\(deviceID.uuidString)\", Version=\"1.0\", Token=\"\(apiKey)\""]
        } else {
            headers = ["X-Emby-Token": apiKey]
            if !url.path.lowercased().hasSuffix("/emby") { base = url.appending(path: "emby") }
        }
        rest = RESTClient(baseURL: base, pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    private struct QueryResult<Item: Decodable>: Decodable {
        var Items: [Item]
    }

    struct SystemInfo: Decodable {
        var ServerName: String?
        var Version: String?
        var HasUpdateAvailable: Bool?
        var HasPendingRestart: Bool?
        var CanSelfRestart: Bool?
        var OperatingSystemDisplayName: String?
    }

    struct VirtualFolder: Decodable {
        var Name: String?
        var CollectionType: String?
        var ItemId: String?
        var Id: String?
        var RefreshStatus: String?
        var RefreshProgress: Double?
    }

    struct Item: Decodable {
        struct UserDataInfo: Decodable { var PlayedPercentage: Double? }
        var Id: String
        var Name: String?
        var `Type`: String?
        var SeriesName: String?
        var ParentIndexNumber: Int?
        var IndexNumber: Int?
        var ProductionYear: Int?
        var DateCreated: String?
        var AlbumArtist: String?
        var UserData: UserDataInfo?

        var mediaItem: MediaItem {
            MediaItem(id: Id, title: displayTitle, subtitle: subtitle, addedAt: APIDate.parse(DateCreated), progress: UserData?.PlayedPercentage.map { $0 / 100 })
        }

        var displayTitle: String {
            if `Type` == "Episode", let series = SeriesName { return series }
            return Name ?? "Untitled"
        }

        var subtitle: String? {
            switch `Type` {
            case "Episode":
                let code = ParentIndexNumber.flatMap { season in IndexNumber.map { "S\(String(format: "%02d", season))E\(String(format: "%02d", $0))" } }
                return [code, Name].compactMap { $0 }.joined(separator: " · ")
            case "MusicAlbum": return AlbumArtist
            default: return ProductionYear.map(String.init)
            }
        }
    }

    struct Session: Decodable {
        struct PlayStateInfo: Decodable {
            var PositionTicks: Int64?
            var IsPaused: Bool?
            var PlayMethod: String?
            var AudioStreamIndex: Int?
            var SubtitleStreamIndex: Int?
        }

        /// Only descriptive fields; the stream object also carries file paths and delivery URLs.
        struct Stream: Decodable {
            var `Type`: String?
            var Index: Int?
            var DisplayTitle: String?
            var Codec: String?
            var Language: String?
        }

        struct NowPlayingInfo: Decodable {
            var Name: String?
            var SeriesName: String?
            var ParentIndexNumber: Int?
            var IndexNumber: Int?
            var `Type`: String?
            var RunTimeTicks: Int64?
            var MediaStreams: [Stream]?
        }

        struct TranscodingDetails: Decodable {
            var VideoCodec: String?
            var AudioCodec: String?
            var IsVideoDirect: Bool?
            var CompletionPercentage: Double?
            var TranscodeReasons: [String]?
            var HardwareAccelerationType: String?
            var VideoEncoderIsHardware: Bool?
            var Bitrate: Int?
        }

        struct ClientCapabilities: Decodable { var SupportedCommands: [String]? }

        var Id: String
        var UserName: String?
        var Client: String?
        var DeviceName: String?
        var SupportsRemoteControl: Bool?
        var NowPlayingItem: NowPlayingInfo?
        var PlayState: PlayStateInfo?
        var TranscodingInfo: TranscodingDetails?
        /// Jellyfin nests supported commands under `Capabilities`; Emby reports them at the top level.
        var Capabilities: ClientCapabilities?
        var SupportedCommands: [String]?

        var streams: [MediaStreamInfo] {
            (NowPlayingItem?.MediaStreams ?? []).compactMap { stream in
                guard let index = stream.Index else { return nil }
                let kind: MediaStreamInfo.Kind
                let selected: Bool
                switch stream.Type {
                case "Video": kind = .video; selected = true
                case "Audio": kind = .audio; selected = index == PlayState?.AudioStreamIndex
                case "Subtitle": kind = .subtitle; selected = index == PlayState?.SubtitleStreamIndex
                default: return nil
                }
                let title = stream.DisplayTitle ?? [stream.Language, stream.Codec?.uppercased()].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Track \(index)"
                return MediaStreamInfo(index: index, kind: kind, title: title, isSelected: selected)
            }
        }

        var mediaSession: MediaSession? {
            guard let item = NowPlayingItem else { return nil }
            let method: MediaPlayMethod = switch PlayState?.PlayMethod {
            case "DirectPlay": .directPlay
            case "DirectStream": .directStream
            case "Transcode": .transcode
            default: .unknown
            }
            let isEpisode = item.Type == "Episode"
            let code = item.ParentIndexNumber.flatMap { season in item.IndexNumber.map { "S\(season)E\($0)" } }
            return MediaSession(
                id: Id,
                user: UserName,
                client: Client,
                device: DeviceName,
                title: isEpisode ? (item.SeriesName ?? item.Name ?? "Episode") : (item.Name ?? "Unknown"),
                subtitle: isEpisode ? [code, item.Name].compactMap { $0 }.joined(separator: " · ") : nil,
                isPaused: PlayState?.IsPaused ?? false,
                position: Ticks.seconds(PlayState?.PositionTicks),
                duration: Ticks.seconds(item.RunTimeTicks),
                playMethod: method,
                transcode: method == .transcode ? TranscodingInfo.map {
                    MediaTranscode(
                        videoCodec: $0.VideoCodec,
                        audioCodec: $0.AudioCodec,
                        reasons: $0.TranscodeReasons ?? [],
                        progress: $0.CompletionPercentage.map { $0 / 100 },
                        hardwareAccelerated: $0.VideoEncoderIsHardware ?? $0.HardwareAccelerationType.map { $0.lowercased() != "none" }
                    )
                } : nil,
                supportsRemoteControl: SupportsRemoteControl ?? false,
                streams: streams,
                bandwidthKbps: TranscodingInfo?.Bitrate.map { $0 / 1000 },
                supportedCommands: Set(Capabilities?.SupportedCommands ?? SupportedCommands ?? [])
            )
        }
    }

    struct User: Decodable {
        struct UserPolicy: Decodable { var IsAdministrator: Bool?; var IsDisabled: Bool? }
        var Id: String
        var Name: String?
        var LastActivityDate: String?
        var Policy: UserPolicy?

        var mediaUser: MediaUser {
            MediaUser(id: Id, name: Name ?? Id, isAdministrator: Policy?.IsAdministrator, isDisabled: Policy?.IsDisabled, lastActivity: APIDate.parse(LastActivityDate))
        }
    }

    struct ScheduledTask: Decodable {
        struct Result: Decodable { var EndTimeUtc: String?; var Status: String?; var ErrorMessage: String? }
        var Id: String
        var Name: String
        var State: String?
        var Category: String?
        var Description: String?
        var CurrentProgressPercentage: Double?
        var LastExecutionResult: Result?

        var mediaTask: MediaTask {
            MediaTask(id: Id, name: Name, category: Category, detail: Description,
                      state: State == "Running" ? .running : (State == "Cancelling" ? .cancelling : .idle),
                      progress: CurrentProgressPercentage.map { $0 / 100 },
                      lastRun: APIDate.parse(LastExecutionResult?.EndTimeUtc),
                      lastOutcome: LastExecutionResult?.Status.flatMap { MediaTask.Outcome(rawValue: $0.lowercased()) },
                      lastError: LastExecutionResult?.ErrorMessage?.nilIfEmpty)
        }
    }

    /// The device list also carries each device's access token (Jellyfin) or IP address (Emby); neither is decoded.
    struct Device: Decodable {
        var Id: String
        var Name: String?
        var AppName: String?
        var AppVersion: String?
        var LastUserName: String?
        var DateLastActivity: String?
    }

    struct ActivityEntry: Decodable {
        var Id: Int64
        var Name: String
        var ShortOverview: String?
        var Date: String?
        var Severity: String?
    }

    func info() async throws -> MediaServerInfo {
        let info = try await rest.json(.get("System/Info"), as: SystemInfo.self)
        return MediaServerInfo(name: info.ServerName ?? kind.displayName, version: info.Version, updateAvailable: info.HasUpdateAvailable)
    }

    func itemCounts() async throws -> MediaItemCounts? {
        try await rest.json(.get("Items/Counts"), as: MediaItemCounts.self)
    }

    func libraries() async throws -> [MediaLibrary] {
        let folders: [VirtualFolder] = kind == .jellyfin
            ? try await rest.json(.get("Library/VirtualFolders"))
            : try await rest.json(.get("Library/VirtualFolders/Query"), as: QueryResult<VirtualFolder>.self).Items
        return folders.map {
            MediaLibrary(
                id: $0.ItemId ?? $0.Id ?? $0.Name ?? UUID().uuidString,
                name: $0.Name ?? "Library",
                kind: MediaLibraryKind(collectionType: $0.CollectionType),
                isRefreshing: $0.RefreshStatus == "Active",
                refreshProgress: $0.RefreshStatus == "Active" ? $0.RefreshProgress.map { $0 / 100 } : nil
            )
        }
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        let query = [
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,MusicAlbum"),
            URLQueryItem(name: "Fields", value: "DateCreated"),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        return try await rest.json(.get("Items", query: query), as: QueryResult<Item>.self).Items.map(\.mediaItem)
    }

    func continueWatching(userID: String?, limit: Int) async throws -> [MediaItem] {
        guard let userID else { return [] }
        let query = [URLQueryItem(name: "Limit", value: String(limit)), URLQueryItem(name: "Fields", value: "DateCreated")]
        let request: RESTRequest = kind == .jellyfin
            ? .get("UserItems/Resume", query: query + [URLQueryItem(name: "userId", value: userID)])
            : .get("Users/\(userID)/Items/Resume", query: query)
        return try await rest.json(request, as: QueryResult<Item>.self).Items.map(\.mediaItem)
    }

    func sessions() async throws -> [MediaSession] {
        let query = kind == .jellyfin ? [URLQueryItem(name: "activeWithinSeconds", value: "960")] : []
        return try await rest.json(.get("Sessions", query: query), as: [Session].self).compactMap(\.mediaSession)
    }

    func users() async throws -> [MediaUser] {
        let users: [User] = kind == .jellyfin
            ? try await rest.json(.get("Users"))
            : try await rest.json(.get("Users/Query"), as: QueryResult<User>.self).Items
        return users.map(\.mediaUser)
    }

    func send(_ command: MediaSessionCommand, to sessionID: String) async throws {
        _ = try await rest.data(RESTRequest(method: "POST", path: "Sessions/\(sessionID)/Playing/\(command.rawValue)"))
    }

    func terminate(sessionID: String, reason: String) async throws {
        throw NetworkError.unsupportedByServer("\(kind.displayName) stops sessions with the Stop command instead.")
    }

    /// A library refresh with default modes looks for new and changed files without replacing existing metadata.
    func refresh(libraryID: String?) async throws {
        guard let libraryID else {
            _ = try await rest.data(RESTRequest(method: "POST", path: "Library/Refresh"))
            return
        }
        let names = kind == .jellyfin
            ? ["metadataRefreshMode", "imageRefreshMode", "replaceAllMetadata", "replaceAllImages"]
            : ["MetadataRefreshMode", "ImageRefreshMode", "ReplaceAllMetadata", "ReplaceAllImages"]
        var query = zip(names, ["Default", "Default", "false", "false"]).map { URLQueryItem(name: $0, value: $1) }
        if kind == .emby { query.append(URLQueryItem(name: "Recursive", value: "true")) }
        _ = try await rest.data(RESTRequest(method: "POST", path: "Items/\(libraryID)/Refresh", query: query))
    }

    private struct QueryItems<Item: Decodable>: Decodable { var Items: [Item] }

    func management() async throws -> MediaManagement {
        var management = MediaManagement()
        let info = try await rest.json(.get("System/Info"), as: SystemInfo.self)
        management.health = MediaServerHealth(pendingRestart: info.HasPendingRestart, canRestart: info.CanSelfRestart, operatingSystem: info.OperatingSystemDisplayName)
        management.tasks = try await MediaManagement.section("Scheduled tasks", into: &management.unavailable) {
            try await rest.json(.get("ScheduledTasks", query: [URLQueryItem(name: kind == .jellyfin ? "isHidden" : "IsHidden", value: "false")]), as: [ScheduledTask].self)
                .map(\.mediaTask)
                .sorted { ($0.state == .idle ? 1 : 0, $0.category ?? "", $0.name) < ($1.state == .idle ? 1 : 0, $1.category ?? "", $1.name) }
        }
        management.devices = try await MediaManagement.section("Devices", into: &management.unavailable) {
            try await rest.json(.get("Devices"), as: QueryItems<Device>.self).Items.map {
                MediaDevice(id: $0.Id, name: $0.Name ?? $0.Id, app: [$0.AppName, $0.AppVersion].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                            lastUser: $0.LastUserName, lastActive: APIDate.parse($0.DateLastActivity))
            }
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        }
        management.users = try await MediaManagement.section("Users", into: &management.unavailable) { try await users() }
        if kind == .jellyfin {
            management.plugins = try await MediaManagement.section("Plugins", into: &management.unavailable) {
                try await rest.json(.get("Plugins"), as: [PluginInfo].self).map { MediaPlugin(name: $0.Name, version: $0.Version, status: $0.Status) }
                    .sorted { ($0.needsAttention ? 0 : 1, $0.name) < ($1.needsAttention ? 0 : 1, $1.name) }
            }
        } else {
            let system = try await MediaManagement.section("Server updates", into: &management.unavailable) {
                try await rest.json(.get("Packages/Updates", query: [URLQueryItem(name: "PackageType", value: "System")]), as: [PackageVersion].self)
            }
            management.health.updateVersion = system?.first?.versionStr
            management.plugins = try await MediaManagement.section("Plugin updates", into: &management.unavailable) {
                try await rest.json(.get("Packages/Updates", query: [URLQueryItem(name: "PackageType", value: "UserInstalled")]), as: [PackageVersion].self)
                    .map { MediaPlugin(name: $0.name ?? "Plugin", availableUpdate: $0.versionStr) }
            }
        }
        management.history = try await MediaManagement.section("Activity log", into: &management.unavailable) {
            let limit = URLQueryItem(name: kind == .jellyfin ? "limit" : "Limit", value: "25")
            return try await rest.json(.get("System/ActivityLog/Entries", query: [limit]), as: QueryItems<ActivityEntry>.self).Items.map { entry in
                let severity: MediaHistoryEntry.Severity = switch entry.Severity?.lowercased() {
                case "error", "critical", "fatal": .error
                case "warning", "warn": .warning
                default: .info
                }
                return MediaHistoryEntry(id: String(entry.Id), title: entry.Name, detail: entry.ShortOverview?.nilIfEmpty, date: APIDate.parse(entry.Date), severity: severity)
            }
        }
        return management
    }

    private struct Message: Encodable { var Header: String; var Text: String; var TimeoutMs: Int }
    private struct GeneralCommand: Encodable { var Name: String; var Arguments: [String: String] }

    func perform(_ action: MediaAdminAction) async throws {
        let request: RESTRequest
        switch action {
        case .runTask(let id):
            request = RESTRequest(method: "POST", path: "ScheduledTasks/Running/\(id)")
        case .stopTask(let id):
            request = RESTRequest(method: "DELETE", path: "ScheduledTasks/Running/\(id)")
        case .restartServer:
            request = RESTRequest(method: "POST", path: "System/Restart")
        case .removeDevice(let id):
            request = .delete("Devices", query: [URLQueryItem(name: kind == .jellyfin ? "id" : "Id", value: id)])
        case .message(let sessionID, let text):
            let message = Message(Header: "Petty: Homelab", Text: text, TimeoutMs: 10_000)
            request = kind == .jellyfin
                ? try .post("Sessions/\(sessionID)/Message", json: message)
                : .post("Sessions/\(sessionID)/Message", query: [URLQueryItem(name: "Header", value: message.Header), URLQueryItem(name: "Text", value: text),
                                                                  URLQueryItem(name: "TimeoutMs", value: String(message.TimeoutMs))])
        case .setStream(let sessionID, let streamKind, let index):
            let name = streamKind == .audio ? "SetAudioStreamIndex" : "SetSubtitleStreamIndex"
            request = try .post("Sessions/\(sessionID)/Command", json: GeneralCommand(Name: name, Arguments: ["Index": String(index)]))
        case .cancelActivity, .refreshMetadata, .analyze, .emptyTrash, .plex:
            throw NetworkError.unsupportedByServer("\(kind.displayName) doesn't offer this action.")
        }
        _ = try await rest.data(request)
    }
}

extension MediaBrowserClient: ServerLogSource {
    struct PluginInfo: Decodable { var Name: String; var Version: String?; var Status: String? }
    struct PackageVersion: Decodable { var name: String?; var versionStr: String? }
    struct LogFile: Decodable { var Name: String; var Size: Int64?; var DateModified: String? }
    struct LogFiles: Decodable { var Items: [LogFile] }
    struct LogLines: Decodable { var Items: [String] }

    func logFiles() async throws -> [MediaLogFile] {
        let files = kind == .jellyfin
            ? try await rest.json(.get("System/Logs"), as: [LogFile].self)
            : try await rest.json(.get("System/Logs/Query", query: [URLQueryItem(name: "Limit", value: "50")]), as: LogFiles.self).Items
        return files.map { MediaLogFile(name: $0.Name, size: $0.Size, modified: APIDate.parse($0.DateModified)) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Jellyfin returns the file as text; Emby returns its lines as JSON. Either way only the tail is kept, redacted.
    func logLines(_ file: MediaLogFile, limit: Int) async throws -> [String] {
        let lines: [String]
        if kind == .jellyfin {
            let text = String(decoding: try await rest.data(.get("System/Logs/Log", query: [URLQueryItem(name: "name", value: file.name)])), as: UTF8.self)
            lines = text.split(whereSeparator: \.isNewline).map(String.init)
        } else {
            let name = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
            lines = try await rest.json(.get("System/Logs/\(name)/Lines"), as: LogLines.self).Items
        }
        return lines.suffix(limit).map(LogRedactor.redact)
    }
}
