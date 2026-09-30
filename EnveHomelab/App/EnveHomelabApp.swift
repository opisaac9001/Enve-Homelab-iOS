import BackgroundTasks
import SwiftUI

@main
struct EnveHomelabApp: App {
    @State private var appModel = AppModel()
    @StateObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(ObjectIdentifier(appModel))
                .environment(appModel)
                .environment(\.allowsActions, appModel.profiles.allowsActions)
                .onOpenURL { url in
                    guard let link = DeepLink(url: url), appModel.isVisible(link) else { return }
                    appModel.close()
                    appModel.deepLink = link
                }
                .tint(.enveAccent)
                .preferredColorScheme(theme.preferredColorScheme)
                .task(id: LoopID(isActive: scenePhase == .active, model: ObjectIdentifier(appModel))) {
                    guard scenePhase == .active else { return }
                    await appModel.runServiceHealth()
                }
                .task(id: LoopID(isActive: scenePhase == .active, model: ObjectIdentifier(appModel))) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await appModel.alerts.pollNtfy()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                .onChange(of: appModel.isErased) { _, erased in
                    if erased { appModel = AppModel() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Self.scheduleRefresh() }
                }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskIdentifier)) { [appModel] in
            Self.scheduleRefresh()
            await appModel.refreshEverything()
        }
    }

    /// Restarts the foreground loops when the app becomes active or starts over after an erase.
    private struct LoopID: Hashable {
        let isActive: Bool
        let model: ObjectIdentifier
    }

    /// iOS decides when (and whether) the refresh actually runs.
    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTaskIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
