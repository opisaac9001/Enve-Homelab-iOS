import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh: the live Unraid client against GraphQL fixtures shaped by the official schema.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct UnraidIntegrationTests {
    private func client(_ path: String = "unraid", key: String = "unraid-key") throws -> UnraidClient {
        UnraidClient(endpoint: ServerEndpoint(kind: .local, url: try FixtureServer.url(path)), apiKey: key)
    }

    @Test func diagnosticsQueriesDecodeFromTheServer() async throws {
        let client = try client()
        let details = try await client.containerDetails(id: "c1")
        #expect(details.templateName == "my-plex.xml" && details.isUpdateAvailable == true && details.sizeLog == 52_428_800)
        #expect(details.autoStartWait == 5 && details.lanIpPorts == ["192.168.1.20:32400"])
        await #expect(throws: NetworkError.self, "A container that's gone is an error, not an empty screen") { _ = try await client.containerDetails(id: "missing") }

        let conflicts = try await client.portConflicts()
        #expect(conflicts.descriptions == ["192.168.1.20:8080/tcp: qbittorrent, sabnzbd"])

        let temperatures = try await client.temperatures()
        #expect(temperatures.health == .critical && temperatures.sensors.first?.id == "cpu" && temperatures.sensors.first?.history.count == 2)
        #expect(temperatures.sensors.last?.history.isEmpty == true)

        let files = try await client.logFiles()
        #expect(files.map(\.name) == ["docker.log", "syslog"], "Sorted by name")
        let syslog = try await client.logFile(path: "/var/log/syslog", lines: 200)
        #expect(syslog.lines.count == 2 && syslog.totalLines == 9120)
        #expect(try await FixtureServer.log().contains("unraid logFile /var/log/syslog 200"))
    }

    @Test func olderServersReportTheFeatureAsUnsupported() async throws {
        let old = try client("unraid-old")
        for call in [{ _ = try await old.containerDetails(id: "c1") }, { _ = try await old.portConflicts() }, { _ = try await old.temperatures() }] as [@Sendable () async throws -> Void] {
            do {
                try await call()
                Issue.record("Expected the older server to refuse the query")
            } catch let error as NetworkError {
                #expect(error.isUnsupported, "\(error)")
            }
        }
        #expect(try await old.logFiles().count == 2, "Log files exist on every API release")
        await #expect(throws: NetworkError.unauthorized) { _ = try await self.client(key: "wrong").logFiles() }
    }
}
