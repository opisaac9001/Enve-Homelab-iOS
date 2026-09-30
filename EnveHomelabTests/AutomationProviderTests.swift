import Foundation
import Testing
@testable import EnveHomelab

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct ArrDecodingTests {
    @Test func radarrQueueUsesIncludedMovieAndMapsStates() throws {
        let page = try decode(ArrQueuePage.self, """
        {"page":1,"pageSize":100,"totalRecords":2,"records":[
          {"id":7,"movieId":3,"movie":{"title":"Big Buck Bunny","year":2008},"size":1000.0,"sizeleft":250.0,"timeleft":"00:04:10",
           "title":"Big.Buck.Bunny.2008.1080p","status":"downloading","trackedDownloadStatus":"ok","trackedDownloadState":"downloading",
           "statusMessages":[],"downloadClient":"qBittorrent","protocol":"torrent","indexer":"Example"},
          {"id":8,"title":"Sintel.2010","status":"completed","trackedDownloadStatus":"warning","trackedDownloadState":"importBlocked",
           "statusMessages":[{"title":"Sintel.2010","messages":["No files found are eligible for import"]}],"size":10,"sizeleft":0}
        ]}
        """)
        #expect(page.totalRecords == 2)
        let first = page.records[0]
        #expect(first.mediaTitle == "Big Buck Bunny (2008)")
        #expect(first.progress == 0.75)
        #expect(first.timeLeft == 250)
        #expect(first.state == .downloading)
        #expect(first.downloadProtocol == "torrent")
        let blocked = page.records[1]
        #expect(blocked.state == .failed)
        #expect(blocked.problem == "No files found are eligible for import")
        #expect(blocked.transferItem.message == "No files found are eligible for import")
    }

    @Test func sonarrAndLidarrMediaTitles() throws {
        let episode = try decode(ArrQueueItem.self, """
        {"id":1,"title":"x","status":"queued","series":{"title":"Pioneer One"},"episode":{"seasonNumber":1,"episodeNumber":4,"title":"Sermon"},"size":1,"sizeleft":1}
        """)
        #expect(episode.mediaTitle == "Pioneer One · S01E04")
        #expect(episode.state == .queued)
        let album = try decode(ArrQueueItem.self, """
        {"id":2,"title":"y","status":"paused","artist":{"artistName":"Kevin MacLeod"},"album":{"title":"Royalty Free"},"size":1,"sizeleft":0}
        """)
        #expect(album.mediaTitle == "Kevin MacLeod — Royalty Free")
        #expect(album.state == .paused)
    }

    @Test func healthStatusAndDiskSpace() throws {
        let health = try decode([ArrHealthItem].self, """
        [{"source":"IndexerStatusCheck","type":"warning","message":"Indexers unavailable","wikiUrl":"https://wiki.servarr.com"},
         {"source":"Future","type":"somethingNew","message":"?"}]
        """)
        #expect(health[0].type.health == .warning)
        #expect(health[1].type == .unknown)
        let status = try decode(ArrSystemStatus.self, #"{"appName":"Radarr","instanceName":"Radarr","version":"5.26.2.10099","isDebug":false}"#)
        #expect(status.version == "5.26.2.10099")
        let disks = try decode([ArrDiskSpace].self, #"[{"id":1,"path":"/data","label":"","freeSpace":250,"totalSpace":1000}]"#)
        #expect(disks[0].usedFraction == 0.75)
    }

    @Test func calendarPicksTheReleaseInsideTheWindow() throws {
        let start = try #require(APIDate.parse("2026-03-01T00:00:00Z"))
        let end = try #require(APIDate.parse("2026-03-15T00:00:00Z"))
        let movie = try decode(ArrCalendar.Movie.self, """
        {"id":7,"title":"Dune","year":2026,"inCinemas":"2026-02-01T00:00:00Z","physicalRelease":"2026-03-10T00:00:00Z","digitalRelease":"2026-03-03T00:00:00Z","hasFile":false}
        """)
        let item = try #require(movie.upcoming(from: start, to: end))
        #expect(item.detail == "Digital release" && item.isAllDay && item.subtitle == "2026")
        #expect(movie.upcoming(from: end, to: end.addingTimeInterval(86_400)) == nil, "Nothing when every release is outside the window")

        let episode = try decode(ArrCalendar.Episode.self, """
        {"id":3,"title":"Pilot","seasonNumber":1,"episodeNumber":2,"airDateUtc":"2026-03-04T02:00:00Z","hasFile":true,"series":{"title":"Severance"}}
        """)
        #expect(episode.upcoming?.title == "Severance" && episode.upcoming?.subtitle == "S01E02 · Pilot" && episode.upcoming?.hasFile == true)
        #expect(episode.upcoming?.isAllDay == false)

        let album = try decode(ArrCalendar.Album.self, """
        {"id":9,"title":"Blue","releaseDate":"2026-03-05T00:00:00Z","artist":{"artistName":"Joni"},"statistics":{"trackFileCount":0}}
        """)
        #expect(album.upcoming?.subtitle == "Joni" && album.upcoming?.hasFile == false)
    }

    @Test func prowlarrIndexers() throws {
        let indexers = try decode([ProwlarrIndexer].self, """
        [{"id":1,"name":"Example","enable":true,"protocol":"torrent","privacy":"public","fields":[]},{"id":2,"enable":false}]
        """)
        #expect(indexers[0].isEnabled && indexers[0].downloadProtocol == "torrent")
        #expect(indexers[1].name == "Indexer 2")
        let statuses = try decode([ProwlarrIndexerStatus].self, #"[{"id":1,"indexerId":1,"disabledTill":"2030-01-01T00:00:00Z"}]"#)
        #expect(APIDate.parse(statuses[0].disabledTill) != nil)
    }

    @Test(arguments: [("00:04:10", 250.0), ("1.02:00:00", 93_600.0), ("0:16:44", 1_004.0), ("", -1.0), ("nonsense", -1.0)])
    func timeSpans(_ text: String, _ expected: Double) {
        let parsed = Durations.timeSpan(text)
        if expected < 0 { #expect(parsed == nil) } else { #expect(parsed == expected) }
    }
}

struct DownloadClientDecodingTests {
    @Test func qBittorrentTorrentsAndStates() throws {
        let torrents = try decode([QBittorrentTorrent].self, """
        [{"hash":"8c21","name":"debian.iso","size":100,"progress":0.5,"dlspeed":2048,"upspeed":0,"eta":8640000,"state":"stalledDL","category":"","amount_left":50},
         {"hash":"54ed","name":"ubuntu.iso","size":100,"progress":1,"dlspeed":0,"upspeed":10,"eta":0,"state":"stoppedUP","category":"linux","amount_left":0}]
        """)
        #expect(torrents[0].transferItem.state == .stalled)
        #expect(torrents[0].transferItem.eta == nil)
        #expect(torrents[0].transferItem.category == nil)
        #expect(torrents[1].transferItem.state == .completed)
        #expect(torrents[1].transferItem.category == "linux")
        #expect(QBittorrentTorrent(hash: "", name: "", progress: 0, dlspeed: 0, upspeed: 0, state: "pausedDL").transferState == .paused)
    }

    @Test func qBittorrentVersionSelectsEndpoints() {
        #expect(QBittorrentClient.usesStartStop(webAPIVersion: "2.11.2"))
        #expect(QBittorrentClient.usesStartStop(webAPIVersion: "2.12"))
        #expect(!QBittorrentClient.usesStartStop(webAPIVersion: "2.9.3"))
        #expect(!QBittorrentClient.usesStartStop(webAPIVersion: "2.10.4"))
    }

    @Test func sabnzbdQueueFromDocumentedShape() throws {
        let queue = try decode(SABQueueResponse.self, """
        {"queue":{"status":"Downloading","paused":false,"kbpersec":"1296.02","speed":"1.3 M","mb":"1277.65","mbleft":"1271.58","version":"4.5.3",
         "slots":[{"status":"Downloading","index":0,"mb":"1277.65","mbleft":"1271.58","filename":"Example.Release","cat":"*","priority":"Normal",
                   "percentage":"0","nzo_id":"SABnzbd_nzo_p86tgx","timeleft":"0:16:44"}]}}
        """).queue
        #expect(queue.version == "4.5.3")
        let item = queue.slots[0].transferItem
        #expect(item.state == .downloading)
        #expect(item.eta == 1_004)
        #expect(item.category == nil)
        #expect(item.size == Int64(1277.65 * 1_048_576))
    }

    @Test func transmissionTorrentStates() throws {
        let torrent = try decode(TransmissionTorrent.self, """
        {"id":1,"hashString":"abc","name":"t","status":4,"percentDone":0.3,"totalSize":10,"leftUntilDone":7,"rateDownload":5,"rateUpload":0,"eta":-1,"error":0,"errorString":"","labels":["iso"]}
        """)
        #expect(torrent.transferItem.state == .downloading)
        #expect(torrent.transferItem.eta == nil)
        #expect(torrent.transferItem.category == "iso")
        var stopped = torrent
        stopped.status = 0
        stopped.percentDone = 1
        #expect(stopped.transferState == .completed)
        var failed = torrent
        failed.error = 3
        #expect(failed.transferState == .failed)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(RESTClient.formEncode(["password": "a&b=c d+e", "username": "admin"]) == "password=a%26b%3Dc%20d%2Be&username=admin")
    }
}
