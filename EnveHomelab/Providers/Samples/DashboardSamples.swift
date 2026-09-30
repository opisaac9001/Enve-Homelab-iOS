import Foundation

/// Sample data for the labelled sample integrations only. Each sample renders through the same mapper as its live client.
private func pause() async throws {
    try await Task.sleep(for: .milliseconds(150))
}

private func iso(_ offset: TimeInterval) -> String {
    Date.now.addingTimeInterval(offset).formatted(.iso8601)
}

actor SampleBazarr: DashboardService, BazarrOperations {
    nonisolated let kind = IntegrationKind.bazarr
    private var throttled = true
    private var running: Set<String> = []
    private var episodes = [
        BazarrWantedEpisode(seriesTitle: "Open Source Chronicles", episode_number: "2x5", episodeTitle: "Merge Conflict",
                            missing_subtitles: [BazarrLanguage(name: "English", code2: "en", forced: false, hi: false), BazarrLanguage(name: "Spanish", code2: "es", forced: false, hi: false)],
                            sonarrSeriesId: 12, sonarrEpisodeId: 3456),
        BazarrWantedEpisode(seriesTitle: "Community Garden", episode_number: "1x1", episodeTitle: "Seedlings",
                            missing_subtitles: [BazarrLanguage(name: "English", code2: "en", forced: false, hi: true)], sonarrSeriesId: 14, sonarrEpisodeId: 3500),
    ]
    private var movies = [BazarrWantedMovie(title: "Sample Home Movie (2024)", missing_subtitles: [BazarrLanguage(name: "French", code2: "fr", forced: false, hi: false)], radarrId: 77)]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let providers = [BazarrProvider(name: "opensubtitlescom", status: "Good", retry: "-"),
                         BazarrProvider(name: "podnapisi", status: throttled ? "TooManyRequests" : "Good", retry: throttled ? "in 2 hours" : "-")]
        let tasks = [
            BazarrTask(job_id: "wanted_search_missing_subtitles_series", name: "Search for Missing Series Subtitles", interval: "every 6 hours",
                       job_running: running.contains("wanted_search_missing_subtitles_series"), next_run_in: "in 3 hours"),
            BazarrTask(job_id: "wanted_search_missing_subtitles_movies", name: "Search for Missing Movies Subtitles", interval: "every 6 hours",
                       job_running: running.contains("wanted_search_missing_subtitles_movies"), next_run_in: "in 4 hours"),
            BazarrTask(job_id: "backup", name: "Backup Database and Configuration File", interval: "every day at 3:00", job_running: false, next_run_in: "in 11 hours"),
        ]
        let overview = BazarrOverview(
            status: BazarrStatus(bazarr_version: "1.6.2", sonarr_version: "4.0.15.2941", radarr_version: "5.26.2.10099"),
            badges: BazarrBadges(episodes: episodes.map(\.missing_subtitles.count).reduce(0, +), movies: movies.map(\.missing_subtitles.count).reduce(0, +),
                                 providers: throttled ? 1 : 0, status: 0),
            health: [], providers: providers, tasks: tasks,
            wantedEpisodes: BazarrPage(data: episodes, total: episodes.count), wantedMovies: BazarrPage(data: movies, total: movies.count))
        return BazarrDashboard.snapshot(overview, operations: self)
    }

    func runTask(_ id: String) async throws { running.insert(id) }
    func resetProviders() async throws { throttled = false }

    func searchEpisode(seriesID: Int, episodeID: Int, language: BazarrLanguage) async throws {
        for index in episodes.indices where episodes[index].sonarrEpisodeId == episodeID {
            episodes[index].missing_subtitles.removeAll { $0 == language }
        }
        episodes.removeAll { $0.missing_subtitles.isEmpty }
    }

    func searchMovie(radarrID: Int) async throws { movies.removeAll { $0.radarrId == radarrID } }
}

