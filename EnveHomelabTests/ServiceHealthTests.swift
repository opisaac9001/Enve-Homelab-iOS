import Foundation
import Testing
@testable import EnveHomelab

struct ServiceCheckTests {
    @Test func urlParsingKeepsPathAndQuery() throws {
        #expect(try ServiceCheck.parseURL("Plex.Local:32400/identity?x=1").get().absoluteString == "https://plex.local:32400/identity?x=1")
        #expect(try ServiceCheck.parseURL("http://user:pw@10.0.0.2/health#top").get().absoluteString == "http://10.0.0.2/health")
        #expect(throws: ServiceCheck.URLFailure.unsupportedScheme) { try ServiceCheck.parseURL("ftp://nas").get() }
        #expect(throws: ServiceCheck.URLFailure.empty) { try ServiceCheck.parseURL("  ").get() }
    }

    @Test func acceptedStatusRanges() {
        #expect(ServiceCheck.AcceptedStatus.successOrRedirect.accepts(302))
        #expect(!ServiceCheck.AcceptedStatus.successOrRedirect.accepts(401))
        #expect(!ServiceCheck.AcceptedStatus.successOnly.accepts(301))
        #expect(ServiceCheck.AcceptedStatus.anyResponse.accepts(503))
    }

    private func result(_ outcome: ServiceCheckResult.Outcome, time: Duration? = .milliseconds(120), expiresIn days: Double? = nil, now: Date) -> ServiceCheckResult {
        let certificate = days.map {
            CertificateSummary(host: "h", subject: "s", sha256Fingerprint: "F", notValidBefore: nil,
                               notValidAfter: now.addingTimeInterval($0 * 86_400 + 60), evaluationFailure: nil)
        }
        return ServiceCheckResult(checkedAt: now, outcome: outcome, responseTime: time, certificate: certificate, trust: .system, finalURL: nil)
    }

    @Test func healthCombinesStatusLatencyAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(result(.responded(status: 200, accepted: true), now: now).health(now: now) == .ok)
        #expect(result(.responded(status: 500, accepted: false), now: now).health(now: now) == .critical)
        #expect(result(.failed(.timedOut), time: nil, now: now).health(now: now) == .critical)
        #expect(result(.responded(status: 200, accepted: true), time: .seconds(3), now: now).health(now: now) == .warning)
        #expect(result(.responded(status: 200, accepted: true), expiresIn: 10, now: now).health(now: now) == .warning)
        #expect(result(.responded(status: 200, accepted: true), expiresIn: 1, now: now).health(now: now) == .critical)
        #expect(result(.responded(status: 200, accepted: true), expiresIn: 90, now: now).daysUntilExpiry(now: now) == 90)
        #expect(result(.responded(status: 200, accepted: true), expiresIn: -2, now: now).health(now: now) == .critical)
    }
}

@MainActor
struct ServiceHealthMonitorTests {
    @Test func dueChecksRespectIntervalAndHistoryIsBounded() {
        let monitor = ServiceHealthMonitor()
        var check = ServiceCheck(name: "x", url: URL(string: "https://x.local")!)
        check.intervalSeconds = 60
        #expect(monitor.isDue(check))

        let start = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<(ServiceHealthMonitor.historyLimit + 5) {
            monitor.record(ServiceCheckResult(checkedAt: start.addingTimeInterval(Double(offset)), outcome: .responded(status: 200, accepted: true),
                                              responseTime: nil, certificate: nil, trust: .none, finalURL: nil), for: check.id)
        }
        #expect(monitor.history[check.id]?.count == ServiceHealthMonitor.historyLimit)
        let last = monitor.latest(for: check.id)!.checkedAt
        #expect(!monitor.isDue(check, now: last.addingTimeInterval(59)))
        #expect(monitor.isDue(check, now: last.addingTimeInterval(60)))

        monitor.forget(check.id)
        #expect(monitor.latest(for: check.id) == nil)
    }

    @Test func storePersistsChecks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "checks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ServiceCheckStore(file: JSONFile(url: url))
        var check = ServiceCheck(name: "Grafana", url: URL(string: "https://grafana.local/api/health")!)
        check.pinnedCertificateSHA256 = "AB:CD"
        try store.save(check)
        let reloaded = ServiceCheckStore(file: JSONFile(url: url))
        #expect(reloaded.checks == [check])
        try reloaded.delete(check)
        #expect(ServiceCheckStore(file: JSONFile(url: url)).checks.isEmpty)
    }
}
