import Foundation

struct ArrSystemStatus: Decodable, Sendable, Hashable {
    var appName: String?
    var instanceName: String?
    var version: String
}

enum ArrHealthLevel: String, ResilientEnum {
    case ok, notice, warning, error
    case unknown = "_unknown"

    var health: Health {
        switch self {
        case .ok: .ok
        case .notice, .unknown: .unknown
        case .warning: .warning
        case .error: .critical
        }
    }
}

struct ArrHealthItem: Decodable, Sendable, Hashable, Identifiable {
    var id: String { "\(source ?? "")|\(message)" }
    var source: String?
    var type: ArrHealthLevel
    var message: String
    var wikiUrl: String?
}

struct ArrStatusMessage: Decodable, Sendable, Hashable {
    var title: String?
    var messages: [String]?
}

struct ArrQueueItem: Sendable, Hashable, Identifiable {
    var id: Int
    var title: String
    var mediaTitle: String?
    var status: String
    var trackedDownloadStatus: String?
    var trackedDownloadState: String?
    var size: Double
    var sizeLeft: Double
    var timeLeft: TimeInterval?
    var downloadClient: String?
    var downloadProtocol: String?
    var indexer: String?
    var errorMessage: String?
    var statusMessages: [ArrStatusMessage]

    var progress: Double { size > 0 ? max(0, min(1, (size - sizeLeft) / size)) : 0 }

    var state: TransferState {
        switch trackedDownloadState {
        case "importing", "importPending": return .importing
        case "importBlocked", "failedPending", "failed": return .failed
        case "imported": return .completed
        default: break
        }
        switch status {
        case "downloading": return trackedDownloadStatus == "warning" ? .stalled : .downloading
        case "paused": return .paused
        case "queued", "delay": return .queued
        case "completed": return .completed
        case "failed", "warning", "downloadClientUnavailable": return .failed
        default: return .unknown
        }
    }

    var problem: String? {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        return statusMessages.flatMap { $0.messages ?? [] }.first
    }

    var transferItem: TransferItem {
        TransferItem(
            id: "arr-\(id)",
            name: mediaTitle ?? title,
            subtitle: mediaTitle == nil ? downloadClient : title,
            state: state,
            progress: progress,
            size: Int64(size),
            remaining: Int64(sizeLeft),
            eta: timeLeft,
            category: downloadClient,
            message: problem
        )
    }
}

extension ArrQueueItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, status, trackedDownloadStatus, trackedDownloadState, size, sizeleft, timeleft
        case downloadClient, indexer, errorMessage, statusMessages, movie, series, episode, artist, album
        case downloadProtocol = "protocol"
    }

    private struct Named: Decodable {
        var title: String?
        var artistName: String?
        var year: Int?
        var seasonNumber: Int?
        var episodeNumber: Int?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Unknown release"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        trackedDownloadStatus = try c.decodeIfPresent(String.self, forKey: .trackedDownloadStatus)
        trackedDownloadState = try c.decodeIfPresent(String.self, forKey: .trackedDownloadState)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0
        sizeLeft = try c.decodeIfPresent(Double.self, forKey: .sizeleft) ?? 0
        timeLeft = Durations.timeSpan(try c.decodeIfPresent(String.self, forKey: .timeleft))
        downloadClient = try c.decodeIfPresent(String.self, forKey: .downloadClient)
        downloadProtocol = try c.decodeIfPresent(String.self, forKey: .downloadProtocol)
        indexer = try c.decodeIfPresent(String.self, forKey: .indexer)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        statusMessages = try c.decodeIfPresent([ArrStatusMessage].self, forKey: .statusMessages) ?? []

        if let movie = try c.decodeIfPresent(Named.self, forKey: .movie), let name = movie.title {
            mediaTitle = movie.year.map { "\(name) (\($0))" } ?? name
        } else if let series = try c.decodeIfPresent(Named.self, forKey: .series), let name = series.title {
            let episode = try c.decodeIfPresent(Named.self, forKey: .episode)
            if let season = episode?.seasonNumber, let number = episode?.episodeNumber {
                mediaTitle = "\(name) · S\(String(format: "%02d", season))E\(String(format: "%02d", number))"
            } else {
                mediaTitle = name
            }
        } else if let artist = try c.decodeIfPresent(Named.self, forKey: .artist), let name = artist.artistName {
            let album = try c.decodeIfPresent(Named.self, forKey: .album)
            mediaTitle = album?.title.map { "\(name) — \($0)" } ?? name
        } else {
            mediaTitle = nil
        }
    }
}

struct ArrQueuePage: Decodable, Sendable {
    var totalRecords: Int
    var records: [ArrQueueItem]
}

struct ArrDiskSpace: Decodable, Sendable, Hashable, Identifiable {
    var id: String { path ?? label ?? "" }
    var path: String?
    var label: String?
    var freeSpace: Int64
    var totalSpace: Int64

    var usedFraction: Double { totalSpace > 0 ? Double(totalSpace - freeSpace) / Double(totalSpace) : 0 }
}

struct ProwlarrIndexer: Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var isEnabled: Bool
    var downloadProtocol: String?
    var privacy: String?
    var disabledUntil: Date?
}

