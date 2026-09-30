import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh against the documented Pi-hole, AdGuard Home, UniFi and Home Assistant routes.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct NetworkDiagnosticsIntegrationTests {
    @Test func piholeDiagnosticsAndMaintenance() async throws {
        let client = PiholeClient(url: try FixtureServer.url("pihole"), password: "app-password", pinnedFingerprint: nil)
        let queries = try await client.recentQueries(limit: 50)
        #expect(queries.map(\.outcome) == [.blocked, .allowed, .cached])
        #expect(queries.map(\.client) == ["tv.lan", "192.168.1.41", "192.168.1.41"], "Blank client names fall back to the address")

        let blocked = try await client.check(domain: "ads.example.net")
        #expect(blocked.verdict == .blocked && blocked.reasons == ["Blocklist: https://lists.example.org/hosts"])
        #expect(try await client.check(domain: "fine.example").verdict == .notListed)

        #expect(try await client.messages().first?.text == "Rate-limiting 192.168.1.42 for at least 5 seconds")
        #expect(try await client.perform(.updateGravity) == "[✓] Done.", "The last line of the streamed output is reported")
        #expect(try await client.perform(.restartDNS) == nil)
        await #expect(throws: NetworkError.self) { _ = try await client.perform(.refreshFilters) }

        try await client.allow(domain: "ads.example.net")
        #expect(try await client.check(domain: "ads.example.net").verdict == .allowed, "An allow entry wins over the blocklist")

        let log = try await FixtureServer.log()
        #expect(log.contains("pihole gravity") && log.contains("pihole restartdns") && log.contains("pihole allow ads.example.net"))
        let logins = log.filter { $0.hasPrefix("pihole logout") }.count
        #expect(logins >= 7, "Every call releases its session")
    }

    @Test func adguardDiagnosticsAndRefresh() async throws {
        let client = AdGuardHomeClient(url: try FixtureServer.url("adguard"), username: "admin", password: "guard", pinnedFingerprint: nil)
        let queries = try await client.recentQueries(limit: 50)
        #expect(queries.map(\.outcome) == [.blocked, .cached])
        #expect(queries.last?.domain == "аррӏе.com" && queries.last?.client == "192.168.1.41", "Unicode names are shown; blank client names fall back")

        let blocked = try await client.check(domain: "ads.example.net")
        #expect(blocked.verdict == .blocked && blocked.reasons == ["Rule ||ads.example.net^ (list 1)"])
        let rewritten = try await client.check(domain: "nas.home.arpa")
        #expect(rewritten.verdict == .rewritten && rewritten.reasons == ["Answers 192.168.1.10"])
        #expect(try await client.check(domain: "fine.example").verdict == .notListed)

        #expect(try await client.perform(.refreshFilters) == "2 lists updated.")
        await #expect(throws: NetworkError.self, "Allowing would rewrite every custom rule") { try await client.allow(domain: "ads.example.net") }
        #expect(try await FixtureServer.log().contains("adguard refresh whitelist=false"))
    }

    @Test func unifiDeviceDetailsStatisticsAndPowerCycle() async throws {
        let client = UniFiClient(url: try FixtureServer.url("unifi"), apiKey: "unifi-key", pinnedFingerprint: nil)
        let device = try #require(try await client.snapshot(siteID: nil).devices.first { $0.id == "dev-1" })
        let details = try await client.details(of: device, siteID: "site-1")
        let ports = try #require(details.interfaces?.ports)
        #expect(ports.map(\.canPowerCycle) == [false, true, false], "Only the port supplying PoE can be power cycled")
        #expect(UniFiDeviceView.portDetail(ports[1]) == "RJ45 · 1 Gbps · PoE 802.3at supplying")
        #expect(UniFiDeviceView.portDetail(ports[2]) == "SFPPLUS · No link")

        let statistics = try await client.statistics(of: device, siteID: "site-1")
        #expect(statistics.cpuUtilizationPct == 7.5 && statistics.uplink?.rxRateBps == 25_000_000)
        #expect(UniFiDeviceView.rate(25_000_000) == "25.0 Mbps" && UniFiDeviceView.rate(640_000) == "640 kbps")

        try await client.powerCycle(port: 2, on: device, siteID: "site-1")
        await #expect(throws: NetworkError.self, "The controller refuses ports without PoE") { try await client.powerCycle(port: 1, on: device, siteID: "site-1") }
        #expect(try await FixtureServer.log().contains("unifi POWER_CYCLE port 2"))
    }

    @Test func homeAssistantConfigCheckAndErrorLog() async throws {
        let client = HomeAssistantClient(url: try FixtureServer.url("ha"), token: "ha-token", pinnedFingerprint: nil)
        let check = try await client.checkConfiguration()
        #expect(!check.isValid && check.errors == "Integration error: frontend - Integration not found.")
        #expect(try await client.errorLog().contains("Error connecting to MQTT broker"))

        let user = HomeAssistantClient(url: try FixtureServer.url("ha"), token: "ha-user-token", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.forbidden("Reading the error log needs a token from an administrator account.")) { _ = try await user.errorLog() }
    }
}
