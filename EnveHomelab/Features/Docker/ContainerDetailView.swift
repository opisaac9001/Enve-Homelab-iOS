import SwiftUI

struct ContainerDetailView: View {
    let context: ServerContext
    let model: ContainersModel
    let containerID: String
    @State private var pending: PendingAction?
    @State private var isCheckingUpdates = false
    @State private var updateCheckError: NetworkError?
    @State private var details = LoadState<ContainerDetails>()
    @Environment(\.openURL) private var openURL
    @Environment(\.allowsActions) private var allowsActions

    var body: some View {
        ScrollView {
            if let container = model.container(id: containerID) {
                content(container)
                    .padding()
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("Container not found", systemImage: "shippingbox", description: Text("It may have been removed from the server."))
            }
        }
        .bottomBarPadding()
        .refreshable { await model.load() }
        .navigationTitle(model.container(id: containerID)?.name ?? "Container")
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
        .actionConfirmation($pending) { Task { await model.load() } }
        .task { await loadDetails() }
    }

    private func loadDetails() async {
        details.begin()
        let service = model.service, id = containerID
        details.finish(await captureResult { try await service.containerDetails(id: id) })
    }

    @ViewBuilder
    private var templateCard: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Template & housekeeping", systemImage: "doc.badge.gearshape")
                if let info = details.value {
                    if info.isOrphaned == true {
                        Label("No template found. Unraid can't recreate or update this container from its settings.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if info.isRebuildReady == true {
                        Label("Ready to rebuild: the image or template changed since the container was created.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote).foregroundStyle(Color.enveAccent)
                    }
                    if let template = info.templateName { LabeledValue(label: "Template", value: template, monospaced: true) }
                    if let ports = info.lanIpPorts, !ports.isEmpty { LabeledValue(label: "LAN addresses", value: ports.joined(separator: ", "), monospaced: true) }
                    if let rw = info.sizeRw { LabeledValue(label: "Writable layer", value: Format.bytes(rw)) }
                    if let log = info.sizeLog { LabeledValue(label: "Log size", value: Format.bytes(log)) }
                    if info.autoStart == true {
                        LabeledValue(label: "Autostart", value: [info.autoStartOrder.map { "position \($0 + 1)" }, info.autoStartWait.flatMap { $0 > 0 ? "waits \($0) s" : nil }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "On")
                    }
                    let links = [("Project page", info.projectUrl), ("Support", info.supportUrl), ("Registry", info.registryUrl)]
                        .compactMap { title, value in ContainerDetails.webLink(value).map { (title, $0) } }
                    if !links.isEmpty {
                        HStack {
                            ForEach(links, id: \.0) { title, url in
                                Button(title) { openURL(url) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    if let conflicts = model.conflicts, conflicts.involves(containerID) {
                        Label("This container shares a published port with another one.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } else if let error = details.error {
                    Text(error.isUnsupported ? "Needs Unraid API 4.29 or later. Updating Unraid or the Unraid Connect plugin adds it." : (error.errorDescription ?? "Unavailable"))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Loading template details")
                }
            }
        }
    }

    private func content(_ container: DockerContainer) -> some View {
        VStack(spacing: 14) {
            EnveCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ContainerIcon(container: container)
                            .scaleEffect(1.3)
                            .padding(6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(container.name)
                                .font(.title2.weight(.bold))
                            Text(container.status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(text: container.state.displayName, health: container.state.health)
                    }
                    if allowsActions { actionButtons(container) }
                }
            }

            if let error = model.containers.error {
                InlineErrorBanner(error: error)
            }

            updateCard(container)

            HStack(spacing: 12) {
                NavigationLink {
                    ContainerLogsView(service: context.service, container: container)
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let webUI = container.webUIURL {
                    Button {
                        openURL(webUI)
                    } label: {
                        Label("Web UI", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens \(webUI.absoluteString)")
                }
            }
            .controlSize(.large)

            EnveCard {
                VStack(spacing: 10) {
                    LabeledValue(label: "Image", value: container.image)
                    if let network = container.networkMode {
                        LabeledValue(label: "Network", value: network)
                    }
                    LabeledValue(label: "Autostart", value: container.autoStart ? "On" : "Off")
                    if let created = container.created {
                        LabeledValue(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let size = container.sizeRootFs {
                        LabeledValue(label: "Size", value: Format.bytes(size))
                    }
                }
            }

            if !container.ports.isEmpty {
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Ports", systemImage: "point.3.connected.trianglepath.dotted")
                        ForEach(container.ports, id: \.self) { port in
                            Text(port.displayValue)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            templateCard

            if !container.mounts.isEmpty {
                EnveCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Volumes", systemImage: "folder.fill")
                        ForEach(container.mounts, id: \.self) { mount in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mount.destination)
                                    .font(.subheadline.monospaced().weight(.semibold))
                                Text("\(mount.source)\(mount.readOnly ? " · read-only" : "")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func updateCard(_ container: DockerContainer) -> some View {
        let availability = ContainerUpdateAvailability(container.isUpdateAvailable)
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Image", systemImage: "arrow.down.circle")
                switch availability {
                case .available:
                    Label("A newer image is available.", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.enveAccent)
                    Button(role: .destructive) {
                        pending = PendingAction(
                            title: "Update Container",
                            systemImage: "arrow.down.circle.fill",
                            targetKind: "Container",
                            targetName: container.name,
                            serverName: context.serverName,
                            consequence: "Unraid pulls the latest \(container.image) image and recreates the container from its template. The container stops and restarts; if the new image misbehaves, the service stays down until you fix or roll it back on the server.",
                            isDestructive: true,
                            isPreview: context.isPreview
                        ) { [service = context.service, id = container.id] in
                            try await service.updateContainer(id: id)
                        }
                    } label: {
                        Label("Update Container…", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                case .upToDate:
                    Label("Up to date as of the server's last check.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .notReported:
                    Text("This server's API doesn't report image updates, so updating isn't offered here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if availability != .notReported {
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        HStack {
                            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                            if isCheckingUpdates { ProgressView() }
                        }
                    }
                    .disabled(isCheckingUpdates || !allowsActions)
                    .font(.subheadline.weight(.semibold))
                }
                if let updateCheckError {
                    InlineErrorBanner(error: updateCheckError)
                }
            }
        }
    }

    private func checkForUpdates() async {
        isCheckingUpdates = true
        updateCheckError = nil
        do {
            try await context.service.refreshContainerUpdateStatus()
            await model.load()
        } catch {
            let failure = NetworkError.from(error)
            if !failure.isCancellation { updateCheckError = failure }
        }
        isCheckingUpdates = false
    }

    private func actionButtons(_ container: DockerContainer) -> some View {
        let actions = ContainerAction.available(for: container.state)
        return HStack(spacing: 10) {
            ForEach(actions) { action in
                Button(role: action == .stop ? .destructive : nil) {
                    pending = .container(action, container, context: context)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(action == .stop ? .red : .enveAccent)
            }
        }
        .labelStyle(VerticalActionLabelStyle())
    }
}

struct VerticalActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.body.weight(.semibold))
            configuration.title.font(.caption.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}

struct ContainerLogsView: View {
    let service: any UnraidService
    let container: DockerContainer

    @State private var lines: [ContainerLogLine] = []
    @State private var cursor: String?
    @State private var error: NetworkError?
    @State private var isLoading = true
    @State private var follow = true
    @State private var showTimestamps = false

    private static let tail = 300
    private static let maxLines = 3_000

    var body: some View {
        Group {
            if lines.isEmpty, let error {
                ErrorStateView(error: error) { Task { await loadInitial() } }
            } else if lines.isEmpty, isLoading {
                LoadingStateView(message: "Loading logs…")
            } else if lines.isEmpty {
                ContentUnavailableView("No log output", systemImage: "text.alignleft", description: Text("The container hasn't written anything recently."))
            } else {
                logList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("\(container.name) Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle(isOn: $follow) {
                    Label("Follow", systemImage: follow ? "dot.radiowaves.left.and.right" : "pause.circle")
                }
                .toggleStyle(.button)
                .accessibilityHint("Automatically fetches new log lines")
                Menu {
                    Toggle("Show Timestamps", isOn: $showTimestamps)
                    ShareLink(item: exportText) {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .enveScreen()
        .task { await loadInitial() }
        .task(id: follow) {
            guard follow else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await loadNewer()
            }
        }
        .ownerOnlyLogs()
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let error {
                        InlineErrorBanner(error: error).padding(.bottom, 8)
                    }
                    ForEach(lines) { line in
                        Text(render(line))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .bottomBarPadding()
            .onChange(of: lines.last?.id) {
                guard follow else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func render(_ line: ContainerLogLine) -> String {
        guard showTimestamps, let date = line.timestamp else { return line.message }
        return "\(date.formatted(date: .omitted, time: .standard))  \(line.message)"
    }

    private var exportText: String {
        lines.map { "\($0.timestampRaw) \($0.message)" }.joined(separator: "\n")
    }

    private func loadInitial() async {
        isLoading = true
        do {
            let batch = try await service.containerLogs(id: container.id, tail: Self.tail, since: nil)
            lines = batch.lines
            cursor = batch.cursor ?? batch.lines.last?.timestampRaw
            error = nil
        } catch {
            let failure = NetworkError.from(error)
            if !failure.isCancellation { self.error = failure }
        }
        isLoading = false
    }

    private func loadNewer() async {
        guard !isLoading else { return }
        do {
            let batch = try await service.containerLogs(id: container.id, tail: Self.tail, since: cursor)
            let recent = Set(lines.suffix(200).map(\.id))
            let fresh = batch.lines.filter { !recent.contains($0.id) }
            if !fresh.isEmpty {
                lines.append(contentsOf: fresh)
                if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            }
            cursor = batch.cursor ?? fresh.last?.timestampRaw ?? cursor
            error = nil
        } catch {
            let failure = NetworkError.from(error)
            if !failure.isCancellation { self.error = failure }
        }
    }
}
