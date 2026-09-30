import Foundation

struct BazarrEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    var data: Value
}

struct BazarrPage<Item: Decodable & Sendable>: Decodable, Sendable {
    var data: [Item]
    var total: Int
}

struct BazarrStatus: Decodable, Sendable {
    var bazarr_version: String
    var sonarr_version: String?
    var radarr_version: String?
}

struct BazarrHealthIssue: Decodable, Sendable {
    var object: String
    var issue: String
}

struct BazarrBadges: Decodable, Sendable {
    var episodes: Int
    var movies: Int
    var providers: Int
    var status: Int
}

struct BazarrLanguage: Decodable, Sendable, Hashable {
    var name: String
    var code2: String
    var forced: Bool
    var hi: Bool

    var label: String {
        name + (forced ? " (forced)" : "") + (hi ? " (HI)" : "")
    }
}

struct BazarrWantedEpisode: Decodable, Sendable {
    var seriesTitle: String
    var episode_number: String
    var episodeTitle: String
    var missing_subtitles: [BazarrLanguage]
    var sonarrSeriesId: Int
    var sonarrEpisodeId: Int
}

struct BazarrWantedMovie: Decodable, Sendable {
    var title: String
    var missing_subtitles: [BazarrLanguage]
    var radarrId: Int
}

struct BazarrProvider: Decodable, Sendable {
    var name: String
    var status: String
    var retry: String

    var isThrottled: Bool { status != "Good" }
}

struct BazarrTask: Decodable, Sendable {
    var job_id: String
    var name: String
    var interval: String
    var job_running: Bool
    var next_run_in: String
}

struct BazarrOverview: Sendable {
    var status: BazarrStatus
    var badges: BazarrBadges
    var health: [BazarrHealthIssue]
    var providers: [BazarrProvider]
    var tasks: [BazarrTask]
    var wantedEpisodes: BazarrPage<BazarrWantedEpisode>
    var wantedMovies: BazarrPage<BazarrWantedMovie>
}

protocol BazarrOperations: Sendable {
    func runTask(_ id: String) async throws
    func resetProviders() async throws
    func searchEpisode(seriesID: Int, episodeID: Int, language: BazarrLanguage) async throws
    func searchMovie(radarrID: Int) async throws
}

/// Bazarr 1.4+ REST API (flask-restx, self-documented via its Swagger UI). Key in `X-API-KEY`.
struct BazarrClient: DashboardService, BazarrOperations {
    let kind = IntegrationKind.bazarr
    static let wantedPageSize = 25
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, headers: ["X-API-KEY": apiKey])
    }

    func overview() async throws -> BazarrOverview {
        let page = [URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "length", value: String(Self.wantedPageSize))]
        async let status = rest.json(.get("api/system/status"), as: BazarrEnvelope<BazarrStatus>.self)
        async let badges = rest.json(.get("api/badges"), as: BazarrBadges.self)
        async let health = rest.json(.get("api/system/health"), as: BazarrEnvelope<[BazarrHealthIssue]>.self)
        async let providers = rest.json(.get("api/providers"), as: BazarrEnvelope<[BazarrProvider]>.self)
        async let tasks = rest.json(.get("api/system/tasks"), as: BazarrEnvelope<[BazarrTask]>.self)
        async let episodes = rest.json(.get("api/episodes/wanted", query: page), as: BazarrPage<BazarrWantedEpisode>.self)
        async let movies = rest.json(.get("api/movies/wanted", query: page), as: BazarrPage<BazarrWantedMovie>.self)
        return try await BazarrOverview(status: status.data, badges: badges, health: health.data, providers: providers.data,
                                        tasks: tasks.data, wantedEpisodes: episodes, wantedMovies: movies)
    }

    func dashboard() async throws -> DashboardSnapshot {
        BazarrDashboard.snapshot(try await overview(), operations: self)
    }

    func runTask(_ id: String) async throws {
        _ = try await rest.data(.post("api/system/tasks", form: ["taskid": id]))
    }

    func resetProviders() async throws {
        _ = try await rest.data(.post("api/providers", form: ["action": "reset"]))
    }

    func searchEpisode(seriesID: Int, episodeID: Int, language: BazarrLanguage) async throws {
        _ = try await rest.data(RESTRequest(method: "PATCH", path: "api/episodes/subtitles", body: .form([
            "seriesid": String(seriesID), "episodeid": String(episodeID), "language": language.code2,
            "forced": String(language.forced), "hi": String(language.hi),
        ])))
    }

    func searchMovie(radarrID: Int) async throws {
        _ = try await rest.data(RESTRequest(method: "PATCH", path: "api/movies", body: .form(["radarrid": String(radarrID), "action": "search-missing"])))
    }
}

enum BazarrDashboard {
    static let searchTasks = ["wanted_search_missing_subtitles_series": "Search Missing Series Subtitles",
                              "wanted_search_missing_subtitles_movies": "Search Missing Movie Subtitles"]

