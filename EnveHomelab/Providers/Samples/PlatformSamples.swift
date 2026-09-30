import Foundation

/// Sample data for the labelled sample integrations only; each renders through its live client's mapper.
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(150))
}

private func iso(_ offset: TimeInterval) -> String {
    Date.now.addingTimeInterval(offset).formatted(.iso8601)
}

actor SampleSynology: DashboardService, SynologyOperations {
    nonisolated let kind = IntegrationKind.synology
    private var guests = [
        SynologyGuest(guest_id: "g1", guest_name: "home-assistant-os", status: "running", vcpu_num: 2, vram_size: 4_096, storage_name: "volume1"),
        SynologyGuest(guest_id: "g2", guest_name: "windows-lab", status: "shutdown", vcpu_num: 4, vram_size: 8_192, storage_name: "volume1"),
    ]
    private var tasks: [SynologyTask] = [
        SynologyTask(id: "dbid_1", type: "bt", title: "debian-13.1.0-amd64-netinst.iso", size: LooseNumber(700_000_000), status: "downloading",
                     additional: .init(transfer: .init(size_downloaded: LooseNumber(420_000_000), speed_download: LooseNumber(6_200_000)))),
        SynologyTask(id: "dbid_2", type: "http", title: "firmware-update.pat", size: LooseNumber(380_000_000), status: "error", status_extra: .init(error_detail: "disk_full")),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return SynologyDashboard.snapshot(SynologyOverview(downloadStationVersion: "4.0.1-4760", tasks: tasks, downloadRate: 6_200_000, uploadRate: 0, guests: guests,
                                                           hosts: [SynologyHost(host_id: "h1", host_name: "DS923+", status: "running", total_cpu_core: 4, free_cpu_core: 2, total_ram_size: 32_768, free_ram_size: 20_480)]),
                                          operations: self)
    }

    func tasks(_ method: String, ids: [String]) async throws {
        for index in tasks.indices where ids.contains(tasks[index].id) {
            tasks[index].status = method == "pause" ? "paused" : "downloading"
        }
        if method == "delete" { tasks.removeAll { ids.contains($0.id) } }
    }

    func guest(_ action: SynologyGuestAction, id: String) async throws {
        for index in guests.indices where guests[index].guest_id == id {
            guests[index].status = action == .poweron ? "running" : "shutdown"
        }
    }
}

actor SampleDockhand: DashboardService, DockhandOperations {
    nonisolated let kind = IntegrationKind.dockhand
    private var states = ["c1": "running", "c2": "running", "c3": "exited"]

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        let containers = [
            DockhandContainer(id: "c1", name: "vaultwarden", image: "vaultwarden/server:latest", state: states["c1"]!, status: "Up 3 days (healthy)", health: "healthy"),
            DockhandContainer(id: "c2", name: "uptime-probe", image: "ghcr.io/example/probe:1.2", state: states["c2"]!, status: "Up 2 hours (unhealthy)", health: "unhealthy", restartCount: 4),
            DockhandContainer(id: "c3", name: "backup-job", image: "restic/restic:0.18", state: states["c3"]!, status: "Exited (0) 6 hours ago"),
        ]
        return DockhandDashboard.snapshot(DockhandOverview(environments: [
            .init(environment: DockhandEnvironment(id: 1, name: "Tower"), containers: containers,
                  stacks: [DockhandStack(name: "monitoring", status: "partial", containers: ["uptime-probe", "grafana"])]),
        ]), operations: self)
    }

    func container(_ action: DockerAction, id: String, environment: Int) async throws { states[id] = action == .stop ? "exited" : "running" }
    func stack(_ action: DockerAction, name: String, environment: Int) async throws {}
}

