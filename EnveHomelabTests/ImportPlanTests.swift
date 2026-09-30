import Foundation
import Testing
@testable import EnveHomelab

struct ImportPlanTests {
    private let radarr = IntegrationInstance(kind: .radarr, name: "Radarr", url: URL(string: "http://192.168.1.20:7878")!)
    private let grafana = ServiceCheck(name: "grafana", url: URL(string: "http://192.168.1.20:3000")!)

    private func file(_ integrations: [IntegrationInstance], _ checks: [ServiceCheck] = [], purpose: ConfigurationBackup.Purpose = .companion) -> ConfigurationBackup {
        ConfigurationBackup(format: 1, purpose: purpose, exportedAt: .now, servers: [], integrations: integrations, serviceChecks: checks, sshHosts: [], notificationRules: [])
    }

    private func plan(_ backup: ConfigurationBackup, integrations: [IntegrationInstance], checks: [ServiceCheck] = []) -> ImportPlan {
        ImportPlan.make(backup, integrations: integrations, checks: checks, serverIDs: [], hostIDs: [], ruleIDs: [])
    }

    @Test func rerunsRecogniseWhatsAlreadyHere() {
        var moved = radarr
        moved.url = URL(string: "http://192.168.1.20:7879")!
        let result = plan(file([moved], [grafana]), integrations: [radarr], checks: [grafana])
        #expect(result.integrations.first?.status == .moved(from: radarr.url), "Same ID with a new port is offered as an address update")
        #expect(result.checks.first?.status == .alreadyHere)
        #expect(result.newIDs.isEmpty, "Nothing is re-added")
    }

    @Test func olderExportsMatchByKindAndAddress() {
        let legacy = IntegrationInstance(kind: .radarr, name: "radarr", url: URL(string: "HTTP://192.168.1.20:7878/")!)
        let otherKind = IntegrationInstance(kind: .sonarr, name: "Sonarr", url: URL(string: "http://192.168.1.20:7878")!)
        let result = plan(file([legacy, otherKind]), integrations: [radarr])
        #expect(result.integrations.map(\.status) == [.sameAs("Radarr"), .new], "Case, default ports and a trailing slash don't create duplicates; a different kind does")
    }

    @Test func servicesMissingFromTheExportAreKeptAndNamed() {
        let elsewhere = IntegrationInstance(kind: .plex, name: "Plex elsewhere", url: URL(string: "http://10.0.0.5:32400")!)
        let gone = IntegrationInstance(kind: .sonarr, name: "Old Sonarr", url: URL(string: "http://192.168.1.20:8989")!)
        let result = plan(file([radarr]), integrations: [radarr, gone, elsewhere])
        #expect(result.keptOnDevice == ["Old Sonarr"], "Only items on the exported host are mentioned")
        #expect(plan(file([radarr], purpose: .backup), integrations: [radarr, gone]).keptOnDevice.isEmpty, "Backups aren't host exports")
    }

    @Test func normalisation() {
        #expect(ImportPlan.normalized(URL(string: "https://NAS.local/")!) == ImportPlan.normalized(URL(string: "https://nas.local:443")!))
        #expect(ImportPlan.normalized(URL(string: "http://nas.local:8080/app")!) != ImportPlan.normalized(URL(string: "http://nas.local:8080")!))
    }
}
