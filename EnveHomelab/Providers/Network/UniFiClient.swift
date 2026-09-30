import Foundation

struct UniFiSite: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var internalReference: String?

    var displayName: String { name?.nilIfEmpty ?? internalReference ?? id }
}

struct UniFiDevice: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var model: String?
    var macAddress: String?
    var ipAddress: String?
    var state: String
    var firmwareVersion: String?
    var firmwareUpdatable: Bool?
    var features: [String]?

    var displayName: String { name?.nilIfEmpty ?? model ?? macAddress ?? id }
    var isOnline: Bool { state == "ONLINE" }

    var health: Health {
        switch state {
        case "ONLINE": .ok
        case "OFFLINE", "CONNECTION_INTERRUPTED", "ISOLATED": .critical
        case "UPDATING", "GETTING_READY", "ADOPTING", "PENDING_ADOPTION": .warning
        default: .unknown
        }
    }

    var role: String {
        let roles = features ?? []
        if roles.contains("gateway") { return "Gateway" }
        if roles.contains("switching") { return "Switch" }
        if roles.contains("accessPoint") { return "Access point" }
        return "Device"
    }
}

struct UniFiClientDevice: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var type: String
    var ipAddress: String?
    var macAddress: String?
    var connectedAt: String?
    var uplinkDeviceId: String?

    var displayName: String { name?.nilIfEmpty ?? ipAddress ?? macAddress ?? "Client" }

    var connectionName: String {
        switch type {
        case "WIRED": "Wired"
        case "WIRELESS": "Wi-Fi"
        case "VPN": "VPN"
        case "TELEPORT": "Teleport"
        default: type.capitalized
        }
    }
}

/// `GET /sites/{siteId}/devices/{deviceId}`: physical ports (with PoE) and radios.
struct UniFiDeviceDetails: Decodable, Sendable, Equatable {
    struct Port: Decodable, Sendable, Equatable, Identifiable {
        struct PoE: Decodable, Sendable, Equatable {
            var enabled: Bool?
            var standard: String?
            var state: String?
        }
        var idx: Int
        var state: String?
        var connector: String?
        var speedMbps: Int?
        var maxSpeedMbps: Int?
        var poe: PoE?
        var id: Int { idx }

        /// Power-cycling only makes sense for a port that is supplying PoE.
        var canPowerCycle: Bool { poe?.enabled == true }
        var isUp: Bool { state == "UP" }
    }
    struct Radio: Decodable, Sendable, Equatable {
        var frequencyGHz: Double?
        var channel: Int?
        var channelWidthMHz: Int?
        var wlanStandard: String?
    }
    struct Interfaces: Decodable, Sendable, Equatable {
        var ports: [Port]?
        var radios: [Radio]?
    }
    struct Uplink: Decodable, Sendable, Equatable { var deviceId: String? }

    var interfaces: Interfaces?
    var uplink: Uplink?
    var adoptedAt: String?
}

/// `GET /sites/{siteId}/devices/{deviceId}/statistics/latest`.
struct UniFiDeviceStatistics: Decodable, Sendable, Equatable {
    struct Radio: Decodable, Sendable, Equatable { var frequencyGHz: Double?; var txRetriesPct: Double? }
    struct Interfaces: Decodable, Sendable, Equatable { var radios: [Radio]? }
    struct Uplink: Decodable, Sendable, Equatable { var rxRateBps: Int64?; var txRateBps: Int64? }

    var uptimeSec: Int64?
    var cpuUtilizationPct: Double?
    var memoryUtilizationPct: Double?
    var loadAverage1Min: Double?
    var loadAverage5Min: Double?
    var loadAverage15Min: Double?
    var lastHeartbeatAt: String?
    var interfaces: Interfaces?
    var uplink: Uplink?
}

struct UniFiSnapshot: Sendable {
    var version: String?
    var site: UniFiSite?
    var sites: [UniFiSite]
    var devices: [UniFiDevice]
    var clients: [UniFiClientDevice]
}

protocol UniFiService: IntegrationService {
    func snapshot(siteID: String?) async throws -> UniFiSnapshot
    func restart(_ device: UniFiDevice, siteID: String) async throws
    func details(of device: UniFiDevice, siteID: String) async throws -> UniFiDeviceDetails
    func statistics(of device: UniFiDevice, siteID: String) async throws -> UniFiDeviceStatistics
    /// Cuts and restores PoE power on one port of a switch or gateway.
    func powerCycle(port: Int, on device: UniFiDevice, siteID: String) async throws
}

extension UniFiService {
    func summary() async throws -> IntegrationSummary {
        let snapshot = try await snapshot(siteID: nil)
        let offline = snapshot.devices.filter { !$0.isOnline }.count
        return IntegrationSummary(
            product: "UniFi Network",
            version: snapshot.version,
            health: offline > 0 ? .warning : .ok,
            headline: "\(snapshot.devices.count) devices · \(snapshot.clients.count) clients",
            detail: offline > 0 ? "\(offline) device\(offline == 1 ? "" : "s") not online" : snapshot.site?.displayName
        )
    }
}

/// The official UniFi Network Integration API on the local console (`/proxy/network/integration/v1`).
struct UniFiClient: UniFiService {
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "proxy/network/integration/v1"), pinnedFingerprint: pinnedFingerprint, headers: ["X-API-KEY": apiKey])
    }

    struct Page<Item: Decodable>: Decodable {
        var offset: Int
        var limit: Int
        var count: Int
        var totalCount: Int
        var data: [Item]
    }

    private func all<Item: Decodable>(_ path: String, as type: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        while true {
            let page = try await rest.json(.get(path, query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "200")]), as: Page<Item>.self)
            items += page.data
            offset += page.count
            if page.count == 0 || offset >= page.totalCount || items.count >= 2_000 { return items }
        }
    }

    func snapshot(siteID: String?) async throws -> UniFiSnapshot {
        struct Info: Decodable { var applicationVersion: String? }
        async let info = rest.json(.get("info"), as: Info.self)
        let sites = try await all("sites", as: UniFiSite.self)
        guard let site = sites.first(where: { $0.id == siteID }) ?? sites.first else {
            return UniFiSnapshot(version: try await info.applicationVersion, sites: [], devices: [], clients: [])
        }
        async let devices = all("sites/\(site.id)/devices", as: UniFiDevice.self)
        async let clients = all("sites/\(site.id)/clients", as: UniFiClientDevice.self)
        return UniFiSnapshot(
            version: try await info.applicationVersion,
            site: site,
            sites: sites,
            devices: try await devices.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            clients: try await clients.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        )
    }

    func restart(_ device: UniFiDevice, siteID: String) async throws {
        _ = try await rest.data(try .post("sites/\(siteID)/devices/\(device.id)/actions", json: ["action": "RESTART"]))
    }

    func details(of device: UniFiDevice, siteID: String) async throws -> UniFiDeviceDetails {
        try await rest.json(.get("sites/\(siteID)/devices/\(device.id)"), as: UniFiDeviceDetails.self)
    }

    func statistics(of device: UniFiDevice, siteID: String) async throws -> UniFiDeviceStatistics {
        try await rest.json(.get("sites/\(siteID)/devices/\(device.id)/statistics/latest"), as: UniFiDeviceStatistics.self)
    }

    func powerCycle(port: Int, on device: UniFiDevice, siteID: String) async throws {
        _ = try await rest.data(try .post("sites/\(siteID)/devices/\(device.id)/interfaces/ports/\(port)/actions", json: ["action": "POWER_CYCLE"]))
    }
}
