import SwiftUI

struct DNSFilterView: View {
    let instance: IntegrationInstance
    let service: any DNSFilterService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<DNSFilterOverview>()
    @State private var pending: PendingAction?
    @State private var pauseDuration = DNSPauseDuration.fiveMinutes

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading \(instance.kind.displayName)…", interval: .seconds(10), load: load) { overview in
            VStack(spacing: 14) {
                IntegrationHeader(
                    title: instance.name,
                    version: overview.version,
                    health: overview.blockingEnabled ? .ok : .warning,
                    lines: [overview.blockingEnabled ? "Blocking is on" : "Blocking is paused" + (overview.pauseRemaining.map { " · resumes in \(Format.duration($0))" } ?? "")]
                )
                EnveCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Queries", systemImage: "chart.bar")
                        HStack {
                            Spacer()
                            RingGauge(fraction: overview.blockedFraction, title: "Blocked", valueText: Format.percent(overview.blockedFraction))
                            Spacer()
                        }
                        LabeledValue(label: "Total queries", value: overview.totalQueries.formatted())
                        LabeledValue(label: "Blocked", value: overview.blockedQueries.formatted())
                        if let cached = overview.cachedQueries { LabeledValue(label: "Answered from cache", value: cached.formatted()) }
                        if let clients = overview.activeClients { LabeledValue(label: "Active clients", value: clients.formatted()) }
                        if let domains = overview.blocklistDomains { LabeledValue(label: "Domains on blocklists", value: domains.formatted()) }
                        if let average = overview.averageResponseMilliseconds { LabeledValue(label: "Average processing", value: String(format: "%.1f ms", average)) }
                    }
                }
                if let diagnostics = service as? any DNSDiagnosticsService,
                   diagnostics.diagnostics.domainCheck || diagnostics.diagnostics.queryLog || !diagnostics.diagnostics.maintenance.isEmpty {
                    NavigationLink {
                        DNSDiagnosticsView(instance: instance, service: diagnostics)
                    } label: {
                        EnveCard {
                            HStack {
                                SectionTitle(title: "Diagnostics", systemImage: "stethoscope")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                EnveCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Protection", systemImage: "shield")
                        if overview.blockingEnabled {
                            Picker("Pause for", selection: $pauseDuration) {
                                ForEach(DNSPauseDuration.allCases) { Text($0.title).tag($0) }
                            }
                            Button(role: .destructive) {
                                pending = .integration(instance, title: "Pause Blocking", systemImage: "pause.circle", targetKind: "DNS filtering",
                                                       targetName: instance.name,
                                                       consequence: "Every device using \(instance.name) for DNS stops being protected \(pauseDuration == .untilResumed ? "until you turn blocking back on" : "for \(pauseDuration.title)"). Ads and trackers will load.",
                                                       destructive: true) { [service, pauseDuration] in
                                    try await service.setBlocking(false, for: pauseDuration.seconds)
                                }
                            } label: {
                                Label("Pause Blocking…", systemImage: "pause.circle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                Task {
                                    // Reloading straight after a failure would replace the error with the unchanged state.
                                    do {
                                        try await service.setBlocking(true, for: nil)
                                        await load()
                                    } catch {
                                        state.finish(.failure(.from(error)))
                                    }
                                }
                            } label: {
                                Label("Turn Blocking On", systemImage: "play.circle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!allowsActions)
                        }
                    }
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.overview() })
    }
}

struct UniFiView: View {
    let instance: IntegrationInstance
    let service: any UniFiService
    @State private var state = LoadState<UniFiSnapshot>()
    @State private var siteID: String?
    @State private var pending: PendingAction?
    @State private var clientSearch = ""

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading UniFi…", load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(title: snapshot.site?.displayName ?? instance.name, version: snapshot.version,
                                  health: snapshot.devices.contains { !$0.isOnline } ? .warning : .ok, lines: [])
                if snapshot.sites.count > 1 {
                    Picker("Site", selection: Binding(get: { siteID ?? snapshot.site?.id }, set: { siteID = $0; Task { await load() } })) {
                        ForEach(snapshot.sites) { Text($0.displayName).tag(String?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                }
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Devices", systemImage: "wifi.router", trailing: "\(snapshot.devices.filter(\.isOnline).count)/\(snapshot.devices.count) online")
                        if snapshot.devices.isEmpty { Text("No adopted devices on this site.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(snapshot.devices) { device in
                            HStack {
                                NavigationLink {
                                    if let site = snapshot.site {
                                        UniFiDeviceView(instance: instance, service: service, device: device, siteID: site.id)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.displayName).font(.subheadline.weight(.semibold))
                                        Text([device.role, device.model, device.ipAddress, device.firmwareVersion.map { "fw \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if device.firmwareUpdatable == true {
                                            Text("Firmware update available").font(.caption2).foregroundStyle(Color.enveAccent)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows ports and statistics")
                                StatusBadge(text: device.state.replacingOccurrences(of: "_", with: " ").capitalized, health: device.health)
                                if device.isOnline, let site = snapshot.site {
                                    Menu {
                                        Button(role: .destructive) {
                                            pending = .integration(instance, title: "Restart Device", systemImage: "arrow.clockwise", targetKind: device.role,
                                                                   targetName: device.displayName,
                                                                   consequence: "The device reboots. Everything connected through it loses connectivity for a few minutes\(device.role == "Gateway" ? ", including your internet connection and possibly this app's connection to UniFi" : "").",
                                                                   destructive: true, typed: device.role == "Gateway") { [service] in
                                                try await service.restart(device, siteID: site.id)
                                            }
                                        } label: {
                                            Label("Restart…", systemImage: "arrow.clockwise")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .accessibilityLabel("Actions for \(device.displayName)")
                                }
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Clients", systemImage: "laptopcomputer.and.iphone", trailing: "\(snapshot.clients.count)")
                        TextField("Filter clients", text: $clientSearch)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                        let clients = snapshot.clients.filter { clientSearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(clientSearch) || ($0.ipAddress ?? "").contains(clientSearch) }
                        if clients.isEmpty { Text(snapshot.clients.isEmpty ? "No clients connected." : "No clients match “\(clientSearch)”.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(clients.prefix(200)) { client in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(client.displayName).font(.subheadline)
                                    Text([client.connectionName, client.ipAddress, client.uplinkDeviceId.flatMap { id in snapshot.devices.first { $0.id == id }?.displayName }.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func load() async {
        state.begin()
        let siteID = siteID
        state.finish(await captureResult { try await service.snapshot(siteID: siteID) })
    }
}

struct TailscaleView: View {
    let instance: IntegrationInstance
    let service: any TailscaleService
    @State private var state = LoadState<[TailscaleDevice]>()

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading tailnet…", interval: .seconds(30), load: load) { devices in
            VStack(spacing: 14) {
                IntegrationHeader(title: instance.name, version: nil, health: devices.contains { $0.keyExpiresSoon() } ? .warning : .ok,
                                  lines: ["\(devices.filter { $0.connectedToControl == true }.count) of \(devices.count) connected"])
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Devices", systemImage: "point.3.connected.trianglepath.dotted")
                        if devices.isEmpty { Text("No devices in this tailnet.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(devices) { device in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(device.displayName).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    StatusBadge(text: device.connectedToControl == true ? "Connected" : "Offline", health: device.health)
                                }
                                Text([device.os, device.addresses?.first, device.clientVersion.map { "v\($0)" }, device.user].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let expiry = device.expiryDate {
                                    Text("Key expires \(Format.relative(expiry))").font(.caption2).foregroundStyle(device.keyExpiresSoon() ? Color.orange : Color.secondary)
                                }
                                if device.updateAvailable == true {
                                    Text("Client update available").font(.caption2).foregroundStyle(Color.enveAccent)
                                }
                                if device.connectedToControl != true, let seen = APIDate.parse(device.lastSeen) {
                                    Text("Last seen \(Format.relative(seen))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Divider()
                        }
                    }
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.devices() })
    }
}

struct CloudflareView: View {
    let instance: IntegrationInstance
    let service: any CloudflareService
    @State private var state = LoadState<CloudflareSnapshot>()

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading Cloudflare…", interval: .seconds(30), load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(title: instance.name, version: nil, health: snapshot.tunnels.map(\.health).filter { $0 != .unknown }.max() ?? .ok,
                                  lines: ["API token \(snapshot.tokenStatus)"])
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Tunnels", systemImage: "point.topleft.down.to.point.bottomright.curvepath", trailing: "\(snapshot.tunnels.count)")
                        if snapshot.tunnels.isEmpty { Text("No tunnels in this account.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(snapshot.tunnels) { tunnel in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tunnel.name).font(.subheadline.weight(.semibold))
                                    let colos = (tunnel.connections ?? []).compactMap(\.colo_name)
                                    Text(colos.isEmpty ? "No edge connections" : "\(colos.count) connection\(colos.count == 1 ? "" : "s") · \(Set(colos).sorted().joined(separator: ", "))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusBadge(text: (tunnel.status ?? "unknown").capitalized, health: tunnel.health)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Zones", systemImage: "globe")
                        if let zones = snapshot.zones {
                            ForEach(zones) { zone in
                                HStack {
                                    Text(zone.name).font(.subheadline)
                                    Spacer()
                                    StatusBadge(text: zone.paused == true ? "Paused" : (zone.status ?? "").capitalized, health: zone.status == "active" && zone.paused != true ? .ok : .warning)
                                }
                            }
                        } else {
                            Text("This token can't read zones. Add Zone › Zone › Read to list them.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.snapshot() })
    }
}

struct HomeAssistantView: View {
    let instance: IntegrationInstance
    let service: any HomeAssistantService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<HomeAssistantSnapshot>()
    @State private var pending: PendingAction?
    @State private var search = ""
    @State private var controllableOnly = true
    @State private var inFlight: Set<String> = []

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading Home Assistant…", interval: .seconds(10), load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(title: snapshot.locationName ?? instance.name, version: snapshot.version, health: .ok, lines: [])
                HomeAssistantDiagnosticsCard(service: service)
                VStack(spacing: 8) {
                    TextField("Search entities", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    Toggle("Controllable only", isOn: $controllableOnly).font(.subheadline)
                }
                let entityGroups = groups(snapshot)
                if entityGroups.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Entities" : "No Matches", systemImage: "house",
                                           description: Text(search.isEmpty ? (controllableOnly ? "No controllable entities are exposed." : "Home Assistant reported no entities.") : "No entities match “\(search)”."))
                }
                ForEach(entityGroups, id: \.title) { group in
                    EnveCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: group.title, systemImage: "square.split.bottomrightquarter", trailing: "\(group.entities.count)")
                            ForEach(group.entities) { entity in
                                entityRow(entity)
                            }
                        }
                    }
                }
                Text("Locks, alarm panels and climate devices are shown read-only.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func groups(_ snapshot: HomeAssistantSnapshot) -> [(title: String, entities: [HomeAssistantEntity])] {
        let visible = snapshot.entities.filter {
            (!controllableOnly || $0.control != nil) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.entity_id.localizedCaseInsensitiveContains(search))
        }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.entity_id, $0) })
        var assigned = Set<String>()
        var result: [(String, [HomeAssistantEntity])] = []
        for area in snapshot.areas {
            let entities = area.entities.compactMap { byID[$0] }
            assigned.formUnion(entities.map(\.entity_id))
            if !entities.isEmpty { result.append((area.name, entities)) }
        }
        let rest = visible.filter { !assigned.contains($0.entity_id) }
        if !rest.isEmpty { result.append(("No area", rest)) }
        return result
    }

    @ViewBuilder
    private func entityRow(_ entity: HomeAssistantEntity) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(.subheadline)
                Text(entity.displayState).font(.caption).foregroundStyle(entity.isUnavailable ? Color.orange : Color.secondary)
            }
            Spacer()
            if inFlight.contains(entity.entity_id) {
                ProgressView()
            } else if let control = entity.control, allowsActions {
                switch control {
                case .toggle(let isOn):
                    Toggle(entity.name, isOn: Binding(get: { isOn }, set: { value in run(control, entity, turnOn: value) }))
                        .labelsHidden()
                case .activate:
                    Button("Activate") { run(control, entity) }.buttonStyle(.bordered).controlSize(.small)
                case .run(let confirm):
                    Button("Run…") {
                        pending = .integration(instance, title: "Run \(entity.name)", systemImage: "play.fill", targetKind: entity.domain.capitalized,
                                               targetName: entity.name, consequence: confirm) { [service] in
                            try await service.perform(control, on: entity)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                case .cover(let isOpen):
                    Button(isOpen ? "Close…" : "Open…") {
                        pending = .integration(instance, title: isOpen ? "Close \(entity.name)" : "Open \(entity.name)", systemImage: isOpen ? "arrow.down.to.line" : "arrow.up.to.line",
                                               targetKind: "Cover", targetName: entity.name,
                                               consequence: isOpen ? "The cover closes. Make sure nothing is in its path." : "The cover opens. For garage doors and gates this leaves the opening unsecured until it's closed again.",
                                               destructive: !isOpen) { [service] in
                            try await service.perform(control, on: entity, turnOn: !isOpen)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func run(_ control: HomeAssistantControl, _ entity: HomeAssistantEntity, turnOn: Bool = true) {
        inFlight.insert(entity.entity_id)
        Task {
            do {
                try await service.perform(control, on: entity, turnOn: turnOn)
                inFlight.remove(entity.entity_id)
                await load()
            } catch {
                inFlight.remove(entity.entity_id)
                state.finish(.failure(.from(error)))
            }
        }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.snapshot() })
    }
}

/// Ports, radios and live statistics for one UniFi device; PoE power cycling is the only port action offered.
struct UniFiDeviceView: View {
    let instance: IntegrationInstance
    let service: any UniFiService
    let device: UniFiDevice
    let siteID: String
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<(details: UniFiDeviceDetails, statistics: UniFiDeviceStatistics?)>()
    @State private var pending: PendingAction?
    @State private var notice: String?

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading \(device.displayName)…", interval: .seconds(15), load: load) { value in
            VStack(spacing: 14) {
                IntegrationHeader(title: device.displayName, version: device.firmwareVersion.map { "firmware \($0)" }, health: device.health,
                                  lines: [[device.role, device.model, device.ipAddress].compactMap { $0 }.joined(separator: " · ")])
                if let notice { InlineNotice(text: notice) }
                if let stats = value.statistics { statisticsCard(stats) }
                if let ports = value.details.interfaces?.ports, !ports.isEmpty { portsCard(ports) }
                if let radios = value.details.interfaces?.radios, !radios.isEmpty { radiosCard(radios, retries: value.statistics?.interfaces?.radios ?? []) }
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func statisticsCard(_ stats: UniFiDeviceStatistics) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Now", systemImage: "gauge.with.dots.needle.33percent")
                if let uptime = stats.uptimeSec { LabeledValue(label: "Up for", value: Format.duration(TimeInterval(uptime))) }
                if let cpu = stats.cpuUtilizationPct { LabeledValue(label: "CPU", value: Format.percent(cpu / 100)) }
                if let memory = stats.memoryUtilizationPct { LabeledValue(label: "Memory", value: Format.percent(memory / 100)) }
                if let one = stats.loadAverage1Min, let five = stats.loadAverage5Min, let fifteen = stats.loadAverage15Min {
                    LabeledValue(label: "Load", value: String(format: "%.2f · %.2f · %.2f", one, five, fifteen))
                }
                if let rx = stats.uplink?.rxRateBps, let tx = stats.uplink?.txRateBps {
                    LabeledValue(label: "Uplink", value: "↓ \(Self.rate(rx)) · ↑ \(Self.rate(tx))")
                }
            }
        }
    }

    nonisolated static func rate(_ bitsPerSecond: Int64) -> String {
        let megabits = Double(bitsPerSecond) / 1_000_000
        return megabits >= 1 ? String(format: "%.1f Mbps", megabits) : String(format: "%.0f kbps", Double(bitsPerSecond) / 1_000)
    }

    private func portsCard(_ ports: [UniFiDeviceDetails.Port]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Ports", systemImage: "cable.connector.horizontal", trailing: "\(ports.filter(\.isUp).count)/\(ports.count) up")
                ForEach(ports) { port in
                    HStack {
                        Image(systemName: port.isUp ? "circle.fill" : "circle").font(.caption2).foregroundStyle(port.isUp ? .green : .secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Port \(port.idx)").font(.subheadline.weight(.semibold))
                            Text(Self.portDetail(port)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if port.canPowerCycle, allowsActions {
                            Button("Power Cycle…") { confirmPowerCycle(port) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("Power cycle port \(port.idx)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                Text("Power cycling briefly cuts PoE power to one port, restarting whatever it powers (a camera, access point or phone). Port settings, VLANs and PoE modes are changed in UniFi Network.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    nonisolated static func portDetail(_ port: UniFiDeviceDetails.Port) -> String {
        var parts = [port.connector, port.isUp ? port.speedMbps.map { $0 >= 1_000 ? "\($0 / 1_000) Gbps" : "\($0) Mbps" } : "No link"].compactMap { $0 }
        if let poe = port.poe, poe.enabled == true {
            parts.append("PoE \(poe.standard ?? "")\(poe.state == "UP" ? " supplying" : (poe.state == "LIMITED" ? " limited" : " idle"))".replacingOccurrences(of: "  ", with: " "))
        }
        return parts.joined(separator: " · ")
    }

    private func radiosCard(_ radios: [UniFiDeviceDetails.Radio], retries: [UniFiDeviceStatistics.Radio]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Radios", systemImage: "antenna.radiowaves.left.and.right")
                ForEach(Array(radios.enumerated()), id: \.offset) { _, radio in
                    let retry = retries.first { $0.frequencyGHz == radio.frequencyGHz }?.txRetriesPct
                    LabeledValue(label: radio.frequencyGHz.map { String(format: "%g GHz", $0) } ?? "Radio",
                                 value: [radio.channel.map { "channel \($0)" }, radio.channelWidthMHz.map { "\($0) MHz" }, radio.wlanStandard,
                                         retry.map { String(format: "%.1f%% retries", $0) }].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }

    private func confirmPowerCycle(_ port: UniFiDeviceDetails.Port) {
        pending = .integration(instance, title: "Power Cycle Port", systemImage: "bolt.slash", targetKind: "PoE port",
                               targetName: "Port \(port.idx) on \(device.displayName)",
                               consequence: "PoE power on port \(port.idx) is cut and restored. Whatever it powers restarts and is offline for a minute or two; if that's the access point or camera you're using, this app may lose its connection too.",
                               destructive: true) { [service, device, siteID] in
            try await service.powerCycle(port: port.idx, on: device, siteID: siteID)
            notice = "Port \(port.idx) power cycled."
        }
    }

    private func load() async {
        state.begin()
        let service = service, device = device, siteID = siteID
        state.finish(await captureResult {
            async let details = service.details(of: device, siteID: siteID)
            async let statistics = try? service.statistics(of: device, siteID: siteID)
            return (details: try await details, statistics: await statistics)
        })
    }
}

/// Configuration check and error log; neither changes anything in Home Assistant.
private struct HomeAssistantDiagnosticsCard: View {
    let service: any HomeAssistantService
    @State private var check: LoadState<HomeAssistantConfigCheck>?

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Diagnostics", systemImage: "stethoscope")
                Button {
                    Task { await runCheck() }
                } label: {
                    Label("Check Configuration", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(check?.isLoading == true)
                if let check {
                    if let result = check.value {
                        Label(result.isValid ? "Configuration is valid" : "Configuration has errors",
                              systemImage: result.isValid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.isValid ? Color.green : Color.red)
                            .font(.subheadline.weight(.semibold))
                        if let errors = result.errors?.nilIfEmpty {
                            Text(errors).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else if let error = check.error {
                        Text(error.errorDescription ?? "Couldn't check").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                NavigationLink {
                    HomeAssistantErrorLogView(service: service)
                } label: {
                    Label("Error Log", systemImage: "doc.text.magnifyingglass")
                }
                Text("The check validates configuration.yaml the way Home Assistant does before a restart, without applying anything.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func runCheck() async {
        var state = LoadState<HomeAssistantConfigCheck>()
        state.begin()
        check = state
        state.finish(await captureResult { try await service.checkConfiguration() })
        check = state
    }
}

struct HomeAssistantErrorLogView: View {
    let service: any HomeAssistantService
    @State private var state = LoadState<String>()
    @State private var query = ""
    @State private var problemsOnly = false

    private var lines: [String] {
        (state.value ?? "").split(whereSeparator: \.isNewline).map(String.init)
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .filter { !problemsOnly || $0.contains(" ERROR ") || $0.contains(" WARNING ") || $0.contains(" CRITICAL ") }
    }

    var body: some View {
        List {
            Toggle("Warnings and errors only", isOn: $problemsOnly)
            if let error = state.error, state.value == nil {
                ErrorStateView(error: error) { Task { await load() } }
            } else if state.value == nil {
                LoadingStateView(message: "Reading the error log…")
            } else if lines.isEmpty {
                Text(query.isEmpty && !problemsOnly ? "Nothing has been logged since Home Assistant started." : "No lines match.").foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(line.contains(" ERROR ") || line.contains(" CRITICAL ") ? Color.red : (line.contains(" WARNING ") ? Color.orange : Color.primary))
            }
        }
        .searchable(text: $query, prompt: "Filter lines")
        .navigationTitle("Error Log")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .enveScreen()
        .ownerOnlyLogs()
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.errorLog() })
    }
}