actor SampleNZBHydra: DashboardService, HydraOperations {
    nonisolated let kind = IntegrationKind.nzbhydra

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = HydraOverview(
            version: "9.1.0",
            indexers: [
                HydraIndexerStatus(indexer: "Usenet Index", state: "ENABLED", apiHits: 142, apiHitLimit: 1000, downloadHits: 12, downloadHitLimit: 100),
                HydraIndexerStatus(indexer: "Archive Search", state: "DISABLED_SYSTEM_TEMPORARY", level: 2, lastError: "Connection timed out after 20 seconds"),
                HydraIndexerStatus(indexer: "Old Mirror", state: "DISABLED_USER"),
            ],
            recentDownloads: [
                HydraDownload(id: 1, time: iso(-900), title: "Conference.Talks.2025", indexer: "Usenet Index", status: "NZB_ADDED"),
                HydraDownload(id: 2, time: iso(-7_200), title: "Linux.Distribution.ISO.Collection", indexer: "Usenet Index", status: "CONTENT_DOWNLOAD_SUCCESSFUL"),
            ])
        return HydraDashboard.snapshot(overview, operations: self)
    }

    func createBackup() async throws {}
}

actor SampleJackett: DashboardService, JackettOperations {
    nonisolated let kind = IntegrationKind.jackett

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        return JackettDashboard.snapshot(JackettOverview(indexers: [
            JackettIndexer(id: "linuxtracker", title: "Linux Tracker", configured: true, type: "public", language: "en-US", link: "https://linuxtracker.example"),
            JackettIndexer(id: "archive", title: "Community Archive", configured: true, type: "semi-private", language: "en-US", link: "https://archive.example"),
            JackettIndexer(id: "private-media", title: "Private Media Club", configured: true, type: "private", language: "en-GB", link: "https://club.example"),
        ]), operations: self)
    }

    func test(indexerID: String) async throws -> Int {
        try await Task.sleep(for: .milliseconds(600))
        return 42
    }
}

actor SampleTdarr: DashboardService, TdarrOperations {
    nonisolated let kind = IntegrationKind.tdarr
    private var paused: Set<String> = ["node-garage"]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        func node(_ id: String, _ name: String, workers: [String: TdarrWorker], queue: [String: Double]) -> TdarrOverview.NodeState {
            .init(id: id, node: TdarrNode(nodeName: name, nodePaused: paused.contains(id), workers: workers),
                  limits: TdarrWorkerLimits(queueLengths: queue.mapValues { LooseNumber($0) }))
        }
        return TdarrDashboard.snapshot(TdarrOverview(version: "2.92.01", nodes: [
            node("node-tower", "Tower", workers: [
                "w1": TdarrWorker(idle: paused.contains("node-tower"), file: "/media/movies/Sample Home Movie (2024)/Sample Home Movie.mkv"),
                "w2": TdarrWorker(idle: true),
            ], queue: ["transcodecpu": 14, "healthcheckcpu": 3]),
            node("node-garage", "Garage GPU", workers: ["w3": TdarrWorker(idle: true)], queue: ["transcodegpu": 6]),
        ]), operations: self)
    }

    func setPaused(_ isPaused: Bool, nodeID: String) async throws {
        if isPaused { paused.insert(nodeID) } else { paused.remove(nodeID) }
    }
}

actor SampleMaintainerr: DashboardService, MaintainerrOperations {
    nonisolated let kind = IntegrationKind.maintainerr
    private var rulesRunning = false
    private var handled = false

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = MaintainerrOverview(
            status: MaintainerrStatus(version: "3.29.0", updateAvailable: false),
            health: MaintainerrHealth(status: "ok", database: "ok"),
            execution: MaintainerrExecution(processingQueue: rulesRunning),
            handlerRunning: false,
            collections: [
                MaintainerrCollection(id: 1, title: "Leaving Soon — Movies", isActive: true, arrAction: 0, deleteAfterDays: 30, type: "movie", mediaServerType: "plex", mediaCount: 17, totalSizeBytes: LooseNumber(53_687_091_200)),
                MaintainerrCollection(id: 2, title: "Unwatched Shows", isActive: true, arrAction: 3, deleteAfterDays: 60, type: "show", mediaServerType: "plex", mediaCount: 6, totalSizeBytes: LooseNumber(120_000_000_000)),
                MaintainerrCollection(id: 3, title: "Old Recordings", isActive: false, arrAction: 4, deleteAfterDays: nil, type: "movie", mediaServerType: "jellyfin", mediaCount: 0),
            ],
            dueCounts: handled ? [1: 0, 2: 0] : [1: 3, 2: 1])
        return MaintainerrDashboard.snapshot(overview, operations: self)
    }

    func runRules() async throws { rulesRunning = true }
    func stopRules() async throws { rulesRunning = false }
    func handleCollections() async throws { handled = true }
}

