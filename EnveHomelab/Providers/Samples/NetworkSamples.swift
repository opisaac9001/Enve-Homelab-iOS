import Foundation

actor SampleDNSFilter: DNSFilterService {
    nonisolated let kind: IntegrationKind
    private var enabled = true
    private var pausedUntil: Date?
    private var allowed: Set<String> = []

    init(kind: IntegrationKind) {
        self.kind = kind
    }

    func overview() async throws -> DNSFilterOverview {
        try await Task.sleep(for: .milliseconds(150))
        if let pausedUntil, pausedUntil <= .now {
            enabled = true
            self.pausedUntil = nil
        }
        return DNSFilterOverview(
            version: kind == .pihole ? "v6.1.4" : (kind == .technitium ? "15.5.1" : "v0.107.66"),
            blockingEnabled: enabled,
            pauseRemaining: pausedUntil.map { $0.timeIntervalSinceNow },
            totalQueries: 48_210,
            blockedQueries: 9_874,
            cachedQueries: kind == .adguard ? nil : 21_004,
            activeClients: kind == .adguard ? nil : 23,
            blocklistDomains: kind == .adguard ? nil : 1_214_551,
            averageResponseMilliseconds: kind == .adguard ? 14.2 : nil
        )
    }

    func setBlocking(_ enabled: Bool, for duration: TimeInterval?) async throws {
        self.enabled = enabled
        pausedUntil = enabled ? nil : duration.map { Date.now.addingTimeInterval($0) }
    }
}

extension SampleDNSFilter: DNSDiagnosticsService {
    nonisolated var diagnostics: DNSDiagnosticsCapabilities {
        switch kind {
        case .pihole: DNSDiagnosticsCapabilities(queryLog: true, domainCheck: true, messages: true, allowDomain: true, maintenance: [.updateGravity, .restartDNS])
        case .adguard: DNSDiagnosticsCapabilities(queryLog: true, domainCheck: true, messages: false, allowDomain: false, maintenance: [.refreshFilters])
        default: DNSDiagnosticsCapabilities(queryLog: false, domainCheck: false, messages: false, allowDomain: false, maintenance: [])
        }
    }

    func recentQueries(limit: Int) async throws -> [DNSQueryLogEntry] {
        let rows: [(String, String, DNSQueryLogEntry.Outcome)] = [
            ("ads.example-tracker.net", "Living Room TV", .blocked), ("api.weather.example", "Kitchen Display", .allowed),
            ("time.apple.com", "Sam's iPhone", .cached), ("telemetry.example-vendor.com", "Office Laptop", .blocked),
            ("updates.example-os.org", "Media Server", .allowed), ("nas.home.arpa", "Office Laptop", .rewritten),
        ]
        return rows.prefix(limit).enumerated().map { index, row in
            DNSQueryLogEntry(id: "sample-\(index)", date: .now.addingTimeInterval(Double(-index * 40)), domain: row.0, client: row.1, type: "A",
                             outcome: row.2, detail: row.2 == .blocked ? (kind == .pihole ? "gravity" : "FilteredBlackList") : nil)
        }
    }

    func check(domain: String) async throws -> DNSDomainCheck {
        if domain.contains("tracker") || domain.hasPrefix("ads.") {
            return DNSDomainCheck(domain: domain, verdict: .blocked, reasons: [kind == .pihole ? "Blocklist: https://lists.example.org/hosts.txt" : "Rule ||\(domain)^ (list 1)"])
        }
        if allowed.contains(domain) { return DNSDomainCheck(domain: domain, verdict: .allowed, reasons: ["Allowlist (exact): \(domain)"]) }
        return DNSDomainCheck(domain: domain, verdict: .notListed, reasons: [])
    }

    func messages() async throws -> [DNSDiagnosticMessage] {
        kind == .pihole ? [DNSDiagnosticMessage(id: "1", date: .now.addingTimeInterval(-3_600), text: "Rate-limiting 192.168.1.42 for at least 5 seconds")] : []
    }

    func perform(_ maintenance: DNSMaintenance) async throws -> String? {
        try await Task.sleep(for: .milliseconds(300))
        switch maintenance {
        case .updateGravity: return "[✓] Done."
        case .refreshFilters: return "2 lists updated."
        case .restartDNS: return nil
        }
    }

    func allow(domain: String) async throws {
        allowed.insert(domain)
    }
}

