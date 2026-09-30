import SwiftUI

struct ServerListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    @State private var editorTarget: EditorTarget?
    @State private var deleting: ServerProfile?
    @State private var deletingHost: SSHHost?
    @State private var editingIntegration: IntegrationInstance?
    @State private var deletingIntegration: IntegrationInstance?
    @State private var errorMessage: String?
    @State private var route: HomeRoute?

    enum HomeRoute: Hashable {
        case settings
        case search
        case alerts
    }

    enum EditorTarget: Identifiable {
        case connect
        case new
        case edit(ServerProfile)
        case newService
        case newSSHHost
        case newIntegration
        case discover
        case importFromHost
        case editSSHHost(SSHHost)

        var id: String {
            switch self {
            case .connect: "connect"
            case .new: "new"
            case .edit(let profile): profile.id.uuidString
            case .newService: "new-service"
            case .newSSHHost: "new-ssh"
            case .editSSHHost(let host): "ssh-\(host.id.uuidString)"
            case .newIntegration: "new-integration"
            case .discover: "discover"
            case .importFromHost: "import-host"
            }
        }
    }

    private var loadErrors: [String] {
        [app.store.loadError, app.integrations.loadError, app.serviceChecks.loadError, app.ssh.loadError].compactMap { $0 }
    }

    private var isEmpty: Bool {
        app.visibleServers.isEmpty && app.visibleChecks.isEmpty && app.visibleSSHHosts.isEmpty
            && app.visibleIntegrations.isEmpty && app.visibleSampleInstances.isEmpty
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    home
                } detail: {
                    NavigationStack {
                        ContentUnavailableView("Choose something to open", systemImage: "sidebar.left", description: Text("Servers, integrations, services and terminals open here."))
                            .enveScreen()
                    }
                }
            } else {
                NavigationStack { home }
            }
        }
        .sheet(item: Binding(get: { app.deepLink }, set: { app.deepLink = $0 })) { link in
            NavigationStack {
                Group {
                    switch link {
                    case .alerts: AlertsInboxView()
                    case .upcoming: UpcomingView()
                    case .statistics: StatisticsView()
                    case .integration(let id): IntegrationDetailView(instanceID: id)
                    case .serviceCheck(let id): ServiceDetailView(checkID: id)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { app.deepLink = nil } }
                }
            }
        }
        .modifier(HomeSheets(editorTarget: $editorTarget, deleting: $deleting, deletingHost: $deletingHost, editingIntegration: $editingIntegration, deletingIntegration: $deletingIntegration, errorMessage: $errorMessage))
    }

    private var home: some View {
            Group {
                if isEmpty {
                    welcome
                } else {
                    serverList
                }
            }
            .navigationTitle("Enve Homelab")
            .navigationDestination(item: $route) { route in
                switch route {
                case .settings: SettingsView()
                case .search: UniversalSearchView()
                case .alerts: AlertsInboxView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { route = .settings } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { route = .search } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    Button { route = .alerts } label: {
                        Label("Alerts", systemImage: app.visibleUnreadAlerts > 0 ? "bell.badge.fill" : "bell")
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .accessibilityValue(app.visibleUnreadAlerts > 0 ? "\(app.visibleUnreadAlerts) unread" : "")
                }
                if !isEmpty && allowsActions {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { editorTarget = .connect } label: { Label("Connect by Address", systemImage: "magnifyingglass") }
                            Button { editorTarget = .new } label: { Label("Unraid Server", systemImage: "server.rack") }
                            Button { editorTarget = .newService } label: { Label("Service Check", systemImage: "heart.text.square") }
                            Button { editorTarget = .newSSHHost } label: { Label("SSH Host", systemImage: "terminal") }
                            Button { editorTarget = .newIntegration } label: { Label("Integration", systemImage: "puzzlepiece.extension") }
                            Divider()
                            Button { editorTarget = .discover } label: { Label("Discover on Network…", systemImage: "dot.radiowaves.left.and.right") }
                            Button { editorTarget = .importFromHost } label: { Label("Import from Docker Host…", systemImage: "shippingbox") }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                }
            }
            .enveScreen()
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "server.rack")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(Color.enveAccent.gradient)
                    .padding(.top, 48)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Connect your homelab")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Enter an address to find the right service, or choose one from the list.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 12) {
                    if allowsActions {
                        Button {
                            editorTarget = .connect
                        } label: {
                            Label("Connect to a Server", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        HStack(spacing: 12) {
                            Button {
                                editorTarget = .newService
                            } label: {
                                Label("Service Check", systemImage: "heart.text.square")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                editorTarget = .newSSHHost
                            } label: {
                                Label("SSH Host", systemImage: "terminal")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button {
                            editorTarget = .newIntegration
                        } label: {
                            Label("Browse Integrations", systemImage: "puzzlepiece.extension")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            editorTarget = .importFromHost
                        } label: {
                            Label("Import from Docker Host", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("This View-only profile doesn't include anything yet. An Owner can choose what it shows in Settings › Profiles.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        app.openPreview()
                    } label: {
                        Label("Preview with Sample Data", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                ForEach(loadErrors, id: \.self) { loadError in
                    InlineErrorBanner(error: .unexpectedResponse(loadError))
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var serverList: some View {
        List {
            if !loadErrors.isEmpty {
                Section {
                    ForEach(loadErrors, id: \.self) { Text($0) }
                } header: {
                    Label("Some saved data couldn't be read", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if app.profiles.active.role == .viewer {
                Section {
                    NavigationLink {
                        ProfilesView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Viewing as \(app.profiles.active.name)").font(.subheadline.weight(.semibold))
                                Text(app.profiles.active.isLimited ? "View only · showing chosen items" : "View only · nothing here can be changed")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "eye").foregroundStyle(Color.enveAccent)
                        }
                    }
                    .accessibilityHint("Opens profiles to switch")
                }
            }

            if app.isOffline {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Offline — showing last known data").font(.subheadline.weight(.semibold))
                            Text("Checks and refreshes pause until this device reconnects, so a lost connection never raises alerts.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi.slash").foregroundStyle(Color.enveAccent)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            ForEach(app.preferences.visibleSections) { section in
                homeSection(section)
            }
        }
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSection) -> some View {
        switch section {
        case .overview: HomeOverviewSection()
        case .pinned: PinnedSection()
        case .servers: serversSection
        case .integrations: IntegrationSections(editing: $editingIntegration, deleting: $deletingIntegration)
        case .services: servicesSection
        case .terminal: terminalSection
        case .preview: previewSection
        }
    }

    @ViewBuilder
    private var serversSection: some View {
        if !app.visibleServers.isEmpty {
            Section("Servers") {
                ForEach(app.visibleServers) { profile in
                    Button {
                        app.open(profile)
                    } label: {
                        ServerRow(profile: profile)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        if allowsActions {
                            Button("Remove", role: .destructive) { deleting = profile }
                            Button("Edit") { editorTarget = .edit(profile) }
                                .tint(.enveAccent)
                        }
                    }
                    .contextMenu {
                        if allowsActions {
                            Button {
                                editorTarget = .edit(profile)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleting = profile
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .onMove(perform: allowsActions ? { source, destination in
                    do {
                        try app.store.move(from: source, to: destination)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } : nil)
            }
        }

    }

    @ViewBuilder
    private var servicesSection: some View {
        if !app.visibleChecks.isEmpty {
            Section {
                ForEach(app.visibleChecks) { check in
                    NavigationLink {
                        ServiceDetailView(checkID: check.id)
                    } label: {
                        ServiceCheckRow(check: check, result: app.serviceHealth.latest(for: check.id), isChecking: app.serviceHealth.inFlight.contains(check.id))
                    }
                    .contextMenu { PinButton(item: .serviceCheck(check.id)) }
                }
            } header: {
                Text("Services")
            }
        }

    }

    @ViewBuilder
    private var terminalSection: some View {
        Section {
            ForEach(app.visibleSSHHosts) { host in
                NavigationLink {
                    TerminalScreen(hostID: host.id)
                } label: {
                    SSHHostRow(host: host)
                }
                .swipeActions(edge: .trailing) {
                    if allowsActions {
                        Button("Remove", role: .destructive) { deletingHost = host }
                        Button("Edit") { editorTarget = .editSSHHost(host) }
                            .tint(.enveAccent)
                    }
                }
                .contextMenu {
                    if allowsActions {
                        Button { editorTarget = .editSSHHost(host) } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { deletingHost = host } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }
            if allowsActions {
                NavigationLink {
                    SSHKeysView()
                } label: {
                    Label("SSH Keys", systemImage: "key.fill")
                }
            }
        } header: {
            Text("Terminal")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            Button {
                app.openPreview()
            } label: {
                Label("Preview with Sample Data", systemImage: "eye")
            }
        } footer: {
            Text("Preview mode uses built-in sample data and never contacts a server.")
        }
    }
}

struct SSHHostRow: View {
    let host: SSHHost

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.title3)
                .foregroundStyle(Color.enveAccent)
                .frame(width: 40, height: 40)
                .background(Color.enveAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name).font(.headline)
                Text("\(host.username)@\(host.address)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if host.knownHostKey == nil {
                Image(systemName: "key.viewfinder")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Host key not yet reviewed")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens a terminal session")
    }
}

private struct ServerRow: View {
    let profile: ServerProfile

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(Color.enveAccent)
                .frame(width: 40, height: 40)
                .background(Color.enveAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.headline)
                Text(profile.endpoints.compactMap { $0.url.host() }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(profile.provider.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects to this server")
    }
}

private struct HomeSheets: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var editorTarget: ServerListView.EditorTarget?
    @Binding var deleting: ServerProfile?
    @Binding var deletingHost: SSHHost?
    @Binding var editingIntegration: IntegrationInstance?
    @Binding var deletingIntegration: IntegrationInstance?
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content
        .sheet(item: $editorTarget) { target in
            switch target {
            case .connect:
                AddConnectionSheet()
            case .new:
                ServerEditorView(profile: nil, hasSavedKey: false)
            case .edit(let profile):
                ServerEditorView(profile: profile, hasSavedKey: (try? app.store.apiKey(for: profile)) != nil)
            case .newService:
                ServiceEditorView(check: nil)
            case .newSSHHost:
                SSHHostEditorView(host: nil)
            case .editSSHHost(let host):
                SSHHostEditorView(host: host)
            case .newIntegration:
                AddIntegrationSheet()
            case .discover:
                NavigationStack { DiscoveryView() }
            case .importFromHost:
                NavigationStack { CompanionImportView() }
            }
        }
        .confirmationDialog(
            "Remove \(deletingHost?.name ?? "host")?",
            isPresented: Binding(get: { deletingHost != nil }, set: { if !$0 { deletingHost = nil } }),
            titleVisibility: .visible,
            presenting: deletingHost
        ) { host in
            Button("Remove Host", role: .destructive) {
                do {
                    try app.ssh.delete(host)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { host in
            Text("\(host.name)'s saved password, trusted host key, and saved commands are deleted from this device.")
        }
        .confirmationDialog(
            "Remove \(deleting?.name ?? "server")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { profile in
            Button("Remove Server", role: .destructive) {
                do {
                    try app.store.delete(profile)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { profile in
            Text("\(profile.name)'s addresses, trusted certificates, and the API key saved on this device are deleted. Nothing changes on the server.")
        }
        .sheet(item: $editingIntegration) { instance in
            IntegrationEditorView(instance: instance)
        }
        .confirmationDialog(
            "Remove \(deletingIntegration?.name ?? "integration")?",
            isPresented: Binding(get: { deletingIntegration != nil }, set: { if !$0 { deletingIntegration = nil } }),
            titleVisibility: .visible,
            presenting: deletingIntegration
        ) { instance in
            Button("Remove Integration", role: .destructive) {
                do {
                    try app.integrations.delete(instance)
                    app.integrationStatus.forget(instance.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { instance in
            Text("\(instance.name)'s address, trusted certificate and saved credentials are deleted from this device. Nothing changes on the server.")
        }
        .alert("Couldn't update servers", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// Last-known health across everything on this device; it reads cached results and never triggers requests.
private struct HomeOverviewSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let checkResults = app.visibleChecks.compactMap { app.serviceHealth.latest(for: $0.id) }
        let checkProblems = checkResults.filter { $0.health() >= .warning }.count
        let summaries = app.visibleIntegrations.filter(\.isEnabled).map { app.integrationStatus.state(for: $0.id) }
        let integrationProblems = summaries.filter { ($0.value?.health ?? .ok) >= .warning || $0.error != nil }.count
        if !checkResults.isEmpty || !summaries.isEmpty || app.visibleUnreadAlerts > 0 {
            Section {
                HStack(spacing: 12) {
                    tile("Services", value: checkResults.isEmpty ? "—" : "\(checkResults.count - checkProblems)/\(checkResults.count)", problems: checkProblems)
                    tile("Healthy connections", value: summaries.isEmpty ? "—" : "\(summaries.count - integrationProblems)/\(summaries.count)", problems: integrationProblems)
                    NavigationLink {
                        AlertsInboxView()
                    } label: {
                        tile("Unread alerts", value: "\(app.visibleUnreadAlerts)", problems: app.visibleUnreadAlerts)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func tile(_ title: String, value: String, problems: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if problems > 0 {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).padding(8).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(problems > 0 ? "\(value), \(problems) need attention" : value)
    }
}

/// Integrations and service checks the user pinned to the top of home.
private struct PinnedSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let pins = app.preferences.pinned { item in
            switch item {
            case .integration(let id): app.integrationInstance(id: id) != nil && app.profiles.active.shows(id)
            case .serviceCheck(let id): app.serviceChecks.check(id: id) != nil && app.profiles.active.shows(id)
            }
        }
        if !pins.isEmpty {
            Section {
                ForEach(pins, id: \.self) { item in
                    switch item {
                    case .integration(let id):
                        if let instance = app.integrationInstance(id: id) {
                            NavigationLink { IntegrationDetailView(instanceID: id) } label: { IntegrationRow(instance: instance) }
                                .contextMenu { PinButton(item: item) }
                        }
                    case .serviceCheck(let id):
                        if let check = app.serviceChecks.check(id: id) {
                            NavigationLink { ServiceDetailView(checkID: id) } label: {
                                ServiceCheckRow(check: check, result: app.serviceHealth.latest(for: id), isChecking: app.serviceHealth.inFlight.contains(id))
                            }
                            .contextMenu { PinButton(item: item) }
                        }
                    }
                }
                .onMove { app.preferences.movePins(from: $0, to: $1) }
            } header: {
                Label("Pinned", systemImage: "pin.fill")
            }
        }
    }
}

/// Pinning changes only this device's home layout, so view-only profiles can use it too.
struct PinButton: View {
    @Environment(AppModel.self) private var app
    let item: PinnedItem

    var body: some View {
        let pinned = app.preferences.isPinned(item)
        Button { app.preferences.togglePin(item) } label: {
            Label(pinned ? "Unpin from Home" : "Pin to Home", systemImage: pinned ? "pin.slash" : "pin")
        }
    }
}
