import Foundation

/// Sample data for the labelled sample integrations only.
actor SampleArrService: ArrService {
    nonisolated let kind: IntegrationKind
    private var queue: [ArrQueueItem]
    private var indexers: [ProwlarrIndexer]

    init(kind: IntegrationKind) {
        self.kind = kind
        queue = Self.makeQueue(kind)
        indexers = kind == .prowlarr ? [
            ProwlarrIndexer(id: 1, name: "Community Tracker", isEnabled: true, downloadProtocol: "torrent", privacy: "public"),
            ProwlarrIndexer(id: 2, name: "Usenet Index", isEnabled: true, downloadProtocol: "usenet", privacy: "private"),
            ProwlarrIndexer(id: 3, name: "Archive Mirror", isEnabled: true, downloadProtocol: "torrent", privacy: "semiPrivate", disabledUntil: .now.addingTimeInterval(3_600)),
        ] : []
    }

    func snapshot() async throws -> ArrSnapshot {
        try await Task.sleep(for: .milliseconds(200))
        let health: [ArrHealthItem] = switch kind {
        case .sonarr: [ArrHealthItem(source: "DownloadClientCheck", type: .warning, message: "Download client qBittorrent reported a stalled item", wikiUrl: nil)]
        case .prowlarr: [ArrHealthItem(source: "IndexerStatusCheck", type: .warning, message: "Indexers unavailable due to failures: Archive Mirror", wikiUrl: nil)]
        default: []
        }
        return ArrSnapshot(
            status: ArrSystemStatus(appName: kind.displayName, instanceName: kind.displayName, version: kind == .prowlarr ? "2.0.5.5160" : "5.26.2.10099"),
            health: health,
            queue: queue,
            queueTotal: queue.count,
            diskSpace: kind == .prowlarr ? [] : [ArrDiskSpace(path: "/data", label: "media", freeSpace: 6_400_000_000_000, totalSpace: 24_000_000_000_000)],
            indexers: indexers
        )
    }

    func run(_ command: ArrCommand) async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    func removeFromQueue(id: Int, removeFromClient: Bool, blocklist: Bool) async throws {
        try await Task.sleep(for: .milliseconds(300))
        queue.removeAll { $0.id == id }
    }

    func calendar(from start: Date, to end: Date, includeUnmonitored: Bool) async throws -> [UpcomingItem] {
        let day = 86_400.0
        let midnight = Calendar.current.startOfDay(for: .now)
        let items: [UpcomingItem] = switch kind {
        case .radarr: [
            UpcomingItem(id: "radarr:1", date: midnight.addingTimeInterval(day * 2), isAllDay: true, title: "Sample Documentary", subtitle: "2026", detail: "Digital release", hasFile: false, source: .radarr),
            UpcomingItem(id: "radarr:2", date: midnight.addingTimeInterval(day * 9), isAllDay: true, title: "Open Film Festival Highlights", subtitle: "2026", detail: "Physical release", hasFile: false, source: .radarr),
        ]
        case .sonarr: [
            UpcomingItem(id: "sonarr:1", date: midnight.addingTimeInterval(day + 20 * 3_600), isAllDay: false, title: "Open Source Chronicles", subtitle: "S02E06 · Pull Request", hasFile: false, source: .sonarr),
            UpcomingItem(id: "sonarr:2", date: midnight.addingTimeInterval(-day + 21 * 3_600), isAllDay: false, title: "Community Garden", subtitle: "S01E02 · Seedlings", hasFile: true, source: .sonarr),
        ]
        case .lidarr: [
            UpcomingItem(id: "lidarr:1", date: midnight.addingTimeInterval(day * 5), isAllDay: true, title: "Live at the Library", subtitle: "Community Choir", detail: "Album release", hasFile: false, source: .lidarr),
            UpcomingItem(id: "lidarr:2", date: midnight.addingTimeInterval(day * 3), isAllDay: true, title: "Field Recordings", subtitle: "Community Choir", detail: "Album release", hasFile: false, source: .lidarr, isMonitored: false),
        ]
        default: []
        }
        return items.filter { $0.date >= start && $0.date < end && (includeUnmonitored || $0.isMonitored) }
    }

    func systemDiagnostics() async throws -> ArrSystemDiagnostics {
        try await Task.sleep(for: .milliseconds(150))
        let iso = { (offset: TimeInterval) in Date.now.addingTimeInterval(offset).formatted(.iso8601) }
        let tasks = [
            ArrTask(id: 1, name: "Backup", taskName: "Backup", interval: 10_080, lastExecution: iso(-86_400 * 2), nextExecution: iso(86_400 * 5), lastDuration: "00:00:03.2100000"),
            ArrTask(id: 2, name: "Check Health", taskName: "CheckHealth", interval: 360, lastExecution: iso(-3_600), nextExecution: iso(18_000), lastDuration: "00:00:00.4100000"),
            ArrTask(id: 3, name: "Housekeeping", taskName: "Housekeeping", interval: 1_440, lastExecution: iso(-40_000), nextExecution: iso(46_400), lastDuration: "00:00:01.0200000"),
            ArrTask(id: 4, name: "RSS Sync", taskName: "RssSync", interval: 15, lastExecution: iso(-300), nextExecution: iso(600), lastDuration: "00:00:02.5000000"),
        ]
        let problems = [
            ArrLogEntry(id: 2, time: iso(-900), level: "warn", logger: "DownloadClientCheck", message: "Unable to communicate with SABnzbd. Connection refused"),
            ArrLogEntry(id: 1, time: iso(-7_200), level: "error", logger: "ImportListSyncService", message: "Import list sync failed: HTTP 401", exception: "HttpException: Unauthorized"),
        ]
        return ArrSystemDiagnostics(tasks: tasks, problems: problems, problemTotal: 2,
                                    availableUpdate: ArrUpdate(version: "5.27.0.10202", branch: "master", releaseDate: iso(-86_400), installed: false, installable: true, latest: true,
                                                               changes: .init(new: ["Calendar filters remember their state"], fixed: ["Queue sorting by time left"])),
                                    backups: [ArrBackup(id: 1, name: "\(kind.rawValue)_backup_v5.26.2_2026.09.27.zip", type: "scheduled", size: 4_812_000, time: iso(-86_400 * 2))])
    }

    func runTask(_ task: ArrTask) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func missing(limit: Int) async throws -> ArrMissing {
        let day = 86_400.0
        let midnight = Calendar.current.startOfDay(for: .now)
        let items: [UpcomingItem] = switch kind {
        case .radarr: [
            UpcomingItem(id: "radarr:m1", date: midnight.addingTimeInterval(-day * 12), isAllDay: true, title: "Harbour Lights", subtitle: "2025", detail: "Digital release", hasFile: false, source: .radarr),
        ]
        case .sonarr: [
            UpcomingItem(id: "sonarr:m1", date: midnight.addingTimeInterval(-day * 2 + 21 * 3_600), isAllDay: false, title: "Community Garden", subtitle: "S01E03 · Compost", hasFile: false, source: .sonarr),
            UpcomingItem(id: "sonarr:m2", date: midnight.addingTimeInterval(-day * 30), isAllDay: false, title: "Open Source Chronicles", subtitle: "S01E09 · Forks", hasFile: false, source: .sonarr),
        ]
        default: []
        }
        return ArrMissing(total: items.count, items: Array(items.prefix(limit)))
    }

    func testAllIndexers() async throws {
        try await Task.sleep(for: .milliseconds(600))
        for index in indexers.indices { indexers[index].disabledUntil = nil }
    }

    private static func makeQueue(_ kind: IntegrationKind) -> [ArrQueueItem] {
        func item(_ id: Int, _ title: String, _ media: String, status: String, size: Double, left: Double, eta: TimeInterval?, state: String = "downloading", trackedStatus: String = "ok") -> ArrQueueItem {
            ArrQueueItem(id: id, title: title, mediaTitle: media, status: status, trackedDownloadStatus: trackedStatus, trackedDownloadState: state,
                         size: size, sizeLeft: left, timeLeft: eta, downloadClient: "qBittorrent", downloadProtocol: "torrent", indexer: nil, errorMessage: nil, statusMessages: [])
        }
        switch kind {
        case .radarr:
            return [
                item(101, "Sample.Home.Movie.2024.1080p", "Sample Home Movie (2024)", status: "downloading", size: 8_400_000_000, left: 2_100_000_000, eta: 540),
                item(102, "Family.Holiday.2023.2160p", "Family Holiday (2023)", status: "completed", size: 22_000_000_000, left: 0, eta: nil, state: "importPending"),
            ]
        case .sonarr:
            return [item(201, "Open.Source.Chronicles.S02E05.720p", "Open Source Chronicles · S02E05", status: "downloading", size: 1_200_000_000, left: 900_000_000, eta: nil, trackedStatus: "warning")]
        case .lidarr:
            return [item(301, "Community.Choir-Live.Recordings-FLAC", "Community Choir — Live Recordings", status: "queued", size: 640_000_000, left: 640_000_000, eta: nil)]
        default:
            return []
        }
    }
}

