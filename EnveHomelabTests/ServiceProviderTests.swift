import Foundation
import Testing
@testable import EnveHomelab

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct ServiceParsingTests {
    @Test func goDurations() {
        #expect(GoDuration.seconds("3h51m57.5s") == 13_917.5)
        #expect(GoDuration.seconds("1m30s") == 90)
        #expect(GoDuration.seconds("250ms") == 0.25)
        #expect(GoDuration.seconds("-2h") == -7_200)
        #expect(GoDuration.seconds("soon") == nil)
        #expect(GoDuration.seconds("3h later") == nil)
    }

    @Test func dotNetAndZonelessTimestamps() throws {
        let utc = try #require(APIDate.parse("2026-09-28T03:00:00.1234567Z"))
        #expect(abs(utc.timeIntervalSince1970 - 1_790_564_400.123) < 0.001)
        let local = try #require(APIDate.parse("2026-09-28T03:00:00"))
        let components = Calendar.current.dateComponents([.hour, .minute], from: local)
        #expect(components.hour == 3 && components.minute == 0, "Zone-less server times read as local time")
        #expect(APIDate.parse("2026-09-28") == nil)
    }

    @Test func looseNumbers() throws {
        let values = try decode([LooseNumber].self, #"["27", 4200, "", null, 1.5]"#)
        #expect(values.map(\.value) == [27, 4_200, nil, nil, 1.5])
    }

    @Test func kavitaPaginationHeader() {
        #expect(KavitaClient.totalItems(fromPagination: #"{"currentPage":1,"itemsPerPage":10,"totalItems":188,"totalPages":19}"#) == 188)
        #expect(KavitaClient.totalItems(fromPagination: nil) == nil)
    }

    @Test func glancesViewsSkipNonDictionaryEntries() {
        let keyed = GlancesClient.parseViews(Data(#"{"/":{"used":{"decoration":"WARNING_LOG"},"free":{"decoration":"DEFAULT"}},"show_pod_name":false}"#.utf8), keyed: true)
        #expect(keyed == ["/": ["used": "WARNING_LOG", "free": "DEFAULT"]])
        #expect(GlancesDecoration.health("WARNING_LOG") == .warning)
        #expect(GlancesDecoration.health("CAREFUL") == .ok)
        #expect(GlancesDecoration.health("SOMETHING_NEW") == nil)
    }

    @Test func torznabInventoryErrorsAndResults() throws {
        let inventory = try TorznabXMLParser.parse(Data("""
        <?xml version="1.0"?><indexers><indexer id="a" configured="true"><title>A &amp; B</title><type>semi-private</type><language>en-US</language><caps><server title="Jackett"/></caps></indexer></indexers>
        """.utf8))
        #expect(inventory.indexers == [JackettIndexer(id: "a", title: "A & B", configured: true, type: "semi-private", language: "en-US")])
        let error = try TorznabXMLParser.parse(Data(#"<error code="100" description="Invalid API Key"/>"#.utf8))
        #expect(error.error?.code == "100")
        let results = try TorznabXMLParser.parse(Data("<rss><channel><item/><item/><item/></channel></rss>".utf8))
        #expect(results.itemCount == 3)
    }

    @Test func nzbgetPausedPartsAndFailingHealth() throws {
        let group = try decode(NZBGetGroup.self, """
        {"NZBID":7,"NZBName":"x","Status":"PAUSED","FileSizeLo":1000,"FileSizeHi":0,"RemainingSizeLo":600,"RemainingSizeHi":0,
         "PausedSizeLo":200,"PausedSizeHi":0,"Health":800,"CriticalHealth":900}
        """)
        let item = group.transferItem(globalRate: 100)
        #expect(item.progress == 0.5, "Paused parts are excluded from progress, like the web UI")
        #expect(item.state == .failed)
        #expect(item.eta == nil, "Paused items have no ETA")
        #expect(item.message == "Too many missing articles to repair")
    }

    @Test func delugeStates() {
        func state(_ name: String, progress: Double = 50) -> TransferState {
            DelugeTorrent(name: "t", state: name, progress: progress).transferState
        }
        #expect(state("Paused", progress: 100) == .completed)
        #expect(state("Paused") == .paused)
        #expect(state("Allocating") == .checking)
        #expect(state("Error") == .failed)
        #expect(DelugeTorrent(name: "t", state: "Seeding", progress: 100, eta: -1).transferItem(id: "h").eta == nil, "-1 means more than a year")
    }

    @Test func maintainerrDueDates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let members = [
            MaintainerrMember(id: 1, addDate: Date(timeIntervalSince1970: 2_000_000_000 - 31 * 86_400).formatted(.iso8601)),
            MaintainerrMember(id: 2, addDate: Date(timeIntervalSince1970: 2_000_000_000 - 86_400).formatted(.iso8601)),
            MaintainerrMember(id: 3, addDate: nil),
        ]
        #expect(MaintainerrDashboard.dueCount(members, deleteAfterDays: 30, now: now) == 1)
        #expect(MaintainerrDashboard.dueCount(members, deleteAfterDays: nil, now: now) == 2, "No waiting period means due at once")
    }

    @Test func hydraInstantsAcceptBothEncodings() throws {
        let values = try decode([HydraInstant].self, #"[1544551917.5, "2026-09-29T12:34:56Z", null]"#)
        #expect(values[0].date == Date(timeIntervalSince1970: 1_544_551_917.5))
        #expect(values[1].date == APIDate.parse("2026-09-29T12:34:56Z"))
        #expect(values[2].date == nil)
    }

    @Test func immichQueueNames() {
        #expect(ImmichDashboard.queueTitle("thumbnailGeneration") == "Thumbnails")
        #expect(ImmichDashboard.queueTitle("integrityCheck") == "Integrity check")
    }

    @Test func credentialStyles() {
        #expect(IntegrationKind.tdarr.credentialStyle.worksWithoutSecret)
        #expect(IntegrationKind.maintainerr.credentialStyle.worksWithoutSecret)
        #expect(!IntegrationKind.komga.credentialStyle.worksWithoutSecret)
        #expect(!IntegrationKind.proxmox.credentialStyle.worksWithoutSecret)
    }
}

struct ServiceDashboardMappingTests {
    @Test func everyKindIsDocumentedAndAddressable() {
        for kind in IntegrationKind.allCases {
            #expect(!kind.guide.steps.isEmpty, "\(kind) needs setup steps")
            #expect(!kind.credentialHelp.isEmpty)
            #expect((try? EndpointURLParser.parse(kind.exampleAddress).get()) != nil, "\(kind) example address must parse")
        }
    }

    @Test func activityCoversOnlyTransferQueues() {
        #expect(IntegrationKind.allCases.filter(\.hasTransferQueue) == [.radarr, .sonarr, .lidarr, .qbittorrent, .sabnzbd, .transmission, .nzbget, .deluge, .qui])
    }

    @MainActor
    @Test func everySampleDashboardRendersWithUniqueActions() async throws {
        for kind in IntegrationKind.allCases {
            guard case .dashboard(let service) = IntegrationConnector.sample(for: kind) else { continue }
            let snapshot = try await service.dashboard()
            #expect(!snapshot.sections.isEmpty, "\(kind) sample has no content")
            let ids = snapshot.actions.map(\.id) + snapshot.sections.flatMap { $0.rows.flatMap(\.actions).map(\.id) }
            #expect(Set(ids).count == ids.count, "\(kind) action ids must be unique")
            let summary = try await service.summary()
            #expect(summary.product == kind.displayName)
        }
    }

    @Test func destructiveActionsAlwaysConfirm() async throws {
        for kind in IntegrationKind.allCases {
            guard case .dashboard(let service) = IntegrationConnector.sample(for: kind) else { continue }
            let snapshot = try await service.dashboard()
            for action in snapshot.actions + snapshot.sections.flatMap({ $0.rows.flatMap(\.actions) }) {
                let lowered = action.title.lowercased()
                if ["remove", "delete", "empty", "handle", "stop"].contains(where: lowered.contains) {
                    #expect(action.confirmation != .none, "\(kind) \(action.id) must be confirmed")
                }
                #expect(!action.consequence.isEmpty && !action.targetName.isEmpty)
            }
        }
    }

    @Test func bazarrOffersResetOnlyWhenThrottled() throws {
        let overview = BazarrOverview(
            status: BazarrStatus(bazarr_version: "1.6.2"), badges: BazarrBadges(episodes: 0, movies: 0, providers: 0, status: 0), health: [],
            providers: [BazarrProvider(name: "p", status: "Good", retry: "-")], tasks: [],
            wantedEpisodes: BazarrPage(data: [], total: 0), wantedMovies: BazarrPage(data: [], total: 0))
        let snapshot = BazarrDashboard.snapshot(overview, operations: SampleBazarr())
        #expect(snapshot.health == .ok)
        #expect(snapshot.headline == "No missing subtitles")
        #expect(snapshot.action("providers:reset") == nil)
    }

    @Test func immichStorageThresholds() {
        func health(_ percent: Double) -> Health {
            ImmichDashboard.snapshot(ImmichOverview(version: "3.2.4", storage: ImmichStorage(diskSizeRaw: 100, diskUseRaw: Int64(percent), diskAvailableRaw: 100 - Int64(percent), diskUsagePercentage: percent)),
                                     operations: SampleImmich()).health
        }
        #expect(health(50) == .ok)
        #expect(health(90) == .warning)
        #expect(health(97) == .critical)
    }
}

struct PlatformParsingTests {
    @Test func restPathsKeepTrailingSlashes() {
        let client = RESTClient(baseURL: URL(string: "http://host/base")!, pinnedFingerprint: nil)
        #expect(client.url(for: "api/core/version/").absoluteString == "http://host/base/api/core/version/", "Django routes need the slash")
        #expect(client.url(for: "api/jobs").absoluteString == "http://host/base/api/jobs")
    }

    @Test func coolifyStatusesAndDeploymentShapes() throws {
        #expect(CoolifyStatus("running:healthy").appHealth == .ok)
        #expect(CoolifyStatus("degraded:unhealthy").appHealth == .warning)
        #expect(CoolifyStatus("exited") == CoolifyStatus("exited:excluded"), "The excluded flag isn't a health value")
        #expect(!CoolifyStatus(nil).isRunning)
        let array = try decode(CoolifyDeploymentList.self, #"[{"deployment_uuid":"a","status":"queued"}]"#)
        let object = try decode(CoolifyDeploymentList.self, #"{"1":{"deployment_uuid":"b","status":"in_progress"},"0":{"deployment_uuid":"a","status":"queued"}}"#)
        #expect(array.items.map(\.deployment_uuid) == ["a"])
        #expect(object.items.map(\.deployment_uuid) == ["a", "b"], "Laravel can emit an object when keys aren't sequential")
    }

    @Test func arcaneHealthAndStreamErrors() {
        #expect(ArcaneContainer(id: "1", names: ["/web"], image: "i", state: "running", status: "Up 2 hours (unhealthy)").dockerHealth == "unhealthy")
        #expect(ArcaneContainer(id: "1", names: [], image: "i", state: "exited", status: "Exited (1)").name == "1")
        #expect(ArcaneClient.streamError(Data("{\"status\":\"pulling\"}\n{\"error\":\"port already allocated\"}\n".utf8)) == "port already allocated")
        #expect(ArcaneClient.streamError(Data("{\"status\":\"done\"}\n".utf8)) == nil)
    }

    @Test func quiCompositeIDs() {
        #expect(QuiClient.split(["1:abc", "2:def", "1:ghi", "bogus"]) == [1: ["abc", "ghi"], 2: ["def"]])
    }

    @Test func synologyStringSizesAndAuthErrors() throws {
        let task = try decode(SynologyTask.self, """
        {"id":"dbid_1","type":"bt","title":"x","size":"1000","status":"downloading","status_extra":null,
         "additional":{"transfer":{"size_downloaded":"250","size_uploaded":"0","speed_download":"50","speed_upload":0}}}
        """)
        #expect(task.transferItem.progress == 0.25)
        #expect(task.transferItem.eta == 15)
        let failed = try decode(SynologyTask.self, #"{"id":"d","title":"y","size":"1","status":"error","status_extra":{"error_detail":"disk_full"}}"#)
        #expect(failed.transferItem.state == .failed)
        #expect(failed.transferItem.message == "Disk full")
        #expect(SynologyClient.authError(400) == .unauthorized)
        #expect(SynologyClient.authError(403) != .unauthorized, "Two-factor accounts get an explanation, not a password error")
    }

    @Test func controlDFailureBodyIsAnArray() throws {
        let failure = try decode(ControlDEnvelope<[String: Int]>.self, #"{"body":[],"success":false,"error":{"message":"Invalid token","code":40100}}"#)
        #expect(failure.body == nil && failure.error?.message == "Invalid token")
    }

    @Test func tracearrEpisodeTitles() {
        let stream = TracearrStream(id: "1", username: "a", mediaTitle: "Pilot", showTitle: "Show", seasonNumber: 1, episodeNumber: 2, state: "playing")
        #expect(stream.displayTitle == "Show · S01E02 Pilot")
    }

    @Test func gluetunPortsAndPublicIP() throws {
        #expect(try decode(GluetunPortForward.self, #"{"port":0}"#).all.isEmpty)
        #expect(try decode(GluetunPortForward.self, #"{"port":5914,"ports":[5914,5915]}"#).all == [5914, 5915])
        let ip = try decode(GluetunPublicIP.self, #"{"public_ip":"203.0.113.9","city":"Oslo","country":"Norway"}"#)
        #expect(ip.place == "Oslo, Norway")
    }

    @Test func komodoAlertsTolerateObjectPayloads() throws {
        let alert = try decode(KomodoAlert.self, #"{"level":"WARNING","ts":1,"data":{"type":"ServerUnreachable","data":{"id":"s","name":"pi","err":{"error":"x","trace":[]}}}}"#)
        #expect(alert.data.type == "ServerUnreachable")
        #expect(alert.targetName == "pi", "Nested objects in the payload don't stop scalar fields decoding")
    }
}