extension ProwlarrIndexer: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, enable, privacy
        case downloadProtocol = "protocol"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Indexer \(id)"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        downloadProtocol = try c.decodeIfPresent(String.self, forKey: .downloadProtocol)
        privacy = try c.decodeIfPresent(String.self, forKey: .privacy)
        disabledUntil = nil
    }
}

struct ProwlarrIndexerStatus: Decodable, Sendable {
    var indexerId: Int
    var disabledTill: String?
}

enum ArrCommand: String, Sendable, Identifiable {
    case rssSync = "RssSync"
    case refreshMonitoredDownloads = "RefreshMonitoredDownloads"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rssSync: "RSS Sync"
        case .refreshMonitoredDownloads: "Refresh Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .rssSync: "dot.radiowaves.up.forward"
        case .refreshMonitoredDownloads: "arrow.clockwise"
        }
    }

    var explanation: String {
        switch self {
        case .rssSync: "Checks every enabled indexer's RSS feed for releases your library is waiting on."
        case .refreshMonitoredDownloads: "Re-reads the state of downloads in your download clients."
        }
    }
}

struct ArrSnapshot: Sendable {
    var status: ArrSystemStatus
    var health: [ArrHealthItem]
    var queue: [ArrQueueItem]
    var queueTotal: Int
    var diskSpace: [ArrDiskSpace]
    var indexers: [ProwlarrIndexer]
}

/// A monitored release or air date from a Radarr, Sonarr or Lidarr calendar.
struct UpcomingItem: Sendable, Hashable, Identifiable {
    var id: String
    var date: Date
    /// Release dates without a time (movies, albums) are shown as whole days.
    var isAllDay: Bool
    var title: String
    var subtitle: String?
    var detail: String?
    var hasFile: Bool
    var source: IntegrationKind
    var isMonitored = true
}

/// Monitored items that are released but have no file yet.
struct ArrMissing: Sendable {
    var total: Int
    var items: [UpcomingItem]
}

struct ArrPage<Record: Decodable & Sendable>: Decodable, Sendable {
    var totalRecords: Int
    var records: [Record]
}

enum ArrCalendar {
    struct Movie: Decodable, Sendable {
        var id: Int
        var title: String
        var year: Int?
        var inCinemas: String?
        var digitalRelease: String?
        var physicalRelease: String?
        var hasFile: Bool?
        var monitored: Bool?

        private var releases: [(String, Date)] {
            [("In cinemas", inCinemas), ("Digital release", digitalRelease), ("Physical release", physicalRelease)]
                .compactMap { label, value in APIDate.parse(value).map { (label, $0) } }
        }

        /// The most recent release that has already happened, for the missing list.
        func missing(now: Date = .now) -> UpcomingItem? {
            guard let (label, date) = releases.filter({ $0.1 <= now }).max(by: { $0.1 < $1.1 }) else { return nil }
            return UpcomingItem(id: "radarr:\(id)", date: date, isAllDay: true, title: title, subtitle: year.map(String.init), detail: label,
                                hasFile: hasFile ?? false, source: .radarr, isMonitored: monitored ?? true)
        }

        /// The first release of this movie that falls inside the requested window.
        func upcoming(from start: Date, to end: Date) -> UpcomingItem? {
            guard let (label, date) = releases.filter({ $0.1 >= start && $0.1 < end }).min(by: { $0.1 < $1.1 }) else { return nil }
            return UpcomingItem(id: "radarr:\(id):\(label)", date: date, isAllDay: true, title: title, subtitle: year.map(String.init), detail: label,
                                hasFile: hasFile ?? false, source: .radarr, isMonitored: monitored ?? true)
        }
    }

    struct Episode: Decodable, Sendable {
        struct Series: Decodable, Sendable { var title: String }
        var id: Int
        var title: String?
        var seasonNumber: Int
        var episodeNumber: Int
        var airDateUtc: String?
        var hasFile: Bool?
        var monitored: Bool?
        var series: Series?

        var upcoming: UpcomingItem? {
            APIDate.parse(airDateUtc).map { date in
                UpcomingItem(id: "sonarr:\(id)", date: date, isAllDay: false, title: series?.title ?? title ?? "Episode",
                             subtitle: String(format: "S%02dE%02d", seasonNumber, episodeNumber) + (title.map { " · \($0)" } ?? ""),
                             hasFile: hasFile ?? false, source: .sonarr, isMonitored: monitored ?? true)
            }
        }
    }

    struct Album: Decodable, Sendable {
        struct Artist: Decodable, Sendable { var artistName: String }
        struct Statistics: Decodable, Sendable { var trackFileCount: Int? }
        var id: Int
        var title: String
        var releaseDate: String?
        var monitored: Bool?
        var artist: Artist?
        var statistics: Statistics?

        var upcoming: UpcomingItem? {
            APIDate.parse(releaseDate).map { date in
                UpcomingItem(id: "lidarr:\(id)", date: date, isAllDay: true, title: title, subtitle: artist?.artistName, detail: "Album release",
                             hasFile: (statistics?.trackFileCount ?? 0) > 0, source: .lidarr, isMonitored: monitored ?? true)
            }
        }
    }
}
