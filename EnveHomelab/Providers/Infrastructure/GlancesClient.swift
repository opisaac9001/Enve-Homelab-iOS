import Foundation

struct GlancesSystem: Decodable, Sendable {
    var hostname: String
    var hr_name: String?
    var os_name: String?
}

struct GlancesQuicklook: Decodable, Sendable {
    var cpu: Double?
    var mem: Double?
    var swap: Double?
    var load: Double?
    var cpu_name: String?
}

struct GlancesMemory: Decodable, Sendable {
    var total: Int64
    var used: Int64?
    var available: Int64?
    var percent: Double
}

struct GlancesLoad: Decodable, Sendable {
    var min1: Double
    var min5: Double
    var min15: Double
    var cpucore: Int?
}

struct GlancesFileSystem: Decodable, Sendable {
    var mnt_point: String
    var device_name: String?
    var fs_type: String?
    var size: Int64
    var used: Int64
    var percent: Double
}

/// Sensor values can be placeholders (e.g. "ERR" from hddtemp), so the number is optional.
struct GlancesSensor: Decodable, Sendable {
    var label: String
    var type: String?
    var unit: String?
    var value: Double?
    var warning: Double?
    var critical: Double?

    enum CodingKeys: String, CodingKey { case label, type, unit, value, warning, critical }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        value = try? container.decodeIfPresent(Double.self, forKey: .value)
        warning = try? container.decodeIfPresent(Double.self, forKey: .warning)
        critical = try? container.decodeIfPresent(Double.self, forKey: .critical)
    }
}

struct GlancesContainer: Decodable, Sendable {
    var name: String
    var status: String?
    var cpu_percent: Double?
    var memory_usage: Int64?
    var uptime: String?
    var engine: String?
}

struct GlancesEvent: Decodable, Sendable {
    var begin: Double
    var end: Double
    var state: String
    var type: String
    var max: Double?
    var global_msg: String?

    var isOngoing: Bool { end < 0 }
    var health: Health { state == "CRITICAL" ? .critical : .warning }
}

/// Glances' own threshold verdict for a value (`OK`, `CAREFUL`, `WARNING`, `CRITICAL`, optionally with `_LOG`).
enum GlancesDecoration {
    static func health(_ decoration: String?) -> Health? {
        guard let decoration else { return nil }
        switch decoration.replacingOccurrences(of: "_LOG", with: "") {
        case "CRITICAL": return .critical
        case "WARNING": return .warning
        case "OK", "CAREFUL", "DEFAULT", "MAX": return .ok
        default: return nil
        }
    }
}

struct GlancesOverview: Sendable {
    var version: String?
    var system: GlancesSystem
    var uptime: String?
    var quicklook: GlancesQuicklook
    var memory: GlancesMemory
    var load: GlancesLoad?
    var fileSystems: [GlancesFileSystem]
    var sensors: [GlancesSensor]?
    var containers: [GlancesContainer]?
    var events: [GlancesEvent]
    /// Decorations keyed by plugin, then by item key (or `""` for single-value plugins), then by field.
    var views: [String: [String: [String: String]]]

    func decoration(_ plugin: String, item: String = "", field: String) -> Health? {
        GlancesDecoration.health(views[plugin]?[item]?[field])
    }
}

protocol GlancesOperations: Sendable {
    func clearEvents(warningsOnly: Bool) async throws
}

/// Glances 4.x REST API (`/api/4`). Authentication is optional HTTP Basic; the default user is "glances".
struct GlancesClient: DashboardService, GlancesOperations {
    let kind = IntegrationKind.glances
    private let rest: RESTClient

    init(url: URL, username: String?, password: String?, pinnedFingerprint: String?) {
        var headers: [String: String] = [:]
        if let password = password?.nilIfEmpty {
            headers["Authorization"] = "Basic " + Data("\(username?.nilIfEmpty ?? "glances"):\(password)".utf8).base64EncodedString()
        }
        rest = RESTClient(baseURL: url.path().hasSuffix("/api/4") || url.path().hasSuffix("/api/4/") ? url : url.appending(path: "api/4"), pinnedFingerprint: pinnedFingerprint, headers: headers)
    }

    private func views(_ plugin: String, keyed: Bool) async throws -> [String: [String: String]] {
        let data = try await rest.data(.get("\(plugin)/views"))
        return Self.parseViews(data, keyed: keyed)
    }

    /// Views are nested dictionaries whose leaves carry `decoration`; non-dictionary entries (e.g. `show_pod_name`) are skipped.
    static func parseViews(_ data: Data, keyed: Bool) -> [String: [String: String]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        func fields(_ dictionary: [String: Any]) -> [String: String] {
            dictionary.compactMapValues { ($0 as? [String: Any])?["decoration"] as? String }
        }
        guard keyed else { return ["": fields(object)] }
        return object.compactMapValues { ($0 as? [String: Any]).map(fields) }
    }

