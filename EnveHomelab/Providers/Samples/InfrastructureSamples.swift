import Foundation

actor SampleProxmox: ProxmoxService {
    func nodeStatus(_ node: String) async throws -> ProxmoxNodeStatus {
        ProxmoxNodeStatus(cpu: 0.18, loadavg: [.init("0.84"), .init("0.71"), .init("0.66")], uptime: 1_209_600, pveversion: "pve-manager/9.0.10/deadbeef",
                          kversion: "Linux 6.14.11-2-pve", memory: .init(total: 68_719_476_736, used: 30_064_771_072), swap: .init(total: 8_589_934_592, used: 0),
                          rootfs: .init(total: 100_000_000_000, used: 21_500_000_000), cpuinfo: .init(model: "AMD Ryzen 7 5700G", cores: 8, cpus: 16, sockets: 1),
                          bootInfo: .init(mode: "efi", secureboot: ProxmoxFlag(true)), currentKernel: .init(release: "6.14.11-2-pve", version: nil))
    }

    func storage(_ node: String) async throws -> [ProxmoxStorage] {
        [
            ProxmoxStorage(storage: "local", type: "dir", content: "iso,vztmpl,backup", active: ProxmoxFlag(true), enabled: ProxmoxFlag(true), shared: ProxmoxFlag(false), total: 100_000_000_000, used: 21_500_000_000, avail: 78_500_000_000),
            ProxmoxStorage(storage: "local-zfs", type: "zfspool", content: "images,rootdir", active: ProxmoxFlag(true), enabled: ProxmoxFlag(true), shared: ProxmoxFlag(false), total: 1_800_000_000_000, used: 1_530_000_000_000, avail: 270_000_000_000),
            ProxmoxStorage(storage: "nas-backups", type: "nfs", content: "backup", active: ProxmoxFlag(false), enabled: ProxmoxFlag(true), shared: ProxmoxFlag(true)),
        ]
    }

    func disks(_ node: String) async throws -> [ProxmoxDisk] {
        [
            ProxmoxDisk(devpath: "/dev/nvme0n1", model: "Samsung SSD 990 PRO 2TB", serial: "S7KHNJ0W100001", size: 2_000_398_934_016, health: "PASSED", used: "ZFS", mounted: ProxmoxFlag(false)),
            ProxmoxDisk(devpath: "/dev/sda", model: "WDC WD80EFPX", vendor: "ATA", serial: "WD-RD0000001", size: 8_001_563_222_016, health: "PASSED", used: "ZFS", mounted: ProxmoxFlag(false)),
            ProxmoxDisk(devpath: "/dev/sdb", model: "ST4000VN006", vendor: "ATA", serial: "ZW600001", size: 4_000_787_030_016, health: "FAILED", used: "LVM", mounted: ProxmoxFlag(false)),
        ]
    }

    func smart(_ node: String, disk: String) async throws -> ProxmoxSMART {
        if disk.contains("nvme") {
            return ProxmoxSMART(health: "PASSED", type: "text", attributes: nil, text: "Critical Warning: 0x00\nTemperature: 41 Celsius\nAvailable Spare: 100%\nPercentage Used: 3%\nMedia and Data Integrity Errors: 0\n")
        }
        let failing = disk == "/dev/sdb"
        return ProxmoxSMART(health: failing ? "FAILED" : "PASSED", type: "ata", attributes: [
            .init(id: .init("5"), name: "Reallocated_Sector_Ct", value: .init(failing ? "005" : "100"), worst: .init(failing ? "005" : "100"), threshold: .init("010"), raw: .init(failing ? "3912" : "0"), fail: failing ? "FAILING_NOW" : "-", flags: "PO--CK"),
            .init(id: .init("9"), name: "Power_On_Hours", value: .init("071"), worst: .init("071"), threshold: .init("000"), raw: .init("25614"), fail: "-", flags: "-O--CK"),
            .init(id: .init("194"), name: "Temperature_Celsius", value: .init("064"), worst: .init("052"), threshold: .init("000"), raw: .init("36 (Min/Max 18/48)"), fail: "-", flags: "-O---K"),
            .init(id: .init("197"), name: "Current_Pending_Sector", value: .init("100"), worst: .init("100"), threshold: .init("000"), raw: .init(failing ? "16" : "0"), fail: "-", flags: "-O--C-"),
        ], text: nil)
    }

    func taskLog(_ task: ProxmoxTask, limit: Int) async throws -> [String] {
        ["INFO: starting new backup job: vzdump 101 --storage nas-backups --mode snapshot", "ERROR: storage 'nas-backups' is not online", "INFO: Failed at 2026-09-29 02:00:04", "TASK ERROR: job errors"]
    }

    private var guests: [ProxmoxGuest] = [
        ProxmoxGuest(id: "qemu/100", type: .qemu, node: "pve1", vmid: 100, name: "home-assistant", status: "running", cpu: 0.04, maxcpu: 2, mem: 2_100_000_000, maxmem: 4_294_967_296, uptime: 1_209_600),
        ProxmoxGuest(id: "qemu/101", type: .qemu, node: "pve1", vmid: 101, name: "windows-desktop", status: "stopped", cpu: 0, maxcpu: 8, mem: 0, maxmem: 17_179_869_184),
        ProxmoxGuest(id: "lxc/200", type: .lxc, node: "pve2", vmid: 200, name: "pihole", status: "running", cpu: 0.01, maxcpu: 1, mem: 180_000_000, maxmem: 536_870_912, uptime: 3_024_000),
        ProxmoxGuest(id: "lxc/201", type: .lxc, node: "pve2", vmid: 201, name: "nginx-proxy", status: "running", cpu: 0.02, maxcpu: 2, mem: 240_000_000, maxmem: 1_073_741_824, uptime: 604_800),
        ProxmoxGuest(id: "qemu/9000", type: .qemu, node: "pve1", vmid: 9000, name: "debian-template", status: "stopped", maxcpu: 2, maxmem: 2_147_483_648, template: 1),
    ]
    private var tasks: [ProxmoxTask] = [
        ProxmoxTask(upid: "UPID:pve1:0002:sample:vzdump::root@pam:", node: "pve1", type: "vzdump", target: "101", user: "root@pam", starttime: Int64(Date.now.timeIntervalSince1970) - 3_600, endtime: Int64(Date.now.timeIntervalSince1970) - 3_590, status: "job errors"),
        ProxmoxTask(upid: "UPID:pve1:0001:sample:vzdump::root@pam:", node: "pve1", type: "vzdump", target: "100", user: "root@pam", starttime: Int64(Date.now.timeIntervalSince1970) - 7_200, endtime: Int64(Date.now.timeIntervalSince1970) - 6_900, status: "OK"),
    ]

    func snapshot() async throws -> ProxmoxSnapshot {
        try await Task.sleep(for: .milliseconds(200))
        return ProxmoxSnapshot(
            version: "9.0.10",
            nodes: [
                ProxmoxNode(node: "pve1", status: "online", cpu: 0.18, maxcpu: 16, mem: 22_000_000_000, maxmem: 68_719_476_736, uptime: 2_592_000),
                ProxmoxNode(node: "pve2", status: "online", cpu: 0.07, maxcpu: 4, mem: 3_100_000_000, maxmem: 17_179_869_184, uptime: 3_110_400),
            ],
            guests: guests,
            tasks: tasks
        )
    }

    func perform(_ action: ProxmoxPowerAction, on guest: ProxmoxGuest) async throws -> String {
        try await Task.sleep(for: .milliseconds(800))
        guard let index = guests.firstIndex(where: { $0.id == guest.id }) else { return "OK" }
        switch action {
        case .start, .resume, .reboot, .reset: guests[index].status = "running"
        case .shutdown, .stop: guests[index].status = "stopped"
        case .suspend: guests[index].status = "paused"
        }
        let now = Int64(Date.now.timeIntervalSince1970)
        tasks.insert(ProxmoxTask(upid: "UPID:\(guest.node):\(now):sample", node: guest.node, type: "qm\(action.rawValue)", target: String(guest.vmid), user: "homelab@pve!app", starttime: now, endtime: now, status: "OK"), at: 0)
        return "OK"
    }
}

