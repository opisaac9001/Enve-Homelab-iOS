import SwiftUI

@MainActor
@Observable
final class DashboardModel {
    var system = LoadState<SystemOverview>()
    var metrics = LoadState<SystemMetrics>()
    var array = LoadState<ArrayStatus>()
    var notifications = LoadState<NotificationOverview>()
    var attention = LoadState<[UnraidNotification]>()
    var containers = LoadState<[DockerContainer]>()
    var vms = LoadState<[VirtualMachine]>()
    var metricsMode: LiveFeedMode = .connecting
    var ups = LoadState<[UPSDevice]>()

    let service: any UnraidService

    init(service: any UnraidService) {
        self.service = service
    }

    func load() async {
        system.begin(); array.begin(); notifications.begin()
        attention.begin(); containers.begin(); vms.begin()

        let service = service
        async let system = captureResult { try await service.systemOverview() }
        async let array = captureResult { try await service.arrayStatus() }
        async let notifications = captureResult { try await service.notificationOverview() }
        async let alerts = captureResult { try await service.notifications(.unread, importance: .alert, limit: 5) }
        async let warnings = captureResult { try await service.notifications(.unread, importance: .warning, limit: 5) }
        async let containers = captureResult { try await service.containers() }
        async let vms = captureResult { try await service.virtualMachines() }

        self.system.finish(await system)
        self.array.finish(await array)
        self.notifications.finish(await notifications)
        self.containers.finish(await containers)
        self.vms.finish(await vms)

        let alertResult = await alerts
        let warningResult = await warnings
        let combined = alertResult.flatMap { alerts in
            warningResult.map { (alerts + $0).sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) } }
        }
        attention.finish(combined)
    }

    func apply(metrics event: LiveFeedEvent<SystemMetrics>) {
        switch event {
        case .mode(let mode): metricsMode = mode
        case .value(let result): metrics.finish(result)
        }
    }

    func apply(ups event: LiveFeedEvent<[UPSDevice]>) {
        if case .value(let result) = event { ups.finish(result) }
    }
}

struct DashboardView: View {
    let context: ServerContext
    let selectTab: (AppTab) -> Void
    @State private var model: DashboardModel
    @State private var terminalHostID: UUID?
    @Environment(AppModel.self) private var app