actor SampleKomodo: DashboardService, KomodoOperations {
    nonisolated let kind = IntegrationKind.komodo
    private var stackState = "running"

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return KomodoDashboard.snapshot(KomodoOverview(
            version: "2.3.3",
            servers: [KomodoServer(id: "s1", name: "tower", info: .init(state: "Ok", region: "home", version: "2.3.3", stats: .init(cpu_perc: 18, mem_used_gb: 22.4, mem_total_gb: 64))),
                      KomodoServer(id: "s2", name: "offsite-pi", info: .init(state: "NotOk", region: "offsite", version: "2.3.1"))],
            stacks: [KomodoStack(id: "st1", name: "media", info: .init(state: stackState, status: "Up 2 days", server_name: "tower", services: [.init(service: "web", update_available: true)]))],
            deployments: [KomodoDeployment(id: "d1", name: "reverse-proxy", info: .init(state: "running", status: "Up 9 days", image: "caddy:2", server_name: "tower"))],
            alerts: [try JSONDecoder().decode(KomodoAlert.self, from: Data(#"{"level":"CRITICAL","ts":\#(Date.now.addingTimeInterval(-900).timeIntervalSince1970 * 1000),"data":{"type":"ServerUnreachable","data":{"id":"s2","name":"offsite-pi"}}}"#.utf8))]
        ), operations: self)
    }

    func stack(_ action: DockerAction, id: String) async throws { stackState = action == .stop ? "stopped" : "running" }
    func deployment(_ action: DockerAction, id: String) async throws {}
}

actor SampleCoolify: DashboardService, CoolifyOperations {
    nonisolated let kind = IntegrationKind.coolify
    private var deploying = true

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return CoolifyDashboard.snapshot(CoolifyOverview(
            version: "4.3.23",
            servers: [CoolifyServer(uuid: "srv1", name: "localhost", ip: "host.docker.internal", is_reachable: true, is_usable: true)],
            applications: [CoolifyResource(uuid: "app1", name: "family-website", status: "running:healthy", fqdn: "https://family.example.com"),
                           CoolifyResource(uuid: "app2", name: "recipes-api", status: "degraded:unhealthy", fqdn: "https://recipes.example.com")],
            services: [CoolifyResource(uuid: "svc1", name: "plausible", status: "running:healthy", service_type: "plausible")],
            databases: [CoolifyResource(uuid: "db1", name: "postgres-main", status: "exited", database_type: "standalone-postgresql")],
            deployments: deploying ? [CoolifyDeployment(deployment_uuid: "dep1", application_name: "recipes-api", server_name: "localhost", status: "in_progress",
                                                        commit_message: "Fix pagination on search", created_at: iso(-120))] : []
        ), operations: self)
    }

    func perform(_ action: DockerAction, on kind: CoolifyResourceKind, uuid: String) async throws {}
    func deploy(uuid: String) async throws { deploying = true }
    func cancel(deployment uuid: String) async throws { deploying = false }
}

actor SampleArcane: DashboardService, ArcaneOperations {
    nonisolated let kind = IntegrationKind.arcane

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return ArcaneDashboard.snapshot(ArcaneOverview(version: "v2.14.0", environments: [
            .init(environment: ArcaneEnvironment(id: "0", name: "Local", status: "online", enabled: true, connected: true),
                  containers: [ArcaneContainer(id: "a1", names: ["/immich_server"], image: "ghcr.io/immich-app/immich-server:release", state: "running", status: "Up 5 days (healthy)"),
                               ArcaneContainer(id: "a2", names: ["/paperless"], image: "ghcr.io/paperless-ngx/paperless-ngx", state: "running", status: "Up 1 hour (unhealthy)")],
                  projects: [ArcaneProject(id: "p1", name: "immich", status: "running", runningCount: 4, serviceCount: 4),
                             ArcaneProject(id: "p2", name: "paperless", status: "partially running", runningCount: 2, serviceCount: 3, statusReason: "broker exited with code 1")]),
            .init(environment: ArcaneEnvironment(id: "env-2", name: "Garage Pi", status: "offline", enabled: true, connected: false), containers: [], projects: [],
                  error: "The agent hasn't checked in for 3 hours."),
        ]), operations: self)
    }

    func container(_ action: DockerAction, id: String, environment: String) async throws {}
    func project(_ action: DockerAction, id: String, environment: String) async throws {}
}

