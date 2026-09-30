import Foundation

struct MediaServerInfo: Sendable, Hashable {
    var name: String
    var version: String?
    var updateAvailable: Bool?
}

enum MediaLibraryKind: String, Sendable {
    case movies, shows, music, photos, other

    init(collectionType: String?) {
        switch collectionType?.lowercased() {
        case "movies", "movie": self = .movies
        case "tvshows", "show": self = .shows
        case "music", "artist": self = .music
        case "photos", "photo", "homevideos": self = .photos
        default: self = .other
        }
    }

    var systemImage: String {
        switch self {
        case .movies: "film"
        case .shows: "tv"
        case .music: "music.note"
        case .photos: "photo.on.rectangle"
        case .other: "folder"
        }
    }
}

struct MediaLibrary: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var kind: MediaLibraryKind
    var isRefreshing: Bool
    var refreshProgress: Double?
}

struct MediaItem: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var addedAt: Date?
    var progress: Double?
}

enum MediaPlayMethod: String, Sendable {
    case directPlay, directStream, transcode, unknown

    var displayName: String {
        switch self {
        case .directPlay: "Direct play"
        case .directStream: "Direct stream"
        case .transcode: "Transcode"
        case .unknown: "Playing"
        }
    }
}

struct MediaTranscode: Sendable, Hashable {
    var videoCodec: String?
    var audioCodec: String?
    var reasons: [String]
    var progress: Double?
    var speed: Double?
    var hardwareAccelerated: Bool?
    var throttled: Bool?
}

/// A track the session is playing, or could switch to.
struct MediaStreamInfo: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable { case video, audio, subtitle }

    var index: Int
    var kind: Kind
    var title: String
    var isSelected: Bool

    var id: String { "\(kind.rawValue):\(index)" }
}

struct MediaSession: Sendable, Hashable, Identifiable {
    var id: String
    var user: String?
    var client: String?
    var device: String?
    var title: String
    var subtitle: String?
    var isPaused: Bool
    var position: TimeInterval?
    var duration: TimeInterval?
    var playMethod: MediaPlayMethod
    var transcode: MediaTranscode?
    var supportsRemoteControl: Bool
    var streams: [MediaStreamInfo] = []
    /// "lan" or "wan" when the server reports it.
    var location: String?
    var bandwidthKbps: Int?
    /// Jellyfin and Emby general commands the client advertises, e.g. `DisplayMessage`, `SetSubtitleStreamIndex`.
    var supportedCommands: Set<String> = []

    var selectedAudio: MediaStreamInfo? { streams.first { $0.kind == .audio && $0.isSelected } }
    var selectedSubtitle: MediaStreamInfo? { streams.first { $0.kind == .subtitle && $0.isSelected } }
    var canMessage: Bool { supportedCommands.contains("DisplayMessage") }
    func canSwitch(_ kind: MediaStreamInfo.Kind) -> Bool {
        supportedCommands.contains(kind == .audio ? "SetAudioStreamIndex" : "SetSubtitleStreamIndex") && streams.contains { $0.kind == kind }
    }

    var progress: Double? {
        guard let position, let duration, duration > 0 else { return nil }
        return min(1, position / duration)
    }
}

struct MediaUser: Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var isAdministrator: Bool?
    var isDisabled: Bool?
    var lastActivity: Date?
}

enum MediaSessionCommand: String, Sendable, Identifiable {
    case pause = "Pause"
    case unpause = "Unpause"
    case stop = "Stop"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pause: "Pause"
        case .unpause: "Resume"
        case .stop: "Stop Playback"
        }
    }

    var systemImage: String {
        switch self {
        case .pause: "pause.fill"
        case .unpause: "play.fill"
        case .stop: "stop.fill"
        }
    }
}

struct MediaCapabilities: Sendable {
    /// Jellyfin and Emby forward playstate commands to clients that support remote control.
    var sessionCommands: Bool
    /// Plex terminates sessions; the server rejects it without Plex Pass.
    var terminateSessions: Bool
    var refreshPerLibrary: Bool
    var resumeNeedsUser: Bool
    /// Plex offers per-library metadata refresh, analysis and trash emptying.
    var libraryMaintenance = false
}

protocol MediaServerService: IntegrationService {
    var kind: IntegrationKind { get }
    var capabilities: MediaCapabilities { get }
    func info() async throws -> MediaServerInfo
    func libraries() async throws -> [MediaLibrary]
    func recentlyAdded(limit: Int) async throws -> [MediaItem]
    func continueWatching(userID: String?, limit: Int) async throws -> [MediaItem]
    func sessions() async throws -> [MediaSession]
    func users() async throws -> [MediaUser]
    func send(_ command: MediaSessionCommand, to sessionID: String) async throws
    func terminate(sessionID: String, reason: String) async throws
    func refresh(libraryID: String?) async throws
    func management() async throws -> MediaManagement
    func perform(_ action: MediaAdminAction) async throws
    /// Whole-server item totals, where the server reports them.
    func itemCounts() async throws -> MediaItemCounts?
}

/// Jellyfin's and Emby's `/Items/Counts`; zero counts are omitted when shown.
struct MediaItemCounts: Decodable, Sendable, Equatable {
    var MovieCount: Int?
    var SeriesCount: Int?
    var EpisodeCount: Int?
    var ArtistCount: Int?
    var AlbumCount: Int?
    var SongCount: Int?
    var MusicVideoCount: Int?
    var BookCount: Int?
    var BoxSetCount: Int?

    var entries: [(label: String, count: Int)] {
        [("Movies", MovieCount), ("Series", SeriesCount), ("Episodes", EpisodeCount), ("Artists", ArtistCount), ("Albums", AlbumCount),
         ("Songs", SongCount), ("Music videos", MusicVideoCount), ("Books", BookCount), ("Collections", BoxSetCount)]
            .compactMap { label, count in count.flatMap { $0 > 0 ? (label, $0) : nil } }
    }
}

extension MediaServerService {
    func itemCounts() async throws -> MediaItemCounts? { nil }

    func summary() async throws -> IntegrationSummary {
        async let info = info()
        async let sessions = sessions()
        let active = try await sessions
        let transcodes = active.filter { $0.playMethod == .transcode }.count
        let server = try await info
        return IntegrationSummary(
            product: kind.displayName,
            version: server.version,
            health: .ok,
            headline: active.isEmpty ? "Nothing playing" : "\(active.count) playing",
            detail: transcodes > 0 ? "\(transcodes) transcoding" : (server.updateAvailable == true ? "Update available" : server.name)
        )
    }
}

enum Ticks {
    /// Jellyfin and Emby express durations in 100-nanosecond ticks.
    static func seconds(_ ticks: Int64?) -> TimeInterval? {
        ticks.map { TimeInterval($0) / 10_000_000 }
    }
}
