import SwiftUI
import UniformTypeIdentifiers

/// Reads a backup, household or companion file from the Files picker, rejecting anything too large to be one.
enum ConfigurationFile {
    static let maximumSize = 2_000_000

    static func read(_ result: Result<URL, any Error>) throws -> ConfigurationBackup {
        let url = try result.get()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumSize else { throw ConfigurationFileError.tooLarge }
        return try ConfigurationBackup.decode(Data(contentsOf: url))
    }
}

struct PendingImport: Identifiable {
    let id = UUID()
    let backup: ConfigurationBackup
}

enum ConfigurationFileError: Error, LocalizedError {
    case tooLarge
    var errorDescription: String? { "That file is too large to be a Petty: Homelab file." }
}

/// Lists every item in an imported file so the user picks what to add, then walks them through the credentials still needed.
struct ImportReviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let backup: ConfigurationBackup
    @State private var selected: Set<UUID> = []
    @State private var updating: Set<UUID> = []
    @State private var plan: ImportPlan?
    @State private var updatedAddresses = 0
    @State private var result: ConfigurationBackup.ImportResult?
    @State private var isImporting = false
    @State private var editing: ConfigurationBackup.PendingCredential?
    @State private var confirmingViewOnly = false
    @State private var limitToImported = true
    @State private var viewOnlyError: String?

    init(backup: ConfigurationBackup) {
        self.backup = backup
    }

    private var chosen: ConfigurationBackup { backup.selecting(selected) }
    private var changeCount: Int { chosen.itemCount + updating.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(origin).font(.subheadline)
                    if backup.rejected > 0 {
                        Label("\(backup.rejected) unreadable or unsafe entr\(backup.rejected == 1 ? "y was" : "ies were") left out.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let result {
                    resultSections(result)
                } else {
                    itemSections
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import \(changeCount)") { Task { await importChosen() } }
                            .disabled(changeCount == 0 || isImporting)
                    }
                }
            }
            .onAppear {
                guard plan == nil else { return }
                let made = ImportPlan.make(backup, integrations: app.integrations.instances, checks: app.serviceChecks.checks,
                                           serverIDs: Set(app.store.profiles.map(\.id)), hostIDs: Set(app.ssh.hosts.map(\.id)), ruleIDs: Set(app.alerts.rules.map(\.id)))
                plan = made
                selected = made.newIDs
            }
            .sheet(item: $editing) { pending in
                editor(for: pending)
            }
            .confirmationDialog("Switch to View Only?", isPresented: $confirmingViewOnly, titleVisibility: .visible) {
                Button("Switch to View Only") { Task { await switchToViewOnly() } }
            } message: {
                Text(viewOnlyNotice)
            }
        }
    }

    private var title: String {
        switch backup.purpose {
        case .backup: "Restore Backup"
        case .household: "Household Setup"
        case .companion: "Docker Host Import"
        }
    }

    private var origin: String {
        let date = backup.exportedAt.formatted(date: .abbreviated, time: .shortened)
        switch backup.purpose {
        case .backup:
            return "Backup made \(date). Items already on this device are skipped; nothing is replaced."
        case .household:
            return "Shared from another device in your household on \(date). It holds addresses only — no API keys, passwords or SSH hosts. Self-signed certificates aren't trusted from the file: you review each one here when it first connects. Ask for your own limited keys rather than copying theirs."
        case .companion:
            return "Made \(date) by the companion script on your Docker host from its running containers. It holds addresses only; you enter each API key here."
        }
    }

    @ViewBuilder
    private var itemSections: some View {
        if let plan {
            itemSection("Unraid servers", plan.servers)
            itemSection("Integrations", plan.integrations)
            itemSection("Service checks", plan.checks)
            itemSection("SSH hosts", plan.sshHosts)
            itemSection("Notification rules", plan.rules)
            if !plan.keptOnDevice.isEmpty {
                Section {
                    Text(plan.keptOnDevice.joined(separator: ", ")).font(.subheadline)
                } header: {
                    Text("Not in this export")
                } footer: {
                    Text("These are set up for the same host but the export doesn't list them — perhaps the container stopped or was renamed. Importing never removes anything; delete them yourself if they're gone for good.")
                }
            }
            if backup.itemCount == 0 {
                Text("This file has nothing to add.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func itemSection(_ title: String, _ entries: [ImportPlan.Entry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    switch entry.status {
                    case .new:
                        toggle(entry, detail: entry.detail, in: $selected)
                    case .alreadyHere:
                        LabeledContent(entry.name, value: "Already here").foregroundStyle(.secondary)
                    case .sameAs(let name):
                        LabeledContent(entry.name, value: name == entry.name ? "Already set up" : "Already set up as \(name)").foregroundStyle(.secondary)
                    case .moved(let from):
                        toggle(entry, detail: "Update address: \(from.host() ?? ""):\(from.port.map(String.init) ?? "") → \(entry.detail)", in: $updating)
                    }
                }
            }
        }
    }

    private func toggle(_ entry: ImportPlan.Entry, detail: String, in set: Binding<Set<UUID>>) -> some View {
        Toggle(isOn: Binding(get: { set.wrappedValue.contains(entry.id) }, set: { if $0 { set.wrappedValue.insert(entry.id) } else { set.wrappedValue.remove(entry.id) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ result: ConfigurationBackup.ImportResult) -> some View {
        Section {
            LabeledContent("Added", value: "\(result.added)")
            if updatedAddresses > 0 { LabeledContent("Addresses updated", value: "\(updatedAddresses)") }
            if result.skipped > 0 { LabeledContent("Already on this device", value: "\(result.skipped)") }
            if !result.failed.isEmpty {
                Text("Couldn't save: \(result.failed.joined(separator: ", ")). Try importing the file again.").foregroundStyle(.red)
            }
        }
        if !result.needsCredentials.isEmpty {
            Section {
                ForEach(result.needsCredentials) { pending in
                    Button {
                        editing = pending
                    } label: {
                        HStack {
                            Label(pending.name, systemImage: symbol(pending.kind))
                            Spacer()
                            Image(systemName: hasCredential(pending) ? "checkmark.circle.fill" : "key")
                                .foregroundStyle(hasCredential(pending) ? .green : Color.enveAccent)
                                .accessibilityLabel(hasCredential(pending) ? "Credentials saved" : "Needs credentials")
                        }
                    }
                }
            } header: {
                Text("Enter credentials")
            } footer: {
                Text("These can't connect until you add their API key, token or password. Credentials go only into this device's Keychain.")
            }
        }
        if backup.purpose == .household, app.profiles.allowsActions {
            Section {
                Toggle("Show only what this file added", isOn: $limitToImported)
                Button("Switch to View Only…") { confirmingViewOnly = true }
                if let viewOnlyError { Text(viewOnlyError).foregroundStyle(.red) }
            } footer: {
                Text("Optional, once credentials are in. View Only hides every control that changes a server; it's a convenience, not a lock — limited API keys are what actually restrict access.")
            }
        }
    }

    private func symbol(_ kind: ConfigurationBackup.PendingCredential.Kind) -> String {
        switch kind {
        case .server: "server.rack"
        case .integration: "puzzlepiece.extension"
        case .sshHost: "terminal"
        }
    }

    private func hasCredential(_ pending: ConfigurationBackup.PendingCredential) -> Bool {
        switch pending.kind {
        case .server: app.store.profile(id: pending.id).flatMap { try? app.store.apiKey(for: $0) }?.isEmpty == false
        case .integration: app.integrations.instance(id: pending.id).map { app.integrations.hasSecret(for: $0) } ?? false
        case .sshHost: app.ssh.host(id: pending.id).map { app.ssh.hasPassword(for: $0) } ?? false
        }
    }

    @ViewBuilder
    private func editor(for pending: ConfigurationBackup.PendingCredential) -> some View {
        switch pending.kind {
        case .server:
            if let profile = app.store.profile(id: pending.id) { ServerEditorView(profile: profile, hasSavedKey: false) }
        case .integration:
            if let instance = app.integrations.instance(id: pending.id) { IntegrationEditorView(instance: instance) }
        case .sshHost:
            if let host = app.ssh.host(id: pending.id) { SSHHostEditorView(host: host) }
        }
    }

    private var viewerProfile: HouseholdProfile {
        app.profiles.profiles.first { $0.role == .viewer } ?? HouseholdProfile(name: "View Only", role: .viewer)
    }

    private var viewOnlyNotice: String {
        app.profiles.transitionNotice(to: viewerProfile) ?? "This device switches to a View Only profile."
    }

    private func importChosen() async {
        isImporting = true
        let moves = Dictionary(uniqueKeysWithValues: (plan?.all ?? []).filter { updating.contains($0.id) }.compactMap { entry in entry.url.map { (entry.id, $0) } })
        let failedUpdates = app.updateAddresses(moves)
        updatedAddresses = moves.count - failedUpdates.count
        var outcome = await app.restore(chosen)
        outcome.failed += failedUpdates
        result = outcome
        isImporting = false
    }

    private func switchToViewOnly() async {
        do {
            var profile = viewerProfile
            if limitToImported {
                profile.visibleItems = Set((backup.integrations.map(\.id) + backup.serviceChecks.map(\.id)).filter { app.integrations.instance(id: $0) != nil || app.serviceChecks.check(id: $0) != nil })
                profile.showsServers = !backup.servers.isEmpty
            }
            try app.profiles.save(profile)
            try await app.profiles.activate(profile)
            app.publishWidgetSnapshot()
            dismiss()
        } catch {
            viewOnlyError = error.localizedDescription
        }
    }
}
