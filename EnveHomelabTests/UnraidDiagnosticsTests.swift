import Foundation
import Testing
@testable import EnveHomelab

struct UnraidDiagnosticsDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func containerDetailsReadTemplateFieldsAndBigInts() throws {
        let details = try decode(ContainerDetails.self, """
        {"id":"abc","templatePath":"/boot/config/plugins/dockerMan/templates-user/my-plex.xml","projectUrl":"https://plex.tv",
         "supportUrl":"javascript:alert(1)","registryUrl":"","isOrphaned":false,"isUpdateAvailable":true,"isRebuildReady":null,
         "lanIpPorts":["192.168.1.20:32400"],"sizeRootFs":"2400000000","sizeRw":1048576,"sizeLog":"9007199254740993",
         "autoStart":true,"autoStartOrder":2,"autoStartWait":15}
        """)
        #expect(details.templateName == "my-plex.xml" && details.registryUrl == nil)
        #expect(details.sizeRootFs == 2_400_000_000 && details.sizeLog == 9_007_199_254_740_993, "BigInt strings keep full precision")
        #expect(ContainerDetails.webLink(details.projectUrl)?.host() == "plex.tv")
        #expect(ContainerDetails.webLink(details.supportUrl) == nil, "Only http(s) links from templates are opened")
    }

    @Test func portConflictsNameEveryContainer() throws {
        let conflicts = try decode(DockerPortConflicts.self, """
        {"containerPorts":[{"privatePort":8080,"type":"TCP","containers":[{"id":"a","name":"qbittorrent"},{"id":"b","name":"sabnzbd"}]}],
         "lanPorts":[{"lanIpPort":"192.168.1.20:443","publicPort":443,"type":"TCP","containers":[{"id":"c","name":"swag"},{"id":"d","name":"npm"}]}]}
        """)
        #expect(conflicts.descriptions == ["192.168.1.20:443/tcp: swag, npm", "Container port 8080/tcp: qbittorrent, sabnzbd"])
        #expect(conflicts.involves("b") && !conflicts.involves("z"))
        #expect(try decode(DockerPortConflicts.self, #"{"containerPorts":[],"lanPorts":[]}"#).isEmpty)
    }

    @Test func temperaturesConvertUnitsAndSortProblemsFirst() throws {
        let report = try decode(TemperatureReport.self, """
        {"summary":{"average":45.5,"warningCount":1,"criticalCount":0},
         "sensors":[
          {"id":"mb","name":"Motherboard","type":"MOTHERBOARD","location":"","warning":null,"critical":null,
           "current":{"value":35,"unit":"CELSIUS","status":"NORMAL","timestamp":"2026-09-29T10:00:00.000Z"},"min":null,"max":null,"history":[]},
          {"id":"nvme","name":"NVMe","type":"NVME","location":"nvme0n1","warning":140,"critical":158,
           "current":{"value":143.6,"unit":"FAHRENHEIT","status":"WARNING","timestamp":"2026-09-29T10:00:00.000Z"},
           "min":{"value":104,"unit":"FAHRENHEIT"},"max":{"value":149,"unit":"FAHRENHEIT"},
           "history":[{"value":140,"unit":"FAHRENHEIT","timestamp":"2026-09-29T09:55:00.000Z"},{"value":143.6,"unit":"FAHRENHEIT","timestamp":"2026-09-29T10:00:00.000Z"}]}
         ]}
        """)
        #expect(report.sensors.map(\.id) == ["nvme", "mb"], "Sensors at warning come first")
        let nvme = try #require(report.sensors.first)
        #expect(abs(nvme.current.celsius - 62) < 0.01 && abs((nvme.warning ?? 0) - 60) < 0.01 && abs((nvme.critical ?? 0) - 70) < 0.01)
        #expect(nvme.history.count == 2 && nvme.status == .warning && report.health == .warning)
        #expect(report.sensors.last?.location == nil, "Empty locations are dropped")
    }

    @Test func logFileLinesSkipBlanks() throws {
        let text = try decode(LogFileText.self, #"{"path":"/var/log/syslog","content":"one\n\ntwo\n","totalLines":40,"startLine":38}"#)
        #expect(text.lines == ["one", "two"] && text.totalLines == 40)
    }
}

struct ArrayDiskHealthTests {
    private func disk(used: Int64? = nil, size: Int64? = nil, temperature: Int? = nil, rotational: Bool = true, spinning: Bool? = true,
                      warning: Int? = 70, critical: Int? = 90, errors: Int64? = 0) -> ArrayDisk {
        ArrayDisk(id: "disk1", slot: 1, name: "disk1", device: "sdb", sizeKB: size, status: .ok, rotational: rotational, temperature: temperature,
                  reads: nil, writes: nil, errors: errors, filesystemSizeKB: size, filesystemFreeKB: nil, filesystemUsedKB: used,
                  filesystemType: "xfs", type: .data, usageWarningPercent: warning, usageCriticalPercent: critical, isSpinning: spinning, transport: nil, comment: nil)
    }

