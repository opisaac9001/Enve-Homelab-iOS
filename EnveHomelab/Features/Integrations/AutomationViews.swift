import SwiftUI

struct TransferRow: View {
    let item: TransferItem
    var source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: item.state.systemImage)
                    .foregroundStyle(item.state.health == .unknown ? Color.secondary : item.state.health.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let subtitle = [source, item.subtitle].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(Format.percent(item.progress))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            UsageBar(fraction: item.progress, tint: item.state == .failed ? .red : .enveAccent, height: 6)
            Text(details)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if let message = item.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue([item.state.displayName, Format.percent(item.progress), details, item.message].compactMap { $0 }.joined(separator: ", "))
    }

    private var details: String {
        var parts = [item.state.displayName]
        if let size = item.size, size > 0 { parts.append(Format.bytes(size)) }
        if let rate = item.downloadRate, rate > 0 { parts.append("↓ \(Format.rate(rate))") }
        if let rate = item.uploadRate, rate > 0 { parts.append("↑ \(Format.rate(rate))") }
        if let eta = item.eta, eta > 0 { parts.append(Format.duration(eta) + " left") }
        if let category = item.category { parts.append(category) }
        return parts.joined(separator: " · ")
    }
}

struct IntegrationHeader: View {
    let title: String
    let version: String?
    let health: Health
    let lines: [String]

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    StatusBadge(text: health.accessibilityName, health: health)
                }
                if let version {
                    Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(lines, id: \.self) { Text($0).font(.subheadline) }
            }
        }
    }
}

