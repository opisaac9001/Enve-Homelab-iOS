import Foundation
import Testing
@testable import EnveHomelab

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct MediaBrowserDecodingTests {
    @Test func jellyfinSessionWithTranscode() throws {
        let sessions = try decode([MediaBrowserClient.Session].self, """
        [{"Id":"s1","UserName":"alex","Client":"Jellyfin Web","DeviceName":"Firefox","SupportsRemoteControl":true,
          "NowPlayingItem":{"Name":"Pilot","SeriesName":"Pioneer One","ParentIndexNumber":1,"IndexNumber":1,"Type":"Episode","RunTimeTicks":27000000000},
          "PlayState":{"PositionTicks":13500000000,"IsPaused":true,"PlayMethod":"Transcode"},
          "TranscodingInfo":{"VideoCodec":"h264","AudioCodec":"aac","IsVideoDirect":false,"CompletionPercentage":42.5,"TranscodeReasons":["VideoCodecNotSupported"],"HardwareAccelerationType":"vaapi"}},
         {"Id":"idle","UserName":"sam","Client":"Android TV"}]
        """)
        let active = sessions.compactMap(\.mediaSession)
        #expect(active.count == 1)
        let session = try #require(active.first)
        #expect(session.title == "Pioneer One")
        #expect(session.subtitle == "S1E1 · Pilot")
        #expect(session.isPaused)
        #expect(session.progress == 0.5)
        #expect(session.playMethod == .transcode)
        #expect(session.transcode?.progress == 0.425)
        #expect(session.transcode?.hardwareAccelerated == true)
        #expect(session.supportsRemoteControl)
    }

    @Test func itemsAndVirtualFolders() throws {
        struct Items: Decodable { var Items: [MediaBrowserClient.Item] }
        let items = try decode(Items.self, """
        {"Items":[{"Id":"1","Name":"Sintel","Type":"Movie","ProductionYear":2010,"DateCreated":"2025-01-02T03:04:05.0000000Z"},
                  {"Id":"2","Name":"Pilot","Type":"Episode","SeriesName":"Pioneer One","ParentIndexNumber":1,"IndexNumber":1,"UserData":{"PlayedPercentage":25}}],"TotalRecordCount":2}
        """).Items.map(\.mediaItem)
        #expect(items[0].title == "Sintel" && items[0].subtitle == "2010")
        #expect(items[0].addedAt != nil)
        #expect(items[1].title == "Pioneer One" && items[1].subtitle == "S01E01 · Pilot")
        #expect(items[1].progress == 0.25)
        let folders = try decode([MediaBrowserClient.VirtualFolder].self, #"[{"Name":"Movies","CollectionType":"movies","ItemId":"abc","RefreshStatus":"Idle"}]"#)
        #expect(MediaLibraryKind(collectionType: folders[0].CollectionType) == .movies)
    }

    @Test func tickConversion() {
        #expect(Ticks.seconds(10_000_000) == 1)
        #expect(Ticks.seconds(nil) == nil)
    }
}

struct PlexDecodingTests {
    @Test func sessionsFromMediaContainer() throws {
        let container = try decode(PlexClient.Container<PlexClient.MetadataList>.self, """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"10","sessionKey":"3","title":"Sintel","type":"movie","year":2010,"viewOffset":444000,"duration":888000,
           "User":{"id":"1","title":"alex"},"Player":{"title":"Living Room","product":"Plex for Apple TV","state":"playing"},
           "Session":{"id":"abc123","bandwidth":8000,"location":"lan"}},
          {"ratingKey":"11","title":"Pilot","grandparentTitle":"Pioneer One","parentIndex":1,"index":1,"type":"episode","viewOffset":0,"duration":1000,
           "Player":{"title":"Chrome","product":"Plex Web","state":"paused"},"Session":{"id":"def456"},
           "TranscodeSession":{"videoDecision":"transcode","audioDecision":"copy","progress":55.0,"speed":2.4,"throttled":true,"transcodeHwFullPipeline":true}}]}}
        """).MediaContainer.Metadata ?? []
        let sessions = container.map(\.mediaSession)
        #expect(sessions[0].id == "abc123")
        #expect(sessions[0].playMethod == .directPlay)
        #expect(sessions[0].progress == 0.5)
        #expect(sessions[0].user == "alex")
        #expect(sessions[1].title == "Pioneer One")
        #expect(sessions[1].subtitle == "S01E01 · Pilot")
        #expect(sessions[1].isPaused)
        #expect(sessions[1].playMethod == .transcode)
        #expect(sessions[1].transcode?.progress == 0.55)
        #expect(sessions[1].transcode?.throttled == true)
    }

    @Test func sectionsHubsAndRecentlyAdded() throws {
        let sections = try decode(PlexClient.Container<PlexClient.DirectoryList>.self, """
        {"MediaContainer":{"size":2,"Directory":[{"key":"1","title":"Movies","type":"movie","refreshing":false},{"key":"2","title":"TV","type":"show","refreshing":true}]}}
        """).MediaContainer.Directory ?? []
        #expect(sections.map(\.key) == ["1", "2"])
        #expect(MediaLibraryKind(collectionType: sections[1].type) == .shows)
        let hubs = try decode(PlexClient.Container<PlexClient.HubList>.self, """
        {"MediaContainer":{"Hub":[{"title":"Continue Watching","Metadata":[{"ratingKey":"5","title":"Sintel","type":"movie","viewOffset":100,"duration":400}]}]}}
        """).MediaContainer.Hub ?? []
        #expect(hubs.first?.Metadata?.first?.mediaItem.progress == 0.25)
        let recent = try decode(PlexClient.Container<PlexClient.MetadataList>.self, #"{"MediaContainer":{"Metadata":[{"ratingKey":"9","title":"Sintel","type":"movie","year":2010,"addedAt":1700000000}]}}"#)
        #expect(recent.MediaContainer.Metadata?.first?.mediaItem.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

struct MediaManagementDecodingTests {
    @Test func jellyfinStreamsFollowPlayStateIndexes() throws {
        let session = try decode(MediaBrowserClient.Session.self, """
        {"Id":"s","NowPlayingItem":{"Name":"x","Type":"Movie","MediaStreams":[
           {"Type":"Video","Index":0,"DisplayTitle":"4K HEVC"},{"Type":"Audio","Index":1,"Codec":"eac3","Language":"eng"},
           {"Type":"Audio","Index":2,"DisplayTitle":"Commentary"},{"Type":"Subtitle","Index":3,"DisplayTitle":"English"},{"Type":"Data","Index":4}]},
         "PlayState":{"AudioStreamIndex":2,"SubtitleStreamIndex":3},"Capabilities":{"SupportedCommands":["SetSubtitleStreamIndex"]}}
        """).mediaSession
        let media = try #require(session)
        #expect(media.streams.count == 4, "Data streams are ignored")
        #expect(media.selectedAudio?.title == "Commentary")
        #expect(media.streams.first { $0.index == 1 }?.title == "eng EAC3", "Streams without a display title fall back to language and codec")
        #expect(media.selectedSubtitle?.index == 3)
        #expect(media.canSwitch(.subtitle) && !media.canSwitch(.audio) && !media.canMessage)
    }

    @Test func scheduledTaskOutcomes() throws {
        let task = try decode(MediaBrowserClient.ScheduledTask.self, """
        {"Id":"t","Name":"Refresh Guide","State":"Cancelling","CurrentProgressPercentage":12.5,
         "LastExecutionResult":{"EndTimeUtc":"2026-09-28T02:00:00.0000000Z","Status":"Aborted","ErrorMessage":""}}
        """).mediaTask
        #expect(task.state == .cancelling && task.progress == 0.125)
        #expect(task.lastOutcome == .aborted && task.lastError == nil)
        #expect(task.lastRun != nil)
    }

    @Test func plexSelectedMediaStreams() throws {
        let metadata = try decode(PlexClient.Metadata.self, """
        {"title":"x","type":"movie","Media":[{"selected":false,"Part":[{"Stream":[{"id":9,"streamType":2,"displayTitle":"Other version"}]}]},
          {"selected":true,"Part":[{"Stream":[{"id":1,"streamType":1,"displayTitle":"1080p"},{"id":2,"streamType":2,"displayTitle":"English","selected":true},
                                              {"id":3,"streamType":2,"displayTitle":"French"},{"id":4,"streamType":3,"displayTitle":"English (SRT)"}]}]}]}
        """)
        let streams = metadata.streams
        #expect(streams.map(\.title) == ["1080p", "English", "French", "English (SRT)"], "Only the selected media version's streams")
        #expect(streams.filter(\.isSelected).map(\.title) == ["1080p", "English"], "An unselected subtitle means none is showing")
    }

    @Test func tautulliTrackDescriptions() throws {
        let session = try decode(TautulliSession.self, """
        {"stream_audio_codec":"eac3","audio_language":"English","stream_audio_channel_layout":"5.1(side)","audio_decision":"copy",
         "subtitle_codec":"","stream_subtitle_codec":"","subtitle_decision":""}
        """)
        #expect(session.tracks == "Audio: English EAC3 5.1(side) (copied)")
        #expect(try decode(TautulliSession.self, "{}").tracks == nil)
    }
}
