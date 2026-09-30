import Foundation
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh against the documented Proxmox, TrueNAS and Portainer (Docker Engine) routes.
@Suite(.enabled(if: FixtureServer.http != nil, "Requires Scripts/run-integration-tests.sh"), .serialized)
struct InfrastructureDiagnosticsIntegrationTests {
    @Test func proxmoxNodeStorageDisksSMARTAndTaskLog() async throws {
        let client = ProxmoxClient(url: try FixtureServer.url("pve"), tokenID: "ci@pve!homelab", secret: "0000-1111", pinnedFingerprint: nil)
        let status = try await client.nodeStatus("pve1")
        #expect(status.memory?.fraction == 0.5 && status.loadavg?.map(\.value) == ["0.52", "0.40", "0.33"])
        #expect(status.bootDescription == "UEFI", "Secure Boot reported as 0 isn't claimed")
        #expect(status.currentKernel?.release == "6.14.11-2-pve" && status.rootfs?.fraction == 0.4)

        let storage = try await client.storage("pve1")
        #expect(storage.map(\.storage) == ["local", "nfs-backup"])
        #expect(storage.map(\.isUnavailable) == [false, true], "0/1 flags decode, and an enabled but inactive store is unavailable")
        #expect(storage.first?.usedFraction == 0.25)

        let disks = try await client.disks("pve1")
        #expect(disks.map(\.devpath) == ["/dev/nvme0n1", "/dev/sdb"])
        #expect(disks.map(\.healthLevel) == [.ok, .critical])

        let failing = try await client.smart("pve1", disk: "/dev/sdb")
        let reallocated = try #require(failing.attributes?.first)
        #expect(reallocated.isFailing && reallocated.isWearIndicator && reallocated.value?.value == "5", "Numeric values and padded ids decode")
        #expect(failing.attributes?.last?.isFailing == false)
        let nvme = try await client.smart("pve1", disk: "/dev/nvme0n1")
        #expect(nvme.attributes == nil && nvme.text?.contains("Percentage Used") == true)

        let task = ProxmoxTask(upid: "UPID:pve1:9:failed", node: "pve1", type: "vzdump", target: "101", user: "root@pam", starttime: 1, endtime: 2, status: "job errors")
        #expect(try await client.taskLog(task, limit: 200) == ["ERROR: storage 'nfs-backup' is not online", "TASK ERROR: job errors"], "Lines come back in order")

        let auditorless = ProxmoxClient(url: try FixtureServer.url("pve"), tokenID: "auditor-less@pve!x", secret: "1", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.self) { _ = try await auditorless.disks("pve1") }
        do {
            _ = try await auditorless.disks("pve1")
        } catch let error as NetworkError {
            #expect(ProxmoxNodeView.explain(error, section: "Disks").contains("Sys.Audit"), "A permission refusal explains the missing privilege")
        }
    }

    @Test(.enabled(if: FixtureServer.tls != nil)) func trueNASDataProtection() async throws {
        let client = TrueNASClient(url: try #require(FixtureServer.tls), apiKey: "truenas-key", pinnedFingerprint: FixtureServer.tlsFingerprint)
        let protection = try await client.dataProtection()
        let tasks = try #require(protection.snapshotTasks)
        #expect(tasks.map { $0.state?.state } == ["FINISHED", "ERROR", "PENDING"], "Dict and bare-string states both decode")
        #expect(tasks[1].state?.error == "Dataset tank/photos is locked." && tasks[1].state?.date != nil)
        #expect(tasks[0].retention == "2 weeks" && tasks[2].retention == "1 day")
        #expect(protection.replicationTasks == nil, "A refused method means the key lacks that role, not that the server is down")
        #expect(protection.health == .critical)

        try await client.runSnapshotTask(tasks[0])
        #expect(try await FixtureServer.log().contains("truenas snapshottask run 1"))
    }

    @Test func portainerContainerHealthFromInspect() async throws {
        let client = PortainerClient(url: try FixtureServer.url("portainer"), apiKey: "ptr_fixture", pinnedFingerprint: nil)
        let inspection = try await client.inspect(environmentID: 1, containerID: "c1")
        #expect(inspection.restartCount == 3 && inspection.state?.OOMKilled == true && inspection.state?.ExitCode == 137)
        #expect(inspection.healthLevel == .critical && inspection.state?.Health?.FailingStreak == 2)
        #expect(inspection.restartPolicy == "On failure (up to 5 tries)")
        #expect(APIDate.parse(inspection.state?.StartedAt) != nil, "Docker's nanosecond timestamps parse")
    }
}
