import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh; each fixture route enforces the vendor's documented authentication.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct PlatformIntegrationTests {
    private func perform(_ snapshot: DashboardSnapshot, _ id: String) async throws {
        try await #require(snapshot.action(id), "Missing action \(id)").perform()
    }

    @Test func synologyDiscoveryNamedSessionsAndRelogin() async throws {
        let client = SynologyClient(url: try FixtureServer.url("synology"), account: "app-user", password: "syno-pass", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.downloadStationVersion == "4.0.1-4760", "An expired Download Station session (119) signs in again")
        #expect(overview.tasks?.first?.transferItem.progress == 0.5)
        #expect(overview.guests?.first?.guest_name == "ha-os")
        #expect(overview.downloadRate == 2048)
        let snapshot = SynologyDashboard.snapshot(overview, operations: client)
        #expect(snapshot.action("vm:g1:poweroff")?.confirmation == .typed)
        try await perform(snapshot, "vm:g1:shutdown")
        try await perform(snapshot, "task:dbid_1:pause")
        await #expect(throws: NetworkError.graphQL(["Download Station couldn't delete task dbid_9 (error 404)."])) { try await client.tasks("delete", ids: ["dbid_9"]) }
        let log = try await FixtureServer.log()
        #expect(log.contains("synology vm shutdown g1"))
        #expect(log.contains("synology task pause dbid_1 force_complete=null"))
        #expect(log.contains("synology task delete dbid_9 force_complete=false"), "Deleting never force-completes incomplete files")

        let wrong = SynologyClient(url: try FixtureServer.url("synology"), account: "app-user", password: "nope", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
        let twoFactor = SynologyClient(url: try FixtureServer.url("synology"), account: "app-user", password: "two-factor", pinnedFingerprint: nil)
        await #expect(throws: SynologyClient.authError(403)) { _ = try await twoFactor.overview() }
    }

    @Test func dockhandEnvironmentsActionsAndFailures() async throws {
        let client = DockhandClient(url: try FixtureServer.url("dockhand"), token: "dh_fixture", pinnedFingerprint: nil)
        let snapshot = try await client.dashboard()
        #expect(snapshot.health == .critical, "An unhealthy container is critical")
        #expect(snapshot.headline == "2 of 2 containers running · 1 need attention")
        try await perform(snapshot, "container:1:c1:restart")
        await #expect(throws: NetworkError.graphQL(["compose stop failed"])) { try await client.stack(.stop, name: "media stack", environment: 1) }
        let log = try await FixtureServer.log()
        #expect(log.contains("dockhand containers c1 restart"))
        #expect(log.contains("dockhand stacks media stack stop"), "Stack names with spaces are encoded in the path")

        let wrong = DockhandClient(url: try FixtureServer.url("dockhand"), token: "dh_wrong", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func komodoReadsAndFollowsExecutionUpdates() async throws {
        let client = KomodoClient(url: try FixtureServer.url("komodo"), apiKey: "K_fixture_K", apiSecret: "S_fixture_S", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "2.3.3")
        #expect(overview.alerts.first?.targetName == "pi")
        let snapshot = KomodoDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .critical)
        #expect(snapshot.sections.first { $0.id == "deployments" }?.rows.first?.actions.isEmpty == true, "Undeployed resources offer no lifecycle actions")
        try await perform(snapshot, "stack:st1:restart")
        await #expect(throws: NetworkError.graphQL(["User does not have Execute permission on Stack"])) { try await client.stack(.stop, id: "st1") }
        #expect(try await FixtureServer.log().contains(#"komodo RestartStack {"stack":"st1"}"#))

        let wrong = KomodoClient(url: try FixtureServer.url("komodo"), apiKey: "K_fixture_K", apiSecret: "wrong", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func coolifyResourcesAndSafeActions() async throws {
        let client = CoolifyClient(url: try FixtureServer.url("coolify"), token: "1|coolify-token", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "4.3.23", "Version is plain text")
        #expect(overview.deployments.map(\.deployment_uuid) == ["dep1", "dep2"])
        let snapshot = CoolifyDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .warning)
        #expect(snapshot.action("applications:app1:stop")?.confirmation == .destructive)
        try await perform(snapshot, "applications:app1:stop")
        try await perform(snapshot, "applications:app1:deploy")
        try await perform(snapshot, "cancel:dep1")
        let log = try await FixtureServer.log()
        #expect(log.contains("coolify /applications/app1/stop?docker_cleanup=false"), "Stop never prunes volumes or networks")
        #expect(log.contains("coolify /deploy?uuid=app1"))
        #expect(log.contains("coolify /deployments/dep1/cancel"))

        let wrong = CoolifyClient(url: try FixtureServer.url("coolify"), token: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func arcaneScopedEnvironmentsAndStreamedErrors() async throws {
        let client = ArcaneClient(url: try FixtureServer.url("arcane"), apiKey: "arc_fixture", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "v2.14.0")
        #expect(overview.environments.count == 2, "Disabled environments are skipped")
        #expect(overview.environments.last?.error == "API key lacks containers:list for this environment")
        #expect(overview.environments.first?.projects.first?.name == "immich")
        await #expect(throws: NetworkError.graphQL(["port 2283 already allocated"])) { try await client.project(.start, id: "p1", environment: "0") }
        try await client.container(.restart, id: "a1", environment: "0")
        let log = try await FixtureServer.log()
        #expect(log.contains("arcane project up p1"))
        #expect(log.contains("arcane containers a1 restart"))

        let wrong = ArcaneClient(url: try FixtureServer.url("arcane"), apiKey: "arc_wrong", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func beszelLoginRefreshSystemsAndPause() async throws {
        let client = BeszelClient(url: try FixtureServer.url("beszel"), email: "app@example.com", password: "beszel-pass", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "0.20.0")
        #expect(overview.systems.map(\.status) == ["up", "down"])
        #expect(overview.alerts.count == 1)
        let snapshot = BeszelDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .critical)
        try await perform(snapshot, "pause:sys2")
        #expect(try await FixtureServer.log().contains("beszel paused sys2"))

        let wrong = BeszelClient(url: try FixtureServer.url("beszel"), email: "app@example.com", password: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
        let mfa = BeszelClient(url: try FixtureServer.url("beszel"), email: "mfa@example.com", password: "x", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.forbidden("This Beszel hub requires a one-time code at sign-in, which the app doesn't support.")) { _ = try await mfa.overview() }
    }

    @Test func technitiumTokenInBodyPauseAndResume() async throws {
        let client = TechnitiumClient(url: try FixtureServer.url("technitium"), token: "tech-token", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "15.5.1")
        #expect(!overview.blockingEnabled)
        #expect((overview.pauseRemaining ?? 0) > 500)
        #expect(overview.blockedQueries == 49)
        try await client.setBlocking(false, for: 90)
        try await client.setBlocking(true, for: nil)
        let log = try await FixtureServer.log()
        #expect(log.contains("technitium pause 2"), "Pauses round up to whole minutes")
        #expect(log.contains("technitium set enableBlocking=true keys=enableBlocking,token"), "Only the blocking setting is sent")

        let wrong = TechnitiumClient(url: try FixtureServer.url("technitium"), token: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func controlDProfilesDevicesAndPause() async throws {
        let client = ControlDClient(token: "cd-token", baseURL: try FixtureServer.url("controld"))
        let snapshot = try await client.dashboard()
        #expect(snapshot.health == .warning, "A hard-disabled endpoint needs attention")
        try await perform(snapshot, "pause:p1")
        try await perform(snapshot, "resume:p1")
        let log = try await FixtureServer.log()
        #expect(log.contains("controld p1 disable_ttl=future"))
        #expect(log.contains("controld p1 disable_ttl=0"))

        let wrong = ControlDClient(token: "bad", baseURL: try FixtureServer.url("controld"))
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func nextDNSAnalyticsAndAllowlist() async throws {
        let client = NextDNSClient(profileID: "abc123", apiKey: "nd-key", baseURL: try FixtureServer.url("nextdns"))
        let overview = try await client.overview()
        #expect(overview.total == 1000 && overview.blocked == 200)
        #expect(overview.blockedDomains.first?.domain == "ads.example.com")
        try await client.allow(domain: "ads.example.com")
        await #expect(throws: NetworkError.graphQL(["Invalid domain"])) { try await client.allow(domain: "bad..domain") }
        #expect(try await FixtureServer.log().contains("nextdns allow ads.example.com active=true"))

        let wrong = NextDNSClient(profileID: "abc123", apiKey: "bad", baseURL: try FixtureServer.url("nextdns"))
        await #expect(throws: NetworkError.self) { _ = try await wrong.overview() }
    }

    @Test func gluetunPerRouteRolesAndLegacyPortForward() async throws {
        let client = GluetunClient(url: try FixtureServer.url("gluetun"), username: nil, secret: "glu-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.vpn?.status == "running")
        #expect(overview.publicIP == nil)
        #expect(overview.forbiddenRoutes == ["v1/publicip/ip"], "A route the role doesn't grant is reported, not fatal")
        #expect(overview.portForward?.all == [5914], "Pre-3.41 servers use the OpenVPN port-forward route")
        let snapshot = GluetunDashboard.snapshot(overview, operations: client)
        #expect(snapshot.action("vpn:stop")?.confirmation == .destructive)
        try await perform(snapshot, "vpn:stop")
        #expect(try await FixtureServer.log().contains("gluetun vpn stopped"))

        let wrong = GluetunClient(url: try FixtureServer.url("gluetun"), username: nil, secret: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func quiInstancesAndExplicitBulkActions() async throws {
        let client = QuiClient(url: try FixtureServer.url("qui"), apiKey: "qui-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "v1.8.0")
        #expect(overview.items.map(\.id) == ["1:h1"], "Disconnected and inactive instances are skipped")
        #expect(overview.items.first?.subtitle == "seedbox")
        #expect(overview.downloadRate == 4096)
        try await client.pause(["1:h1"])
        try await client.remove(["1:h1"], deleteData: true)
        let log = try await FixtureServer.log()
        #expect(log.contains("qui pause h1 deleteFiles=undefined"))
        #expect(log.contains("qui delete h1 deleteFiles=true"))

        let wrong = QuiClient(url: try FixtureServer.url("qui"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func tracearrStreamsViolationsAndTerminate() async throws {
        let client = TracearrClient(url: try FixtureServer.url("tracearr"), apiKey: "trr_pub_fixture", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.health.version == "2.5.1")
        #expect(overview.streams.first?.displayTitle == "Pioneer One · S01E04 Sermon")
        #expect(overview.today?.todayPlays == 47)
        let snapshot = TracearrDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .critical, "An offline media server is critical")
        try await perform(snapshot, "stop:st-1")
        #expect(try await FixtureServer.log().contains("tracearr terminate st-1 reason=\(TracearrClient.terminationReason)"))

        let wrong = TracearrClient(url: try FixtureServer.url("tracearr"), apiKey: "trr_pub_wrong", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }

    @Test func dispatcharrOperationalAllowlist() async throws {
        let client = DispatcharrClient(url: try FixtureServer.url("dispatcharr"), apiKey: "disp-key", pinnedFingerprint: nil)
        let overview = try await client.overview()
        #expect(overview.version == "0.31.0", "Trailing slashes reach Django routes")
        #expect(overview.stats == nil, "Redis being down makes live stats unavailable, not a failure")
        #expect(overview.playlists.first?.last_message == "Download timed out")
        #expect(overview.errorEvents.map(\.id) == [9])
        let snapshot = DispatcharrDashboard.snapshot(overview, operations: client)
        #expect(snapshot.health == .critical)
        let rendered = snapshot.sections.flatMap(\.rows).map { [$0.title, $0.subtitle, $0.detail, $0.message].compactMap { $0 }.joined(separator: " ") }.joined(separator: "\n")
        #expect(!rendered.contains("provider.example") && !rendered.contains("never-shown") && !rendered.contains("10.0.0.9"), "Provider URLs, channel names and client IPs are never shown")
        #expect(snapshot.action("backup")?.confirmation == .confirm, "Backups ask first")
        try await perform(snapshot, "backup")
        #expect(try await FixtureServer.log().contains { $0.hasPrefix("dispatcharr backup") })

        let wrong = DispatcharrClient(url: try FixtureServer.url("dispatcharr"), apiKey: "bad", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.unauthorized) { _ = try await wrong.overview() }
    }
}