actor SamplePortainer: PortainerService {
    private var containerList: [PortainerContainer] = [
        PortainerContainer(Id: "a1b2c3d4e5f6", Names: ["/grafana"], Image: "grafana/grafana:12.1.0", State: "running", Status: "Up 3 days (healthy)", Created: 1_758_000_000, Labels: ["com.docker.compose.project": "monitoring"]),
        PortainerContainer(Id: "b2c3d4e5f6a1", Names: ["/prometheus"], Image: "prom/prometheus:v3.5.0", State: "running", Status: "Up 3 days", Created: 1_758_000_000, Labels: ["com.docker.compose.project": "monitoring"]),
        PortainerContainer(Id: "c3d4e5f6a1b2", Names: ["/gitea"], Image: "gitea/gitea:1.24", State: "exited", Status: "Exited (0) 2 hours ago", Created: 1_757_000_000, Labels: [:]),
    ]
    private var stackList: [PortainerStack] = [
        PortainerStack(Id: 1, Name: "monitoring", Type: 2, EndpointId: 1, Status: 1),
        PortainerStack(Id: 2, Name: "git", Type: 2, EndpointId: 1, Status: 2),
    ]

    func version() async throws -> String? { "2.33.1" }

    func environments() async throws -> [PortainerEnvironment] {
        try await Task.sleep(for: .milliseconds(150))
        return [
            PortainerEnvironment(Id: 1, Name: "local", Type: 1, Status: 1, URL: "unix:///var/run/docker.sock"),
            PortainerEnvironment(Id: 2, Name: "garage-pi", Type: 2, Status: 2, URL: "tcp://10.0.0.40:9001"),
        ]
    }

    func containers(environmentID: Int) async throws -> [PortainerContainer] {
        environmentID == 1 ? containerList : []
    }

    func stacks() async throws -> [PortainerStack] { stackList }

    func inspect(environmentID: Int, containerID: String) async throws -> PortainerInspection {
        let unhealthy = containerID.hasPrefix("c3")
        return PortainerInspection(
            state: .init(Status: "running", OOMKilled: false, ExitCode: 0, Error: "", StartedAt: Date.now.addingTimeInterval(-3_600).formatted(.iso8601), FinishedAt: nil,
                         Health: .init(Status: unhealthy ? "unhealthy" : "healthy", FailingStreak: unhealthy ? 4 : 0,
                                       Log: [.init(Start: Date.now.addingTimeInterval(-30).formatted(.iso8601), ExitCode: unhealthy ? 1 : 0,
                                                   Output: unhealthy ? "curl: (7) Failed to connect to localhost port 8080: Connection refused" : "OK")])),
            restartCount: unhealthy ? 7 : 0,
            hostConfig: .init(RestartPolicy: .init(Name: "unless-stopped", MaximumRetryCount: 0))
        )
    }

    func logs(environmentID: Int, containerID: String, tail: Int) async throws -> [String] {
        (1...20).map { "level=info msg=\"sample log line \($0)\" component=\(containerID.prefix(6))" }
    }

    func perform(_ action: PortainerContainerAction, environmentID: Int, containerID: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard let index = containerList.firstIndex(where: { $0.Id == containerID }) else { return }
        containerList[index].State = action == .stop ? "exited" : "running"
        containerList[index].Status = action == .stop ? "Exited (0) Less than a second ago" : "Up Less than a second"
    }

    func setStack(_ stack: PortainerStack, active: Bool) async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard let index = stackList.firstIndex(where: { $0.Id == stack.Id }) else { return }
        stackList[index].Status = active ? 1 : 2
    }
}

