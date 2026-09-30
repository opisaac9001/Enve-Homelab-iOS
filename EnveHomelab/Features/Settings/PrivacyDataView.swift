import SwiftUI

struct PrivacyDataView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    @State private var erasing = false

    var body: some View {
        List {
            Section {
                LabeledContent("Unraid servers", value: "\(app.store.profiles.count)")
                LabeledContent("Integrations", value: "\(app.integrations.instances.count)")
                LabeledContent("Service checks", value: "\(app.serviceChecks.checks.count)")
                LabeledContent("SSH hosts and keys", value: "\(app.ssh.hosts.count + app.ssh.keys.count)")
                LabeledContent("Alerts in the inbox", value: "\(app.alerts.events.count)")
                LabeledContent("Drive history readings", value: "\(app.diskHistory.samples.values.reduce(0) { $0 + $1.count })")
                LabeledContent("Profiles", value: "\(app.profiles.profiles.count)")
            } header: {
                Text("Stored on this device")
            } footer: {
                Text("Addresses, settings, check history, drive readings, last-known status and alerts are files in the app's private storage. Like other app data they're part of your encrypted device backups.")
            }

            Section("Credentials") {
                Text("API keys, tokens, passwords and SSH private keys live only in the Keychain, marked for this device only: they're never restored onto another device and never included in Enve Homelab backup files. Each one is sent only to the server it belongs to.")
            }

            Section("Widgets and notifications") {
                Text("Widgets read a copy of names and health summaries — no addresses or credentials — from storage shared with the widget extension. Notifications show alert titles; to hide them on the Lock Screen, turn off previews in iOS Settings.")
            }

            Section("What leaves this device") {
                Text("Only requests to the servers and services you add, and to your own ntfy server if you set one up. There's no Enve account, relay, analytics, crash reporting, advertising or tracking.")
            }

            if allowsActions {
                Section {
                    Button("Erase All Data…", role: .destructive) { erasing = true }
                } footer: {
                    Text("Removes every server, integration, check, SSH host and key, alert, profile and home layout, plus all saved credentials. Your servers aren't changed.")
                }
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $erasing) { EraseAllDataSheet() }
        .enveScreen()
    }
}

private struct EraseAllDataSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var failure: String?

    private static let phrase = "ERASE"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This can't be undone", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    Text("Everything Enve Homelab stores on this device is deleted: \(app.store.profiles.count) servers, \(app.integrations.instances.count) integrations, \(app.serviceChecks.checks.count) checks, SSH hosts and keys, alerts, profiles and all Keychain credentials. The app then starts fresh. Export a backup first if you want to restore your setup later; credentials are never in backups.")
                }
                Section {
                    TextField(Self.phrase, text: $typed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type \(Self.phrase) to confirm")
                } footer: {
                    Text("Type \(Self.phrase) to confirm.")
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
                Section {
                    Button("Erase All Data", role: .destructive) {
                        do {
                            try app.eraseAllData()
                        } catch {
                            failure = "Not everything could be erased: \(error.localizedDescription)"
                        }
                    }
                    .disabled(typed != Self.phrase)
                }
            }
            .navigationTitle("Erase All Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
