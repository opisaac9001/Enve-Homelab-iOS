import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let session = app.session {
                ServerShellView(session: session)
            } else {
                ServerListView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.session == nil)
    }
}

struct ServerShellView: View {
    @Environment(AppModel.self) private var app
    let session: ServerSession

    var body: some View {
        switch session.phase {
        case .connecting:
            ConnectingView(serverName: session.displayName) { app.close() }
        case .failed(let failure):
            ConnectionFailureView(session: session, failure: failure)
        case .connected(let context):
            MainTabsView(context: context)
        }
    }
}

private struct ConnectingView: View {
    let serverName: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(serverName)…")
                .font(.headline)
            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .enveScreen()
    }
}

enum AppTab: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case overview, storage, docker, vms, alerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .storage: "Storage"
        case .docker: "Docker"
        case .vms: "VMs"
        case .alerts: "Alerts"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .storage: "externaldrive.fill"
        case .docker: "shippingbox.fill"
        case .vms: "desktopcomputer"
        case .alerts: "bell.fill"
        }
    }
}

struct MainTabsView: View {
    @Environment(AppModel.self) private var app
    let context: ServerContext
    @State private var selection: AppTab = .overview
    @State private var unreadAlerts = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(app.preferences.tabOrder, selection: sidebarSelection) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .badge(tab == .alerts ? unreadAlerts : 0)
                            .tag(tab)
                    }
                    .navigationTitle(context.serverName)
                    .safeAreaInset(edge: .bottom) {
                        if context.isPreview { PreviewBanner().padding() }
                    }
                } detail: {
                    content(for: selection)
                }
            } else {
                content(for: selection)
                    .environment(\.bottomBarInset, context.isPreview ? 110 : 76)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            if context.isPreview {
                                PreviewBanner().allowsHitTesting(false)
                            }
                            PillTabBar(
                                tabs: app.preferences.tabOrder,
                                selection: $selection,
                                title: \.title,
                                systemImage: \.systemImage,
                                badge: { $0 == .alerts ? unreadAlerts : 0 }
                            )
                        }
                        .padding(.bottom, 4)
                    }
            }
        }
        .task(id: selection) {
            if let overview = try? await context.service.notificationOverview() {
                unreadAlerts = overview.unread.alert + overview.unread.warning
            }
        }
    }

    private var sidebarSelection: Binding<AppTab?> {
        Binding(get: { selection }, set: { if let value = $0 { selection = value } })
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .overview: DashboardView(context: context) { selection = $0 }
        case .storage: StorageView(context: context)
        case .docker: ContainerListView(context: context)
        case .vms: VMListView(context: context)
        case .alerts: NotificationsView(context: context)
        }
    }
}

struct ServerSwitcherButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.close()
        } label: {
            Label("Servers", systemImage: "server.rack")
        }
        .accessibilityHint("Disconnects and returns to your saved servers")
    }
}