actor SampleTautulli: DashboardService, TautulliOperations, WatchStatisticsSource {
    nonisolated let kind = IntegrationKind.tautulli

    func watchUsers() async throws -> [WatchUser] {
        [WatchUser(id: "1", name: "Alex"), WatchUser(id: "2", name: "Jordan"), WatchUser(id: "3", name: "Sam")]
    }

    func userSummary(userID: String) async throws -> WatchUserSummary {
        let scale = Int(userID) ?? 1
        return WatchUserSummary(
            periods: [.init(days: 1, plays: 4 / scale, seconds: Double(9_000 / scale)), .init(days: 7, plays: 20 / scale, seconds: Double(52_000 / scale)),
                      .init(days: 30, plays: 52 / scale, seconds: Double(151_200 / scale)), .init(days: 0, plays: 610 / scale, seconds: Double(1_900_000 / scale))],
            players: [.init(name: "Living Room TV", plays: 40 / scale, duration: Double(120_000 / scale)), .init(name: "iPhone", plays: 12 / scale, duration: Double(31_000 / scale))]
        )
    }

    func statistics(days count: Int, userID: String?) async throws -> WatchStatistics {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        // A fixed weekly rhythm (busier weekends) so the sample looks plausible and stays stable between launches.
        let pattern = [3, 2, 4, 3, 5, 9, 8].map { userID == nil ? $0 : max(1, $0 / 3) }
        let days = (0..<count).reversed().compactMap { offset -> WatchStatistics.Day? in
            calendar.date(byAdding: .day, value: -offset, to: today).map { date in
                WatchStatistics.Day(date: date, plays: pattern[(calendar.component(.weekday, from: date) + 5) % 7])
            }
        }
        let total = days.reduce(0) { $0 + $1.plays }
        return WatchStatistics(
            days: days,
            playsByType: [("TV", total * 6 / 10), ("Movies", total * 3 / 10), ("Music", total - total * 6 / 10 - total * 3 / 10)],
            topMovies: [.init(name: "Sample Documentary", plays: 6, duration: 32_400), .init(name: "Night Sky Timelapse", plays: 4, duration: 14_400)],
            topShows: [.init(name: "Open Source Chronicles", plays: 31, duration: 86_000), .init(name: "Community Garden", plays: 18, duration: 41_000)],
            topUsers: userID != nil ? [] : [.init(name: "Alex", plays: 52, duration: 151_200), .init(name: "Jordan", plays: 37, duration: 98_000), .init(name: "Sam", plays: 12, duration: 30_000)],
            topPlatforms: [.init(name: "tvOS", plays: 61), .init(name: "iOS", plays: 28), .init(name: "Web", plays: 12)]
        )
    }
    private var sessions = [
        TautulliSession(session_id: "s1", session_key: LooseNumber(27), friendly_name: "Alex", full_title: "Open Source Chronicles - Merge Conflict", media_type: "episode", state: "playing",
                        progress_percent: LooseNumber(42), player: "Living Room TV", product: "Plex for Apple TV", transcode_decision: "direct play",
                        stream_video_full_resolution: "1080p", quality_profile: "Original", location: "lan", bandwidth: LooseNumber(12_400)),
        TautulliSession(session_id: "s2", session_key: LooseNumber(28), friendly_name: "Sam", full_title: "Sample Home Movie", media_type: "movie", state: "paused",
                        progress_percent: LooseNumber(76), player: "Sam's iPhone", product: "Plex for iOS", transcode_decision: "transcode",
                        stream_video_full_resolution: "720p", quality_profile: "4 Mbps 720p", location: "wan", bandwidth: LooseNumber(4_200), transcode_hw_encoding: LooseNumber(1),
                        audio_decision: "transcode", subtitle_decision: "burn", stream_audio_codec: "aac", audio_language: "English", stream_audio_channel_layout: "stereo",
                        subtitle_language: "English", stream_subtitle_codec: "pgs"),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let direct = sessions.filter { $0.transcode_decision == "direct play" }.count
        let transcodes = sessions.filter { $0.transcode_decision == "transcode" }.count
        let lan = sessions.filter { $0.location == "lan" }.compactMap(\.bandwidth?.value).reduce(0, +)
        let wan = sessions.filter { $0.location != "lan" }.compactMap(\.bandwidth?.value).reduce(0, +)
        var activity = TautulliActivity()
        activity.stream_count_direct_play = LooseNumber(Double(direct))
        activity.stream_count_direct_stream = LooseNumber(0)
        activity.stream_count_transcode = LooseNumber(Double(transcodes))
        activity.total_bandwidth = LooseNumber(lan + wan)
        activity.lan_bandwidth = LooseNumber(lan)
        activity.wan_bandwidth = LooseNumber(wan)
        activity.sessions = sessions
        let overview = TautulliOverview(
            version: "v2.18.2", server: TautulliServerInfo(pms_name: "Tower", pms_version: "1.42.1.10060"), plexReachable: true, activity: activity,
            libraries: [
                TautulliLibrary(section_id: LooseNumber(1), section_name: "Movies", section_type: "movie", count: LooseNumber(412)),
                TautulliLibrary(section_id: LooseNumber(2), section_name: "TV Shows", section_type: "show", count: LooseNumber(62), child_count: LooseNumber(3_745)),
            ],
            history: [
                TautulliHistory.Row(row_id: LooseNumber(1124), full_title: "Community Garden - Seedlings", friendly_name: "Jordan", player: "Bedroom TV",
                                    started: LooseNumber(Date.now.addingTimeInterval(-5_400).timeIntervalSince1970), percent_complete: LooseNumber(100)),
            ],
            stats: [TautulliHomeStat(stat_id: "top_users", rows: [.init(friendly_name: "Alex", total_plays: LooseNumber(42), total_duration: LooseNumber(151_200)),
                                                                  .init(friendly_name: "Sam", total_plays: LooseNumber(17), total_duration: LooseNumber(54_000))]),
                    TautulliHomeStat(stat_id: "top_platforms", rows: [.init(platform: "tvOS", total_plays: LooseNumber(38)), .init(platform: "Chrome", total_plays: LooseNumber(21))])],
            problems: [TautulliLogLine(loglevel: "WARNING", msg: "Tautulli Notifiers :: Discord notification failed: HTTP 429", time: "2026-09-29 09:41:02")],
            deliveryFailures: [TautulliDeliveryFailure(agent: "discord", failures: 3, attempts: 25, lastFailure: Date.now.addingTimeInterval(-1_200))])
        return TautulliDashboard.snapshot(overview, operations: self)
    }

    func terminate(sessionID: String, message: String) async throws { sessions.removeAll { $0.session_id == sessionID } }
    func run(_ maintenance: TautulliMaintenance) async throws {}
}