struct ArrView: View {
    let instance: IntegrationInstance
    let service: any ArrService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<ArrSnapshot>()
    @State private var pending: PendingAction?
    @State private var removing: ArrQueueItem?
    @State private var message: String?

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading \(instance.kind.displayName)…", load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(
                    title: instance.name,
                    version: snapshot.status.version,
                    health: snapshot.health.map(\.type.health).max() ?? .ok,
                    lines: []
                )
                if let message { InlineNotice(text: message) }
                healthCard(snapshot.health)
                NavigationLink {
                    ArrSystemView(instance: instance, service: service)
                } label: {
                    EnveCard {
                        HStack {
                            SectionTitle(title: "System", systemImage: "gearshape.2")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Scheduled tasks, recent problems, updates and backups")
                if service.supportsQueue {
                    actionsCard
                    queueCard(snapshot)
                    diskCard(snapshot.diskSpace)
                } else {
                    indexerCard(snapshot.indexers)
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
        .sheet(item: $removing) { item in
            QueueRemovalSheet(instance: instance, item: item) { removeFromClient, blocklist in
                try await service.removeFromQueue(id: item.id, removeFromClient: removeFromClient, blocklist: blocklist)
                await load()
            }
        }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.snapshot() })
    }

    @ViewBuilder
    private func healthCard(_ items: [ArrHealthItem]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Health", systemImage: "stethoscope", trailing: items.isEmpty ? "No issues" : "\(items.count)")
                ForEach(items) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.message).font(.subheadline)
                            if let source = item.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: item.type.health.systemImage).foregroundStyle(item.type.health.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var actionsCard: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Tasks", systemImage: "gearshape.2")
                HStack {
                    ForEach(service.commands) { command in
                        Button {
                            Task { await run(command) }
                        } label: {
                            Label(command.title, systemImage: command.systemImage).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!allowsActions)
                        .accessibilityHint(command.explanation)
                    }
                }
            }
        }
    }

    private func run(_ command: ArrCommand) async {
        do {
            try await service.run(command)
            message = "\(command.title) started."
        } catch {
            message = NetworkError.from(error).errorDescription
        }
    }

    @ViewBuilder
    private func queueCard(_ snapshot: ArrSnapshot) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Queue", systemImage: "list.bullet", trailing: "\(snapshot.queueTotal)")
                if snapshot.queue.isEmpty {
                    Text("Nothing is downloading.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(snapshot.queue) { item in
                    TransferRow(item: item.transferItem)
                        .contextMenu {
                            if allowsActions {
                                Button(role: .destructive) { removing = item } label: { Label("Remove from Queue…", systemImage: "trash") }
                            }
                        }
                    Divider()
                }
                if snapshot.queueTotal > snapshot.queue.count {
                    Text("Showing \(snapshot.queue.count) of \(snapshot.queueTotal).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func diskCard(_ disks: [ArrDiskSpace]) -> some View {
        if !disks.isEmpty {
            EnveCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Disk space", systemImage: "internaldrive")
                    ForEach(disks) { disk in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(disk.label?.nilIfEmpty ?? disk.path ?? "Disk").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(Format.bytes(disk.freeSpace)) free").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            UsageBar(fraction: disk.usedFraction, tint: UsageBar.tint(for: disk.usedFraction))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func indexerCard(_ indexers: [ProwlarrIndexer]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Indexers", systemImage: "magnifyingglass", trailing: "\(indexers.count)")
                }
                ForEach(indexers) { indexer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(indexer.name).font(.subheadline.weight(.semibold))
                            Text([indexer.downloadProtocol, indexer.privacy].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !indexer.isEnabled {
                            StatusBadge(text: "Disabled", health: .unknown)
                        } else if let until = indexer.disabledUntil, until > .now {
                            StatusBadge(text: "Backing off", health: .warning)
                        } else {
                            StatusBadge(text: "Available", health: .ok)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button {
                    Task {
                        do {
                            try await service.testAllIndexers()
                            message = "Indexer tests finished."
                            await load()
                        } catch {
                            message = NetworkError.from(error).errorDescription
                        }
                    }
                } label: {
                    Label("Test All Indexers", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(!allowsActions)
            }
        }
    }
}

struct InlineNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.subheadline)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.enveAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct QueueRemovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let instance: IntegrationInstance
    let item: ArrQueueItem
    let remove: (Bool, Bool) async throws -> Void
    @State private var removeFromClient = true
    @State private var blocklist = false
    @State private var isRunning = false
    @State private var error: NetworkError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledValue(label: "Release", value: item.title)
                    if let media = item.mediaTitle { LabeledValue(label: "For", value: media) }
                    LabeledValue(label: "Server", value: instance.name)
                }
                Section {
                    Toggle("Also remove from \(item.downloadClient ?? "download client")", isOn: $removeFromClient)
                    Toggle("Blocklist this release", isOn: $blocklist)
                } footer: {
                    Text(consequence)
                }
                if let error {
                    Section { InlineErrorBanner(error: error).listRowBackground(Color.clear) }
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            isRunning = true
                            do {
                                try await remove(removeFromClient, blocklist)
                                dismiss()
                            } catch {
                                self.error = .from(error)
                            }
                            isRunning = false
                        }
                    } label: {
                        HStack { Spacer(); if isRunning { ProgressView() } else { Text("Remove from Queue") }; Spacer() }
                    }
                    .disabled(isRunning)
                }
            }
            .navigationTitle("Remove from Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var consequence: String {
        var parts = ["\(instance.kind.displayName) stops tracking this download."]
        if removeFromClient { parts.append("The download and its partial data are removed from the download client.") }
        if blocklist { parts.append("This release won't be grabbed again.") }
        if instance.isSample { parts.append("Sample data only.") }
        return parts.joined(separator: " ")
    }
}

struct DownloadClientView: View {
    let instance: IntegrationInstance
    let service: any DownloadClientService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<DownloadOverview>()
    @State private var pending: PendingAction?
    @State private var inspecting: TransferItem?

    /// The clients whose APIs document per-torrent tracker status and verification.
    nonisolated static let torrentDiagnosticsKinds: Set<IntegrationKind> = [.qbittorrent, .transmission]

