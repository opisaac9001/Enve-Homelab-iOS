import Foundation

/// Sample data for preview mode only. Actions mutate local state so flows can be exercised without a server.
actor UnraidPreviewService: UnraidService {
    /// Keys the sample server's in-memory disk history.
    static let historyKey = UUID(uuidString: "00000000-0000-0000-0000-00000000A11D")!
    static let serverName = "atlas"

    private var containerList: [DockerContainer]
    private var vmList: [VirtualMachine]
    private var parity: ParityCheck
    private var unread: [UnraidNotification]
    private var archived: [UnraidNotification]
    private var logSequence = 0
    private var arrayState: ArrayState = .started
    private let bootTime = Date.now.addingTimeInterval(-(19 * 86_400 + 7 * 3_600))

    init() {
        containerList = Self.makeContainers()
        vmList = [
            VirtualMachine(id: "preview:vm-windows", name: "Windows 11 Workstation", state: .running),
            VirtualMachine(id: "preview:vm-ubuntu", name: "Ubuntu Build Runner", state: .idle),
            VirtualMachine(id: "preview:vm-haos", name: "Home Automation OS", state: .shutoff),
        ]
        parity = ParityCheck(
            status: .completed,
            date: .now.addingTimeInterval(-12 * 86_400),
            durationSeconds: 71_940,
            speed: "154.2",
            errors: 0,
            progress: 100,
            correcting: false,
            paused: false,
            running: false
        )
        unread = Self.makeUnreadNotifications()
        archived = Self.makeArchivedNotifications()
    }

    func identity() async throws -> UnraidIdentity {
        try await simulateLatency()
        return UnraidIdentity(name: Self.serverName, unraidVersion: "7.2.0")
    }

    func systemOverview() async throws -> SystemOverview {
        try await simulateLatency()
        return SystemOverview(
            hostname: Self.serverName,
            bootTime: bootTime,
            kernel: "6.12.24-Unraid",
            cpuBrand: "AMD Ryzen 7 5700G",
            cores: 8,
            threads: 16,
            unraidVersion: "7.2.0",
            apiVersion: "4.25.0"
        )
    }

    func metrics() async throws -> SystemMetrics {
        try await simulateLatency()
        return Self.sampleMetrics()
    }

    nonisolated func metricsUpdates() -> AsyncThrowingStream<SystemMetrics, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(Self.sampleMetrics())
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sampleMetrics() -> SystemMetrics {
        let total: Int64 = 64 * 1_073_741_824
        let percent = Double.random(in: 38...46)
        let used = Int64(Double(total) * percent / 100)
        return SystemMetrics(
            cpuPercent: Double.random(in: 9...27),
            memory: MemoryUsage(
                total: total,
                used: used,
                available: total - used,
                percent: percent,
                swapTotal: 0,
                swapUsed: 0
            )
        )
    }

    func arrayStatus() async throws -> ArrayStatus {
        try await simulateLatency()
        let tb: Int64 = 976_562_500
        let parities = [
            Self.disk("parity", slot: 0, type: .parity, sizeKB: 18 * tb, temp: 33, device: "sdb"),
            Self.disk("parity2", slot: 29, type: .parity, sizeKB: 18 * tb, temp: 34, device: "sdc"),
        ]
        let disks = [
            Self.disk("disk1", slot: 1, type: .data, sizeKB: 18 * tb, usedKB: 15_200_000_000, temp: 35, device: "sdd"),
            Self.disk("disk2", slot: 2, type: .data, sizeKB: 18 * tb, usedKB: 13_900_000_000, temp: 36, device: "sde"),
            Self.disk("disk3", slot: 3, type: .data, sizeKB: 14 * tb, usedKB: 12_800_000_000, temp: 46, device: "sdf"),
            Self.disk("disk4", slot: 4, type: .data, sizeKB: 14 * tb, usedKB: 6_100_000_000, temp: nil, device: "sdg", spinning: false),
            Self.disk("disk5", slot: 5, type: .data, sizeKB: 12 * tb, usedKB: 2_400_000_000, temp: nil, device: "sdh", spinning: false, errors: 3),
        ]
        let caches = [
            Self.disk("cache", slot: 30, type: .cache, sizeKB: 2 * tb, usedKB: 820_000_000, temp: 41, device: "nvme0n1", rotational: false, fsType: "btrfs"),
            Self.disk("cache2", slot: 31, type: .cache, sizeKB: 2 * tb, usedKB: 820_000_000, temp: 43, device: "nvme1n1", rotational: false, fsType: "btrfs"),
        ]
        let boot = Self.disk("flash", slot: 54, type: .flash, sizeKB: 31_000_000, usedKB: 1_200_000, temp: nil, device: "sda", rotational: false, fsType: "vfat")

        let total = disks.compactMap(\.filesystemSizeKB).reduce(0, +)
        let used = disks.compactMap(\.filesystemUsedKB).reduce(0, +)
        return ArrayStatus(
            state: arrayState,
            capacity: ArrayCapacity(totalKB: total, usedKB: used, freeKB: total - used),
            parityCheck: parity,
            parities: parities,
            disks: disks,
            caches: caches,
            boot: boot
        )
    }

    nonisolated func arrayUpdates() -> AsyncThrowingStream<ArrayStatus, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        continuation.yield(try await self.arrayStatus())
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func parityHistory() async throws -> [ParityCheck] {
        try await simulateLatency()
        let history = [42, 72, 102].map { days in
            ParityCheck(status: .completed, date: .now.addingTimeInterval(-Double(days) * 86_400), durationSeconds: 70_200 + days * 13, speed: "151.8", errors: 0)
        } + [ParityCheck(status: .cancelled, date: .now.addingTimeInterval(-118 * 86_400), durationSeconds: 8_400, speed: "149.0", errors: 0)]
        return [parity] + history
    }

    func perform(_ action: ParityAction) async throws {
        try await simulateLatency()
        switch action {
        case .startCheck:
            parity = ParityCheck(status: .running, date: .now, durationSeconds: 0, speed: "152.0", errors: 0, progress: 0, correcting: false, paused: false, running: true)
        case .pause:
            parity.status = .paused
            parity.paused = true
        case .resume:
            parity.status = .running
            parity.paused = false
        case .cancel:
            parity.status = .cancelled
            parity.running = false
            parity.paused = false
        }
    }

    func setArrayState(_ action: ArrayStateAction, decryptionPassword: String?) async throws -> ArrayState {
        try await simulateLatency(seconds: 1.5)
        switch (action, arrayState) {
        case (.stop, .started):
            arrayState = .stopped
            for index in containerList.indices where containerList[index].state != .exited {
                containerList[index].state = .exited
                containerList[index].status = "Exited (0) Less than a second ago"
            }
            for index in vmList.indices where vmList[index].state != .shutoff {
                vmList[index].state = .shutoff
            }
            if parity.isActive {
                parity.status = .cancelled
                parity.running = false
            }
        case (.start, .stopped):
            arrayState = .started
            for index in containerList.indices where containerList[index].autoStart {
                containerList[index].state = .running
                containerList[index].status = "Up Less than a second"
            }
        default:
            throw NetworkError.graphQL(["The array is already \(arrayState.displayName.lowercased())."])
        }
        return arrayState
    }

    func physicalDisks() async throws -> [PhysicalDisk] {
        try await simulateLatency()
        let array = try await arrayStatus()
        return array.allDevices.compactMap { disk in
            guard let device = disk.device else { return nil }
            let isNVMe = device.hasPrefix("nvme")
            let isFlash = disk.type == .flash
            return PhysicalDisk(
                id: "preview:physical-\(device)",
                device: "/dev/\(device)",
                type: disk.rotational == false ? "SSD" : "HDD",
                name: isFlash ? "SanDisk Cruzer Fit" : (isNVMe ? "Samsung SSD 990 PRO 2TB" : "WDC WUH721818ALE6L4"),
                vendor: isFlash ? "SanDisk" : (isNVMe ? "Samsung" : "Western Digital"),
                size: Double(disk.sizeKB ?? 0) * 1024,
                firmwareRevision: isNVMe ? "4B2QJXD7" : "PCGNW232",
                serialNum: "SAMPLE-\(device.uppercased())",
                interfaceType: isFlash ? .usb : (isNVMe ? .pcie : .sata),
                smartStatus: disk.errors ?? 0 > 0 ? .unknown : .ok,
                temperature: disk.temperature.map(Double.init),
                partitions: disk.filesystemType.map { [DiskPartition(name: "\(device)1", fsType: $0.uppercased(), size: Double(disk.sizeKB ?? 0) * 1024)] } ?? [],
                isSpinning: disk.isSpinning ?? true
            )
        }
    }

    func shares() async throws -> [UnraidShare] {
        try await simulateLatency()
        func share(_ name: String, comment: String?, usedTB: Double, cache: Bool, include: [String] = []) -> UnraidShare {
            let tb = 976_562_500.0
            return UnraidShare(
                id: "preview:share-\(name)", name: name, comment: comment,
                freeKB: Int64(22.18 * tb), usedKB: Int64(usedTB * tb), sizeKB: 0,
                usesCache: cache, includedDisks: include, excludedDisks: [],
                allocator: "highwater", splitLevel: nil, luksStatus: nil
            )
        }
        return [
            share("appdata", comment: "Container configuration", usedTB: 0.21, cache: true),
            share("backups", comment: nil, usedTB: 3.4, cache: false, include: ["disk4", "disk5"]),
            share("cloud", comment: "Nextcloud data", usedTB: 1.9, cache: false),
            share("isos", comment: nil, usedTB: 0.08, cache: true),
            share("media", comment: "Films, series and music", usedTB: 36.2, cache: false),
            share("photos", comment: "Immich library", usedTB: 5.1, cache: false),
        ]
    }

    func upsDevices() async throws -> [UPSDevice] {
        try await simulateLatency()
        return [Self.sampleUPS(load: 31)]
    }

    nonisolated func upsUpdates() -> AsyncThrowingStream<[UPSDevice], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield([Self.sampleUPS(load: Int.random(in: 28...36))])
                    try? await Task.sleep(for: .seconds(3))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sampleUPS(load: Int) -> UPSDevice {
        UPSDevice(
            id: "preview:ups",
            name: "Rack UPS",
            model: "Sample Line-Interactive 1500VA",
            status: "Online",
            battery: UPSBattery(chargeLevel: 100, estimatedRuntime: 2_460, health: "Good"),
            power: UPSPower(inputVoltage: 121.4, outputVoltage: 121.4, loadPercentage: load, nominalPower: 900, currentPower: Double(900 * load) / 100)
        )
    }

    func refreshContainerUpdateStatus() async throws {
        try await simulateLatency(seconds: 1)
    }

    func updateContainer(id: String) async throws {
        try await simulateLatency(seconds: 2)
        guard let index = containerList.firstIndex(where: { $0.id == id }) else { return }
        containerList[index].isUpdateAvailable = false
        containerList[index].state = .running
        containerList[index].status = "Up Less than a second"
        containerList[index].created = .now
    }

    func containers() async throws -> [DockerContainer] {
        try await simulateLatency()
        return containerList
    }

    func containerDetails(id: String) async throws -> ContainerDetails {
        try await simulateLatency()
        guard let container = containerList.first(where: { $0.id == id }) else { throw NetworkError.unexpectedResponse("The server no longer has this container.") }
        let orphaned = container.name == "uptime-kuma"
        let order = containerList.filter(\.autoStart).firstIndex { $0.id == id }
        return ContainerDetails(
            id: id,
            templatePath: orphaned ? nil : "/boot/config/plugins/dockerMan/templates-user/my-\(container.name).xml",
            projectUrl: orphaned ? nil : "https://example.com/\(container.name)",
            supportUrl: orphaned ? nil : "https://forums.example.com/\(container.name)",
            isOrphaned: orphaned,
            isUpdateAvailable: container.isUpdateAvailable,
            isRebuildReady: false,
            lanIpPorts: container.ports.compactMap { $0.publicPort.map { "192.168.1.20:\($0)" } },
            sizeRootFs: container.sizeRootFs,
            sizeRw: 48_000_000,
            sizeLog: container.name == "nextcloud" ? 1_800_000_000 : 12_000_000,
            autoStart: container.autoStart,
            autoStartOrder: order,
            autoStartWait: container.name == "home-assistant" ? 10 : 0
        )
    }

    func portConflicts() async throws -> DockerPortConflicts {
        try await simulateLatency()
        return DockerPortConflicts(containerPorts: [], lanPorts: [
            .init(lanIpPort: "192.168.1.20:8443", publicPort: 8443, type: "TCP",
                  containers: [.init(id: "preview:nextcloud", name: "nextcloud"), .init(id: "preview:uptime-kuma", name: "uptime-kuma")]),
        ])
    }

    func temperatures() async throws -> TemperatureReport {
        try await simulateLatency()
        func history(_ base: Double) -> [TemperatureReport.Reading] {
            (0..<24).map { step in
                TemperatureReport.Reading(celsius: base + sin(Double(step) / 3) * 2.5, date: .now.addingTimeInterval(Double(step - 24) * 300))
            }
        }
        let sensors = [
            TemperatureReport.Sensor(id: "cpu", name: "CPU Package", kind: "CPU_PACKAGE", location: nil, current: .init(celsius: 54, date: .now), status: .normal,
                                     minimum: 38, maximum: 71, warning: 80, critical: 90, history: history(52)),
            TemperatureReport.Sensor(id: "nvme0", name: "Samsung 990 PRO", kind: "NVME", location: "nvme0n1", current: .init(celsius: 61, date: .now), status: .warning,
                                     minimum: 44, maximum: 63, warning: 60, critical: 70, history: history(58)),
            TemperatureReport.Sensor(id: "mb", name: "Motherboard", kind: "MOTHERBOARD", location: nil, current: .init(celsius: 37, date: .now), status: .normal,
                                     minimum: 33, maximum: 41, warning: nil, critical: nil, history: history(37)),
        ]
        return TemperatureReport(average: 50.7, warningCount: 1, criticalCount: 0, sensors: sensors)
    }

    func logFiles() async throws -> [LogFileInfo] {
        try await simulateLatency()
        return [
            LogFileInfo(name: "docker.log", path: "/var/log/docker.log", size: 48_210, modifiedAt: Date.now.formatted(.iso8601)),
            LogFileInfo(name: "syslog", path: "/var/log/syslog", size: 812_400, modifiedAt: Date.now.formatted(.iso8601)),
        ]
    }

    func logFile(path: String, lines: Int) async throws -> LogFileText {
        try await simulateLatency()
        let sample = [
            "Sep 29 09:12:01 Tower emhttpd: read SMART /dev/sdb",
            "Sep 29 09:12:04 Tower kernel: mdcmd (36): spindown 2",
            "Sep 29 09:30:00 Tower crond[1843]: exit status 1 from user root /usr/local/sbin/mover &> /dev/null",
            "Sep 29 10:02:17 Tower kernel: nvme nvme0: temperature above warning threshold (61 C)",
            "Sep 29 10:05:44 Tower webGUI: Successful login user root from 192.168.1.50",
        ]
        return LogFileText(path: path, content: sample.suffix(lines).joined(separator: "\n"), totalLines: 1_284, startLine: 1_280)
    }

    func containerLogs(id: String, tail: Int, since: String?) async throws -> ContainerLogBatch {
        try await simulateLatency()
        guard let container = containerList.first(where: { $0.id == id }) else { return ContainerLogBatch(lines: [], cursor: since) }
        let count = since == nil ? min(tail, 40) : Int.random(in: 0...2)
        let start = Date.now.addingTimeInterval(-Double(count) * 7)
        let lines = (0..<count).map { offset in
            logSequence += 1
            let stamp = start.addingTimeInterval(Double(offset) * 7)
            let raw = stamp.formatted(.iso8601)
            return ContainerLogLine(timestampRaw: raw, timestamp: stamp, message: Self.sampleLogMessage(for: container.name, sequence: logSequence))
        }
        return ContainerLogBatch(lines: lines, cursor: lines.last?.timestampRaw ?? since)
    }

    func perform(_ action: ContainerAction, containerID: String) async throws {
        try await simulateLatency(seconds: 0.8)
        guard let index = containerList.firstIndex(where: { $0.id == containerID }) else { return }
        switch action {
        case .start, .restart, .unpause:
            containerList[index].state = .running
            containerList[index].status = "Up Less than a second"
        case .stop:
            containerList[index].state = .exited
            containerList[index].status = "Exited (0) Less than a second ago"
        case .pause:
            containerList[index].state = .paused
            containerList[index].status = "Up 3 days (Paused)"
        }
    }

    func virtualMachines() async throws -> [VirtualMachine] {
        try await simulateLatency()
        return vmList
    }

    func perform(_ action: VMAction, vmID: String) async throws {
        try await simulateLatency(seconds: 0.8)
        guard let index = vmList.firstIndex(where: { $0.id == vmID }) else { return }
        switch action {
        case .start, .resume, .reboot, .reset: vmList[index].state = .running
        case .stop, .forceStop: vmList[index].state = .shutoff
        case .pause: vmList[index].state = .paused
        }
    }

    func notificationOverview() async throws -> NotificationOverview {
        try await simulateLatency()
        return NotificationOverview(unread: Self.counts(unread), archive: Self.counts(archived))
    }

    func notifications(_ type: NotificationListType, importance: NotificationImportance?, limit: Int) async throws -> [UnraidNotification] {
        try await simulateLatency()
        let source = type == .unread ? unread : archived
        return Array(source.filter { importance == nil || $0.importance == importance }.prefix(limit))
    }

    func archiveNotification(id: String) async throws {
        try await simulateLatency()
        guard let index = unread.firstIndex(where: { $0.id == id }) else { return }
        archived.insert(unread.remove(at: index), at: 0)
    }

    func archiveAllNotifications() async throws {
        try await simulateLatency()
        archived.insert(contentsOf: unread, at: 0)
        unread.removeAll()
    }

    private func simulateLatency(seconds: Double = 0.25) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func counts(_ notifications: [UnraidNotification]) -> NotificationCounts {
        NotificationCounts(
            info: notifications.filter { $0.importance == .info }.count,
            warning: notifications.filter { $0.importance == .warning }.count,
            alert: notifications.filter { $0.importance == .alert }.count,
            total: notifications.count
        )
    }

    private static func disk(
        _ name: String,
        slot: Int,
        type: ArrayDiskType,
        sizeKB: Int64,
        usedKB: Int64? = nil,
        temp: Int?,
        device: String,
        rotational: Bool = true,
        spinning: Bool = true,
        fsType: String = "xfs",
        errors: Int64 = 0
    ) -> ArrayDisk {
        let hasFilesystem = type != .parity
        return ArrayDisk(
            id: "preview:disk-\(name)",
            slot: slot,
            name: name,
            device: device,
            sizeKB: sizeKB,
            status: .ok,
            rotational: rotational,
            temperature: temp,
            reads: Int64(slot + 1) * 1_904_331,
            writes: Int64(slot + 1) * 402_117,
            errors: errors,
            filesystemSizeKB: hasFilesystem ? sizeKB : nil,
            filesystemFreeKB: hasFilesystem ? sizeKB - (usedKB ?? 0) : nil,
            filesystemUsedKB: hasFilesystem ? usedKB : nil,
            filesystemType: hasFilesystem ? fsType : nil,
            type: type,
            usageWarningPercent: 70,
            usageCriticalPercent: 90,
            isSpinning: rotational ? spinning : nil,
            transport: rotational ? "sata" : (type == .flash ? "usb" : "nvme"),
            comment: nil
        )
    }

    private static func makeContainers() -> [DockerContainer] {
        func container(
            _ name: String,
            image: String,
            state: ContainerState,
            status: String,
            ports: [ContainerPort] = [],
            network: String = "bridge",
            mounts: [ContainerMount] = [],
            web: String? = nil,
            update: Bool = false,
            daysOld: Double
        ) -> DockerContainer {
            DockerContainer(
                id: "preview:\(name)",
                name: name,
                image: image,
                state: state,
                status: status,
                created: .now.addingTimeInterval(-daysOld * 86_400),
                autoStart: state != .exited,
                ports: ports,
                networkMode: network,
                mounts: mounts,
                webUIURL: web.flatMap(URL.init(string:)),
                iconURL: nil,
                isUpdateAvailable: update,
                sizeRootFs: Int64.random(in: 180_000_000...2_400_000_000)
            )
        }
        func tcp(_ host: Int, _ container: Int) -> ContainerPort {
            ContainerPort(ip: "0.0.0.0", privatePort: container, publicPort: host, type: "TCP")
        }
        func appdata(_ name: String, _ destination: String = "/config") -> ContainerMount {
            ContainerMount(source: "/mnt/user/appdata/\(name)", destination: destination, readOnly: false)
        }

        return [
            container("jellyfin", image: "jellyfin/jellyfin:latest", state: .running, status: "Up 6 days (healthy)",
                      ports: [tcp(8096, 8096)], network: "host",
                      mounts: [appdata("jellyfin"), ContainerMount(source: "/mnt/user/media", destination: "/media", readOnly: true)],
                      web: "http://192.168.1.20:8096", daysOld: 40),
            container("nextcloud", image: "lscr.io/linuxserver/nextcloud:latest", state: .running, status: "Up 6 days",
                      ports: [tcp(8443, 443)], mounts: [appdata("nextcloud"), ContainerMount(source: "/mnt/user/cloud", destination: "/data", readOnly: false)],
                      web: "https://192.168.1.20:8443", update: true, daysOld: 88),
            container("home-assistant", image: "ghcr.io/home-assistant/home-assistant:stable", state: .running, status: "Up 2 days",
                      network: "host", mounts: [appdata("home-assistant")], web: "http://192.168.1.20:8123", daysOld: 12),
            container("vaultwarden", image: "vaultwarden/server:latest", state: .running, status: "Up 6 days (healthy)",
                      ports: [tcp(4743, 80)], mounts: [appdata("vaultwarden", "/data")], daysOld: 55),
            container("immich-server", image: "ghcr.io/immich-app/immich-server:release", state: .running, status: "Up 6 days",
                      ports: [tcp(2283, 2283)], mounts: [appdata("immich"), ContainerMount(source: "/mnt/user/photos", destination: "/usr/src/app/upload", readOnly: false)],
                      web: "http://192.168.1.20:2283", update: true, daysOld: 21),
            container("paperless-ngx", image: "ghcr.io/paperless-ngx/paperless-ngx:latest", state: .paused, status: "Up 6 days (Paused)",
                      ports: [tcp(8010, 8000)], mounts: [appdata("paperless", "/usr/src/paperless/data")], daysOld: 30),
            container("syncthing", image: "lscr.io/linuxserver/syncthing:latest", state: .running, status: "Up 6 days",
                      ports: [tcp(8384, 8384), ContainerPort(ip: "0.0.0.0", privatePort: 22000, publicPort: 22000, type: "UDP")],
                      mounts: [appdata("syncthing")], daysOld: 140),
            container("uptime-kuma", image: "louislam/uptime-kuma:1", state: .exited, status: "Exited (137) 3 hours ago",
                      ports: [tcp(3001, 3001)], mounts: [appdata("uptime-kuma", "/app/data")], daysOld: 64),
        ]
    }

    private static func sampleLogMessage(for name: String, sequence: Int) -> String {
        let messages = [
            "[info] \(name): health check passed",
            "[info] Scheduled task completed in \(Int.random(in: 40...900)) ms",
            "[info] Accepted connection from 192.168.1.\(Int.random(in: 30...90))",
            "[warn] Slow response from upstream (\(Int.random(in: 1_100...2_800)) ms)",
            "[info] Cache warmed: \(Int.random(in: 100...900)) entries",
            "[debug] Worker \(sequence % 4) idle",
        ]
        return messages[sequence % messages.count]
    }

    private static func makeUnreadNotifications() -> [UnraidNotification] {
        [
            UnraidNotification(id: "preview:n1", title: "Array health", subject: "disk5 has read errors",
                               description: "disk5 (sdh) reported 3 read errors. Parity reconstructed the data. Check the drive's SMART report.",
                               importance: .alert, link: nil, timestamp: .now.addingTimeInterval(-3_600), formattedTimestamp: nil),
            UnraidNotification(id: "preview:n2", title: "Temperature", subject: "disk3 is warm (46 °C)",
                               description: "disk3 crossed its 45 °C warning threshold.", importance: .warning, link: nil,
                               timestamp: .now.addingTimeInterval(-5_400), formattedTimestamp: nil),
            UnraidNotification(id: "preview:n3", title: "Docker", subject: "2 container updates available",
                               description: "Updates are available for nextcloud and immich-server.", importance: .info, link: nil,
                               timestamp: .now.addingTimeInterval(-26_000), formattedTimestamp: nil),
        ]
    }

    private static func makeArchivedNotifications() -> [UnraidNotification] {
        [
            UnraidNotification(id: "preview:a1", title: "Parity check", subject: "Parity check finished (0 errors)",
                               description: "Duration: 19 h 59 m. Average speed 154.2 MB/s.", importance: .info, link: nil,
                               timestamp: .now.addingTimeInterval(-12 * 86_400), formattedTimestamp: nil),
            UnraidNotification(id: "preview:a2", title: "Backup", subject: "Flash backup completed",
                               description: "The boot device configuration was backed up.", importance: .info, link: nil,
                               timestamp: .now.addingTimeInterval(-15 * 86_400), formattedTimestamp: nil),
        ]
    }
}