actor SampleBeszel: DashboardService, BeszelOperations {
    nonisolated let kind = IntegrationKind.beszel
    private var paused: Set<String> = []

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        func status(_ id: String, _ live: String) -> String { paused.contains(id) ? "paused" : live }
        return BeszelDashboard.snapshot(BeszelOverview(
            version: "0.20.0",
            systems: [
                BeszelSystem(id: "sys1", name: "tower", status: status("sys1", "up"), host: "192.168.1.10",
                             info: .init(u: 1_209_600, cpu: 12.4, mp: 58.1, dp: 71.0, v: "0.20.0", la: [0.8, 0.9, 1.0], dt: 47)),
                BeszelSystem(id: "sys2", name: "garage-pi", status: status("sys2", "down"), host: "192.168.1.40", info: .init(v: "0.19.2")),
            ],
            containers: [BeszelContainer(id: "c1", name: "vaultwarden", system: "sys1", status: "Up 3 days", health: 2, cpu: 0.4, memory: 64),
                         BeszelContainer(id: "c2", name: "zigbee2mqtt", system: "sys1", status: "Up 20 minutes", health: 3, cpu: 1.2, memory: 180)],
            alerts: [BeszelAlert(id: "al1", name: "Status", system: "sys2", triggered: true)]
        ), operations: self)
    }

    func setPaused(_ isPaused: Bool, systemID: String) async throws {
        if isPaused { paused.insert(systemID) } else { paused.remove(systemID) }
    }
}

actor SampleControlD: DashboardService, ControlDOperations {
    nonisolated let kind = IntegrationKind.controld

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return ControlDDashboard.snapshot(ControlDOverview(
            profiles: [ControlDProfile(PK: "p1", name: "Family"), ControlDProfile(PK: "p2", name: "Work laptop")],
            devices: [ControlDDevice(PK: "d1", name: "Home router", status: 1, profile: .init(PK: "p1", name: "Family")),
                      ControlDDevice(PK: "d2", name: "Kids' tablet", status: 2, desc: "Filtering switched off", profile: .init(PK: "p1", name: "Family")),
                      ControlDDevice(PK: "d3", name: "MacBook", status: 1, profile: .init(PK: "p2", name: "Work laptop"))]
        ), operations: self)
    }

    func pause(profileID: String, until: Date) async throws {}
    func resume(profileID: String) async throws {}
}

actor SampleNextDNS: DashboardService, NextDNSOperations {
    nonisolated let kind = IntegrationKind.nextdns
    private var allowed: Set<String> = []

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        let domains = [NextDNSDomain(domain: "app-measurement.com", queries: 1_842), NextDNSDomain(domain: "ads.example-network.com", root: "example-network.com", queries: 911),
                       NextDNSDomain(domain: "telemetry.smart-tv.example", root: "smart-tv.example", queries: 604)]
        return NextDNSDashboard.snapshot(NextDNSOverview(
            profileID: "abc123", profile: NextDNSProfile(name: "Home"),
            statuses: [NextDNSStatusCount(status: "default", queries: 41_200), NextDNSStatusCount(status: "blocked", queries: 6_380), NextDNSStatusCount(status: "allowed", queries: 210)],
            blockedDomains: domains.filter { !allowed.contains($0.domain) },
            reasons: [NextDNSReason(id: "blocklist:nextdns-recommended", name: "NextDNS Ads & Trackers Blocklist", queries: 5_100),
                      NextDNSReason(id: "native:samsung", name: "Native tracking (Samsung)", queries: 604)],
            devices: [NextDNSDevice(id: "8TD1G", name: "Alex's iPhone", model: "iPhone", localIp: "192.168.1.51", queries: 12_400),
                      NextDNSDevice(id: "__UNIDENTIFIED__", queries: 3_210)]
        ), operations: self)
    }

    func allow(domain: String) async throws { allowed.insert(domain) }
}