    init(context: ServerContext, selectTab: @escaping (AppTab) -> Void) {
        self.context = context
        self.selectTab = selectTab
        _model = State(initialValue: DashboardModel(service: context.service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ServerHeaderCard(context: context, system: model.system)
                    AttentionCard(state: model.attention, onOpen: { selectTab(.alerts) })
                    LoadCard(state: model.metrics, mode: model.metricsMode)
                    ArraySummaryCard(state: model.array, onOpen: { selectTab(.storage) })
                    UPSCard(state: model.ups)
                    if let profileID = context.profileID {
                        ServicesSummaryCard(serverID: profileID)
                        LinkedIntegrationsCard(serverID: profileID)
                        linkedHosts(profileID)
                    }
                    tiles
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .bottomBarPadding()
            .refreshable { await model.load() }
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ServerSwitcherButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .enveScreen()
        }
        .task { await model.load() }
        .task {
            let service = model.service
            await LiveFeed(subscribe: service.metricsUpdates, poll: service.metrics)
                .run { [model] in model.apply(metrics: $0) }
        }
        .task {
            let service = model.service
            await LiveFeed(subscribe: service.upsUpdates, poll: service.upsDevices, pollInterval: .seconds(15))
                .run { [model] in model.apply(ups: $0) }
        }
    }

    @ViewBuilder
    private func linkedHosts(_ profileID: UUID) -> some View {
        let hosts = app.ssh.hosts.filter { $0.serverID == profileID }
        if !hosts.isEmpty {
            EnveCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(title: "Terminal", systemImage: "terminal.fill")
                        .padding(16)
                    ForEach(hosts) { host in
                        Divider().padding(.leading, 16)
                        Button {
                            terminalHostID = host.id
                        } label: {
                            SSHHostRow(host: host)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .fullScreenCover(item: Binding(get: { terminalHostID.map(IdentifiedID.init) }, set: { terminalHostID = $0?.id })) { item in
                NavigationStack {
                    TerminalScreen(hostID: item.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Close") { terminalHostID = nil }
                            }
                        }
                }
            }
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            Button { selectTab(.docker) } label: {
                MetricTile(
                    title: "Containers running",
                    value: model.containers.value.map { "\($0.filter { $0.state == .running }.count)/\($0.count)" } ?? placeholder(model.containers),
                    systemImage: "shippingbox.fill",
                    health: model.containers.value.map { $0.contains { $0.state == .unknown } ? .warning : .ok }
                )
            }
            Button { selectTab(.vms) } label: {
                MetricTile(
                    title: "VMs running",
                    value: model.vms.value.map { "\($0.filter { $0.state.isActive }.count)/\($0.count)" } ?? placeholder(model.vms),
                    systemImage: "desktopcomputer",
                    health: model.vms.value.map { $0.contains { $0.state == .crashed } ? .critical : .ok }
                )
            }
            Button { selectTab(.alerts) } label: {
                MetricTile(
                    title: "Unread notifications",
                    value: model.notifications.value.map { "\($0.unread.total)" } ?? placeholder(model.notifications),
                    systemImage: "bell.fill",
                    health: model.notifications.value.map { $0.unread.alert > 0 ? .critical : ($0.unread.warning > 0 ? .warning : .ok) }
                )
            }
            Button { selectTab(.storage) } label: {
                MetricTile(
                    title: "Devices needing attention",
                    value: model.array.value.map { "\($0.devicesNeedingAttention.count)" } ?? placeholder(model.array),
                    systemImage: "externaldrive.badge.exclamationmark",
                    health: model.array.value.map { $0.devicesNeedingAttention.map(\.health).max() ?? .ok }
                )
            }
        }
        .buttonStyle(.plain)
    }

    private func placeholder<Value>(_ state: LoadState<Value>) -> String {
        state.error == nil ? "…" : "—"
    }
}

private struct ServerHeaderCard: View {
    let context: ServerContext
    let system: LoadState<SystemOverview>

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.serverName)
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let version = system.value?.unraidVersion {
                            Text("Unraid \(version)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let endpoint = context.endpoint {
                        Label(endpoint.kind.displayName, systemImage: endpoint.kind.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.enveAccent.opacity(0.15), in: Capsule())
                            .accessibilityLabel("Connected over \(endpoint.kind.displayName), \(endpoint.url.host() ?? "")")
                    }
                }

                if let overview = system.value {
                    VStack(spacing: 8) {
                        if let bootTime = overview.bootTime {
                            LabeledValue(label: "Uptime", value: Format.uptime(since: bootTime))
                        }
                        if let cpu = overview.cpuBrand {
                            LabeledValue(label: "Processor", value: cpuDescription(cpu, overview))
                        }
                        if let api = overview.apiVersion {
                            LabeledValue(label: "API", value: api)
                        }
                    }
                    .font(.subheadline)
                } else if let error = system.error {
                    Text(error.errorDescription ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cpuDescription(_ brand: String, _ overview: SystemOverview) -> String {
        guard let cores = overview.cores, let threads = overview.threads else { return brand }
        return "\(brand) · \(cores)C/\(threads)T"
    }
}

private struct AttentionCard: View {
    let state: LoadState<[UnraidNotification]>
    let onOpen: () -> Void

    var body: some View {
        if let items = state.value, !items.isEmpty {
            Button(action: onOpen) {
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Needs attention", systemImage: "exclamationmark.bubble.fill", trailing: "\(items.count)")
                        ForEach(items.prefix(4)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: item.importance.health.systemImage)
                                    .foregroundStyle(item.importance.health.color)
                                    .accessibilityLabel(item.importance.displayName)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.subject)
                                        .font(.subheadline.weight(.semibold))
                                        .multilineTextAlignment(.leading)
                                    if let date = item.timestamp {
                                        Text(Format.relative(date))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens alerts")
        }
    }
}

private struct LoadCard: View {
    let state: LoadState<SystemMetrics>
    let mode: LiveFeedMode

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(title: "System load", systemImage: "cpu")
                    LiveModeBadge(mode: mode)
                }
                if let metrics = state.value {
                    HStack {
                        Spacer()
                        if let cpu = metrics.cpuPercent {
                            RingGauge(fraction: cpu / 100, title: "CPU", valueText: Format.percent(cpu / 100))
                        }
                        Spacer()
                        if let memory = metrics.memory {
                            RingGauge(fraction: memory.percent / 100, title: "Memory", valueText: Format.percent(memory.percent / 100))
                        }
                        Spacer()
                    }
                    if let memory = metrics.memory {
                        Text("\(Format.bytes(memory.used)) of \(Format.bytes(memory.total)) memory in use")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    if let error = state.error {
                        InlineErrorBanner(error: error)
                    }
                } else if let error = state.error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error.errorDescription ?? "")
                            .font(.subheadline.weight(.semibold))
                        if let suggestion = error.recoverySuggestion {
                            Text(suggestion)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LoadingStateView(message: "Reading load…")
                        .frame(minHeight: 100)
                }
            }
        }
    }
}

