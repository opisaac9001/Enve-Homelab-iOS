import SwiftUI

struct SettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme.selectedTheme) {
                    ForEach(ThemeManager.AppTheme.allCases) { Text($0.title).tag($0) }
                }
                NavigationLink {
                    HomeCustomizationView()
                } label: {
                    Label("Home & Tabs", systemImage: "square.grid.2x2")
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("True Black uses pure black backgrounds, which saves power on OLED displays. The orange accent and background stay the same in every theme.")
            }

            Section {
                NavigationLink {
                    ProfilesView()
                } label: {
                    LabeledContent("Profile", value: "\(app.profiles.active.name) · \(app.profiles.active.role.title)")
                }
                if app.profiles.allowsActions {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                }
                NavigationLink {
                    TrustHelpView()
                } label: {
                    Label("Trust & Security", systemImage: "lock.shield")
                }
                NavigationLink {
                    PrivacyDataView()
                } label: {
                    Label("Privacy & Data", systemImage: "hand.raised")
                }
                if app.profiles.allowsActions {
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label("Backup & Sharing", systemImage: "archivebox")
                    }
                }
            }

            Section {
                Toggle("Show sample integrations", isOn: Binding(get: { app.showsSampleIntegrations }, set: { app.showsSampleIntegrations = $0 }))
            } header: {
                Text("Sample data")
            } footer: {
                Text("Adds one clearly labelled sample of every integration to the home screen so you can explore them without a server. Samples never contact the network.")
            }

            Section {
                LabeledValue(label: "Version", value: Bundle.main.versionDescription)
            } header: {
                Text("About")
            } footer: {
                Text("Enve Homelab is free and open source. It has no accounts, analytics, or tracking, and only talks to servers you add.")
            }
        }
        .bottomBarPadding()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
    }
}

private extension Bundle {
    var versionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