actor SampleGluetun: DashboardService, GluetunOperations {
    nonisolated let kind = IntegrationKind.gluetun
    private var vpn = "running"

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return GluetunDashboard.snapshot(GluetunOverview(
            version: "v3.41.3", vpn: GluetunLoopStatus(status: vpn),
            publicIP: vpn == "running" ? GluetunPublicIP(public_ip: "203.0.113.77", country: "Netherlands", region: "North Holland", city: "Amsterdam", organization: "Example VPN AS") : GluetunPublicIP(public_ip: ""),
            portForward: GluetunPortForward(port: vpn == "running" ? 51_413 : 0),
            dns: GluetunLoopStatus(status: "running"), updater: GluetunLoopStatus(status: "completed"), forbiddenRoutes: []
        ), operations: self)
    }

    func set(_ loop: GluetunLoop, running: Bool) async throws {
        if loop == .vpn { vpn = running ? "running" : "stopped" }
    }
}

actor SampleTracearr: DashboardService, TracearrOperations {
    nonisolated let kind = IntegrationKind.tracearr
    private var streams = [
        TracearrStream(id: "t1", serverName: "Tower Plex", username: "jordan", mediaTitle: "Merge Conflict", mediaType: "episode", showTitle: "Open Source Chronicles",
                       seasonNumber: 2, episodeNumber: 5, state: "playing", progressMs: 900_000, durationMs: 2_700_000, videoDecision: "directplay", bitrate: 12_000, resolution: "1080p", player: "Living Room TV"),
        TracearrStream(id: "t2", serverName: "Tower Plex", username: "guest", mediaTitle: "Sample Home Movie", mediaType: "movie", state: "playing",
                       progressMs: 600_000, durationMs: 5_400_000, videoDecision: "transcode", isTranscode: true, bitrate: 4_000, resolution: "720p", player: "Chrome",
                       transcodeInfo: .init(hwRequested: true, hwDecoding: nil, hwEncoding: nil, speed: 0.8, throttled: false, reasons: ["Video codec not supported by client"])),
    ]

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return TracearrDashboard.snapshot(TracearrOverview(
            health: TracearrHealth(version: "2.5.1", servers: [.init(id: "s1", name: "Tower Plex", type: "plex", online: true, activeStreams: streams.count)]),
            today: TracearrToday(todayPlays: 14, watchTimeHours: 9.5),
            streams: streams,
            violations: [TracearrViolation(id: "v1", serverName: "Tower Plex", severity: "warning", acknowledged: false, createdAt: iso(-3_600),
                                           rule: .init(name: "Concurrent streams from two cities"), user: .init(username: "guest"))],
            activity: TracearrActivity(quality: .init(directPlayPercent: 61, directStreamPercent: 12, transcodePercent: 27, total: 96),
                                       concurrent: [.init(total: 3, transcode: 1), .init(total: 5, transcode: 2)])
        ), operations: self)
    }

    func terminate(streamID: String, reason: String) async throws { streams.removeAll { $0.id == streamID } }
}

actor SampleDispatcharr: DashboardService, DispatcharrOperations {
    nonisolated let kind = IntegrationKind.dispatcharr

    func dashboard() async throws -> DashboardSnapshot {
        try await settle()
        return DispatcharrDashboard.snapshot(DispatcharrOverview(
            version: "0.31.0",
            stats: DispatcharrStats(live: .init(channels: [.init(state: "active", client_count: 2, healthy: true), .init(state: "active", client_count: 1, healthy: true)], count: 2),
                                    vod: .init(total_connections: 1), catchup: .init(total_connections: 0)),
            playlists: [DispatcharrSource(id: 1, name: "Local tuner playlist", is_active: true, status: "success", updated_at: iso(-7_200)),
                        DispatcharrSource(id: 2, name: "Backup playlist", is_active: true, status: "error", last_message: "Playlist download timed out", updated_at: iso(-86_400))],
            guides: [DispatcharrSource(id: 1, name: "Local guide", is_active: true, status: "success", updated_at: iso(-10_800))],
            errorEvents: [DispatcharrEvent(id: 812, event_type: "m3u_error", event_type_display: "M3U Error", timestamp: iso(-5_400))],
            backups: DispatcharrBackups(files: [DispatcharrBackup(name: "dispatcharr-backup-2026.09.10.zip", size: 18_400_000, created: iso(-86_400 * 19))],
                                        schedule: DispatcharrBackupSchedule(enabled: false))
        ), operations: self)
    }

    func createBackup() async throws {}
}