actor SampleDownloadClient: DownloadClientService {
    nonisolated let kind: IntegrationKind
    private var items: [TransferItem]
    private var globallyPaused = false

    init(kind: IntegrationKind) {
        self.kind = kind
        let isUsenet = kind == .sabnzbd || kind == .nzbget
        items = [
            TransferItem(id: "s1", name: isUsenet ? "Linux.Distribution.ISO.Collection" : "debian-13.1.0-amd64-DVD-1.iso", state: .downloading, progress: 0.62, size: 3_900_000_000, remaining: 1_480_000_000, downloadRate: 18_400_000, uploadRate: isUsenet ? nil : 1_200_000, eta: 80, category: "software"),
            TransferItem(id: "s2", name: isUsenet ? "Conference.Talks.2025" : "ubuntu-24.04.3-desktop-amd64.iso", state: isUsenet ? .queued : .seeding, progress: isUsenet ? 0 : 1, size: 6_100_000_000, remaining: isUsenet ? 6_100_000_000 : 0, downloadRate: 0, uploadRate: isUsenet ? nil : 640_000, category: "software"),
            TransferItem(id: "s3", name: isUsenet ? "Home.Video.Backup.Part2" : "public-domain-film-archive.mkv", state: .stalled, progress: 0.18, size: 2_300_000_000, remaining: 1_880_000_000, downloadRate: 0, uploadRate: 0, category: "archive", message: isUsenet ? nil : "No peers"),
        ]
    }

    func overview() async throws -> DownloadOverview {
        try await Task.sleep(for: .milliseconds(200))
        let active = items.filter { $0.state == .downloading }
        let version = switch kind {
        case .sabnzbd: "4.5.3"
        case .qbittorrent: "v5.1.2"
        case .nzbget: "25.3"
        case .deluge: "2.2.0"
        case .qui: "v1.8.0"
        default: "4.0.6 (38c164933e)"
        }
        return DownloadOverview(
            version: version,
            downloadRate: active.compactMap(\.downloadRate).reduce(0, +),
            uploadRate: kind == .sabnzbd || kind == .nzbget ? nil : items.compactMap(\.uploadRate).reduce(0, +),
            isPaused: [.sabnzbd, .nzbget, .deluge].contains(kind) ? globallyPaused : nil,
            items: items
        )
    }

    func pause(_ ids: [String]) async throws { update(ids) { $0.state = .paused; $0.downloadRate = 0 } }
    func resume(_ ids: [String]) async throws { update(ids) { $0.state = $0.progress >= 1 ? .seeding : .downloading } }
    func pauseAll() async throws { globallyPaused = true; update(items.map(\.id)) { $0.state = .paused; $0.downloadRate = 0 } }
    func resumeAll() async throws { globallyPaused = false; update(items.map(\.id)) { $0.state = $0.progress >= 1 ? .seeding : .downloading } }

    func remove(_ ids: [String], deleteData: Bool) async throws {
        items.removeAll { ids.contains($0.id) }
    }

    private func update(_ ids: [String], _ change: (inout TransferItem) -> Void) {
        for index in items.indices where ids.contains(items[index].id) {
            change(&items[index])
        }
    }
}

extension SampleDownloadClient: TorrentDiagnosticsService {
    func trackers(for itemID: String) async throws -> [TorrentTracker] {
        try await Task.sleep(for: .milliseconds(150))
        return [
            TorrentTracker(id: "0", host: "tracker.example.org", status: .working, seeds: 42, peers: 7),
            TorrentTracker(id: "1", host: "backup-tracker.example.net", status: .notWorking, message: "Connection timed out"),
            TorrentTracker(id: "2", host: "DHT", status: .disabled),
        ]
    }

    func verify(_ itemID: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}