    private var diagnostics: (any TorrentDiagnosticsService)? {
        Self.torrentDiagnosticsKinds.contains(instance.kind) ? service as? any TorrentDiagnosticsService : nil
    }
    @State private var removing: TransferItem?
    @State private var actionError: NetworkError?

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading \(instance.kind.displayName)…", interval: .seconds(5), load: load) { overview in
            VStack(spacing: 14) {
                IntegrationHeader(
                    title: instance.name,
                    version: overview.version,
                    health: overview.items.contains { $0.state == .failed } ? .warning : .ok,
                    lines: ["↓ \(Format.rate(overview.downloadRate))" + (overview.uploadRate.map { "  ↑ \(Format.rate($0))" } ?? "") + (overview.isPaused == true ? "  · Queue paused" : "")]
                )
                HStack {
                    Button {
                        pending = .integration(instance, title: "Pause All", systemImage: "pause.fill", targetKind: "Download client", targetName: instance.name,
                                               consequence: "Every download and seed in \(instance.name) pauses (\(overview.items.count) in the queue now). Nothing is removed; Resume All starts them again.") { [service] in
                            try await service.pauseAll()
                        }
                    } label: { Label("Pause All…", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    Button {
                        Task { await act { try await service.resumeAll() } }
                    } label: { Label("Resume All", systemImage: "play.fill").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .disabled(!allowsActions)
                if let actionError { InlineErrorBanner(error: actionError) }
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Queue", systemImage: "list.bullet", trailing: "\(overview.items.count)")
                        if overview.items.isEmpty {
                            Text("Nothing queued.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(overview.items) { item in
                            Group {
                                if diagnostics != nil {
                                    Button { inspecting = item } label: { TransferRow(item: item).contentShape(Rectangle()) }
                                        .buttonStyle(.plain)
                                        .accessibilityHint("Shows trackers and verification")
                                } else {
                                    TransferRow(item: item)
                                }
                            }
                            .contextMenu { menu(for: item) }
                            .accessibilityActions { menu(for: item) }
                            Divider()
                        }
                    }
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
        .sheet(item: $removing) { item in
            TransferRemovalSheet(instance: instance, item: item) { deleteData in
                try await service.remove([item.id], deleteData: deleteData)
                await load()
            }
        }
        .sheet(item: $inspecting) { item in
            if let diagnostics { TorrentDiagnosticsSheet(instance: instance, service: diagnostics, item: item) }
        }
    }

    @ViewBuilder
    private func menu(for item: TransferItem) -> some View {
        if diagnostics != nil {
            Button { inspecting = item } label: { Label("Trackers and Verify", systemImage: "antenna.radiowaves.left.and.right") }
        }
        if !allowsActions {
            EmptyView()
        } else if item.state.isPausable {
            Button { Task { await act { try await service.pause([item.id]) } } } label: { Label("Pause", systemImage: "pause.fill") }
        } else if item.state == .paused || item.state == .completed {
            Button { Task { await act { try await service.resume([item.id]) } } } label: { Label("Resume", systemImage: "play.fill") }
        }
        if allowsActions {
            Button(role: .destructive) { removing = item } label: { Label("Remove…", systemImage: "trash") }
        }
    }

    private func act(_ action: () async throws -> Void) async {
        actionError = nil
        do {
            try await action()
        } catch {
            let failure = NetworkError.from(error)
            if !failure.isCancellation { actionError = failure }
        }
        await load()
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.overview() })
    }
}

private struct TransferRemovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let instance: IntegrationInstance
    let item: TransferItem
    let remove: (Bool) async throws -> Void
    @State private var deleteData = false
    @State private var typed = ""
    @State private var isRunning = false
    @State private var error: NetworkError?

    private var confirmationName: String { String(item.name.prefix(24)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledValue(label: "Download", value: item.name)
                    LabeledValue(label: "Client", value: instance.name)
                }
                Section {
                    Toggle("Delete downloaded data", isOn: $deleteData)
                    if deleteData {
                        TextField(confirmationName, text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Type the download name to confirm")
                    }
                } footer: {
                    Text(deleteData
                         ? "The item is removed and its files are permanently deleted from disk. Type “\(confirmationName)” to confirm."
                         : "The item is removed from \(instance.kind.displayName). Files already downloaded stay on disk.")
                }
                if let error {
                    Section { InlineErrorBanner(error: error).listRowBackground(Color.clear) }
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            isRunning = true
                            do {
                                try await remove(deleteData)
                                dismiss()
                            } catch {
                                self.error = .from(error)
                            }
                            isRunning = false
                        }
                    } label: {
                        HStack { Spacer(); if isRunning { ProgressView() } else { Text(deleteData ? "Remove and Delete Data" : "Remove") }; Spacer() }
                    }
                    .disabled(isRunning || (deleteData && typed != confirmationName))
                }
            }
            .navigationTitle("Remove Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Every enabled download client and *arr queue in one list; it shows only what those servers report.
struct ActivityView: View {
    @Environment(AppModel.self) private var app
    @State private var groups: [(instance: IntegrationInstance, result: Result<[TransferItem], NetworkError>)] = []
    @State private var isLoading = true

    private var sources: [IntegrationInstance] {
        (app.visibleIntegrations + app.visibleSampleInstances).filter {
            $0.isEnabled && $0.kind.hasTransferQueue
        }
    }

    var body: some View {
        List {
            if groups.isEmpty && isLoading {
                LoadingStateView(message: "Collecting activity…").listRowBackground(Color.clear)
            } else if groups.isEmpty {
                ContentUnavailableView("No automation integrations", systemImage: "arrow.down.circle", description: Text("Add a download client or Radarr, Sonarr or Lidarr to see activity here."))
                    .listRowBackground(Color.clear)
            }
            let active = groups.flatMap { group in (try? group.result.get())?.filter { $0.state != .completed && $0.state != .seeding }.map { (group.instance, $0) } ?? [] }
            if !groups.isEmpty {
                Section {
                    LabeledValue(label: "Active items", value: "\(active.count)")
                    LabeledValue(label: "Total download rate", value: Format.rate(active.compactMap(\.1.downloadRate).reduce(0, +)))
                }
            }
            ForEach(groups, id: \.instance.id) { group in
                Section {
                    switch group.result {
                    case .success(let items):
                        if items.isEmpty {
                            Text("Nothing queued.").foregroundStyle(.secondary)
                        }
                        ForEach(items) { TransferRow(item: $0) }
                    case .failure(let error):
                        Label(error.errorDescription ?? "Unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: {
                    Label("\(group.instance.name)\(group.instance.isSample ? " (sample)" : "")", systemImage: group.instance.kind.systemImage)
                }
            }
        }
        .navigationTitle("Activity")
        .refreshable { await load() }
        .bottomBarPadding()
        .enveScreen()
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func load() async {
        isLoading = true
        let clients = sources.map { instance in (instance, Result { try app.client(for: instance) }.mapError(NetworkError.from)) }
        let results = await withTaskGroup(of: (Int, Result<[TransferItem], NetworkError>).self) { group in
            for (index, entry) in clients.enumerated() {
                group.addTask {
                    let result = await captureResult { () async throws -> [TransferItem] in
                        switch try entry.1.get() {
                        case .arr(let service): return try await service.snapshot().queue.map(\.transferItem)
                        case .download(let service): return try await service.overview().items
                        default: return []
                        }
                    }
                    return (index, result)
                }
            }
            var ordered = [Result<[TransferItem], NetworkError>?](repeating: nil, count: clients.count)
            for await (index, result) in group { ordered[index] = result }
            return ordered
        }
        groups = zip(clients, results).compactMap { entry, result in result.map { (entry.0, $0) } }
        isLoading = false
    }
}

/// Per-torrent tracker status (host names only) and a confirmed data verification.
private struct TorrentDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    let instance: IntegrationInstance
    let service: any TorrentDiagnosticsService
    let item: TransferItem
    @State private var trackers = LoadState<[TorrentTracker]>()
    @State private var pending: PendingAction?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green) }
                }
                Section {
                    if let list = trackers.value {
                        if list.isEmpty { Text("No trackers reported.").foregroundStyle(.secondary) }
                        ForEach(list) { tracker in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(tracker.host).font(.subheadline.monospaced())
                                    Spacer()
                                    StatusBadge(text: tracker.status.title, health: tracker.status.health)
                                }
                                let counts = [tracker.seeds.map { "\($0) seeds" }, tracker.peers.map { "\($0) peers" }].compactMap { $0 }
                                if !counts.isEmpty { Text(counts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                if let message = tracker.message { Text(message).font(.caption).foregroundStyle(tracker.status == .notWorking ? Color.orange : Color.secondary) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else if let error = trackers.error {
                        InlineErrorBanner(error: error)
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("Trackers")
                } footer: {
                    Text("Only tracker host names are shown; announce URLs can contain a private tracker passkey.")
                }
                if allowsActions {
                    Section {
                        Button("Verify Data…") {
                            pending = .integration(instance, title: "Verify Torrent Data", systemImage: "checkmark.shield", targetKind: "Torrent", targetName: item.name,
                                                   consequence: "\(instance.kind.displayName) re-reads every piece on disk and checks it against the torrent. Nothing is deleted, but the torrent stops transferring until the check finishes, and anything found damaged is downloaded again.") { [service, item] in
                                try await service.verify(item.id)
                                notice = "Verification started."
                            }
                        }
                    } footer: {
                        Text("Useful after moving files or a disk problem, when the client may be seeding data that no longer matches.")
                    }
                }
            }
            .navigationTitle("Torrent Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
            .actionConfirmation($pending) { Task { await load() } }
        }
    }

    private func load() async {
        trackers.begin()
        let service = service, id = item.id
        trackers.finish(await captureResult { try await service.trackers(for: id) })
    }
}

/// Scheduled tasks, recent warnings and errors, pending update and backups for a Servarr app.
struct ArrSystemView: View {
    let instance: IntegrationInstance
    let service: any ArrService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<ArrSystemDiagnostics>()
    @State private var pending: PendingAction?
    @State private var notice: String?

    var body: some View {
        List {
            if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if let value = state.value {
                if let update = value.availableUpdate { updateSection(update) }
                problemsSection(value)
                tasksSection(value.tasks)
                backupsSection(value.backups)
            } else if let error = state.error {
                Section { ErrorStateView(error: error) { Task { await load() } } }
            } else {
                Section { ProgressView() }
            }
        }
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .actionConfirmation($pending) { Task { await load() } }
        .bottomBarPadding()
        .enveScreen()
    }

    private func updateSection(_ update: ArrUpdate) -> some View {
        Section {
            Label("Version \(update.version) is available", systemImage: "arrow.down.app").font(.subheadline.weight(.semibold))
            ForEach((update.changes?.new ?? []).prefix(5), id: \.self) { Text("New: \($0)").font(.caption) }
            ForEach((update.changes?.fixed ?? []).prefix(5), id: \.self) { Text("Fixed: \($0)").font(.caption) }
        } header: {
            Text("Update")
        } footer: {
            Text("Install updates from \(instance.kind.displayName) itself or your container image; the app doesn't start application updates.")
        }
    }

    private func problemsSection(_ value: ArrSystemDiagnostics) -> some View {
        Section {
            if value.problems.isEmpty { Text("No warnings or errors logged recently.").foregroundStyle(.secondary) }
            ForEach(value.problems) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        StatusBadge(text: (entry.level ?? "").capitalized, health: entry.level?.lowercased() == "warn" ? .warning : .critical)
                        Text([entry.logger, APIDate.parse(entry.time).map(Format.relative)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.message ?? "").font(.caption).textSelection(.enabled)
                    if let exception = entry.exception?.nilIfEmpty {
                        Text(exception).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Recent problems")
        } footer: {
            if value.problemTotal > value.problems.count { Text("Showing the latest \(value.problems.count) of \(value.problemTotal).") }
        }
    }

    private func tasksSection(_ tasks: [ArrTask]) -> some View {
        Section {
            ForEach(tasks) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name).font(.subheadline)
                        Text([APIDate.parse(task.lastExecution).map { "last \(Format.relative($0))" },
                              APIDate.parse(task.nextExecution).map { "next \(Format.relative($0))" },
                              Durations.timeSpan(task.lastDuration).map { "took \(String(format: "%.1f", $0)) s" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if allowsActions, task.isRunnable {
                        Button("Run…") {
                            pending = .integration(instance, title: "Run \(task.name)", systemImage: "play.circle", targetKind: "Scheduled task", targetName: "\(task.name) on \(instance.name)",
                                                   consequence: task.consequence) { [service] in
                                try await service.runTask(task)
                                notice = "\(task.name) queued."
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Run \(task.name)")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Scheduled tasks")
        } footer: {
            Text("Backup, housekeeping and health checks can be run now. Tasks that search, grab, import or update aren't started from here.")
        }
    }

    private func backupsSection(_ backups: [ArrBackup]?) -> some View {
        Section {
            if let backups {
                if backups.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
                ForEach(backups.prefix(10)) { backup in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text([backup.type?.capitalized, backup.size.map { Format.bytes($0) }, APIDate.parse(backup.time).map(Format.relative)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text("The backup list isn't available from this server.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Backups")
        } footer: {
            Text("Restoring or deleting backups isn't offered here.")
        }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.systemDiagnostics() })
    }
}