actor SampleKomga: DashboardService, KomgaOperations {
    nonisolated let kind = IntegrationKind.komga
    private var broken = [
        KomgaBook(id: "b9", name: "Public Domain Comics 014", seriesTitle: "Public Domain Comics", libraryId: "l1", created: iso(-86_400 * 3), sizeBytes: 48_000_000,
                  media: .init(status: "ERROR", comment: "ERR_1008")),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = KomgaOverview(
            user: KomgaUser(email: "admin@example.com", roles: ["ADMIN", "USER"]), version: "1.28.0",
            libraries: [KomgaLibrary(id: "l1", name: "Comics", unavailable: false), KomgaLibrary(id: "l2", name: "Manga", unavailable: false)],
            seriesCount: 214, bookCount: 3_812,
            recentBooks: [KomgaBook(id: "b1", name: "Open Web Adventures 007", seriesTitle: "Open Web Adventures", libraryId: "l1", created: iso(-3_600), sizeBytes: 62_000_000,
                                    media: .init(status: "READY", comment: nil))],
            brokenBooks: KomgaPage(content: broken, totalElements: broken.count),
            maintenance: ServerMaintenance(update: .available("1.29.0")))
        return KomgaDashboard.snapshot(overview, operations: self)
    }

    func scan(libraryID: String, deep: Bool) async throws {}
    func analyze(libraryID: String) async throws {}
    func emptyTrash(libraryID: String) async throws {}
    func analyze(bookID: String) async throws { broken.removeAll { $0.id == bookID } }
    func cancelQueuedTasks() async throws -> Int { 0 }
}

