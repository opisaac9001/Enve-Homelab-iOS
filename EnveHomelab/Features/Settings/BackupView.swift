import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    @Environment(AppModel.self) private var app
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?
    @State private var reviewing: PendingImport?

    var body: some View {
        Form {
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share Backup File", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        prepareExport()
                    } label: {
                        Label("Create Backup", systemImage: "archivebox")
                    }
                }
            } footer: {
                Text("Includes servers, integrations, service checks, SSH hosts, saved commands, trusted certificate fingerprints and notification rules. API keys, passwords, tokens and private keys are never included — you'll re-enter them after restoring.")
            }

            Section {
                NavigationLink {
                    HouseholdShareView()
                } label: {
                    Label("Share with Household", systemImage: "person.2")
                }
            } footer: {
                Text("Hand a trimmed copy of your setup to someone else's device — addresses only, never your credentials or SSH hosts.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import a File…", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Backups, household files and Docker host exports. You choose which items to add; nothing already on this device is replaced or deleted.")
            }

            if let message {
                Section { Text(message) }
            }
        }
        .navigationTitle("Backup & Sharing")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                reviewing = PendingImport(backup: try ConfigurationFile.read(result))
            } catch {
                message = "That file isn't a readable Petty: Homelab file. \(error.localizedDescription)"
            }
        }
        .sheet(item: $reviewing) { ImportReviewView(backup: $0.backup) }
        .enveScreen()
    }

    private func prepareExport() {
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: "Petty Homelab Backup \(Date.now.formatted(.iso8601.year().month().day())).json")
            try app.makeBackup().encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            exportURL = url
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Builds a household file on this device and hands it to the share sheet (AirDrop, Messages, Files); nothing passes through a server.
struct HouseholdShareView: View {
    @Environment(AppModel.self) private var app
    @State private var selected: Set<UUID> = []
    @State private var shareURL: URL?
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Text("The file lists the servers, integrations and checks you pick, with their addresses and any certificate fingerprints you've trusted. It never contains API keys, passwords, tokens, SSH hosts or notification rules.")
                Text("On their device, they import it from Settings › Backup & Sharing, enter their own credentials and can switch to View Only. Give them limited keys — for example a Jellyfin user rather than an administrator, or a Proxmox PVEAuditor token — because View Only is a convenience, not a lock.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            choices("Unraid servers", app.store.profiles.map { ($0.id, $0.name) })
            choices("Integrations", app.integrations.instances.map { ($0.id, "\($0.name) · \($0.kind.displayName)") })
            choices("Service checks", app.serviceChecks.checks.map { ($0.id, $0.name) })

            Section {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share Household File", systemImage: "square.and.arrow.up")
                    }
                }
                Button(shareURL == nil ? "Create Household File" : "Create Again") { create() }
                    .disabled(selected.isEmpty)
                if let failure { Text(failure).foregroundStyle(.red) }
            } footer: {
                Text("\(selected.count) item\(selected.count == 1 ? "" : "s") selected.")
            }
        }
        .navigationTitle("Share with Household")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selected) { shareURL = nil }
        .enveScreen()
    }

    @ViewBuilder
    private func choices(_ title: String, _ items: [(id: UUID, name: String)]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.id) { item in
                    Toggle(item.name, isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                }
            }
        }
    }

    private func create() {
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: "Petty Homelab Household \(Date.now.formatted(.iso8601.year().month().day())).json")
            try app.makeHouseholdShare(including: selected).encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            shareURL = url
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
