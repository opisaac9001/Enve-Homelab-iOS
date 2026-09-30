import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: HouseholdProfile?
    @State private var errorMessage: String?
    @State private var switching: HouseholdProfile?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("How profiles work", systemImage: "person.2.badge.gearshape").font(.subheadline.weight(.semibold))
                    Text("Give family members a View-only profile so they can check whether things are up without being able to stop, restart or change anything. Profiles live only on this device; there's no account and nothing syncs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Section {
                ForEach(app.profiles.profiles) { profile in
                    Button {
                        if app.profiles.transitionNotice(to: profile) != nil {
                            switching = profile
                        } else {
                            activate(profile)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.body.weight(.semibold))
                                Text(profile.role.title + (profile.isLimited ? " · limited" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == app.profiles.activeID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.enveAccent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityValue(profile.id == app.profiles.activeID ? "Active" : "")
                    .accessibilityHint("Switches to this profile")
                    .swipeActions {
                        if app.profiles.allowsActions {
                            Button("Delete", role: .destructive) { delete(profile) }
                            Button("Edit") { editing = profile }.tint(.enveAccent)
                        }
                    }
                }
                if app.profiles.allowsActions {
                    Button {
                        editing = HouseholdProfile(name: "", role: .viewer)
                    } label: {
                        Label("Add Profile", systemImage: "person.badge.plus")
                    }
                }
            } header: {
                Text("Profiles on this device")
            } footer: {
                Text("Profiles stay on this device. There are no accounts, and nothing is shared or synced. A View-only profile sees status but can't run actions, open terminals or edit connections.")
            }

            if app.profiles.allowsActions {
                Section {
                    Toggle("Require Face ID or passcode", isOn: Binding(get: { app.profiles.requireAuthenticationForOwner }, set: { value in
                        Task {
                            do {
                                try await app.profiles.setRequireAuthentication(value)
                                errorMessage = nil
                            } catch {
                                errorMessage = "Not turned on: this device couldn't confirm Face ID, Touch ID or the passcode."
                            }
                        }
                    }))
                } footer: {
                    Text("Asks for device authentication before switching into an Owner profile, so a family member using the View-only profile can't simply switch back.")
                }
                if app.profiles.viewerProtectionMissing {
                    Section {
                        Label("A View-only profile exists, but anyone can switch back to an Owner profile without authenticating.", systemImage: "exclamationmark.shield")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Profiles")
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile)
        }
        .confirmationDialog("Switch to \(switching?.name ?? "")?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
                            titleVisibility: .visible, presenting: switching) { profile in
            Button("Switch to View Only") { activate(profile) }
        } message: { profile in
            Text(app.profiles.transitionNotice(to: profile) ?? "")
        }
        .enveScreen()
    }

    private func activate(_ profile: HouseholdProfile) {
        Task {
            do {
                try await app.profiles.activate(profile)
                app.publishWidgetSnapshot()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ profile: HouseholdProfile) {
        do {
            try app.profiles.delete(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProfileEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var profile: HouseholdProfile
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $profile.name)
                Picker("Role", selection: $profile.role) {
                    ForEach(ProfileRole.allCases) { Text($0.title).tag($0) }
                }
                Section { Text(profile.role.summary).font(.footnote).foregroundStyle(.secondary) }
                if profile.role == .viewer { visibility }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(profile.name.isEmpty ? "New Profile" : profile.name)
            .onChange(of: profile.role) { if profile.role == .owner { profile.visibleItems = nil; profile.showsServers = true } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try app.profiles.save(profile)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var groups: [(title: String, items: [(id: UUID, name: String, detail: String)])] {
        let integrations = app.integrations.instances + app.sampleInstances
        var groups = IntegrationCategory.allCases.compactMap { category -> (String, [(UUID, String, String)])? in
            let members = integrations.filter { $0.kind.category == category }
            return members.isEmpty ? nil : (category.title, members.map { ($0.id, $0.name, $0.kind.displayName + ($0.isSample ? " · sample" : "")) })
        }
        if !app.serviceChecks.checks.isEmpty {
            groups.append(("Service checks", app.serviceChecks.checks.map { ($0.id, $0.name, $0.url.host() ?? "") }))
        }
        return groups
    }

    private func setAll(_ ids: [UUID], visible: Bool) {
        if visible { profile.visibleItems?.formUnion(ids) } else { profile.visibleItems?.subtract(ids) }
    }

    @ViewBuilder
    private var visibility: some View {
        Section {
            Toggle("Unraid servers and SSH hosts", isOn: $profile.showsServers)
            Toggle("Every integration and check", isOn: Binding(get: { profile.visibleItems == nil }, set: { profile.visibleItems = $0 ? nil : [] }))
        } header: {
            Text("What this profile sees")
        } footer: {
            Text("Hidden items don't appear on home, in search, the Schedule, Statistics, the alert inbox or the widgets while this profile is active. This keeps the view simple for family members; it isn't a security boundary — credentials stay on this device, so use limited API keys for real restrictions.")
        }
        if profile.visibleItems != nil {
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.items, id: \.id) { item in
                        Toggle(isOn: Binding(get: { profile.visibleItems?.contains(item.id) ?? true },
                                             set: { if $0 { profile.visibleItems?.insert(item.id) } else { profile.visibleItems?.remove(item.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        let ids = group.items.map(\.id)
                        let allShown = ids.allSatisfy { profile.visibleItems?.contains($0) ?? true }
                        Button(allShown ? "Hide All" : "Show All") { setAll(ids, visible: !allShown) }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                            .accessibilityLabel("\(allShown ? "Hide" : "Show") all \(group.title)")
                    }
                }
            }
        }
    }
}