actor SampleKavita: DashboardService, KavitaOperations {
    nonisolated let kind = IntegrationKind.kavita

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = KavitaOverview(
            version: "0.9.1.4",
            libraries: [KavitaLibrary(id: 1, name: "Manga", type: 0, lastScanned: iso(-7_200)), KavitaLibrary(id: 2, name: "Books", type: 2, lastScanned: iso(-86_400))],
            recentSeries: [KavitaSeries(id: 40, name: "Creative Commons Stories", libraryName: "Books", created: iso(-10_000))],
            totalSeries: 188,
            admin: .init(
                stats: KavitaServerStats(seriesCount: 188, volumeCount: 902, chapterCount: 4_410, totalFiles: 5_120, totalSize: 96_000_000_000),
                mediaErrors: [KavitaMediaError(filePath: "/manga/Broken Series/Volume 03.cbz", comment: "The archive couldn't be opened")],
                sessions: [KavitaReadingSession(id: 9, username: "alex", isActive: true, activityData: [
                    .init(seriesName: "Creative Commons Stories", chapterTitle: "Chapter 4", libraryName: "Books", endPage: 30, totalPages: 120),
                ])],
                jobs: [KavitaRecurringJob(id: "scan-libraries", title: "Scan Libraries", lastExecutionUtc: iso(-7_200), cron: "0 */6 * * *")],
                update: .upToDate))
        return KavitaDashboard.snapshot(overview, operations: self)
    }

    func scan(libraryID: Int, force: Bool) async throws {}
    func scanAll() async throws {}
    func backUpDatabase() async throws {}
}

actor SampleAudiobookshelf: DashboardService, AudiobookshelfOperations {
    nonisolated let kind = IntegrationKind.audiobookshelf
    private var issues = [ABSItem(id: "x1", libraryId: "a1", isMissing: true, path: "/audiobooks/Moved Author/Old Title",
                                  media: .init(metadata: .init(title: "Old Title", authorName: "Moved Author")))]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let now = Date.now.timeIntervalSince1970 * 1000
        let overview = ABSOverview(
            version: "2.36.0", user: ABSUser(username: "root", type: "root"),
            libraries: [ABSLibrary(id: "a1", name: "Audiobooks", mediaType: "book", lastScan: now - 3_600_000, stats: .init(totalItems: 318, totalSize: 402_000_000_000, totalDuration: 3_900_000)),
                        ABSLibrary(id: "p1", name: "Podcasts", mediaType: "podcast", lastScan: now - 86_400_000, stats: .init(totalItems: 24, totalSize: 38_000_000_000, totalDuration: 910_000))],
            tasks: [],
            recent: [ABSItem(id: "r1", libraryId: "a1", addedAt: now - 7_200_000, media: .init(metadata: .init(title: "Public Domain Classics, Vol. 2", authorName: "Various"), duration: 41_000))],
            issues: ["a1": ABSItemsPage(results: issues, total: issues.count), "p1": ABSItemsPage(results: [], total: 0)],
            sessions: [ABSSession(id: "s1", displayTitle: "Public Domain Classics, Vol. 2", displayAuthor: "Various", duration: 41_000, currentTime: 12_300, playMethod: 0,
                                  mediaPlayer: "html5", deviceInfo: .init(clientName: "Abs Web", deviceName: nil, osName: "macOS"), user: .init(username: "jordan"))],
            backups: backups)
        return AudiobookshelfDashboard.snapshot(overview, operations: self)
    }

    func scan(libraryID: String, force: Bool) async throws {}
    func removeItemsWithIssues(libraryID: String) async throws { issues.removeAll { $0.libraryId == libraryID } }

    private var backups = [ServerMaintenance.Backup(name: "2026-09-12T0100.audiobookshelf", date: Date.now.addingTimeInterval(-86_400 * 17), size: 21_000_000)]

    func createBackup() async throws {
        try await Task.sleep(for: .milliseconds(300))
        backups.insert(ServerMaintenance.Backup(name: "\(Date.now.formatted(.iso8601.year().month().day())).audiobookshelf", date: .now, size: 21_400_000), at: 0)
    }
}

