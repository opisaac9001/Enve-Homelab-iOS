import Foundation
import Testing
@testable import EnveHomelab

struct InfrastructureDiagnosticsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func proxmoxFlagsAndTextAcceptEveryEncoding() throws {
        #expect(try decode([ProxmoxFlag].self, #"[1, 0, true, "1", "false"]"#).map(\.value) == [true, false, true, true, false])
        #expect(try decode([ProxmoxText].self, #"["12", 34, 5.5]"#).map(\.value) == ["12", "34", "5.5"])
    }

    @Test func smartAttributeRules() throws {
        let attributes = try decode([ProxmoxSMART.Attribute].self, """
        [{"id":"197","name":"Current_Pending_Sector","value":100,"worst":100,"threshold":0,"raw":"16","fail":"-"},
         {"id":"9","name":"Power_On_Hours","value":71,"raw":"25614","fail":"-"},
         {"id":"5","name":"Reallocated_Sector_Ct","value":100,"raw":"0","fail":"In_the_past"}]
        """)
        #expect(attributes.map(\.isWearIndicator) == [true, false, false], "Only rising counts of bad sectors are early warnings")
        #expect(attributes.map(\.isFailing) == [false, false, true], "smartctl's In_the_past still counts as a failure")
    }

    @Test func diskHealthMapping() {
        func disk(_ health: String?) -> ProxmoxDisk { ProxmoxDisk(devpath: "/dev/x", health: health) }
        #expect([disk("PASSED"), disk("OK"), disk("FAILED"), disk("UNKNOWN"), disk(nil), disk("Pre-fail")].map(\.healthLevel) == [.ok, .ok, .critical, .unknown, .unknown, .warning])
    }

    @Test func trueNASStateTitles() throws {
        let states = try decode([TrueNASTaskState].self, #"["HOLD", {"state":"RUNNING","datetime":{"$date":1759140000000}}, {"state":"ERROR","error":""}]"#)
        #expect(states.map(\.title) == ["On hold", "Running", "Failed"])
        #expect(states[2].error == nil, "Empty errors are dropped")
        #expect(states[1].date == Date(timeIntervalSince1970: 1_759_140_000))
    }

    @Test func portainerInspectionIgnoresEnvironment() throws {
        let inspection = try decode(PortainerInspection.self, #"{"State":{"Status":"exited","ExitCode":1},"RestartCount":0,"HostConfig":{"RestartPolicy":{"Name":"no"}},"Config":{"Env":["SECRET=x"]}}"#)
        #expect(inspection.restartPolicy == "Never" && inspection.healthLevel == .unknown)
        #expect(String(describing: inspection).contains("SECRET") == false, "Environment variables are never decoded")
    }

    @Test func samplesCoverTheNewScreens() async throws {
        let proxmox = SampleProxmox()
        #expect(try await proxmox.disks("pve1").contains { $0.healthLevel == .critical })
        #expect(try await proxmox.smart("pve1", disk: "/dev/sdb").attributes?.contains(where: \.isFailing) == true)
        #expect(try await proxmox.storage("pve1").contains(where: \.isUnavailable))
        let truenas = SampleTrueNAS()
        let tasks = try #require(try await truenas.dataProtection().snapshotTasks)
        try await truenas.runSnapshotTask(tasks[1])
        #expect(try await truenas.dataProtection().snapshotTasks?[1].state?.state == "FINISHED")
        #expect(try await SamplePortainer().inspect(environmentID: 1, containerID: "c3d4").healthLevel == .critical)
    }
}