    func overview() async throws -> GlancesOverview {
        let plugins: Set<String>
        do {
            plugins = Set(try await rest.json(.get("pluginslist"), as: [String].self))
        } catch NetworkError.apiNotFound {
            throw NetworkError.unsupportedByServer("Glances 4.0 or later is required (its REST API moved to /api/4). Start it in web server mode with glances -w.")
        }
        async let version = rest.json(.get("version"), as: String.self)
        async let system = rest.json(.get("system"), as: GlancesSystem.self)
        async let uptime = rest.json(.get("uptime"), as: String.self)
        async let quicklook = rest.json(.get("quicklook"), as: GlancesQuicklook.self)
        async let memory = rest.json(.get("mem"), as: GlancesMemory.self)
        async let events = rest.json(.get("alert"), as: [GlancesEvent].self)
        let load = plugins.contains("load") ? try await rest.json(.get("load"), as: GlancesLoad.self) : nil
        let fileSystems = plugins.contains("fs") ? try await rest.json(.get("fs"), as: [GlancesFileSystem].self) : []
        let sensors = plugins.contains("sensors") ? try await rest.json(.get("sensors"), as: [GlancesSensor].self) : nil
        let containers = plugins.contains("containers") ? try await rest.json(.get("containers"), as: [GlancesContainer].self) : nil

        // Views reflect the last update, so they're read after the stats above.
        var views: [String: [String: [String: String]]] = ["quicklook": try await self.views("quicklook", keyed: false)]
        if plugins.contains("fs") { views["fs"] = try await self.views("fs", keyed: true) }
        if plugins.contains("sensors") { views["sensors"] = try await self.views("sensors", keyed: true) }
        if plugins.contains("containers") { views["containers"] = try await self.views("containers", keyed: true) }

        return try await GlancesOverview(version: version, system: system, uptime: uptime, quicklook: quicklook, memory: memory, load: load,
                                         fileSystems: fileSystems, sensors: sensors, containers: containers, events: events, views: views)
    }

    func dashboard() async throws -> DashboardSnapshot {
        GlancesDashboard.snapshot(try await overview(), operations: self)
    }

    func clearEvents(warningsOnly: Bool) async throws {
        _ = try await rest.data(.post(warningsOnly ? "events/clear/warning" : "events/clear/all"))
    }
}

