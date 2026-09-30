import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh, which starts Scripts/integration-fixture-server.mjs.
enum FixtureServer {
    static let http = ProcessInfo.processInfo.environment["PROVIDER_HTTP_URL"].flatMap(URL.init(string:))
    static let tls = ProcessInfo.processInfo.environment["PROVIDER_TLS_URL"].flatMap(URL.init(string:))
    static let tlsFingerprint = ProcessInfo.processInfo.environment["PROVIDER_TLS_FINGERPRINT"]

    static func url(_ path: String) throws -> URL {
        try #require(http).appending(path: path)
    }

    static func log() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: try url("__log"))
        return try JSONDecoder().decode([String].self, from: data)
    }
}

@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct ProviderIntegrationTests {
    @Test func arrCalendarsSendTheWindowAndMapEachApp() async throws {
        let start = Calendar.current.startOfDay(for: .now)
        let end = start.addingTimeInterval(7 * 86_400)
        let movies = try await ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil).calendar(from: start, to: end, includeUnmonitored: false)
        #expect(movies.map(\.detail) == ["Digital release"], "Releases before the window are skipped")
        let episodes = try await ArrClient(kind: .sonarr, url: try FixtureServer.url("sonarr"), apiKey: "arr-key", pinnedFingerprint: nil).calendar(from: start, to: end, includeUnmonitored: false)
        #expect(episodes.first?.title == "Pioneer One" && episodes.first?.hasFile == true)
        let albums = try await ArrClient(kind: .lidarr, url: try FixtureServer.url("lidarr"), apiKey: "arr-key", pinnedFingerprint: nil).calendar(from: start, to: end, includeUnmonitored: false)
        #expect(albums.first?.subtitle == "Blender" && albums.first?.hasFile == false)
        #expect(try await ArrClient(kind: .prowlarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil).calendar(from: start, to: end, includeUnmonitored: false).isEmpty)
        let all = try await ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil).calendar(from: start, to: end, includeUnmonitored: true)
        #expect(all.map(\.isMonitored) == [true, false])
    }

    @Test func wantedMissingIsNewestFirst() async throws {
        let radarr = try await ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil).missing(limit: 20)
        #expect(radarr.total == 7, "The total comes from the server, not the page")
        #expect(radarr.items.map(\.title) == ["Cosmos Laundromat", "Tears of Steel"])
        #expect(radarr.items.first?.detail == "Digital release", "Future releases are ignored when picking the missing date")
        let sonarr = try await ArrClient(kind: .sonarr, url: try FixtureServer.url("sonarr"), apiKey: "arr-key", pinnedFingerprint: nil).missing(limit: 20)
        #expect(sonarr.items.first?.subtitle == "S01E04 · Sermon")
        #expect(try await ArrClient(kind: .lidarr, url: try FixtureServer.url("lidarr"), apiKey: "arr-key", pinnedFingerprint: nil).missing(limit: 20).total == 0)
    }

    @Test func radarrSnapshotCommandAndRemoval() async throws {
        let client = ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil)
        let snapshot = try await client.snapshot()
        #expect(snapshot.status.version == "5.26.2.10099")
        #expect(snapshot.queue.first?.mediaTitle == "Sintel (2010)")
        #expect(snapshot.health.first?.type == .warning)
        try await client.run(.rssSync)
        try await client.removeFromQueue(id: 7, removeFromClient: true, blocklist: false)
        let log = try await FixtureServer.log()
        #expect(log.contains("arr command RssSync"))
        #expect(log.contains("arr delete 7 removeFromClient=true blocklist=false"))

        let wrongKey = ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "nope", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrongKey.snapshot() }
    }

    @Test func qBittorrentLoginCookieAndModernEndpoints() async throws {
        let client = QBittorrentClient(url: try FixtureServer.url("qbt"), username: "admin", password: "p@ss&word", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "v5.1.2")
        #expect(overview.items.first?.state == .downloading)
        try await client.pause(["abc123"])
        try await client.remove(["abc123"], deleteData: true)
        let log = try await FixtureServer.log()
        #expect(log.contains("qbt stop abc123"), "WebAPI 2.11 must use /torrents/stop")
        #expect(log.contains("qbt delete abc123 deleteFiles=true"))

        let wrong = QBittorrentClient(url: try FixtureServer.url("qbt"), username: "admin", password: "wrong", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func transmissionSessionHandshakeAndBasicAuth() async throws {
        let client = TransmissionClient(url: try #require(FixtureServer.http), username: "rpc", password: "secret", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version?.hasPrefix("4.0.6") == true)
        #expect(overview.items.first?.state == .completed || overview.items.first?.state == .seeding)
        try await client.remove(["def456"], deleteData: false)
        #expect(try await FixtureServer.log().contains("transmission remove def456 delete=false"))

        let wrong = TransmissionClient(url: try #require(FixtureServer.http), username: "rpc", password: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func sabnzbdQueueActionsAndKeyErrors() async throws {
        let client = SABnzbdClient(url: try FixtureServer.url("sab"), apiKey: "sab-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.items.first?.eta == 90)
        #expect(overview.downloadRate == 1024 * 1024)
        try await client.pause(["SABnzbd_nzo_1"])
        try await client.pauseAll()
        let log = try await FixtureServer.log()
        #expect(log.contains("sab pause SABnzbd_nzo_1 del_files="))
        #expect(log.contains("sab pause"))
        let wrong = SABnzbdClient(url: try FixtureServer.url("sab"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func jellyfinAndEmbyAuthSessionsAndCommands() async throws {
        let jellyfin = MediaBrowserClient(kind: .jellyfin, url: try FixtureServer.url("jf"), apiKey: "jf-key", deviceID: UUID(), pinnedFingerprint: nil)
        #expect(try await jellyfin.info().name == "Fixture Jellyfin")
        #expect(try await jellyfin.sessions().map(\.id) == ["s1"])
        #expect(try await jellyfin.libraries().first?.kind == .movies)
        #expect(try await jellyfin.continueWatching(userID: "u1", limit: 5).first?.progress == 0.5)
        try await jellyfin.send(.pause, to: "s1")

        let emby = MediaBrowserClient(kind: .emby, url: try #require(FixtureServer.http), apiKey: "emby-key", deviceID: UUID(), pinnedFingerprint: nil)
        #expect(try await emby.info().name == "Fixture Emby")
        #expect(try await emby.libraries().first?.id == "lib1")
        #expect(try await emby.users().first?.name == "alex")
        #expect(try await emby.continueWatching(userID: "u1", limit: 5).count == 1)
        try await emby.refresh(libraryID: nil)
        let log = try await FixtureServer.log()
        #expect(log.contains("jf Pause s1"))
        #expect(log.contains("emby refresh"))
    }

    @Test func plexTokenSessionsAndPlexPassBoundary() async throws {
        let plex = PlexClient(url: try FixtureServer.url("plex"), token: "plex-token", clientID: UUID(), pinnedFingerprint: nil)
        #expect(try await plex.info().name == "Fixture Plex")
        #expect(try await plex.sessions().first?.id == "plex-session")
        #expect(try await plex.continueWatching(userID: nil, limit: 5).first?.progress == 0.5)
        #expect(try await plex.libraries().map(\.id) == ["1"])
        try await plex.refresh(libraryID: "1")
        await #expect(throws: NetworkError.forbidden("Plex only allows stopping streams on servers with an active Plex Pass.")) {
            try await plex.terminate(sessionID: "plex-session", reason: "test")
        }
        let log = try await FixtureServer.log()
        #expect(log.contains("plex refresh 1"))
        #expect(log.contains("plex terminate plex-session"))
    }

    @Test func proxmoxTokenActionAndTaskPolling() async throws {
        let client = ProxmoxClient(url: try FixtureServer.url("pve"), tokenID: "ci@pve!homelab", secret: "0000-1111", pinnedFingerprint: nil)
        let snapshot = try await client.snapshot()
        #expect(snapshot.version == "9.0.10")
        let guest = try #require(snapshot.guests.first)
        #expect(try await client.perform(.shutdown, on: guest) == "OK")
        #expect(try await FixtureServer.log().contains("pve shutdown 100"))

        let wrong = ProxmoxClient(url: try FixtureServer.url("pve"), tokenID: "ci@pve!homelab", secret: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.snapshot() }
    }

    @Test func portainerProxyLogsAndStacks() async throws {
        let client = PortainerClient(url: try FixtureServer.url("portainer"), apiKey: "ptr_fixture", pinnedFingerprint: nil)
        #expect(try await client.version() == "2.33.1")
        let environment = try #require(try await client.environments().first)
        #expect(try await client.containers(environmentID: environment.Id).first?.stack == "monitoring")
        #expect(try await client.logs(environmentID: 1, containerID: "c1", tail: 10) == ["started", "warning: slow"])
        try await client.perform(.start, environmentID: 1, containerID: "c1")
        let stack = try #require(try await client.stacks().first)
        try await client.setStack(stack, active: false)
        let log = try await FixtureServer.log()
        #expect(log.contains("portainer start c1"), "304 Not Modified counts as success")
        #expect(log.contains("portainer stop stack 3 endpoint=1"))
    }

    @Test func piholeSessionIsReleasedAndBlockingTimerSent() async throws {
        let client = PiholeClient(url: try FixtureServer.url("pihole"), password: "app-password", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "v6.1.4")
        #expect(overview.blockedFraction == 0.25)
        #expect(overview.blocklistDomains == 123_456)
        try await client.setBlocking(false, for: 300)
        let log = try await FixtureServer.log()
        #expect(log.contains("pihole blocking false timer=300"))
        #expect(log.filter { $0.hasPrefix("pihole logout") }.count >= 2, "Every session must be released")
        let wrong = PiholeClient(url: try FixtureServer.url("pihole"), password: "nope", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func adGuardBasicAuthStatsAndPause() async throws {
        let client = AdGuardHomeClient(url: try FixtureServer.url("adguard"), username: "admin", password: "guard", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.blockedQueries == 310)
        #expect(overview.averageResponseMilliseconds == 12)
        try await client.setBlocking(false, for: 1_800)
        try await client.setBlocking(true, for: nil)
        let log = try await FixtureServer.log()
        #expect(log.contains("adguard protection false duration=1800000"), "AdGuard pauses are in milliseconds")
        #expect(log.contains("adguard protection true duration=undefined"))
    }

    @Test func unifiPaginatesAndRestarts() async throws {
        let client = UniFiClient(url: try FixtureServer.url("unifi"), apiKey: "unifi-key", pinnedFingerprint: nil)
        let snapshot = try await client.snapshot(siteID: nil)
        #expect(snapshot.version == "10.6.106")
        #expect(snapshot.devices.count == 2, "Pages of one item must be followed to totalCount")
        #expect(snapshot.clients.first?.connectionName == "Wi-Fi")
        let gateway = try #require(snapshot.devices.first { $0.id == "dev-1" })
        try await client.restart(gateway, siteID: "site-1")
        #expect(try await FixtureServer.log().contains("unifi RESTART dev-1"))
    }

    @Test func homeAssistantAreasFromTemplateAndServiceCalls() async throws {
        let client = HomeAssistantClient(url: try FixtureServer.url("ha"), token: "ha-token", pinnedFingerprint: nil)
        let snapshot = try await client.snapshot()
        #expect(snapshot.areas.first?.entities == ["light.kitchen"])
        let light = try #require(snapshot.entities.first { $0.entity_id == "light.kitchen" })
        #expect(light.control == .toggle(isOn: false))
        #expect(snapshot.entities.first { $0.domain == "lock" }?.control == nil, "Locks stay read-only")
        try await client.perform(try #require(light.control), on: light, turnOn: true)
        #expect(try await FixtureServer.log().contains("ha light.turn_on light.kitchen"))
    }

    @Test func tailscaleAndCloudflareReadOnlyStatus() async throws {
        let tailscale = TailscaleClient(token: "tskey-api-fixture", baseURL: try FixtureServer.url("tailscale"))
        let devices = try await tailscale.devices()
        #expect(devices.first?.displayName == "atlas")
        #expect(devices.first?.keyExpiresSoon() == true)
        let cloudflare = CloudflareClient(accountID: "acct-1", token: "cf-token", baseURL: try FixtureServer.url("cloudflare"))
        let snapshot = try await cloudflare.snapshot()
        #expect(snapshot.tokenStatus == "active")
        #expect(snapshot.tunnels.first?.health == .warning)
        #expect(snapshot.zones == nil, "A token without zone access reports zones as unavailable, not as an error")
        let wrong = CloudflareClient(accountID: "acct-1", token: "bad", baseURL: try FixtureServer.url("cloudflare"))
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.snapshot() }
    }

    @Test func diagnosticsWalkEveryLayer() async throws {
        let healthy = await ConnectionDiagnostics.run(url: try FixtureServer.url("radarr"), pinnedFingerprint: nil) {
            try await ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "arr-key", pinnedFingerprint: nil).summary().headline
        }
        #expect(healthy.map(\.title) == ["Address", "Name lookup", "Network connection", "HTTP", "Sign-in"])
        #expect(healthy.allSatisfy { $0.status == .passed }, "\(healthy)")

        let badKey = await ConnectionDiagnostics.run(url: try FixtureServer.url("radarr"), pinnedFingerprint: nil) {
            try await ArrClient(kind: .radarr, url: try FixtureServer.url("radarr"), apiKey: "wrong", pinnedFingerprint: nil).summary().headline
        }
        #expect(badKey.last?.status == .failed && badKey.last?.title == "Sign-in")

        let closed = await ConnectionDiagnostics.run(url: URL(string: "http://127.0.0.1:9")!, pinnedFingerprint: nil, authenticate: { "" })
        #expect(closed.first { $0.title == "Network connection" }?.status == .failed)
        #expect(closed.filter { $0.status == .skipped }.map(\.title) == ["HTTP", "Sign-in"])

        if let tls = FixtureServer.tls {
            let untrusted = await ConnectionDiagnostics.run(url: tls.appending(path: "rest"), pinnedFingerprint: nil, authenticate: nil)
            #expect(untrusted.first { $0.title == "TLS certificate" }?.status == .failed)
            let pinned = await ConnectionDiagnostics.run(url: tls.appending(path: "rest"), pinnedFingerprint: FixtureServer.tlsFingerprint, authenticate: nil)
            #expect(pinned.first { $0.title == "TLS certificate" }?.status == .passed, "\(pinned)")
        }
    }

    @Test func ntfyPublishAndPoll() async throws {
        let configuration = NtfyConfiguration(serverURL: try FixtureServer.url("ntfy"), topic: "homelab")
        let client = NtfyClient(configuration: configuration, token: "tk_fixture")
        let event = AlertEvent(date: .now, severity: .critical, sourceKind: .serviceCheck, sourceID: "x", sourceName: "Plex", title: "Plex: critical", body: "The server couldn't be reached.")
        try await client.publish(event)
        let messages = try await client.poll(since: nil)
        #expect(messages.map(\.id) == ["m1", "m2"], "open and keepalive events are not messages")
        #expect(messages.first?.severity == .critical)
        let log = try await FixtureServer.log()
        #expect(log.contains("ntfy publish homelab title=Plex: critical priority=5 body=The server couldn't be reached."))
        #expect(log.contains("ntfy poll since=1h"), "A first poll must not replay the whole cache")
        let wrong = NtfyClient(configuration: configuration, token: "bad")
        await #expect(throws: NetworkError.self) { _ = try await wrong.poll(since: "m2") }
    }

    @Test(.enabled(if: FixtureServer.tls != nil)) func restOverPinnedTLS() async throws {
        let url = try #require(FixtureServer.tls)
        let unpinned = RESTClient(baseURL: url, pinnedFingerprint: nil)
        do {
            _ = try await unpinned.json(.get("rest"), as: [String].self)
            Issue.record("A self-signed certificate must not be accepted without review")
        } catch let error as NetworkError {
            #expect(error.reviewableCertificate?.sha256Fingerprint == FixtureServer.tlsFingerprint, "\(error)")
        }
        let pinned = RESTClient(baseURL: url, pinnedFingerprint: FixtureServer.tlsFingerprint)
        #expect(try await pinned.json(.get("rest"), as: [String].self) == ["secure"])
    }

    @Test(.enabled(if: FixtureServer.tls != nil)) func trueNASOverPinnedTLS() async throws {
        let url = try #require(FixtureServer.tls)
        let unpinned = TrueNASClient(url: url, apiKey: "truenas-key", pinnedFingerprint: nil)
        do {
            _ = try await unpinned.snapshot()
            Issue.record("A self-signed certificate must not be accepted without review")
        } catch let error as NetworkError {
            #expect(error.reviewableCertificate?.sha256Fingerprint == FixtureServer.tlsFingerprint, "\(error)")
        }

        let client = TrueNASClient(url: url, apiKey: "truenas-key", pinnedFingerprint: FixtureServer.tlsFingerprint)
        let snapshot = try await client.snapshot()
        #expect(snapshot.system.hostname == "vault")
        #expect(snapshot.pools.first?.usedFraction == 0.25)
        #expect(snapshot.alerts.first?.message == "Fixture alert")
        #expect(snapshot.datasets.first?.used?.bytes == 10)
        try await client.setAlert(try #require(snapshot.alerts.first), dismissed: true)
        #expect(try await FixtureServer.log().contains("truenas dismiss alert-1"))

        let wrongKey = TrueNASClient(url: url, apiKey: "nope", pinnedFingerprint: FixtureServer.tlsFingerprint)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrongKey.snapshot() }
    }
}