actor SampleUniFi: UniFiService {
    private let site = UniFiSite(id: "site-default", name: "Home", internalReference: "default")
    private var devices = [
        UniFiDevice(id: "d1", name: "Gateway", model: "UCG-Ultra", macAddress: "aa:bb:cc:00:00:01", ipAddress: "192.168.1.1", state: "ONLINE", firmwareVersion: "4.3.9", firmwareUpdatable: false, features: ["gateway"]),
        UniFiDevice(id: "d2", name: "Office Switch", model: "USW-Lite-8-PoE", macAddress: "aa:bb:cc:00:00:02", ipAddress: "192.168.1.2", state: "ONLINE", firmwareVersion: "7.1.26", firmwareUpdatable: true, features: ["switching"]),
        UniFiDevice(id: "d3", name: "Hallway AP", model: "U7-Pro", macAddress: "aa:bb:cc:00:00:03", ipAddress: "192.168.1.3", state: "ONLINE", firmwareVersion: "8.0.23", firmwareUpdatable: false, features: ["accessPoint"]),
        UniFiDevice(id: "d4", name: "Garage AP", model: "U6-Lite", macAddress: "aa:bb:cc:00:00:04", ipAddress: "192.168.1.4", state: "OFFLINE", firmwareVersion: "6.6.77", features: ["accessPoint"]),
    ]

    func snapshot(siteID: String?) async throws -> UniFiSnapshot {
        try await Task.sleep(for: .milliseconds(150))
        return UniFiSnapshot(
            version: "10.6.106",
            site: site,
            sites: [site],
            devices: devices,
            clients: [
                UniFiClientDevice(id: "c1", name: "Living room TV", type: "WIRED", ipAddress: "192.168.1.40", macAddress: "aa:00:00:00:00:40", uplinkDeviceId: "d2"),
                UniFiClientDevice(id: "c2", name: "Alex's phone", type: "WIRELESS", ipAddress: "192.168.1.51", uplinkDeviceId: "d3"),
                UniFiClientDevice(id: "c3", name: "Laptop", type: "WIRELESS", ipAddress: "192.168.1.52", uplinkDeviceId: "d3"),
                UniFiClientDevice(id: "c4", name: "Travel router", type: "VPN", ipAddress: "192.168.2.10"),
            ]
        )
    }

    func restart(_ device: UniFiDevice, siteID: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    func details(of device: UniFiDevice, siteID: String) async throws -> UniFiDeviceDetails {
        try await Task.sleep(for: .milliseconds(150))
        switch device.role {
        case "Switch":
            let ports = (1...8).map { index in
                UniFiDeviceDetails.Port(idx: index, state: index <= 5 ? "UP" : "DOWN", connector: "RJ45", speedMbps: index <= 5 ? 1_000 : nil, maxSpeedMbps: 1_000,
                                        poe: index <= 4 ? .init(enabled: true, standard: "802.3at", state: index == 3 ? "DOWN" : "UP") : nil)
            }
            return UniFiDeviceDetails(interfaces: .init(ports: ports, radios: nil), uplink: .init(deviceId: "d1"))
        case "Access point":
            return UniFiDeviceDetails(interfaces: .init(ports: [.init(idx: 1, state: "UP", connector: "RJ45", speedMbps: 2_500, maxSpeedMbps: 2_500)],
                                                        radios: [.init(frequencyGHz: 2.4, channel: 6, channelWidthMHz: 20, wlanStandard: "802.11be"),
                                                                 .init(frequencyGHz: 5, channel: 36, channelWidthMHz: 80, wlanStandard: "802.11be")]),
                                      uplink: .init(deviceId: "d2"))
        default:
            return UniFiDeviceDetails(interfaces: .init(ports: (1...4).map { .init(idx: $0, state: $0 == 1 ? "UP" : "DOWN", connector: "RJ45", speedMbps: $0 == 1 ? 1_000 : nil, maxSpeedMbps: 2_500) }, radios: nil))
        }
    }

    func statistics(of device: UniFiDevice, siteID: String) async throws -> UniFiDeviceStatistics {
        try await Task.sleep(for: .milliseconds(150))
        return UniFiDeviceStatistics(uptimeSec: 864_000, cpuUtilizationPct: 12.5, memoryUtilizationPct: 41, loadAverage1Min: 0.4, loadAverage5Min: 0.35, loadAverage15Min: 0.3,
                                     lastHeartbeatAt: Date.now.formatted(.iso8601),
                                     interfaces: .init(radios: device.role == "Access point" ? [.init(frequencyGHz: 2.4, txRetriesPct: 9.5), .init(frequencyGHz: 5, txRetriesPct: 3.1)] : nil),
                                     uplink: .init(rxRateBps: 18_400_000, txRateBps: 2_100_000))
    }

    func powerCycle(port: Int, on device: UniFiDevice, siteID: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
    }
}

struct SampleTailscale: TailscaleService {
    func devices() async throws -> [TailscaleDevice] {
        try await Task.sleep(for: .milliseconds(150))
        let soon = Date.now.addingTimeInterval(5 * 86_400).formatted(.iso8601)
        let later = Date.now.addingTimeInterval(120 * 86_400).formatted(.iso8601)
        return [
            TailscaleDevice(id: "1", name: "atlas.tail1234.ts.net", hostname: "atlas", os: "linux", addresses: ["100.64.0.1"], clientVersion: "1.88.1", updateAvailable: false, connectedToControl: true, lastSeen: Date.now.formatted(.iso8601), expires: later, authorized: true),
            TailscaleDevice(id: "2", name: "laptop.tail1234.ts.net", hostname: "laptop", os: "macOS", addresses: ["100.64.0.2"], clientVersion: "1.86.0", updateAvailable: true, connectedToControl: true, lastSeen: Date.now.formatted(.iso8601), expires: soon, authorized: true),
            TailscaleDevice(id: "3", name: "garage-pi.tail1234.ts.net", hostname: "garage-pi", os: "linux", addresses: ["100.64.0.3"], clientVersion: "1.84.0", connectedToControl: false, lastSeen: Date.now.addingTimeInterval(-86_400 * 3).formatted(.iso8601), keyExpiryDisabled: true, authorized: true),
        ]
    }
}

struct SampleCloudflare: CloudflareService {
    func snapshot() async throws -> CloudflareSnapshot {
        try await Task.sleep(for: .milliseconds(150))
        return CloudflareSnapshot(
            tokenStatus: "active",
            tunnels: [
                CloudflareTunnel(id: "t1", name: "home-lab", status: "healthy", connections: [.init(colo_name: "sea01"), .init(colo_name: "sjc05"), .init(colo_name: "sea02"), .init(colo_name: "lax01")]),
                CloudflareTunnel(id: "t2", name: "cabin", status: "degraded", connections: [.init(colo_name: "den01")]),
            ],
            zones: [CloudflareZone(id: "z1", name: "example.org", status: "active", paused: false)]
        )
    }
}

actor SampleHomeAssistant: HomeAssistantService {
    func checkConfiguration() async throws -> HomeAssistantConfigCheck {
        try await Task.sleep(for: .milliseconds(400))
        return HomeAssistantConfigCheck(result: "invalid", errors: "Integration error: sample_sensor - Integration 'sample_sensor' not found.")
    }

    func errorLog() async throws -> String {
        """
        2026-09-29 08:02:11.410 WARNING (MainThread) [homeassistant.components.sensor] Updating sample_weather sensor took longer than the scheduled update interval
        2026-09-29 09:15:40.022 ERROR (MainThread) [homeassistant.components.mqtt] Error connecting to MQTT broker: [Errno 111] Connection refused
        2026-09-29 09:16:02.871 INFO (MainThread) [homeassistant.components.mqtt] Reconnected to MQTT broker
        """
    }

    private var entities: [HomeAssistantEntity] = [
        .init(entity_id: "light.living_room", state: "on", attributes: ["friendly_name": .string("Living room lamp")]),
        .init(entity_id: "light.kitchen", state: "off", attributes: ["friendly_name": .string("Kitchen lights")]),
        .init(entity_id: "switch.office_heater", state: "off", attributes: ["friendly_name": .string("Office heater")]),
        .init(entity_id: "cover.garage_door", state: "closed", attributes: ["friendly_name": .string("Garage door")]),
        .init(entity_id: "scene.movie_night", state: "unknown", attributes: ["friendly_name": .string("Movie night")]),
        .init(entity_id: "lock.front_door", state: "locked", attributes: ["friendly_name": .string("Front door")]),
        .init(entity_id: "sensor.living_room_temperature", state: "21.4", attributes: ["friendly_name": .string("Living room temperature"), "unit_of_measurement": .string("°C")]),
        .init(entity_id: "script.good_night", state: "off", attributes: ["friendly_name": .string("Good night")]),
    ]

    func snapshot() async throws -> HomeAssistantSnapshot {
        try await Task.sleep(for: .milliseconds(150))
        return HomeAssistantSnapshot(
            version: "2026.9.2",
            locationName: "Sample Home",
            areas: [
                HomeAssistantArea(id: "living_room", name: "Living Room", entities: ["light.living_room", "sensor.living_room_temperature", "scene.movie_night"]),
                HomeAssistantArea(id: "kitchen", name: "Kitchen", entities: ["light.kitchen"]),
                HomeAssistantArea(id: "garage", name: "Garage", entities: ["cover.garage_door"]),
                HomeAssistantArea(id: "entrance", name: "Entrance", entities: ["lock.front_door"]),
            ],
            entities: entities
        )
    }

    func call(_ domain: String, _ service: String, entityID: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
        guard let index = entities.firstIndex(where: { $0.entity_id == entityID }) else { return }
        switch service {
        case "turn_on": if domain != "scene" && domain != "script" { entities[index].state = "on" }
        case "turn_off": entities[index].state = "off"
        case "open_cover": entities[index].state = "open"
        case "close_cover": entities[index].state = "closed"
        default: break
        }
    }
}