enum GlancesDashboard {
    static func snapshot(_ overview: GlancesOverview, operations: some GlancesOperations) -> DashboardSnapshot {
        let quick = overview.quicklook
        let cpuHealth = overview.decoration("quicklook", field: "cpu")
        let memHealth = overview.decoration("quicklook", field: "mem")
        let swapHealth = overview.decoration("quicklook", field: "swap")
        let loadHealth = overview.decoration("quicklook", field: "load")
        let fsHealth = overview.fileSystems.map { overview.decoration("fs", item: $0.mnt_point, field: "used") ?? .ok }
        let sensorHealth = (overview.sensors ?? []).map { overview.decoration("sensors", item: $0.label, field: "value") ?? .ok }
        let ongoing = overview.events.filter(\.isOngoing)
        let health = ([cpuHealth, memHealth, swapHealth, loadHealth].compactMap { $0 } + fsHealth + sensorHealth + ongoing.map(\.health)).max() ?? .ok

        var metrics = [
            DashboardMetric(title: "CPU", value: quick.cpu.map { Format.percent($0 / 100) } ?? "—", systemImage: "cpu", health: cpuHealth),
            DashboardMetric(title: "Memory", value: Format.percent(overview.memory.percent / 100), systemImage: "memorychip", health: memHealth),
        ]
        if let load = overview.load {
            metrics.append(DashboardMetric(title: "Load (1/5/15 min)", value: [load.min1, load.min5, load.min15].map { String(format: "%.2f", $0) }.joined(separator: " "), systemImage: "gauge.with.dots.needle.33percent", health: loadHealth))
        }
        if let swap = quick.swap {
            metrics.append(DashboardMetric(title: "Swap", value: Format.percent(swap / 100), systemImage: "arrow.left.arrow.right", health: swapHealth))
        }

        var sections = [
            DashboardSection(id: "fs", title: "File Systems", systemImage: "internaldrive", trailing: "\(overview.fileSystems.count)", emptyText: "Glances reports no mounted file systems.",
                             rows: overview.fileSystems.map { fs in
                                 let fsHealth = overview.decoration("fs", item: fs.mnt_point, field: "used")
                                 return DashboardRow(id: fs.mnt_point, title: fs.mnt_point, subtitle: [fs.device_name, fs.fs_type].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                     detail: "\(Format.bytes(fs.used)) of \(Format.bytes(fs.size)) · \(Format.percent(fs.percent / 100))",
                                                     health: fsHealth, progress: fs.percent / 100)
                             }),
        ]
        if let sensors = overview.sensors {
            sections.append(DashboardSection(id: "sensors", title: "Sensors", systemImage: "thermometer.medium", trailing: "\(sensors.count)", emptyText: "No sensors are exposed.",
                                             rows: sensors.enumerated().map { index, sensor in
                                                 let unit = sensor.unit.map { $0 == "C" || $0 == "F" ? "°\($0)" : " \($0)" } ?? ""
                                                 return DashboardRow(id: "\(index):\(sensor.label)", title: sensor.label,
                                                                     subtitle: sensor.type?.replacingOccurrences(of: "_", with: " ").capitalizedFirst,
                                                                     health: overview.decoration("sensors", item: sensor.label, field: "value"),
                                                                     badge: sensor.value.map { String(format: $0.rounded() == $0 ? "%.0f" : "%.1f", $0) + unit } ?? "No reading")
                                             }))
        }
        if let containers = overview.containers {
            sections.append(DashboardSection(id: "containers", title: "Containers", systemImage: "shippingbox", trailing: "\(containers.count)", emptyText: "No containers are running.",
                                             rows: containers.map { container in
                                                 let status = container.status ?? "unknown"
                                                 let bad = ["unhealthy", "dead", "restarting", "exited"].contains(status)
                                                 let viewHealth = [overview.decoration("containers", item: container.name, field: "cpu"), overview.decoration("containers", item: container.name, field: "mem")].compactMap { $0 }.max()
                                                 return DashboardRow(id: container.name, title: container.name, subtitle: container.engine,
                                                                     detail: [container.cpu_percent.map { "CPU " + Format.percent($0 / 100) }, container.memory_usage.map { "Mem " + Format.bytes($0) }, container.uptime.map { "Up \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                                     health: bad ? .warning : viewHealth, badge: status.capitalizedFirst)
                                             }))
        }
        sections.append(DashboardSection(id: "events", title: "Alerts", systemImage: "bell", trailing: ongoing.isEmpty ? nil : "\(ongoing.count) ongoing", emptyText: "Glances hasn't raised any alerts.",
                                         rows: overview.events.enumerated().map { index, event in
                                             let started = Date(timeIntervalSince1970: event.begin)
                                             return DashboardRow(id: "\(index):\(event.type):\(event.begin)", title: event.global_msg?.nilIfEmpty ?? event.type.replacingOccurrences(of: "_", with: " "),
                                                                 subtitle: event.isOngoing ? "Since \(Format.relative(started))" : "Started \(Format.relative(started)) · lasted \(Format.duration(max(event.end - event.begin, 0)))",
                                                                 detail: event.max.map { "Peak \(String(format: "%.1f", $0))" }, health: event.health, badge: event.isOngoing ? "Ongoing" : event.state.capitalized)
                                         }))

        var actions: [DashboardAction] = []
        if overview.events.contains(where: { !$0.isOngoing && $0.state == "WARNING" }) {
            actions.append(DashboardAction(id: "clear-warnings", title: "Clear Finished Warnings", systemImage: "checkmark.circle", targetKind: "Alerts", targetName: overview.system.hostname,
                                           consequence: "Glances removes warnings that have already ended from its alert list.", confirmation: .none) {
                try await operations.clearEvents(warningsOnly: true)
            })
        }
        if !overview.events.isEmpty {
            actions.append(DashboardAction(id: "clear-all", title: "Clear All Alerts", systemImage: "trash", targetKind: "Alerts", targetName: overview.system.hostname,
                                           consequence: "Glances forgets every alert in its list, including critical and ongoing ones. Ongoing problems are raised again on the next check.") {
                try await operations.clearEvents(warningsOnly: false)
            })
        }

        return DashboardSnapshot(
            version: overview.version,
            health: health,
            headline: "CPU \(quick.cpu.map { Format.percent($0 / 100) } ?? "—") · Mem \(Format.percent(overview.memory.percent / 100))" + (ongoing.isEmpty ? "" : " · \(ongoing.count) alert\(ongoing.count == 1 ? "" : "s")"),
            detail: [overview.system.hostname, overview.system.hr_name, overview.uptime.map { "up \($0)" }].compactMap { $0 }.joined(separator: " · "),
            metrics: metrics,
            actions: actions,
            sections: sections
        )
    }
}
