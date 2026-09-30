import Foundation
import Testing
@testable import EnveHomelab

struct NetworkDiagnosticsTests {
    @Test func domainInputIsNormalised() {
        #expect(DNSDomainInput.normalized("  Ads.Example.NET. ") == "ads.example.net")
        #expect(DNSDomainInput.normalized("https://tracker.example.com/path?q=1") == "tracker.example.com")
        #expect(DNSDomainInput.normalized("localhost") == nil, "A single label isn't a filterable domain")
        #expect(DNSDomainInput.normalized("bad domain.com") == nil)
        #expect(DNSDomainInput.normalized("a..b.com") == nil)
        #expect(DNSDomainInput.normalized("") == nil)
    }

    @Test func piholeStatusesMapToOutcomes() {
        #expect(PiholeClient.outcome("GRAVITY") == .blocked && PiholeClient.outcome("DENYLIST_CNAME") == .blocked)
        #expect(PiholeClient.outcome("CACHE_STALE") == .cached && PiholeClient.outcome("FORWARDED") == .allowed)
        #expect(PiholeClient.outcome("UNKNOWN") == .other && PiholeClient.outcome(nil) == .other)
    }

    @Test func piholeAllowEntriesWinAndDisabledEntriesAreIgnored() throws {
        let json = """
        {"search":{"domains":[{"domain":"x.example","type":"deny","kind":"exact","enabled":false},{"domain":"x\\\\.example","type":"allow","kind":"regex","enabled":true}],
         "gravity":[{"domain":"x.example","address":"https://list","type":"block"}]}}
        """
        let result = PiholeClient.check(domain: "x.example", result: try JSONDecoder().decode(PiholeClient.SearchResult.self, from: Data(json.utf8)))
        #expect(result.verdict == .allowed)
        #expect(result.reasons == ["Allowlist (regex): x\\.example", "Blocklist: https://list"], "The disabled deny entry isn't a reason")
    }

    @Test func adguardReasonsMapToVerdicts() throws {
        func check(_ json: String) throws -> DNSDomainCheck {
            AdGuardHomeClient.check(domain: "d.example", result: try JSONDecoder().decode(AdGuardHomeClient.CheckHost.self, from: Data(json.utf8)))
        }
        #expect(try check(#"{"reason":"FilteredParental","rules":[]}"#).reasons == ["Parental control"])
        #expect(try check(#"{"reason":"FilteredBlockedService","service_name":"tiktok","rules":[]}"#).reasons == ["Blocked service: tiktok"])
        #expect(try check(#"{"reason":"NotFilteredWhiteList","rules":[{"filter_list_id":0,"text":"@@||d.example^"}]}"#) == DNSDomainCheck(domain: "d.example", verdict: .allowed, reasons: ["Rule @@||d.example^ (custom rules)"]))
        #expect(try check(#"{"reason":"FilteredBlackList","rule":"||d.example^"}"#).reasons == ["Rule ||d.example^"], "Older servers only send the deprecated rule field")
        #expect(AdGuardHomeClient.outcome(reason: "RewriteEtcHosts", cached: false) == .rewritten)
        #expect(AdGuardHomeClient.outcome(reason: "NotFilteredNotFound", cached: true) == .cached)
    }

    @Test func maintenanceNamesItsConsequence() {
        #expect(DNSMaintenance.restartDNS.isDisruptive && !DNSMaintenance.updateGravity.isDisruptive)
        #expect(DNSMaintenance.allCases.allSatisfy { !$0.consequence.isEmpty })
    }

    @Test func samplesMatchEachProductsCapabilities() async throws {
        let pihole = SampleDNSFilter(kind: .pihole)
        #expect(pihole.diagnostics.allowDomain && pihole.diagnostics.maintenance == [.updateGravity, .restartDNS])
        #expect(!SampleDNSFilter(kind: .adguard).diagnostics.allowDomain)
        #expect(SampleDNSFilter(kind: .technitium).diagnostics == DNSDiagnosticsCapabilities(queryLog: false, domainCheck: false, messages: false, allowDomain: false, maintenance: []))
        #expect(try await pihole.check(domain: "ads.example.com").verdict == .blocked)
        try await pihole.allow(domain: "cdn.example.com")
        #expect(try await pihole.check(domain: "cdn.example.com").verdict == .allowed)
    }

    @Test func unifiDetailsDecodeFromTheDocumentedShape() throws {
        let details = try JSONDecoder().decode(UniFiDeviceDetails.self, from: Data("""
        {"interfaces":{"ports":[{"idx":4,"state":"UP","connector":"RJ45","speedMbps":100,"maxSpeedMbps":1000,"poe":{"enabled":true,"standard":"802.3bt","state":"LIMITED","type":3}}],
         "radios":[{"frequencyGHz":6,"channel":37,"channelWidthMHz":160,"wlanStandard":"802.11be"}]},"uplink":{"deviceId":"x"}}
        """.utf8))
        let port = try #require(details.interfaces?.ports?.first)
        #expect(port.canPowerCycle && UniFiDeviceView.portDetail(port) == "RJ45 · 100 Mbps · PoE 802.3bt limited")
        #expect(details.interfaces?.radios?.first?.frequencyGHz == 6)
    }

    @Test func homeAssistantSampleReportsInvalidConfig() async throws {
        let sample = SampleHomeAssistant()
        #expect(try await sample.checkConfiguration().isValid == false)
        #expect(try await sample.errorLog().contains("ERROR"))
    }
}