actor SampleImmich: DashboardService, ImmichOperations {
    nonisolated let kind = IntegrationKind.immich
    private var queues: [String: ImmichQueue] = [
        "thumbnailGeneration": ImmichQueue(jobCounts: .init(active: 2, completed: 0, failed: 0, delayed: 0, waiting: 184, paused: 0), queueStatus: .init(isActive: true, isPaused: false)),
        "smartSearch": ImmichQueue(jobCounts: .init(active: 0, completed: 0, failed: 3, delayed: 0, waiting: 0, paused: 0), queueStatus: .init(isActive: false, isPaused: false)),
        "videoConversion": ImmichQueue(jobCounts: .init(active: 0, completed: 0, failed: 0, delayed: 0, waiting: 12, paused: 12), queueStatus: .init(isActive: false, isPaused: true)),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = ImmichOverview(
            version: "3.2.4",
            storage: ImmichStorage(diskSizeRaw: 4_000_000_000_000, diskUseRaw: 2_640_000_000_000, diskAvailableRaw: 1_360_000_000_000, diskUsagePercentage: 66),
            statistics: ImmichStatistics(photos: 48_210, videos: 1_904, usage: 1_900_000_000_000, usageByUser: [
                .init(userId: "u1", userName: "Alex", photos: 30_100, videos: 1_200, usage: 1_200_000_000_000, quotaSizeInBytes: nil),
                .init(userId: "u2", userName: "Sam", photos: 18_110, videos: 704, usage: 700_000_000_000, quotaSizeInBytes: 750_000_000_000),
            ]),
            queues: queues,
            maintenance: ServerMaintenance(update: .upToDate, backups: [ServerMaintenance.Backup(name: "immich-db-backup-sample.sql.gz", size: 412_000_000)]))
        return ImmichDashboard.snapshot(overview, operations: self)
    }

    func send(_ command: ImmichQueueCommand, to queue: String) async throws {
        guard var state = queues[queue] else { return }
        switch command {
        case .pause: state.queueStatus.isPaused = true
        case .resume: state.queueStatus.isPaused = false
        case .start: state.queueStatus.isActive = true
        case .empty: state.jobCounts.waiting = 0
        case .clearFailed: state.jobCounts.failed = 0
        }
        queues[queue] = state
    }
}

actor SampleWizarr: DashboardService, WizarrOperations {
    nonisolated let kind = IntegrationKind.wizarr
    private var invitations = [
        WizarrInvitation(id: 5, code: "FAMILY2026", status: "pending", created: iso(-86_400), expires: iso(86_400 * 6), duration: "unlimited", unlimited: true, server_names: ["Tower Plex"]),
        WizarrInvitation(id: 4, code: "GUEST30", status: "used", created: iso(-86_400 * 20), duration: "30", unlimited: false, server_names: ["Tower Plex"]),
    ]
    private var users = [
        WizarrUser(id: 12, username: "jordan", email: "jordan@example.com", server: "Tower Plex", server_type: "plex", expires: nil),
        WizarrUser(id: 13, username: "guest", server: "Tower Plex", server_type: "plex", expires: iso(86_400 * 4)),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = WizarrOverview(
            status: WizarrStatus(users: users.count, invites: invitations.count, pending: invitations.filter { $0.status == "pending" }.count, expired: 0),
            invitations: invitations, users: users,
            servers: [WizarrServer(id: 1, name: "Tower Plex", server_type: "plex", verified: true)])
        return WizarrDashboard.snapshot(overview, operations: self)
    }

    func deleteInvitation(id: Int) async throws { invitations.removeAll { $0.id == id } }

    func extend(userID: Int, days: Int) async throws {
        for index in users.indices where users[index].id == userID {
            let base = APIDate.parse(users[index].expires) ?? .now
            users[index].expires = base.addingTimeInterval(Double(days) * 86_400).formatted(.iso8601)
        }
    }

    func removeUser(id: Int) async throws { users.removeAll { $0.id == id } }
}

