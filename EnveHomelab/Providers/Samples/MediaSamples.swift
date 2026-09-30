import Foundation

actor SampleMediaServer: MediaServerService {
    nonisolated let kind: IntegrationKind
    private var sessionList: [MediaSession]

    private var tasks: [MediaTask]
    private var activities: [MediaTask]
    private var pendingRestart = true

    nonisolated var capabilities: MediaCapabilities {
        kind == .plex
            ? MediaCapabilities(sessionCommands: false, terminateSessions: true, refreshPerLibrary: true, resumeNeedsUser: false, libraryMaintenance: true)
            : MediaCapabilities(sessionCommands: true, terminateSessions: false, refreshPerLibrary: true, resumeNeedsUser: true)
    }

    init(kind: IntegrationKind) {
        self.kind = kind
        sessionList = [
            MediaSession(id: "m1", user: "alex", client: kind == .plex ? "Plex for Apple TV" : "\(kind.displayName) for iOS", device: "Living Room",
                         title: "Our Summer Trip", subtitle: "2024", isPaused: false, position: 1_820, duration: 5_400, playMethod: .directPlay,
                         transcode: nil, supportsRemoteControl: kind != .plex,
                         streams: [MediaStreamInfo(index: 0, kind: .video, title: "4K HEVC HDR", isSelected: true),
                                   MediaStreamInfo(index: 1, kind: .audio, title: "English · EAC3 5.1", isSelected: true),
                                   MediaStreamInfo(index: 2, kind: .audio, title: "Commentary · AAC Stereo", isSelected: false),
                                   MediaStreamInfo(index: 3, kind: .subtitle, title: "English (SDH) · SRT", isSelected: false)],
                         location: "lan", bandwidthKbps: 32_000,
                         supportedCommands: kind == .plex ? [] : ["DisplayMessage", "SetAudioStreamIndex", "SetSubtitleStreamIndex"]),
            MediaSession(id: "m2", user: "sam", client: "Web", device: "Firefox",
                         title: "Garden Diaries", subtitle: "S01E03 · Spring Planting", isPaused: true, position: 600, duration: 2_700, playMethod: .transcode,
                         transcode: MediaTranscode(videoCodec: "h264", audioCodec: "aac", reasons: ["VideoCodecNotSupported"], progress: 0.41, speed: 2.1, hardwareAccelerated: true, throttled: true),
                         supportsRemoteControl: kind != .plex,
                         streams: [MediaStreamInfo(index: 0, kind: .video, title: "1080p H.264", isSelected: true),
                                   MediaStreamInfo(index: 1, kind: .audio, title: "English · AAC Stereo", isSelected: true),
                                   MediaStreamInfo(index: 2, kind: .subtitle, title: "English · SRT", isSelected: true)],
                         location: "wan", bandwidthKbps: 4_000),
        ]
        tasks = kind == .plex ? [
            MediaTask(id: "BackupDatabase", name: "Back Up Database", detail: "Every 3 days", state: .idle),
            MediaTask(id: "OptimizeDatabase", name: "Optimize Database", detail: "Every 7 days", state: .idle),
        ] : [
            MediaTask(id: "t1", name: "Scan Media Library", category: "Library", state: .idle, lastRun: .now.addingTimeInterval(-7_200), lastOutcome: .completed),
            MediaTask(id: "t2", name: "Extract Chapter Images", category: "Library", state: .idle, lastRun: .now.addingTimeInterval(-86_400), lastOutcome: .failed,
                      lastError: "ffmpeg exited with code 1"),
            MediaTask(id: "t3", name: "Clean Transcode Directory", category: "Maintenance", state: .idle, lastRun: .now.addingTimeInterval(-3_600), lastOutcome: .completed),
        ]
        activities = kind == .plex ? [MediaTask(id: "a1", name: "Scanning Home Movies", detail: "Birthday Party.mkv", state: .running, progress: 0.62, cancellable: true)] : []
    }

    func info() async throws -> MediaServerInfo {
        try await Task.sleep(for: .milliseconds(150))
        return MediaServerInfo(name: "Sample \(kind.displayName)", version: kind == .plex ? "1.42.1.10060" : (kind == .emby ? "4.9.1.80" : "10.11.0"), updateAvailable: false)
    }

    func itemCounts() async throws -> MediaItemCounts? {
        kind == .plex ? nil : MediaItemCounts(MovieCount: 412, SeriesCount: 38, EpisodeCount: 1_904, ArtistCount: 120, AlbumCount: 356, SongCount: 4_210, BookCount: 12, BoxSetCount: 9)
    }

    func libraries() async throws -> [MediaLibrary] {
        [
            MediaLibrary(id: "l1", name: "Home Movies", kind: .movies, isRefreshing: kind == .plex, refreshProgress: kind == .plex ? 0.62 : nil),
            MediaLibrary(id: "l2", name: "Recorded Shows", kind: .shows, isRefreshing: false),
            MediaLibrary(id: "l3", name: "Music", kind: .music, isRefreshing: false),
            MediaLibrary(id: "l4", name: "Photos", kind: .photos, isRefreshing: false),
        ]
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        [
            MediaItem(id: "r1", title: "Birthday Party", subtitle: "2025", addedAt: .now.addingTimeInterval(-3_600)),
            MediaItem(id: "r2", title: "Garden Diaries", subtitle: "S01E04 · First Harvest", addedAt: .now.addingTimeInterval(-86_400)),
            MediaItem(id: "r3", title: "Community Choir", subtitle: "Live Recordings", addedAt: .now.addingTimeInterval(-172_800)),
        ]
    }

    func continueWatching(userID: String?, limit: Int) async throws -> [MediaItem] {
        guard !capabilities.resumeNeedsUser || userID != nil else { return [] }
        return [MediaItem(id: "c1", title: "Our Summer Trip", subtitle: "2024", progress: 0.34)]
    }

    func sessions() async throws -> [MediaSession] { sessionList }

    func users() async throws -> [MediaUser] {
        capabilities.resumeNeedsUser ? [
            MediaUser(id: "u1", name: "alex", isAdministrator: true, isDisabled: false, lastActivity: .now.addingTimeInterval(-300)),
            MediaUser(id: "u2", name: "sam", isAdministrator: false, isDisabled: false, lastActivity: .now.addingTimeInterval(-3_600)),
            MediaUser(id: "u3", name: "old-guest", isAdministrator: false, isDisabled: true, lastActivity: .now.addingTimeInterval(-86_400 * 90)),
        ] : []
    }

    func send(_ command: MediaSessionCommand, to sessionID: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
        guard let index = sessionList.firstIndex(where: { $0.id == sessionID }) else { return }
        switch command {
        case .pause: sessionList[index].isPaused = true
        case .unpause: sessionList[index].isPaused = false
        case .stop: sessionList.remove(at: index)
        }
    }

    func terminate(sessionID: String, reason: String) async throws {
        sessionList.removeAll { $0.id == sessionID }
    }

    func refresh(libraryID: String?) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func management() async throws -> MediaManagement {
        try await Task.sleep(for: .milliseconds(150))
        if kind == .plex {
            return MediaManagement(
                health: MediaServerHealth(updateVersion: "1.42.2.10156"),
                tasks: tasks, activities: activities,
                history: [MediaHistoryEntry(id: "h1", title: "Garden Diaries", detail: "S01E02 · Seedlings", date: .now.addingTimeInterval(-7_200)),
                          MediaHistoryEntry(id: "h2", title: "Birthday Party", detail: "2025", date: .now.addingTimeInterval(-86_400))]
            )
        }
        return MediaManagement(
            health: MediaServerHealth(pendingRestart: pendingRestart, canRestart: true, operatingSystem: "Linux"),
            tasks: tasks,
            devices: [MediaDevice(id: "d1", name: "Living Room", app: "\(kind.displayName) for iOS 10.11", lastUser: "alex", lastActive: .now.addingTimeInterval(-60)),
                      MediaDevice(id: "d2", name: "Old Tablet", app: "\(kind.displayName) for Android 10.8", lastUser: "old-guest", lastActive: .now.addingTimeInterval(-86_400 * 120))],
            users: try await users(),
            history: [MediaHistoryEntry(id: "e1", title: "alex is playing Our Summer Trip", detail: "Living Room", date: .now.addingTimeInterval(-600)),
                      MediaHistoryEntry(id: "e2", title: "Failed sign-in attempt by unknown-user", detail: "From 192.0.2.40", date: .now.addingTimeInterval(-5_400), severity: .warning)],
            plugins: kind == .jellyfin
                ? [MediaPlugin(name: "Open Subtitles", version: "20.0.0.0", status: "Malfunctioned"), MediaPlugin(name: "Playback Reporting", version: "16.0.0.0", status: "Active")]
                : [MediaPlugin(name: "Trakt", availableUpdate: "4.5.1.0")]
        )
    }

    func perform(_ action: MediaAdminAction) async throws {
        try await Task.sleep(for: .milliseconds(200))
        switch action {
        case .runTask(let id):
            if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].state = .running; tasks[index].progress = 0.05 }
        case .stopTask(let id):
            if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].state = .idle; tasks[index].progress = nil }
        case .cancelActivity(let id):
            activities.removeAll { $0.id == id }
        case .restartServer:
            pendingRestart = false
        case .setStream(let sessionID, let streamKind, let index):
            guard let session = sessionList.firstIndex(where: { $0.id == sessionID }) else { return }
            for stream in sessionList[session].streams.indices where sessionList[session].streams[stream].kind == streamKind {
                sessionList[session].streams[stream].isSelected = sessionList[session].streams[stream].index == index
            }
        case .removeDevice, .message, .refreshMetadata, .analyze, .emptyTrash, .plex:
            break
        }
    }
}

extension SampleMediaServer: ServerLogSource {
    func logFiles() async throws -> [MediaLogFile] {
        [MediaLogFile(name: kind == .emby ? "embyserver.txt" : "log_20260929.log", size: 812_000, modified: .now.addingTimeInterval(-120)),
         MediaLogFile(name: kind == .emby ? "embyserver-1.txt" : "log_20260928.log", size: 2_400_000, modified: .now.addingTimeInterval(-86_400))]
    }

    func logLines(_ file: MediaLogFile, limit: Int) async throws -> [String] {
        [
            "[2026-09-29 09:12:01.101 +00:00] [INF] Scheduled task \"Scan Media Library\" completed after 2 minute(s)",
            "[2026-09-29 09:40:12.402 +00:00] [WRN] Slow HTTP response from 192.168.1.50 to GET /Items?api_key=abcdef0123456789 in 0:00:02.1",
            "[2026-09-29 10:02:44.009 +00:00] [ERR] Error loading plugin Open Subtitles: could not load assembly",
        ].suffix(limit).map(LogRedactor.redact)
    }
}
