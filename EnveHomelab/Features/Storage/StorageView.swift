import Charts
import SwiftUI

@MainActor
@Observable
final class StorageModel {
    var array = LoadState<ArrayStatus>()
    var mode: LiveFeedMode = .connecting
    let service: any UnraidService
    @ObservationIgnored var onArray: ((ArrayStatus) -> Void)?

    init(service: any UnraidService) {
        self.service = service
    }

    func load() async {
        array.begin()
        let service = service
        array.finish(await captureResult { try await service.arrayStatus() })
        if let value = array.value { onArray?(value) }
    }

    func apply(_ event: LiveFeedEvent<ArrayStatus>) {
        switch event {
        case .mode(let mode): self.mode = mode
        case .value(let result):
            array.finish(result)
            if case .success(let value) = result { onArray?(value) }
        }
    }
}

struct StorageView: View {
    @Environment(AppModel.self) private var app
    let context: ServerContext
    @State private var model: StorageModel
    @State private var pending: PendingAction?
    @State private var arrayControl: ArrayControlRequest?

    init(context: ServerContext) {
        self.context = context
        _model = State(initialValue: StorageModel(service: context.service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadStateContainer(state: model.array, loadingMessage: "Reading array…", retry: reload) { array in
                    VStack(spacing: 14) {
                        capacityCard(array)
                        parityCard(array)
                        NavigationLink {
                            SharesView(service: context.service)
                        } label: {
                            EnveCard {
                                HStack {
                                    SectionTitle(title: "Shares", systemImage: "folder.fill")
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        linkCard("Temperatures", systemImage: "thermometer.medium") { TemperaturesView(service: context.service) }
                        linkCard("System logs", systemImage: "doc.text.magnifyingglass") { SystemLogsView(service: context.service) }
                        deviceSection("Parity", systemImage: "shield.lefthalf.filled", devices: array.parities)
                        deviceSection("Array devices", systemImage: "externaldrive.fill", devices: array.disks)
                        deviceSection("Pool devices", systemImage: "bolt.horizontal.fill", devices: array.caches)
                        if let boot = array.boot {
                            deviceSection("Boot device", systemImage: "memorychip", devices: [boot])
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .bottomBarPadding()
            .refreshable { await model.load() }
            .navigationTitle("Storage")
            .navigationDestination(for: ArrayDisk.self) { disk in
                DiskDetailView(disk: disk, service: context.service, history: history(for: disk), isPreview: context.isPreview)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ServerSwitcherButton() }
            }
            .enveScreen()
        }
        .task {
            let store = context.isPreview ? app.previewDiskHistory : app.diskHistory
            let server = context.profileID ?? UnraidPreviewService.historyKey
            model.onArray = { store.record($0.allDevices, server: server) }
            await model.load()
        }
        .task {
            let service = model.service
            await LiveFeed(subscribe: service.arrayUpdates, poll: service.arrayStatus, pollInterval: .seconds(15))
                .run { [model] in model.apply($0) }
        }
        .actionConfirmation($pending) { reload() }
        .sheet(item: $arrayControl) { request in
            ArrayControlSheet(context: context, array: request.array) { reload() }
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private func history(for disk: ArrayDisk) -> [DiskHistoryStore.Sample] {
        (context.isPreview ? app.previewDiskHistory : app.diskHistory).history(server: context.profileID ?? UnraidPreviewService.historyKey, disk: disk)
    }

    private func linkCard(_ title: String, systemImage: String, @ViewBuilder destination: @escaping () -> some View) -> some View {
        NavigationLink {
            destination()
        } label: {
            EnveCard {
                HStack {
                    SectionTitle(title: title, systemImage: systemImage)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func capacityCard(_ array: ArrayStatus) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Array", systemImage: "square.stack.3d.up.fill")
                    LiveModeBadge(mode: model.mode)
                    StatusBadge(text: array.state.displayName, health: array.state.health)
                }
                UsageBar(fraction: array.capacity.usedFraction, tint: UsageBar.tint(for: array.capacity.usedFraction), height: 12)
                    .accessibilityHidden(true)
                HStack {
                    capacityFigure("Used", Format.kilobytes(array.capacity.usedKB))
                    Spacer()
                    capacityFigure("Free", Format.kilobytes(array.capacity.freeKB))
                    Spacer()
                    capacityFigure("Total", Format.kilobytes(array.capacity.totalKB))
                }
                Button {
                    arrayControl = ArrayControlRequest(array: array)
                } label: {
                    Label("Array Operation…", systemImage: "power")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityHint("Review starting or stopping the array")
            }
        }
    }

    private func capacityFigure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func parityCard(_ array: ArrayStatus) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Parity check", systemImage: "checkmark.shield.fill")
                if let parity = array.parityCheck {
                    ParityLine(parity: parity)
                    if parity.isActive, let progress = parity.progress {
                        UsageBar(fraction: Double(progress) / 100, height: 8)
                    }
                    if let speed = parity.speed, parity.isActive || parity.status == .completed {
                        Text("\(speed) MB/s\(parity.durationSeconds.map { " · " + Format.duration(TimeInterval($0)) } ?? "")")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    parityActions(parity, arrayStarted: array.state == .started)
                } else {
                    Text("This server's API doesn't report live parity status.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    ParityHistoryView(service: context.service)
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func parityActions(_ parity: ParityCheck, arrayStarted: Bool) -> some View {
        let actions: [ParityAction] = switch parity.status {
        case .running: [.pause, .cancel]
        case .paused: [.resume, .cancel]
        default: arrayStarted ? [.startCheck] : []
        }
        if !actions.isEmpty {
            HStack {
                ForEach(actions) { action in
                    Button(role: action == .cancel ? .destructive : nil) {
                        pending = PendingAction(
                            title: action.title,
                            systemImage: action.systemImage,
                            targetKind: "Array",
                            targetName: context.serverName,
                            serverName: context.serverName,
                            consequence: action.consequence,
                            isDestructive: action == .cancel,
                            isPreview: context.isPreview
                        ) { [service = context.service] in
                            try await service.perform(action)
                        }
                    } label: {
                        Label(action.title.replacingOccurrences(of: " Parity Check", with: ""), systemImage: action.systemImage)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ title: String, systemImage: String, devices: [ArrayDisk]) -> some View {
        let installed = devices.filter { $0.status != .notPresent }
        if !installed.isEmpty {
            EnveCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(title: title, systemImage: systemImage, trailing: "\(installed.count)")
                        .padding(16)
                    ForEach(installed) { disk in
                        Divider().padding(.leading, 16)
                        NavigationLink(value: disk) {
                            DiskRow(disk: disk, newErrors: DiskHistoryStore.newErrors(in: history(for: disk)))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct ArrayControlRequest: Identifiable {
    let id = UUID()
    let array: ArrayStatus
}

struct DiskRow: View {
    let disk: ArrayDisk
    var newErrors: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: disk.health.systemImage)
                    .foregroundStyle(disk.health.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.displayName)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                temperature
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if let fraction = disk.usedFraction {
                UsageBar(fraction: fraction, tint: UsageBar.tint(for: fraction), height: 6)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(disk.displayName)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var temperature: some View {
        if disk.isSpinning == false {
            Label("Spun down", systemImage: "moon.zzz.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        } else if let temp = disk.temperature {
            Text(Format.temperature(temp))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(disk.temperatureHealth == .ok ? Color.primary : disk.temperatureHealth.color)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let size = disk.sizeKB { parts.append(Format.kilobytes(size)) }
        if let fs = disk.filesystemType { parts.append(fs) }
        if let device = disk.device { parts.append(device) }
        if let errors = disk.errors, errors > 0 { parts.append("\(errors) errors") }
        if newErrors > 0 { parts.append("\(newErrors) new since first seen") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        var parts = [disk.status?.displayName ?? "Unknown status", subtitle]
        if disk.isSpinning == false {
            parts.append("Spun down")
        } else if let temp = disk.temperature {
            parts.append(Format.temperature(temp))
        }
        if let fraction = disk.usedFraction { parts.append("\(Format.percent(fraction)) full") }
        return parts.joined(separator: ", ")
    }
}

struct DiskDetailView: View {
    let disk: ArrayDisk
    let service: any UnraidService
    var history: [DiskHistoryStore.Sample] = []
    var isPreview = false
    @State private var hardware = LoadState<PhysicalDisk?>()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(disk.displayName).font(.title2.weight(.bold))
                            Spacer()
                            StatusBadge(text: disk.status?.displayName ?? "Unknown", health: disk.health)
                        }
                        if let fraction = disk.usedFraction, let used = disk.filesystemUsedKB, let size = disk.filesystemSizeKB {
                            UsageBar(fraction: fraction, tint: UsageBar.tint(for: fraction), height: 10)
                            Text("\(Format.kilobytes(used)) of \(Format.kilobytes(size)) used")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                EnveCard {
                    VStack(spacing: 10) {
                        row("Role", role)
                        row("Slot", "\(disk.slot)")
                        row("Device", disk.device.map { "/dev/\($0)" })
                        row("Transport", disk.transport?.uppercased())
                        row("Size", disk.sizeKB.map(Format.kilobytes))
                        row("Media", disk.rotational.map { $0 ? "Hard drive" : "Solid state" })
                        row("Filesystem", disk.filesystemType)
                        row("Free", disk.filesystemFreeKB.map(Format.kilobytes))
                        row("Comment", disk.comment?.nilIfEmpty)
                    }
                }

                EnveCard {
                    VStack(spacing: 10) {
                        row("Temperature", temperatureText)
                        row("Temperature alerts", disk.temperature == nil ? nil : "\(Format.temperature(disk.temperatureLimits.warning)) warning · \(Format.temperature(disk.temperatureLimits.critical)) critical (Unraid defaults)")
                        row("Usage alerts", usageAlerts)
                        row("Reads", disk.reads.map(Format.count))
                        row("Writes", disk.writes.map(Format.count))
                        row("Errors", disk.errors.map { "\($0)" })
                    }
                }

                Text("I/O counters are kernel statistics since they were last cleared. Errors are unrecoverable read or write errors reported by the drive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                DiskHistoryCard(disk: disk, history: history, isPreview: isPreview)

                hardwareCard
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .bottomBarPadding()
        .navigationTitle(disk.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
    }

    @ViewBuilder
    private var hardwareCard: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Drive health", systemImage: "stethoscope")
                if let physical = hardware.value {
                    if let physical {
                        LabeledValue(label: "SMART", value: physical.smartStatus == .ok ? "Passed" : "Not reported")
                        LabeledValue(label: "Model", value: physical.name)
                        LabeledValue(label: "Vendor", value: physical.vendor)
                        LabeledValue(label: "Serial", value: physical.serialNum, monospaced: true)
                        LabeledValue(label: "Firmware", value: physical.firmwareRevision)
                        LabeledValue(label: "Interface", value: physical.interfaceType.displayName)
                        if let temperature = physical.temperature {
                            LabeledValue(label: "Drive temperature", value: Format.temperature(Int(temperature.rounded())))
                        }
                        Text("The Unraid API reports the drive's overall SMART assessment only. Individual SMART attributes are available in the server's web interface.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No physical drive matching \(disk.device.map { "/dev/\($0)" } ?? "this slot") was reported by the server.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = hardware.error {
                    Text(error.errorDescription ?? "")
                        .font(.subheadline)
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Loading drive health")
                }
            }
        }
        .task {
            hardware.begin()
            let disk = disk
            hardware.finish(await captureResult { try await service.physicalDisks().first { $0.matches(disk) } })
        }
    }

    private var role: String {
        switch disk.type {
        case .parity: "Parity"
        case .data: "Data"
        case .cache: "Pool"
        case .boot, .flash: "Boot"
        case .unknown: "Unknown"
        }
    }

    private var usageAlerts: String? {
        let parts = [disk.usageWarningPercent.flatMap { $0 > 0 ? "\($0)% warning" : nil }, disk.usageCriticalPercent.flatMap { $0 > 0 ? "\($0)% critical" : nil }].compactMap { $0 }
        return disk.filesystemSizeKB == nil || parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var temperatureText: String? {
        if disk.isSpinning == false { return "Spun down" }
        return disk.temperature.map(Format.temperature)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledValue(label: label, value: value)
        }
    }
}

struct ParityHistoryView: View {
    let service: any UnraidService
    @State private var state = LoadState<[ParityCheck]>()

    var body: some View {
        ScrollView {
            LoadStateContainer(state: state, loadingMessage: "Loading history…", retry: { Task { await load() } }) { history in
                if history.isEmpty {
                    ContentUnavailableView("No parity checks", systemImage: "checkmark.shield", description: Text("No parity check has been recorded on this server."))
                } else {
                    EnveCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.offset) { index, record in
                                if index > 0 { Divider().padding(.leading, 16) }
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date")
                                            .font(.body.weight(.semibold))
                                        Text(details(record))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusBadge(text: record.status.displayName, health: record.health)
                                }
                                .padding(16)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .bottomBarPadding()
        .refreshable { await load() }
        .navigationTitle("Parity History")
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
        .task { await load() }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.parityHistory() })
    }

    private func details(_ record: ParityCheck) -> String {
        var parts: [String] = []
        if let duration = record.durationSeconds { parts.append(Format.duration(TimeInterval(duration))) }
        if let speed = record.speed { parts.append("\(speed) MB/s") }
        if let errors = record.errors { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// What this device has recorded for the disk; the Unraid API only reports current counters.
private struct DiskHistoryCard: View {
    let disk: ArrayDisk
    let history: [DiskHistoryStore.Sample]
    let isPreview: Bool

    private var temperatures: [(date: Date, value: Int)] { history.compactMap { sample in sample.temperature.map { (sample.date, $0) } } }

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recorded on this device", systemImage: "chart.line.uptrend.xyaxis")
                if let first = history.first {
                    let newErrors = DiskHistoryStore.newErrors(in: history)
                    Label(newErrors == 0 ? "No new errors since \(first.date.formatted(date: .abbreviated, time: .shortened))"
                                         : "\(newErrors) new error\(newErrors == 1 ? "" : "s") since \(first.date.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: newErrors == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(newErrors == 0 ? Color.green : Color.orange)
                        .font(.subheadline.weight(.semibold))
                    if temperatures.count >= 2 {
                        Chart(temperatures, id: \.date) { point in
                            LineMark(x: .value("Time", point.date), y: .value("°C", point.value))
                                .foregroundStyle(Color.enveAccent)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            RuleMark(y: .value("Warning", disk.temperatureLimits.warning))
                                .foregroundStyle(.orange.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 140)
                        .accessibilityLabel("Recorded temperatures")
                        .accessibilityValue("From \(temperatures.map(\.value).min() ?? 0) to \(temperatures.map(\.value).max() ?? 0) degrees")
                        if let low = temperatures.map(\.value).min(), let high = temperatures.map(\.value).max() {
                            LabeledValue(label: "Recorded range", value: "\(Format.temperature(low)) – \(Format.temperature(high))")
                        }
                    }
                    LabeledValue(label: "Readings kept", value: "\(history.count)")
                } else {
                    Text("Nothing recorded yet.").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(isPreview ? "Sample server readings are kept in memory only." : "Readings are taken while Storage is open, at most every 10 minutes, and stay on this device. A drop in the error count means the counters were cleared on the server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