    static func snapshot(_ overview: BazarrOverview, operations: some BazarrOperations) -> DashboardSnapshot {
        let throttled = overview.providers.filter(\.isThrottled)
        let missing = overview.badges.episodes + overview.badges.movies
        let health: Health = !overview.health.isEmpty || !throttled.isEmpty ? .warning : .ok
        var headline = missing == 0 ? "No missing subtitles" : "\(missing) missing subtitle\(missing == 1 ? "" : "s")"
        if !throttled.isEmpty { headline += " · \(throttled.count) provider\(throttled.count == 1 ? "" : "s") throttled" }

        var actions = overview.tasks.compactMap { task -> DashboardAction? in
            guard let title = searchTasks[task.job_id], !task.job_running else { return nil }
            return DashboardAction(id: "task:\(task.job_id)", title: title, systemImage: "magnifyingglass", targetKind: "Task", targetName: task.name,
                                   consequence: "Bazarr searches your providers now instead of waiting for the next scheduled run.", confirmation: .none) {
                try await operations.runTask(task.job_id)
            }
        }
        if !throttled.isEmpty {
            actions.append(DashboardAction(id: "providers:reset", title: "Reset Throttled Providers", systemImage: "arrow.counterclockwise",
                                           targetKind: "Providers", targetName: throttled.map(\.name).joined(separator: ", "),
                                           consequence: "Bazarr clears every provider's throttle and strike count and starts using them again. If the cause persists, they'll be throttled again.") {
                try await operations.resetProviders()
            })
        }

        return DashboardSnapshot(
            version: overview.status.bazarr_version,
            health: health,
            headline: headline,
            detail: [overview.status.sonarr_version?.nilIfEmpty.map { "Sonarr \($0)" }, overview.status.radarr_version?.nilIfEmpty.map { "Radarr \($0)" }]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            metrics: [
                DashboardMetric(title: "Missing episode subtitles", value: overview.badges.episodes.formatted(), systemImage: "tv"),
                DashboardMetric(title: "Missing movie subtitles", value: overview.badges.movies.formatted(), systemImage: "film"),
                DashboardMetric(title: "Throttled providers", value: "\(throttled.count)/\(overview.providers.count)", systemImage: "network", health: throttled.isEmpty ? .ok : .warning),
            ],
            actions: actions,
            sections: [
                DashboardSection(id: "health", title: "Health", systemImage: "stethoscope", trailing: overview.health.isEmpty ? "No issues" : "\(overview.health.count)",
                                 emptyText: "Bazarr reports no problems.",
                                 rows: overview.health.enumerated().map { DashboardRow(id: "h\($0.offset)", title: $0.element.issue, subtitle: $0.element.object, health: .warning) }),
                DashboardSection(id: "providers", title: "Providers", systemImage: "network", trailing: "\(overview.providers.count)",
                                 emptyText: "No subtitle providers are enabled.",
                                 rows: overview.providers.map { provider in
                                     DashboardRow(id: provider.name, title: provider.name, subtitle: provider.isThrottled && provider.retry != "-" ? "Retries \(provider.retry)" : nil,
                                                  health: provider.isThrottled ? .warning : .ok, badge: provider.isThrottled ? provider.status : "Good")
                                 }),
                DashboardSection(id: "episodes", title: "Wanted Episodes", systemImage: "tv", trailing: overview.wantedEpisodes.total.formatted(),
                                 emptyText: "Every monitored episode has its subtitles.",
                                 rows: overview.wantedEpisodes.data.map { episode in
                                     DashboardRow(id: "e\(episode.sonarrEpisodeId)", title: episode.seriesTitle, subtitle: "\(episode.episode_number) · \(episode.episodeTitle)",
                                                  detail: "Missing: " + episode.missing_subtitles.map(\.label).joined(separator: ", "),
                                                  actions: episode.missing_subtitles.map { language in
                                                      DashboardAction(id: "e\(episode.sonarrEpisodeId):\(language.code2):\(language.forced):\(language.hi)", title: "Search \(language.label)",
                                                                      systemImage: "magnifyingglass", targetKind: "Episode", targetName: "\(episode.seriesTitle) \(episode.episode_number)",
                                                                      consequence: "Bazarr searches providers and downloads the best \(language.label) subtitle next to the episode file.", confirmation: .none) {
                                                          try await operations.searchEpisode(seriesID: episode.sonarrSeriesId, episodeID: episode.sonarrEpisodeId, language: language)
                                                      }
                                                  })
                                 }),
                DashboardSection(id: "movies", title: "Wanted Movies", systemImage: "film", trailing: overview.wantedMovies.total.formatted(),
                                 emptyText: "Every monitored movie has its subtitles.",
                                 rows: overview.wantedMovies.data.map { movie in
                                     DashboardRow(id: "m\(movie.radarrId)", title: movie.title, detail: "Missing: " + movie.missing_subtitles.map(\.label).joined(separator: ", "),
                                                  actions: [DashboardAction(id: "m\(movie.radarrId):search", title: "Search Missing", systemImage: "magnifyingglass", targetKind: "Movie", targetName: movie.title,
                                                                            consequence: "Bazarr searches providers and downloads subtitles for every missing language of this movie.", confirmation: .none) {
                                                      try await operations.searchMovie(radarrID: movie.radarrId)
                                                  }])
                                 }),
                DashboardSection(id: "tasks", title: "Scheduled Tasks", systemImage: "calendar.badge.clock", trailing: "\(overview.tasks.count)",
                                 emptyText: "No tasks are scheduled.",
                                 rows: overview.tasks.map { task in
                                     DashboardRow(id: task.job_id, title: task.name, subtitle: task.interval == "None" ? "Manual" : task.interval.capitalizedFirst,
                                                  detail: task.job_running ? nil : "Next run \(task.next_run_in)", health: task.job_running ? .ok : nil,
                                                  badge: task.job_running ? "Running" : nil,
                                                  actions: task.job_running ? [] : [DashboardAction(id: "run:\(task.job_id)", title: "Run Now", systemImage: "play.fill", targetKind: "Task", targetName: task.name,
                                                                                                    consequence: "Bazarr starts this task now.", confirmation: .none) {
                                                      try await operations.runTask(task.job_id)
                                                  }])
                                 }),
            ]
        )
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
