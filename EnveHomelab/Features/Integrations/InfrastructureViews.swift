import SwiftUI

struct ProxmoxView: View {
    let instance: IntegrationInstance
    let service: any ProxmoxService
    @State private var state = LoadState<ProxmoxSnapshot>()
    @State private var pending: PendingAction?
    @State private var filter = GuestFilter.all

    enum GuestFilter: String, CaseIterable, Identifiable {
        case all = "All", running = "Running", stopped = "Stopped"
        var id: String { rawValue }
    }

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading Proxmox VE…", load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(
                    title: instance.name,
                    version: snapshot.version,
                    health: snapshot.nodes.contains { !$0.isOnline } ? .critical : .ok,
                    lines: []
                )
                nodesCard(snapshot.nodes)
                guestsCard(snapshot.guests)
                tasksCard(snapshot.tasks)
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.snapshot() })
    }

    private func nodesCard(_ nodes: [ProxmoxNode]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Nodes", systemImage: "server.rack", trailing: "\(nodes.count)")
                ForEach(nodes) { node in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(node.node).font(.headline)
                            Spacer()
                            StatusBadge(text: node.isOnline ? "Online" : (node.status ?? "Unknown").capitalized, health: node.isOnline ? .ok : .critical)
                        }
                        if node.isOnline {
                            NavigationLink {
                                ProxmoxNodeView(service: service, node: node.node)
                            } label: {
                                Label("Status, storage and disks", systemImage: "chevron.right.circle")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityLabel("Details for \(node.node)")
                        }
                        if let cpu = node.cpu {
                            meter("CPU", fraction: cpu, detail: node.maxcpu.map { "\($0) cores" })
                        }
                        if let memory = node.memoryFraction {
                            meter("Memory", fraction: memory, detail: node.maxmem.map { Format.bytes($0) })
                        }
                        if let uptime = node.uptime {
                            Text("Up \(Format.duration(TimeInterval(uptime)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func meter(_ label: String, fraction: Double, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text([Format.percent(fraction), detail].compactMap { $0 }.joined(separator: " of ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            UsageBar(fraction: fraction, tint: UsageBar.tint(for: fraction), height: 6)
        }
    }

    @ViewBuilder
    private func guestsCard(_ guests: [ProxmoxGuest]) -> some View {
        let visible = guests.filter {
            switch filter {
            case .all: true
            case .running: $0.isRunning
            case .stopped: !$0.isRunning
            }
        }
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Guests", systemImage: "square.stack.3d.up", trailing: "\(guests.filter(\.isRunning).count) running")
                Picker("Filter", selection: $filter) {
                    ForEach(GuestFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if visible.isEmpty { Text(guests.isEmpty ? "No VMs or containers on this cluster." : "No \(filter.rawValue.lowercased()) guests.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(visible) { guest in
                    guestRow(guest)
                    Divider()
                }
            }
        }
    }

    private func guestRow(_ guest: ProxmoxGuest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: guest.type == .qemu ? "desktopcomputer" : "shippingbox")
                    .foregroundStyle(Color.enveAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(guest.vmid) · \(guest.displayName)").font(.subheadline.weight(.semibold))
                    Text([guest.type.displayName, guest.node, guest.isTemplate ? "template" : nil, guest.lock.map { "locked: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: (guest.status ?? "unknown").capitalized, health: guest.health)
            }
            if guest.isRunning, let mem = guest.mem, let maxmem = guest.maxmem, maxmem > 0 {
                Text("CPU \(Format.percent(guest.cpu ?? 0)) · memory \(Format.bytes(mem)) of \(Format.bytes(maxmem))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            let actions = ProxmoxPowerAction.available(for: guest)
            if !actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(actions) { action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                pending = .integration(instance, title: "\(action.title) \(guest.type == .qemu ? "VM" : "Container")", systemImage: action.systemImage,
                                                       targetKind: guest.type.displayName, targetName: guest.displayName,
                                                       consequence: action.consequence(for: guest.type) + " Proxmox runs this as a task on \(guest.node).",
                                                       destructive: action.isDestructive, typed: action.isDestructive) { [service] in
                                    _ = try await service.perform(action, on: guest)
                                }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(action.isDestructive ? .red : .enveAccent)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tasksCard(_ tasks: [ProxmoxTask]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recent tasks", systemImage: "list.bullet.clipboard")
                if tasks.isEmpty { Text("No recent tasks.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(tasks.prefix(12)) { task in
                    let row = HStack {
                        Image(systemName: task.isRunning ? "hourglass" : task.health.systemImage)
                            .foregroundStyle(task.isRunning ? Color.secondary : task.health.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text([task.type, task.target].compactMap { $0 }.joined(separator: " "))
                                .font(.subheadline)
                            Text([task.node, task.user, task.starttime.map { Format.relative(Date(timeIntervalSince1970: TimeInterval($0))) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(task.isRunning ? "Running" : (task.status ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if task.isRunning || task.succeeded {
                        row
                    } else {
                        NavigationLink {
                            ProxmoxTaskLogView(service: service, task: task)
                        } label: {
                            row.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the task log")
                    }
                }
            }
        }
    }
}

struct PortainerView: View {
    let instance: IntegrationInstance
    let service: any PortainerService
    @State private var state = LoadState<(environments: [PortainerEnvironment], stacks: [PortainerStack])>()
    @State private var pending: PendingAction?

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading Portainer…", load: load) { value in
            VStack(spacing: 14) {
                IntegrationHeader(title: instance.name, version: nil, health: value.environments.contains { !$0.isUp } ? .warning : .ok, lines: [])
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Environments", systemImage: "cube.transparent", trailing: "\(value.environments.count)")
                        ForEach(value.environments) { environment in
                            NavigationLink {
                                PortainerEnvironmentView(instance: instance, service: service, environment: environment)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(environment.Name).font(.subheadline.weight(.semibold))
                                        Text(environment.typeName).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusBadge(text: environment.isUp ? "Up" : "Down", health: environment.isUp ? .ok : .critical)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!environment.isDocker)
                        }
                    }
                }
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Stacks", systemImage: "square.3.layers.3d", trailing: "\(value.stacks.count)")
                        if value.stacks.isEmpty { Text("No stacks.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(value.stacks) { stack in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stack.Name).font(.subheadline.weight(.semibold))
                                    Text("\(stack.typeName) · environment \(value.environments.first { $0.Id == stack.EndpointId }?.Name ?? String(stack.EndpointId))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: stack.isActive ? .destructive : nil) {
                                    pending = .integration(instance, title: stack.isActive ? "Stop Stack" : "Start Stack", systemImage: stack.isActive ? "stop.fill" : "play.fill",
                                                           targetKind: "Stack", targetName: stack.Name,
                                                           consequence: stack.isActive ? "Portainer takes the stack down: its containers are stopped and removed until the stack is started again. Named volumes are kept." : "Portainer deploys every service in the stack again.",
                                                           destructive: stack.isActive) { [service] in
                                        try await service.setStack(stack, active: !stack.isActive)
                                    }
                                } label: {
                                    Text(stack.isActive ? "Stop…" : "Start…")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
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
        state.finish(await captureResult {
            async let environments = service.environments()
            async let stacks = service.stacks()
            return (try await environments, try await stacks)
        })
    }
}

private struct PortainerEnvironmentView: View {
    let instance: IntegrationInstance
    let service: any PortainerService
    let environment: PortainerEnvironment
    @State private var state = LoadState<[PortainerContainer]>()
    @State private var pending: PendingAction?

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading containers…", load: load) { containers in
            EnveCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.element.id) { index, container in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(container.health == .unknown ? Color.gray : container.health.color).frame(width: 9, height: 9).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(container.name).font(.subheadline.weight(.semibold))
                                    Text([container.stack.map { "stack \($0)" }, container.Status].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(container.Image ?? "").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                            HStack {
                                NavigationLink {
                                    PortainerLogsView(service: service, environmentID: environment.Id, container: container)
                                } label: {
                                    Label("Logs", systemImage: "text.alignleft")
                                }
                                NavigationLink {
                                    PortainerContainerDetailView(service: service, environmentID: environment.Id, container: container)
                                } label: {
                                    Label("Health", systemImage: "heart.text.square")
                                }
                                .accessibilityLabel("Health and restarts for \(container.name)")
                                ForEach(container.lifecycleActions) { action in
                                    Button(role: action == .stop ? .destructive : nil) {
                                        pending = .integration(instance, title: "\(action.title) Container", systemImage: action.systemImage,
                                                               targetKind: "Container", targetName: container.name,
                                                               consequence: action.consequence + " Environment: \(environment.Name).",
                                                               destructive: action == .stop) { [service] in
                                            try await service.perform(action, environmentID: environment.Id, containerID: container.Id)
                                        }
                                    } label: {
                                        Label(action.title, systemImage: action.systemImage)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(14)
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
        .navigationTitle(environment.Name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.containers(environmentID: environment.Id) })
    }
}

private struct PortainerLogsView: View {
    let service: any PortainerService
    let environmentID: Int
    let container: PortainerContainer
    @State private var state = LoadState<[String]>()

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading logs…", interval: .seconds(5), load: load) { lines in
            LazyVStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty { Text("No log output.").foregroundStyle(.secondary) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("\(container.name) Logs")
        .navigationBarTitleDisplayMode(.inline)
        .ownerOnlyLogs()
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.logs(environmentID: environmentID, containerID: container.Id, tail: 300) })
    }
}

struct TrueNASView: View {
    let instance: IntegrationInstance
    let service: any TrueNASService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<TrueNASSnapshot>()
    @State private var protection = LoadState<TrueNASDataProtection>()
    @State private var pending: PendingAction?
    @State private var showDismissed = false

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading TrueNAS…", interval: .seconds(20), load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(
                    title: snapshot.system.hostname,
                    version: snapshot.system.version,
                    health: snapshot.pools.map(\.health).max() ?? .ok,
                    lines: [[snapshot.system.system_product, snapshot.system.model].compactMap { $0 }.joined(separator: " · "),
                            snapshot.system.uptime_seconds.map { "Up \(Format.duration($0))" }].compactMap { $0?.nilIfEmpty }
                )
                poolsCard(snapshot.pools)
                alertsCard(snapshot.alerts)
                protectionCard
                jobsCard(snapshot.jobs)
                datasetsCard(snapshot.datasets)
                disksCard(snapshot.disks)
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.snapshot() })
        protection.begin()
        protection.finish(await captureResult { try await service.dataProtection() })
    }

    @ViewBuilder
    private var protectionCard: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Data protection", systemImage: "clock.arrow.2.circlepath")
                if let value = protection.value {
                    if let tasks = value.snapshotTasks {
                        Text("Periodic snapshots").font(.subheadline.weight(.semibold))
                        if tasks.isEmpty { Text("No periodic snapshot tasks.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(tasks) { task in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.dataset + (task.recursive ? " (recursive)" : "")).font(.subheadline)
                                    Text(["keep \(task.retention)", task.enabled ? nil : "disabled", task.state?.date.map { "last \(Format.relative($0))" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let error = task.state?.error { Text(error).font(.caption).foregroundStyle(.red) }
                                }
                                Spacer()
                                if let taskState = task.state { StatusBadge(text: taskState.title, health: taskState.health) }
                                if allowsActions, task.enabled {
                                    Button("Run Now…") { confirmRun(task) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("Run snapshot task for \(task.dataset)")
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text("This key can't read snapshot tasks (needs the SNAPSHOT_TASK_READ role).").font(.caption).foregroundStyle(.secondary)
                    }
                    if let replications = value.replicationTasks {
                        Text("Replication").font(.subheadline.weight(.semibold))
                        if replications.isEmpty { Text("No replication tasks.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(replications) { task in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.name).font(.subheadline)
                                    Text([task.direction == "PUSH" ? "Push" : "Pull", task.transport, "→ \(task.target_dataset)", task.enabled ? nil : "disabled",
                                          task.state?.date.map { "last \(Format.relative($0))" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let error = task.state?.error { Text(error).font(.caption).foregroundStyle(.red) }
                                }
                                Spacer()
                                if let taskState = task.state { StatusBadge(text: taskState.title, health: taskState.health) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text("This key can't read replication tasks (needs the REPLICATION_TASK_READ role).").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Replication runs aren't started from here: a run can prune snapshots on the destination according to its retention.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let error = protection.error {
                    Text(error.errorDescription ?? "Unavailable").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func confirmRun(_ task: TrueNASSnapshotTask) {
        pending = .integration(instance, title: "Run Snapshot Task", systemImage: "camera.aperture", targetKind: "Snapshot task", targetName: task.dataset,
                               consequence: "TrueNAS takes a snapshot of \(task.dataset)\(task.recursive ? " and its children" : "") now, then applies the task's retention (keep \(task.retention)) exactly as a scheduled run would, which can remove snapshots that have expired.", destructive: true) { [service] in
            try await service.runSnapshotTask(task)
        }
    }

    private func poolsCard(_ pools: [TrueNASPool]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Pools", systemImage: "cylinder.split.1x2", trailing: "\(pools.count)")
                if pools.isEmpty { Text("No storage pools have been created.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(pools) { pool in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(pool.name).font(.headline)
                            Spacer()
                            StatusBadge(text: pool.status.capitalized, health: pool.health)
                        }
                        if let fraction = pool.usedFraction, let allocated = pool.allocated, let size = pool.size {
                            UsageBar(fraction: fraction, tint: UsageBar.tint(for: fraction))
                            Text("\(Format.bytes(allocated)) of \(Format.bytes(size)) used").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let detail = pool.status_detail { Text(detail).font(.caption).foregroundStyle(.orange) }
                        if let scan = pool.scan, let function = scan.function {
                            Text("\(function.capitalized) \((scan.state ?? "").lowercased())" + (pool.isScrubbing ? " · \(Int(scan.percentage ?? 0))%" : "") + (scan.errors.map { " · \($0) errors" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if pool.isScrubbing {
                                scrubButton(pool, .pause)
                                scrubButton(pool, .stop)
                            } else {
                                scrubButton(pool, .start)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func scrubButton(_ pool: TrueNASPool, _ action: TrueNASScrubAction) -> some View {
        Button(role: action == .stop ? .destructive : nil) {
            pending = .integration(instance, title: action.title, systemImage: "checkmark.shield", targetKind: "Pool", targetName: pool.name,
                                   consequence: action.consequence, destructive: action == .stop) { [service] in
                try await service.scrub(pool, action: action)
            }
        } label: {
            Text(action.title)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func alertsCard(_ alerts: [TrueNASAlert]) -> some View {
        let visible = alerts.filter { showDismissed || !$0.dismissed }
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Alerts", systemImage: "bell", trailing: "\(alerts.filter { !$0.dismissed }.count) active")
                }
                Toggle("Show dismissed", isOn: $showDismissed).font(.caption)
                if visible.isEmpty { Text("No alerts.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(visible) { alert in
                    HStack(alignment: .top) {
                        Image(systemName: alert.health.systemImage)
                            .foregroundStyle(alert.health == .unknown ? Color.enveAccent : alert.health.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.message).font(.subheadline).foregroundStyle(alert.dismissed ? .secondary : .primary)
                            Text([alert.level.capitalized, alert.datetime.map { Format.relative($0.date) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(alert.dismissed ? "Restore" : "Dismiss") {
                            Task {
                                do {
                                    try await service.setAlert(alert, dismissed: !alert.dismissed)
                                    await load()
                                } catch {
                                    state.finish(.failure(.from(error)))
                                }
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(!allowsActions)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func jobsCard(_ jobs: [TrueNASJob]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Jobs", systemImage: "gearshape.2", trailing: "\(jobs.filter { $0.state == "RUNNING" }.count) running")
                ForEach(jobs.prefix(10)) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.title).font(.subheadline).lineLimit(1)
                            Spacer()
                            StatusBadge(text: job.state.capitalized, health: job.health)
                        }
                        if job.state == "RUNNING", let percent = job.progress?.percent {
                            UsageBar(fraction: percent / 100, height: 5)
                        }
                        if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func datasetsCard(_ datasets: [TrueNASDataset]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Datasets", systemImage: "folder", trailing: "\(datasets.count)")
                ForEach(datasets.prefix(30)) { dataset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dataset.id).font(.subheadline)
                            Text([dataset.used?.bytes.map { "\(Format.bytes($0)) used" }, dataset.available?.bytes.map { "\(Format.bytes($0)) free" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if dataset.encrypted {
                            Image(systemName: dataset.locked ? "lock.fill" : "lock.open")
                                .foregroundStyle(dataset.locked ? .orange : .secondary)
                                .accessibilityLabel(dataset.locked ? "Encrypted, locked" : "Encrypted, unlocked")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func disksCard(_ disks: [TrueNASDisk]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Disks", systemImage: "internaldrive", trailing: "\(disks.count)")
                ForEach(disks) { disk in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(disk.name) · \(disk.model ?? "Unknown model")").font(.subheadline)
                            Text([disk.size.map(Format.bytes), disk.type, disk.pool.map { "pool \($0)" } ?? "unassigned", disk.serial].compactMap { $0 }.joined(separator: " · "))
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

/// Node health from `nodes/{node}/status`, storage availability, and disk SMART health. All read-only.
struct ProxmoxNodeView: View {
    let service: any ProxmoxService
    let node: String
    @State private var status = LoadState<ProxmoxNodeStatus>()
    @State private var storage = LoadState<[ProxmoxStorage]>()
    @State private var disks = LoadState<[ProxmoxDisk]>()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                section("Node", systemImage: "server.rack", state: status) { value in statusRows(value) }
                section("Storage", systemImage: "externaldrive.connected.to.line.below", state: storage) { value in storageRows(value) }
                section("Disks", systemImage: "internaldrive", state: disks) { value in diskRows(value) }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(node)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .bottomBarPadding()
        .enveScreen()
    }

    private func section<Value, Content: View>(_ title: String, systemImage: String, state: LoadState<Value>, @ViewBuilder content: @escaping (Value) -> Content) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: title, systemImage: systemImage)
                if let value = state.value {
                    content(value)
                } else if let error = state.error {
                    Text(Self.explain(error, section: title)).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    nonisolated static func explain(_ error: NetworkError, section: String) -> String {
        if case .forbidden = error {
            return section == "Disks" ? "This token can't read disks. Grant Sys.Audit on / (the PVEAuditor role includes it)." : "This token can't read \(section.lowercased()). Grant PVEAuditor on the node."
        }
        return error.errorDescription ?? "Unavailable"
    }

    @ViewBuilder
    private func statusRows(_ value: ProxmoxNodeStatus) -> some View {
        if let model = value.cpuinfo?.model { LabeledValue(label: "CPU", value: model + (value.cpuinfo?.cpus.map { " · \($0) threads" } ?? "")) }
        if let load = value.loadavg, load.count == 3 { LabeledValue(label: "Load", value: load.map(\.value).joined(separator: " · ")) }
        if let fraction = value.memory?.fraction { LabeledValue(label: "Memory", value: Format.percent(fraction) + (value.memory?.total.map { " of \(Format.bytes($0))" } ?? "")) }
        if let fraction = value.rootfs?.fraction { LabeledValue(label: "Root filesystem", value: Format.percent(fraction) + (value.rootfs?.total.map { " of \(Format.bytes($0))" } ?? "")) }
        if let swap = value.swap, (swap.total ?? 0) > 0, let fraction = swap.fraction { LabeledValue(label: "Swap in use", value: Format.percent(fraction)) }
        if let version = value.pveversion { LabeledValue(label: "Proxmox", value: version.split(separator: "/").dropFirst().first.map(String.init) ?? version) }
        if let kernel = value.currentKernel?.release ?? value.kversion { LabeledValue(label: "Kernel", value: kernel) }
        if let boot = value.bootDescription { LabeledValue(label: "Boot", value: boot) }
        if let uptime = value.uptime { LabeledValue(label: "Up for", value: Format.duration(TimeInterval(uptime))) }
    }

    @ViewBuilder
    private func storageRows(_ value: [ProxmoxStorage]) -> some View {
        if value.isEmpty { Text("No storage visible to this token.").font(.footnote).foregroundStyle(.secondary) }
        ForEach(value) { store in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(store.storage).font(.subheadline.weight(.semibold))
                    Text([store.type, store.shared?.value == true ? "shared" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.isUnavailable {
                        StatusBadge(text: "Not available", health: .critical)
                    } else if store.enabled?.value == false {
                        StatusBadge(text: "Disabled", health: .unknown)
                    }
                }
                if let fraction = store.usedFraction {
                    UsageBar(fraction: fraction, tint: UsageBar.tint(for: fraction), height: 6)
                    Text("\(Format.percent(fraction)) used" + (store.avail.map { " · \(Format.bytes($0)) free" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                if let content = store.content { Text(content.replacingOccurrences(of: ",", with: ", ")).font(.caption2).foregroundStyle(.tertiary) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func diskRows(_ value: [ProxmoxDisk]) -> some View {
        if value.isEmpty { Text("No disks reported.").font(.footnote).foregroundStyle(.secondary) }
        ForEach(value) { disk in
            NavigationLink {
                ProxmoxSMARTView(service: service, node: node, disk: disk)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(disk.devpath).font(.subheadline.monospaced().weight(.semibold))
                        Text([disk.model, disk.size.map { Format.bytes($0) }, disk.used].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(text: disk.health?.capitalized.nilIfEmpty ?? "Unknown", health: disk.healthLevel)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows SMART details")
        }
        Text("Health is the drive's own SMART self-assessment as reported by smartctl on the node.").font(.footnote).foregroundStyle(.secondary)
    }

    private func load() async {
        let service = service, node = node
        status.begin(); storage.begin(); disks.begin()
        async let s = captureResult { try await service.nodeStatus(node) }
        async let st = captureResult { try await service.storage(node) }
        async let d = captureResult { try await service.disks(node) }
        status.finish(await s)
        storage.finish(await st)
        disks.finish(await d)
    }
}

struct ProxmoxSMARTView: View {
    let service: any ProxmoxService
    let node: String
    let disk: ProxmoxDisk
    @State private var state = LoadState<ProxmoxSMART>()

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: disk.devpath)
                if let model = disk.model { LabeledContent("Model", value: model) }
                if let serial = disk.serial { LabeledContent("Serial", value: serial) }
                if let smart = state.value {
                    LabeledContent("SMART health", value: smart.health)
                        .foregroundStyle(smart.health.uppercased() == "PASSED" || smart.health.uppercased() == "OK" ? Color.primary : Color.red)
                }
            }
            if let smart = state.value {
                if let attributes = smart.attributes, !attributes.isEmpty {
                    Section {
                        ForEach(Array(attributes.enumerated()), id: \.offset) { _, attribute in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text([attribute.id?.value, attribute.name?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                                    Spacer()
                                    if attribute.isFailing {
                                        StatusBadge(text: "Failing", health: .critical)
                                    } else if attribute.isWearIndicator {
                                        StatusBadge(text: "Watch", health: .warning)
                                    }
                                }
                                Text("Value \(attribute.value?.value ?? "–") · worst \(attribute.worst?.value ?? "–") · threshold \(attribute.threshold?.value ?? "–") · raw \(attribute.raw?.value ?? "–")")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Attributes")
                    } footer: {
                        Text("A normalised value at or below its threshold means that attribute has failed. Rising raw counts for reallocated, pending or uncorrectable sectors are early warnings.")
                    }
                }
                if let text = smart.text?.nilIfEmpty {
                    Section("Report") {
                        Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else if let error = state.error {
                Section { Text(ProxmoxNodeView.explain(error, section: "Disks")).foregroundStyle(.secondary) }
            } else {
                Section { ProgressView() }
            }
        }
        .navigationTitle(disk.devpath)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .enveScreen()
    }

    private func load() async {
        state.begin()
        let service = service, node = node, path = disk.devpath
        state.finish(await captureResult { try await service.smart(node, disk: path) })
    }
}

struct ProxmoxTaskLogView: View {
    let service: any ProxmoxService
    let task: ProxmoxTask
    @State private var state = LoadState<[String]>()

    var body: some View {
        List {
            Section {
                LabeledContent("Task", value: [task.type, task.target].compactMap { $0 }.joined(separator: " "))
                if let status = task.status { LabeledContent("Result", value: status) }
            }
            if let lines = state.value {
                Section("Log") {
                    if lines.isEmpty { Text("The task wrote no log.").foregroundStyle(.secondary) }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                            .foregroundStyle(line.contains("ERROR") ? Color.red : (line.contains("WARN") ? Color.orange : Color.primary))
                    }
                }
            } else if let error = state.error {
                Section { InlineErrorBanner(error: error) }
            } else {
                Section { ProgressView() }
            }
        }
        .navigationTitle("Task Log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            state.begin()
            let service = service, task = task
            state.finish(await captureResult { try await service.taskLog(task, limit: 200) })
        }
        .enveScreen()
        .ownerOnlyLogs()
    }
}

/// Health checks, restart count and last exit, from Docker's container inspect via Portainer. Read-only.
private struct PortainerContainerDetailView: View {
    let service: any PortainerService
    let environmentID: Int
    let container: PortainerContainer
    @State private var state = LoadState<PortainerInspection>()

    var body: some View {
        List {
            if let value = state.value {
                Section("State") {
                    LabeledContent("Status", value: value.state?.Status?.capitalized ?? "Unknown")
                    if let started = APIDate.parse(value.state?.StartedAt), started.timeIntervalSince1970 > 0 { LabeledContent("Started", value: Format.relative(started)) }
                    LabeledContent("Restarts", value: "\(value.restartCount ?? 0)")
                    LabeledContent("Restart policy", value: value.restartPolicy)
                    if value.state?.OOMKilled == true { Label("Last stopped for running out of memory", systemImage: "memorychip").foregroundStyle(.red) }
                    if let code = value.state?.ExitCode, code != 0 { LabeledContent("Last exit code", value: "\(code)") }
                    if let error = value.state?.Error?.nilIfEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    if let health = value.state?.Health {
                        HStack {
                            Text("Health check")
                            Spacer()
                            StatusBadge(text: health.Status?.capitalized ?? "Unknown", health: value.healthLevel)
                        }
                        if let streak = health.FailingStreak, streak > 0 { LabeledContent("Failing in a row", value: "\(streak)") }
                        ForEach(Array((health.Log ?? []).suffix(5).reversed().enumerated()), id: \.offset) { _, check in
                            VStack(alignment: .leading, spacing: 2) {
                                Text([APIDate.parse(check.Start).map(Format.relative), check.ExitCode.map { "exit \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let output = check.Output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                                    Text(output).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        Text("This container has no health check. Add a HEALTHCHECK to its image or compose file to get one.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Health")
                }
            } else if let error = state.error {
                Section { InlineErrorBanner(error: error) }
            } else {
                Section { ProgressView() }
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .enveScreen()
    }

    private func load() async {
        state.begin()
        let service = service, environmentID = environmentID, id = container.Id
        state.finish(await captureResult { try await service.inspect(environmentID: environmentID, containerID: id) })
    }
}