actor SampleGlances: DashboardService, GlancesOperations {
    nonisolated let kind = IntegrationKind.glances
    private var events = [
        GlancesEvent(begin: Date.now.addingTimeInterval(-600).timeIntervalSince1970, end: -1, state: "WARNING", type: "FS_/mnt/backup", max: 91.2, global_msg: "High file system usage on /mnt/backup"),
        GlancesEvent(begin: Date.now.addingTimeInterval(-7_200).timeIntervalSince1970, end: Date.now.addingTimeInterval(-6_900).timeIntervalSince1970, state: "WARNING", type: "CPU_TOTAL", max: 88, global_msg: "High CPU usage"),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        let overview = GlancesOverview(
            version: "4.5.7",
            system: GlancesSystem(hostname: "atlas", hr_name: "Debian 13 64bit / Linux 6.12.0", os_name: "Linux"),
            uptime: "12 days, 4:05:06",
            quicklook: GlancesQuicklook(cpu: 23.4, mem: 61.2, swap: 4.1, load: 18, cpu_name: "AMD Ryzen 7 5700G"),
            memory: GlancesMemory(total: 34_359_738_368, used: 21_000_000_000, available: 13_300_000_000, percent: 61.2),
            load: GlancesLoad(min1: 1.42, min5: 1.18, min15: 0.97, cpucore: 16),
            fileSystems: [
                GlancesFileSystem(mnt_point: "/", device_name: "/dev/nvme0n1p2", fs_type: "ext4", size: 500_000_000_000, used: 212_000_000_000, percent: 42.4),
                GlancesFileSystem(mnt_point: "/mnt/backup", device_name: "/dev/sdb1", fs_type: "xfs", size: 4_000_000_000_000, used: 3_648_000_000_000, percent: 91.2),
            ],
            sensors: Self.sensors, containers: nil, events: events,
            views: ["quicklook": ["": ["cpu": "OK", "mem": "CAREFUL", "swap": "OK", "load": "OK"]],
                    "fs": ["/": ["used": "OK"], "/mnt/backup": ["used": "WARNING_LOG"]],
                    "sensors": ["Package id 0": ["value": "OK"], "nvme0": ["value": "OK"]]])
        return GlancesDashboard.snapshot(overview, operations: self)
    }

    /// Decoded from JSON so the sample includes the placeholder readings a live server can send.
    private static let sensors = (try? JSONDecoder().decode([GlancesSensor].self, from: Data("""
    [{"label":"Package id 0","type":"temperature_core","unit":"C","value":54,"warning":80,"critical":95},
     {"label":"nvme0","type":"temperature_hdd","unit":"C","value":41,"warning":null,"critical":null},
     {"label":"sdb","type":"temperature_hdd","unit":"C","value":"ERR","warning":null,"critical":null}]
    """.utf8))) ?? []

    func clearEvents(warningsOnly: Bool) async throws {
        events.removeAll { !warningsOnly || (!$0.isOngoing && $0.state == "WARNING") }
    }
}

actor SampleCrowdSec: DashboardService {
    nonisolated let kind = IntegrationKind.crowdsec

    func dashboard() async throws -> DashboardSnapshot {
        try await pause()
        return CrowdSecDashboard.snapshot(CrowdSecOverview(lapiUp: true, decisions: [
            CrowdSecDecision(id: 2336, origin: "crowdsec", type: "ban", scope: "Ip", value: "203.0.113.24", duration: "3h51m57.36s", scenario: "crowdsecurity/ssh-bf"),
            CrowdSecDecision(id: 2337, origin: "crowdsec", type: "ban", scope: "Ip", value: "198.51.100.7", duration: "1h2m3s", scenario: "crowdsecurity/http-probing"),
            CrowdSecDecision(id: 2338, origin: "cscli", type: "captcha", scope: "Range", value: "192.0.2.0/24", duration: "23h59m0s", scenario: "manual 'captcha' from 'admin'"),
        ]))
    }
}
