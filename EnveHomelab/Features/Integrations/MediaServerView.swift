import SwiftUI

struct MediaSnapshot: Sendable {
    var info: MediaServerInfo
    var sessions: [MediaSession]
    var libraries: [MediaLibrary]
    var recent: [MediaItem]
    var resume: [MediaItem]
    var users: [MediaUser]
    /// nil when the management endpoints couldn't be read at all.
    var management: MediaManagement?
}

struct MediaServerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    let instance: IntegrationInstance
    let service: any MediaServerService
    @State private var state = LoadState<MediaSnapshot>()
    @State private var pending: PendingAction?
    @State private var notice: String?
    @State private var messaging: MediaSession?
    @State private var messageText = ""

    private var capabilities: MediaCapabilities { service.capabilities }

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading \(instance.kind.displayName)…", interval: .seconds(10), load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(title: snapshot.info.name, version: snapshot.info.version, health: health(snapshot), lines: headerLines(snapshot))
                if let notice { InlineNotice(text: notice) }
                if let unavailable = snapshot.management?.unavailable, !unavailable.isEmpty {
                    InlineNotice(text: "Not available with this key or server version: \(unavailable.joined(separator: ", ")). Admin access is needed for these.")
                }
                serverCard(snapshot)
                sessionsCard(snapshot.sessions)
                librariesCard(snapshot.libraries)
                if let activities = snapshot.management?.activities, !activities.isEmpty { tasksCard("Background Activity", systemImage: "gearshape.arrow.triangle.2.circlepath", tasks: activities) }
                if let tasks = snapshot.management?.tasks { tasksCard("Scheduled Tasks", systemImage: "calendar.badge.clock", tasks: tasks) }
                itemsCard("Recently added", systemImage: "sparkles.tv", items: snapshot.recent)
                resumeCard(snapshot)
                if let history = snapshot.management?.history { historyCard(history) }
                if let devices = snapshot.management?.devices { devicesCard(devices) }
                if let users = snapshot.management?.users, !users.isEmpty { usersCard(users) }
                if let plugins = snapshot.management?.plugins { pluginsCard(plugins) }
                if let logs = service as? any ServerLogSource, instance.kind != .plex, allowsActions {
                    NavigationLink {
                        MediaServerLogsView(source: logs, serverName: instance.name)
                    } label: {
                        EnveCard {
                            HStack {
                                SectionTitle(title: "Server Logs", systemImage: "doc.text.magnifyingglass")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
        .alert("Send a Message", isPresented: Binding(get: { messaging != nil }, set: { if !$0 { messaging = nil } }), presenting: messaging) { session in
            TextField("Message", text: $messageText)
            Button("Send") {
                let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                messageText = ""
                guard !text.isEmpty else { return }
                Task { await run(.message(sessionID: session.id, text: text), done: "Message shown on \(session.device ?? "the client").") }
            }
            Button("Cancel", role: .cancel) { messageText = "" }
        } message: { session in
            Text("Shown for 10 seconds on \(session.device ?? "the client") (\(session.user ?? "unknown user")).")
        }
    }

    private func health(_ snapshot: MediaSnapshot) -> Health {
        snapshot.management?.health.pendingRestart == true ? .warning : .ok
    }

    private func headerLines(_ snapshot: MediaSnapshot) -> [String] {
        var lines: [String] = []
        if snapshot.management?.health.pendingRestart == true { lines.append("A restart is pending to finish applying changes.") }
        if let version = snapshot.management?.health.updateVersion {
            lines.append("Version \(version) is available.")
        } else if snapshot.info.updateAvailable == true {
            lines.append("An update is available.")
        }
        if let os = snapshot.management?.health.operatingSystem { lines.append(os) }
        return lines
    }

    private func load() async {
        state.begin()
        let userID = instance.mediaUserID ?? (instance.isSample ? "u1" : nil)
        state.finish(await captureResult {
            async let info = service.info()
            async let sessions = service.sessions()
            async let libraries = service.libraries()
            async let recent = service.recentlyAdded(limit: 12)
            async let users = service.users()
            async let management = service.management()
            let resolvedUsers = (try? await users) ?? []
            return MediaSnapshot(
                info: try await info,
                sessions: try await sessions,
                libraries: try await libraries,
                recent: (try? await recent) ?? [],
                resume: (try? await service.continueWatching(userID: userID ?? (capabilities.resumeNeedsUser ? nil : ""), limit: 12)) ?? [],
                users: resolvedUsers,
                management: try? await management
            )
        })
    }

    private func run(_ action: MediaAdminAction, done: String) async {
        do {
            try await service.perform(action)
            notice = done
        } catch {
            notice = NetworkError.from(error).errorDescription
        }
        await load()
    }

    private func confirm(_ title: String, _ systemImage: String, kind: String, target: String, consequence: String,
                         destructive: Bool = false, typed: Bool = false, _ action: MediaAdminAction) {
        pending = .integration(instance, title: title, systemImage: systemImage, targetKind: kind, targetName: target,
                               consequence: consequence, destructive: destructive, typed: typed) { [service] in
            try await service.perform(action)
        }
    }


    @ViewBuilder
    private func serverCard(_ snapshot: MediaSnapshot) -> some View {
        let health = snapshot.management?.health
        let canRestart = health?.canRestart == true
        if allowsActions, canRestart || capabilities.libraryMaintenance {
            EnveCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Server Maintenance", systemImage: "wrench.and.screwdriver")
                    if canRestart {
                        Button(role: .destructive) {
                            confirm("Restart Server", "arrow.clockwise.circle", kind: "Media server", target: snapshot.info.name,
                                    consequence: "\(snapshot.info.name) restarts. Every stream stops, and apps can't connect for about a minute." +
                                        (health?.pendingRestart == true ? " This also finishes applying pending changes." : ""),
                                    destructive: true, .restartServer)
                        } label: { Label("Restart Server…", systemImage: "arrow.clockwise.circle").frame(maxWidth: .infinity) }
                    }
                    if capabilities.libraryMaintenance {
                        Button {
                            confirm("Optimize Database", "cylinder.split.1x2", kind: "Database", target: snapshot.info.name,
                                    consequence: "Plex compacts and reindexes its database. The server can be slow to respond until it finishes.", .plex(.optimizeDatabase))
                        } label: { Label("Optimize Database…", systemImage: "cylinder.split.1x2").frame(maxWidth: .infinity) }
                        Button {
                            confirm("Clean Bundles", "trash.circle", kind: "Metadata bundles", target: snapshot.info.name,
                                    consequence: "Plex deletes metadata bundles (artwork, subtitles it downloaded) that no longer belong to any item in your libraries.", destructive: true, .plex(.cleanBundles))
                        } label: { Label("Clean Bundles…", systemImage: "trash.circle").frame(maxWidth: .infinity) }
                        Button {
                            Task { await run(.plex(.checkForUpdates), done: "Plex is checking for updates; refresh in a moment.") }
                        } label: { Label("Check for Updates", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }


    @ViewBuilder
    private func sessionsCard(_ sessions: [MediaSession]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Now playing", systemImage: "play.circle", trailing: "\(sessions.count)")
                if sessions.isEmpty {
                    Text("Nothing is playing.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    sessionRow(session)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: MediaSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: session.isPaused ? "pause.circle.fill" : "play.circle.fill")
                    .foregroundStyle(Color.enveAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.subheadline.weight(.semibold))
                    if let subtitle = session.subtitle?.nilIfEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusBadge(text: session.playMethod.displayName, health: session.playMethod == .transcode ? .warning : .ok)
            }
            if let progress = session.progress {
                UsageBar(fraction: progress, height: 5)
            }
            Text([session.user, session.device, session.client, session.location?.uppercased(), session.bandwidthKbps.map { String(format: "%.1f Mbps", Double($0) / 1000) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let tracks = trackDescription(session) {
                Text(tracks).font(.caption).foregroundStyle(.secondary)
            }
            if let transcode = session.transcode {
                Text(transcodeDescription(transcode)).font(.caption).foregroundStyle(.secondary)
            }
            sessionControls(session)
        }
        .accessibilityElement(children: .contain)
    }

    private func trackDescription(_ session: MediaSession) -> String? {
        guard session.streams.contains(where: { $0.kind != .video }) else { return nil }
        let video = session.streams.first { $0.kind == .video }?.title
        let audio = session.selectedAudio?.title ?? "Default audio"
        let subtitles = session.selectedSubtitle.map { "Subtitles: \($0.title)" } ?? "No subtitles"
        return [video, audio, subtitles].compactMap { $0 }.joined(separator: " · ")
    }

    private func transcodeDescription(_ transcode: MediaTranscode) -> String {
        var parts: [String] = []
        let codecs = [transcode.videoCodec, transcode.audioCodec].compactMap { $0 }
        if !codecs.isEmpty { parts.append("To " + codecs.joined(separator: "/")) }
        if transcode.hardwareAccelerated == true { parts.append("hardware") }
        if let speed = transcode.speed { parts.append(String(format: "%.1f×", speed)) }
        if transcode.throttled == true { parts.append("throttled") }
        if !transcode.reasons.isEmpty { parts.append(transcode.reasons.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func sessionControls(_ session: MediaSession) -> some View {
        if !allowsActions {
            EmptyView()
        } else if capabilities.sessionCommands && session.supportsRemoteControl {
            HStack {
                Button {
                    Task { await send(session.isPaused ? .unpause : .pause, to: session) }
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                Button(role: .destructive) {
                    pending = .integration(instance, title: "Stop Playback", systemImage: "stop.fill", targetKind: "Session",
                                           targetName: "\(session.title) — \(session.user ?? "user")",
                                           consequence: "Playback stops on \(session.device ?? "the device"). The viewer sees it end immediately.",
                                           destructive: true) { [service] in
                        try await service.send(.stop, to: session.id)
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                if session.canMessage || session.canSwitch(.audio) || session.canSwitch(.subtitle) {
                    Menu {
                        if session.canMessage {
                            Button { messaging = session } label: { Label("Send Message…", systemImage: "text.bubble") }
                        }
                        if session.canSwitch(.audio) { streamMenu(session, kind: .audio) }
                        if session.canSwitch(.subtitle) { streamMenu(session, kind: .subtitle) }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("More controls for \(session.title)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if capabilities.terminateSessions {
            Button(role: .destructive) {
                pending = .integration(instance, title: "Stop Stream", systemImage: "xmark.circle", targetKind: "Session",
                                       targetName: "\(session.title) — \(session.user ?? "user")",
                                       consequence: "Plex ends this stream and shows the viewer “Stopped from Enve Homelab”. Plex only allows this on servers with Plex Pass.",
                                       destructive: true) { [service] in
                    try await service.terminate(sessionID: session.id, reason: "Stopped from Enve Homelab")
                }
            } label: {
                Label("Stop Stream…", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if capabilities.sessionCommands {
            Text("This client doesn't accept remote control.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func streamMenu(_ session: MediaSession, kind: MediaStreamInfo.Kind) -> some View {
        Menu(kind == .audio ? "Audio Track" : "Subtitles") {
            if kind == .subtitle {
                // Index -1 turns subtitles off in Jellyfin and Emby.
                Button { Task { await run(.setStream(sessionID: session.id, kind: .subtitle, index: -1), done: "Subtitles turned off on \(session.device ?? "the client").") } } label: {
                    trackLabel("Off", selected: session.selectedSubtitle == nil)
                }
            }
            ForEach(session.streams.filter { $0.kind == kind }) { stream in
                Button {
                    Task { await run(.setStream(sessionID: session.id, kind: kind, index: stream.index), done: "Switched \(session.device ?? "the client") to \(stream.title).") }
                } label: {
                    trackLabel(stream.title, selected: stream.isSelected)
                }
            }
        }
    }

    @ViewBuilder
    private func trackLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func send(_ command: MediaSessionCommand, to session: MediaSession) async {
        do {
            try await service.send(command, to: session.id)
            notice = "\(command.title) sent to \(session.device ?? "the client")."
        } catch {
            notice = NetworkError.from(error).errorDescription
        }
        await load()
    }


    @ViewBuilder
    private func librariesCard(_ libraries: [MediaLibrary]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Libraries", systemImage: "books.vertical", trailing: "\(libraries.count)")
                if libraries.isEmpty {
                    Text("No libraries are shared with this key.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(libraries) { library in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(library.name, systemImage: library.kind.systemImage).font(.subheadline)
                            Spacer()
                            if library.isRefreshing {
                                ProgressView().controlSize(.small).accessibilityLabel("Scanning")
                            } else if allowsActions, capabilities.refreshPerLibrary {
                                libraryMenu(library)
                            }
                        }
                        if let progress = library.refreshProgress {
                            UsageBar(fraction: progress, height: 4)
                                .accessibilityLabel("Scan progress")
                                .accessibilityValue(Format.percent(progress))
                        }
                    }
                }
                if allowsActions, !capabilities.libraryMaintenance {
                    Button {
                        pending = scanAction(library: nil)
                    } label: {
                        Label("Scan All Libraries", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func libraryMenu(_ library: MediaLibrary) -> some View {
        Menu {
            Button { pending = scanAction(library: library) } label: { Label("Scan for Changes…", systemImage: "arrow.clockwise") }
            if capabilities.libraryMaintenance {
                Button {
                    confirm("Refresh All Metadata", "arrow.triangle.2.circlepath", kind: "Library", target: library.name,
                            consequence: "Plex downloads metadata and artwork again for every item in \(library.name). On large libraries this takes hours and uses a lot of bandwidth.",
                            .refreshMetadata(libraryID: library.id))
                } label: { Label("Refresh All Metadata…", systemImage: "arrow.triangle.2.circlepath") }
                Button {
                    confirm("Analyze Library", "waveform.badge.magnifyingglass", kind: "Library", target: library.name,
                            consequence: "Plex re-reads the media files in \(library.name) to update codec and stream details. It uses disk and CPU while it runs.",
                            .analyze(libraryID: library.id))
                } label: { Label("Analyze…", systemImage: "waveform.badge.magnifyingglass") }
                Button(role: .destructive) {
                    confirm("Empty Trash", "trash", kind: "Library", target: library.name,
                            consequence: "Plex permanently removes items in \(library.name) whose files are missing, including their watch history and edited metadata. If the files return they're added as new.",
                            destructive: true, typed: true, .emptyTrash(libraryID: library.id))
                } label: { Label("Empty Trash…", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Actions for \(library.name)")
    }

    private func scanAction(library: MediaLibrary?) -> PendingAction {
        .integration(instance, title: library == nil ? "Scan All Libraries" : "Scan Library", systemImage: "arrow.clockwise",
                     targetKind: "Library", targetName: library?.name ?? "All libraries",
                     consequence: "The server scans the library folders for new, changed and removed files. It uses disk and CPU while it runs.") { [service] in
            try await service.refresh(libraryID: library?.id)
        }
    }


    private func tasksCard(_ title: String, systemImage: String, tasks: [MediaTask]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: title, systemImage: systemImage, trailing: "\(tasks.filter { $0.state == .running }.count) running")
                if tasks.isEmpty {
                    Text("No tasks.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.name).font(.subheadline.weight(.semibold))
                                if let detail = [task.category, task.detail].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            taskBadge(task)
                            if allowsActions { taskMenu(task) }
                        }
                        if task.state == .running, let progress = task.progress {
                            UsageBar(fraction: progress, height: 4).accessibilityLabel("\(task.name) progress").accessibilityValue(Format.percent(progress))
                        }
                        if let lastRun = task.lastRun {
                            Text("Last ran \(Format.relative(lastRun))").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let error = task.lastError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func taskBadge(_ task: MediaTask) -> some View {
        switch (task.state, task.lastOutcome) {
        case (.running, _): StatusBadge(text: "Running", health: .ok)
        case (.cancelling, _): StatusBadge(text: "Cancelling", health: .unknown)
        case (_, .failed?): StatusBadge(text: "Failed", health: .warning)
        case (_, .aborted?): StatusBadge(text: "Aborted", health: .warning)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func taskMenu(_ task: MediaTask) -> some View {
        let isActivity = task.cancellable
        if task.state == .running {
            Button(role: .destructive) {
                confirm(isActivity ? "Cancel Activity" : "Stop Task", "stop.circle", kind: isActivity ? "Activity" : "Task", target: task.name,
                        consequence: "The server stops \(task.name) now. Work it has already done is kept; the rest waits for the next run.",
                        isActivity ? .cancelActivity(id: task.id) : .stopTask(id: task.id))
            } label: { Image(systemName: "stop.circle").font(.title3) }
            .accessibilityLabel(isActivity ? "Cancel \(task.name)" : "Stop \(task.name)")
        } else if !isActivity {
            Button {
                confirm("Run Task", "play.circle", kind: "Task", target: task.name,
                        consequence: "The server runs \(task.name) now instead of waiting for its schedule. Some tasks use a lot of disk and CPU while they run.",
                        .runTask(id: task.id))
            } label: { Image(systemName: "play.circle").font(.title3) }
            .accessibilityLabel("Run \(task.name)")
        }
    }


    private func pluginsCard(_ plugins: [MediaPlugin]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: instance.kind == .emby ? "Plugin Updates" : "Plugins", systemImage: "puzzlepiece.extension", trailing: "\(plugins.filter(\.needsAttention).count) need attention")
                if plugins.isEmpty {
                    Text(instance.kind == .emby ? "Every plugin is up to date." : "No plugins installed.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(plugins.prefix(12)) { plugin in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name).font(.subheadline)
                            if let version = plugin.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        StatusBadge(text: plugin.statusTitle, health: plugin.needsAttention ? .warning : .ok)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Install, update or remove plugins in \(instance.kind.displayName)'s dashboard.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func devicesCard(_ devices: [MediaDevice]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Devices", systemImage: "iphone.and.arrow.forward", trailing: "\(devices.count)")
                if devices.isEmpty {
                    Text("No signed-in devices.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.subheadline.weight(.semibold))
                            Text([device.app, device.lastUser, device.lastActive.map { "active \(Format.relative($0))" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if allowsActions {
                            Button(role: .destructive) {
                                confirm("Sign Out Device", "iphone.slash", kind: "Device", target: device.name,
                                        consequence: "The server removes \(device.name) and revokes its sign-in. Anyone using it must sign in again.",
                                        destructive: true, .removeDevice(id: device.id))
                            } label: { Image(systemName: "iphone.slash").font(.title3) }
                            .accessibilityLabel("Sign out \(device.name)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func usersCard(_ users: [MediaUser]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Users", systemImage: "person.2", trailing: "\(users.count)")
                ForEach(users) { user in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name).font(.subheadline.weight(.semibold))
                            if let active = user.lastActivity {
                                Text("Active \(Format.relative(active))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if user.isDisabled == true {
                            StatusBadge(text: "Disabled", health: .unknown)
                        } else if user.isAdministrator == true {
                            StatusBadge(text: "Admin", health: .ok)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func historyCard(_ history: [MediaHistoryEntry]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: instance.kind == .plex ? "Watch History" : "Activity Log", systemImage: "clock.arrow.circlepath")
                if history.isEmpty {
                    Text("Nothing recorded yet.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(history) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if entry.severity != .info {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(entry.severity == .error ? .red : .orange).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline)
                            Text([entry.detail, entry.date.map(Format.relative)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }


    @ViewBuilder
    private func itemsCard(_ title: String, systemImage: String, items: [MediaItem]) -> some View {
        if !items.isEmpty {
            EnveCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: title, systemImage: systemImage)
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            HStack {
                                if let subtitle = item.subtitle?.nilIfEmpty { Text(subtitle) }
                                if let added = item.addedAt { Text("· " + Format.relative(added)) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let progress = item.progress, progress > 0 {
                                UsageBar(fraction: progress, height: 4)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resumeCard(_ snapshot: MediaSnapshot) -> some View {
        if capabilities.resumeNeedsUser {
            EnveCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Continue watching", systemImage: "play.rectangle")
                    if !instance.isSample, !snapshot.users.isEmpty {
                        Picker("User", selection: Binding(get: { instance.mediaUserID }, set: selectUser)) {
                            Text("Choose a user").tag(String?.none)
                            ForEach(snapshot.users) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    }
                    if snapshot.resume.isEmpty {
                        Text(instance.mediaUserID == nil && !instance.isSample ? "Choose whose progress to show." : "Nothing in progress.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.resume) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            if let progress = item.progress { UsageBar(fraction: progress, height: 4) }
                        }
                    }
                }
            }
        } else {
            itemsCard("Continue watching", systemImage: "play.rectangle", items: snapshot.resume)
        }
    }

    private func selectUser(_ id: String?) {
        guard var updated = app.integrations.instance(id: instance.id) else { return }
        updated.mediaUserID = id
        try? app.integrations.save(updated, secret: nil)
        Task { await load() }
    }
}

/// Jellyfin and Emby log files for Owner profiles. Lines are redacted and held in memory only.
struct MediaServerLogsView: View {
    let source: any ServerLogSource
    let serverName: String
    @State private var files = LoadState<[MediaLogFile]>()

    var body: some View {
        List {
            if let list = files.value {
                if list.isEmpty { Text("The server listed no log files.").foregroundStyle(.secondary) }
                ForEach(list) { file in
                    NavigationLink {
                        MediaServerLogFileView(source: source, file: file)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.subheadline.monospaced())
                            Text([file.size.map(Format.bytes), file.modified.map(Format.relative)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let error = files.error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                LoadingStateView(message: "Listing logs…")
            }
        }
        .navigationTitle("Server Logs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .enveScreen()
    }

    private func load() async {
        files.begin()
        let source = source
        files.finish(await captureResult { try await source.logFiles() })
    }
}

private struct MediaServerLogFileView: View {
    let source: any ServerLogSource
    let file: MediaLogFile
    @State private var lines = LoadState<[String]>()
    @State private var problemsOnly = false
    @State private var query = ""

    private var visible: [String] {
        (lines.value ?? []).reversed()
            .filter { !problemsOnly || Self.isProblem($0) }
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    static func isProblem(_ line: String) -> Bool {
        ["[ERR]", "[WRN]", "[FTL]", " Error ", " Warn ", "Exception"].contains { line.contains($0) }
    }

    var body: some View {
        List {
            Section {
                Toggle("Warnings and errors only", isOn: $problemsOnly)
            } footer: {
                Text("The latest 300 lines, newest first. Keys and tokens in the lines are masked; nothing is saved.")
            }
            if let error = lines.error, lines.value == nil {
                ErrorStateView(error: error) { Task { await load() } }
            } else if lines.value == nil {
                LoadingStateView(message: "Reading \(file.name)…")
            } else if visible.isEmpty {
                Text("No lines match.").foregroundStyle(.secondary)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    .foregroundStyle(line.contains("[ERR]") || line.contains("[FTL]") ? Color.red : (line.contains("[WRN]") ? Color.orange : Color.primary))
            }
        }
        .searchable(text: $query, prompt: "Filter lines")
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .enveScreen()
    }

    private func load() async {
        lines.begin()
        let source = source, file = file
        lines.finish(await captureResult { try await source.logLines(file, limit: 300) })
    }
}