actor SampleTrueNAS: TrueNASService {
    private var snapshotTasks = [
        TrueNASSnapshotTask(id: 1, dataset: "tank/appdata", recursive: true, enabled: true, lifetime_value: 2, lifetime_unit: "WEEK",
                            schedule: .init(minute: "0", hour: "*", dom: "*", month: "*", dow: "*"), state: TrueNASTaskState(state: "FINISHED", date: .now.addingTimeInterval(-1_800))),
        TrueNASSnapshotTask(id: 2, dataset: "tank/photos", recursive: false, enabled: true, lifetime_value: 6, lifetime_unit: "MONTH",
                            schedule: .init(minute: "0", hour: "3", dom: "*", month: "*", dow: "*"), state: TrueNASTaskState(state: "ERROR", date: .now.addingTimeInterval(-80_000), error: "Dataset tank/photos is locked.")),
    ]

    func dataProtection() async throws -> TrueNASDataProtection {
        try await Task.sleep(for: .milliseconds(150))
        return TrueNASDataProtection(snapshotTasks: snapshotTasks, replicationTasks: [
            TrueNASReplicationTask(id: 1, name: "tank/appdata → backup-nas", direction: "PUSH", transport: "SSH", source_datasets: ["tank/appdata"], target_dataset: "backup/appdata",
                                   enabled: true, auto: true, state: TrueNASTaskState(state: "FINISHED", date: .now.addingTimeInterval(-1_700))),
        ])
    }

    func runSnapshotTask(_ task: TrueNASSnapshotTask) async throws {
        try await Task.sleep(for: .milliseconds(300))
        for index in snapshotTasks.indices where snapshotTasks[index].id == task.id {
            snapshotTasks[index].state = TrueNASTaskState(state: "FINISHED", date: .now)
        }
    }

    private var alerts: [TrueNASAlert] = [
        TrueNASAlert(uuid: "a1", level: "WARNING", klass: "SMARTFailed", formatted: "Device /dev/sdc: 8 Currently unreadable (pending) sectors.", text: nil, dismissed: false, datetime: nil),
        TrueNASAlert(uuid: "a2", level: "INFO", klass: "ScrubFinished", formatted: "Scrub of pool 'tank' finished with 0 errors.", text: nil, dismissed: false, datetime: nil),
    ]
    private var scrubbing = false

    func snapshot() async throws -> TrueNASSnapshot {
        try await Task.sleep(for: .milliseconds(200))
        let tb: Int64 = 1_000_000_000_000
        return TrueNASSnapshot(
            system: TrueNASSystemInfo(version: "25.10.1", hostname: "vault", uptime_seconds: 1_900_000, model: "Intel Xeon E-2336", cores: 12, physmem: 68_719_476_736, system_product: "Sample Storage Server"),
            pools: [
                TrueNASPool(id: 1, name: "tank", status: "ONLINE", healthy: true, warning: false, size: 48 * tb, allocated: 29 * tb, free: 19 * tb,
                            scan: TrueNASPool.Scan(function: "SCRUB", state: scrubbing ? "SCANNING" : "FINISHED", percentage: scrubbing ? 12.5 : 100, errors: 0)),
                TrueNASPool(id: 2, name: "fast", status: "ONLINE", healthy: true, warning: true, status_detail: "One or more features are not enabled.", size: 2 * tb, allocated: tb / 2, free: tb * 3 / 2),
            ],
            disks: [
                TrueNASDisk(identifier: "{serial}S1", name: "sda", serial: "SAMPLE-SDA", size: 12 * tb, model: "WDC WD120EFBX", type: "HDD", pool: "tank", rotationrate: 7200),
                TrueNASDisk(identifier: "{serial}S2", name: "sdb", serial: "SAMPLE-SDB", size: 12 * tb, model: "WDC WD120EFBX", type: "HDD", pool: "tank", rotationrate: 7200),
                TrueNASDisk(identifier: "{serial}S3", name: "sdc", serial: "SAMPLE-SDC", size: 12 * tb, model: "WDC WD120EFBX", type: "HDD", pool: "tank", rotationrate: 7200),
                TrueNASDisk(identifier: "{serial}N1", name: "nvme0n1", serial: "SAMPLE-NVME", size: 2 * tb, model: "Samsung 990 PRO", type: "SSD", pool: "fast"),
            ],
            alerts: alerts,
            datasets: [
                TrueNASDataset(id: "tank/media", type: "FILESYSTEM", name: "media", pool: "tank", encrypted: false, locked: false, used: .init(parsed: .number(21e12)), available: .init(parsed: .number(19e12)), mountpoint: "/mnt/tank/media"),
                TrueNASDataset(id: "tank/backups", type: "FILESYSTEM", name: "backups", pool: "tank", encrypted: true, locked: false, used: .init(parsed: .number(6e12)), available: .init(parsed: .number(19e12)), mountpoint: "/mnt/tank/backups"),
                TrueNASDataset(id: "fast/apps", type: "FILESYSTEM", name: "apps", pool: "fast", encrypted: false, locked: false, used: .init(parsed: .number(4e11)), available: .init(parsed: .number(1.5e12)), mountpoint: "/mnt/fast/apps"),
            ],
            jobs: [
                TrueNASJob(id: 812, method: "pool.scrub.scrub", description: "Scrub of pool tank", state: scrubbing ? "RUNNING" : "SUCCESS", progress: .init(percent: scrubbing ? 12 : 100, description: nil)),
                TrueNASJob(id: 811, method: "replication.run", description: "Replication to offsite", state: "FAILED", progress: .init(percent: 40, description: nil), error: "Connection refused"),
            ]
        )
    }

    func setAlert(_ alert: TrueNASAlert, dismissed: Bool) async throws {
        guard let index = alerts.firstIndex(where: { $0.uuid == alert.uuid }) else { return }
        alerts[index].dismissed = dismissed
    }

    func scrub(_ pool: TrueNASPool, action: TrueNASScrubAction) async throws {
        try await Task.sleep(for: .milliseconds(400))
        scrubbing = action == .start
    }
}