struct LiveModeBadge: View {
    let mode: LiveFeedMode

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(mode.isStreaming ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var title: String {
        switch mode {
        case .connecting: "Connecting"
        case .streaming: "Live"
        case .polling: "Periodic"
        }
    }

    private var accessibilityText: String {
        switch mode {
        case .connecting: "Connecting to live updates"
        case .streaming: "Live updates"
        case .polling(let reason):
            "Refreshing periodically" + (reason?.errorDescription.map { ". \($0)" } ?? "")
        }
    }
}

private struct UPSCard: View {
    let state: LoadState<[UPSDevice]>

    var body: some View {
        if let devices = state.value, !devices.isEmpty {
            ForEach(devices) { device in
                EnveCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionTitle(title: device.name, systemImage: device.isOnBattery ? "minus.plus.batteryblock.exclamationmark.fill" : "minus.plus.batteryblock.fill")
                            StatusBadge(text: device.status, health: device.health)
                        }
                        HStack(spacing: 12) {
                            figure("Battery", "\(device.battery.chargeLevel)%")
                            figure("Runtime", Format.duration(TimeInterval(device.battery.estimatedRuntime)))
                            figure("Load", device.power.currentPower.map { "\(Int($0.rounded())) W" } ?? "\(device.power.loadPercentage)%")
                        }
                        UsageBar(fraction: Double(device.power.loadPercentage) / 100, tint: UsageBar.tint(for: Double(device.power.loadPercentage) / 100))
                        Text("\(device.model) · battery \(device.battery.health.lowercased()) · input \(Int(device.power.inputVoltage.rounded())) V")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } else if let error = state.error, !Self.isQuiet(error) {
            EnveCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "UPS", systemImage: "minus.plus.batteryblock")
                    Text(error.errorDescription ?? "").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// No UPS configured or no UPS support on this server isn't worth a card.
    private static func isQuiet(_ error: NetworkError) -> Bool {
        if case .unsupportedByServer = error { return true }
        if case .forbidden = error { return true }
        return false
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArraySummaryCard: View {
    let state: LoadState<ArrayStatus>
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            EnveCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionTitle(title: "Array", systemImage: "externaldrive.fill")
                        if let array = state.value {
                            StatusBadge(text: array.state.displayName, health: array.state.health)
                        }
                    }
                    if let array = state.value {
                        VStack(alignment: .leading, spacing: 6) {
                            UsageBar(fraction: array.capacity.usedFraction, tint: UsageBar.tint(for: array.capacity.usedFraction), height: 10)
                            HStack {
                                Text("\(Format.kilobytes(array.capacity.usedKB)) used")
                                Spacer()
                                Text("\(Format.kilobytes(array.capacity.freeKB)) free")
                            }
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Capacity")
                        .accessibilityValue("\(Format.percent(array.capacity.usedFraction)) used, \(Format.kilobytes(array.capacity.freeKB)) free")

                        if let parity = array.parityCheck {
                            ParityLine(parity: parity)
                        }
                    } else if let error = state.error {
                        Text(error.errorDescription ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens storage")
    }
}

struct ParityLine: View {
    let parity: ParityCheck

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: parity.health.systemImage)
                .foregroundStyle(parity.health.color)
                .accessibilityHidden(true)
            Text(summary)
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        switch parity.status {
        case .running, .paused:
            let progress = parity.progress.map { " · \($0)%" } ?? ""
            return "Parity check \(parity.status.displayName.lowercased())\(progress)"
        case .completed:
            let errors = parity.errors ?? 0
            let when = parity.date.map { " " + Format.relative($0) } ?? ""
            return "Last parity check\(when) · \(errors) error\(errors == 1 ? "" : "s")"
        default:
            let when = parity.date.map { " " + Format.relative($0) } ?? ""
            return "Parity check \(parity.status.displayName.lowercased())\(when)"
        }
    }
}

private struct IdentifiedID: Identifiable {
    let id: UUID
}