    @Test func usageThresholdsArePercentagesNotTemperatures() {
        #expect(disk(used: 50, size: 100, temperature: 72).usageHealth == .ok)
        #expect(disk(used: 75, size: 100).usageHealth == .warning)
        #expect(disk(used: 95, size: 100).usageHealth == .critical)
        #expect(disk(used: 95, size: 100, warning: 0, critical: 0).usageHealth == .ok, "Zero turns the alert off")
    }

    @Test func temperaturesUseUnraidDefaultsPerMedia() {
        #expect(disk(temperature: 44).temperatureHealth == .ok)
        #expect(disk(temperature: 46).temperatureHealth == .warning)
        #expect(disk(temperature: 56).temperatureHealth == .critical)
        #expect(disk(temperature: 56, rotational: false).temperatureHealth == .ok, "SSDs run hotter")
        #expect(disk(temperature: 71, rotational: false).temperatureHealth == .critical)
        #expect(disk(temperature: 60, spinning: false).temperatureHealth == .unknown, "A spun-down reading is stale")
        #expect(disk(used: 95, size: 100, temperature: 30).health == .critical, "A full disk marks the device critical")
    }
}

@MainActor
struct DiskHistoryStoreTests {
    private func disk(errors: Int64?, temperature: Int? = 40, spinning: Bool? = true) -> ArrayDisk {
        ArrayDisk(id: "disk1", slot: 1, name: "disk1", device: "sdb", sizeKB: nil, status: .ok, rotational: true, temperature: temperature,
                  reads: nil, writes: nil, errors: errors, filesystemSizeKB: nil, filesystemFreeKB: nil, filesystemUsedKB: nil,
                  filesystemType: nil, type: .data, usageWarningPercent: nil, usageCriticalPercent: nil, isSpinning: spinning, transport: nil, comment: nil)
    }

    @Test func recordsSparinglyAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "disk-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DiskHistoryStore(file: JSONFile(url: url))
        store.record([disk(errors: 0)], server: server, now: start)
        store.record([disk(errors: 0)], server: server, now: start.addingTimeInterval(60))
        #expect(store.history(server: server, disk: disk(errors: 0)).count == 1, "Unchanged readings within 10 minutes are skipped")
        store.record([disk(errors: 2)], server: server, now: start.addingTimeInterval(120))
        #expect(store.history(server: server, disk: disk(errors: 0)).count == 2, "A new error is always recorded")
        store.record([disk(errors: 2, spinning: false)], server: server, now: start.addingTimeInterval(1_200))
        let reloaded = DiskHistoryStore(file: JSONFile(url: url))
        let history = reloaded.history(server: server, disk: disk(errors: 0))
        #expect(history.count == 3 && history.last?.temperature == nil, "Spun-down temperatures aren't kept")
        #expect(reloaded.history(server: UUID(), disk: disk(errors: 0)).isEmpty, "History is per server")
    }

    @Test func newErrorsSurviveCounterResets() {
        func sample(_ errors: Int64?) -> DiskHistoryStore.Sample { .init(date: .now, errors: errors, temperature: nil) }
        #expect(DiskHistoryStore.newErrors(in: [sample(3), sample(3), sample(5), sample(0), sample(1), sample(nil)]) == 3,
                "Increases count; a drop to zero means the counters were cleared")
        #expect(DiskHistoryStore.newErrors(in: []) == 0)
    }

    @Test func keepsOnlyTheNewestSamples() {
        let store = DiskHistoryStore(file: nil)
        let server = UUID()
        for index in 0..<(DiskHistoryStore.limit + 20) {
            store.record([disk(errors: Int64(index))], server: server, now: Date(timeIntervalSince1970: Double(index)))
        }
        let history = store.history(server: server, disk: disk(errors: 0))
        #expect(history.count == DiskHistoryStore.limit && history.last?.errors == Int64(DiskHistoryStore.limit + 19))
    }
}

struct UnraidPreviewDiagnosticsTests {
    @Test func sampleServerCoversEveryNewCall() async throws {
        let preview = UnraidPreviewService()
        let containers = try await preview.containers()
        let orphan = try await preview.containerDetails(id: "preview:uptime-kuma")
        #expect(orphan.isOrphaned == true && orphan.templatePath == nil)
        let first = try #require(containers.first)
        #expect(try await preview.containerDetails(id: first.id).templateName != nil)
        #expect(try await preview.portConflicts().involves("preview:nextcloud"))
        #expect(try await preview.temperatures().health == .warning)
        let files = try await preview.logFiles()
        #expect(try await preview.logFile(path: try #require(files.first).path, lines: 2).lines.count == 2)
    }
}
