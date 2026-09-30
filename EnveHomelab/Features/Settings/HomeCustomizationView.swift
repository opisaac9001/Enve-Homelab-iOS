import SwiftUI

struct HomeCustomizationView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingReset = false

    var body: some View {
        let preferences = app.preferences
        List {
            Section {
                ForEach(preferences.snapshot.sectionOrder) { section in
                    Toggle(isOn: Binding(get: { !preferences.snapshot.hiddenSections.contains(section) }, set: { preferences.setHidden(section, !$0) })) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
                .onMove { preferences.moveSections(from: $0, to: $1) }
            } header: {
                Text("Home sections")
            } footer: {
                Text("Drag to reorder. Hidden sections keep their data; they just aren't shown on home. Empty sections never appear.")
            }

            Section {
                let pins = preferences.snapshot.pinned
                if pins.isEmpty {
                    Text("Touch and hold an integration or service check on home, then choose Pin to Home.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(pins, id: \.self) { item in
                    Text(name(item))
                }
                .onMove { preferences.movePins(from: $0, to: $1) }
                .onDelete { offsets in offsets.map { pins[$0] }.forEach(preferences.togglePin) }
            } header: {
                Text("Pinned")
            }

            Section {
                ForEach(preferences.tabOrder) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .onMove { preferences.moveTabs(from: $0, to: $1) }
            } header: {
                Text("Unraid server tabs")
            } footer: {
                Text("The order of the tab bar (iPhone) or sidebar (iPad and Mac) inside an Unraid server.")
            }

            Section {
                Button("Restore Default Layout", role: .destructive) { confirmingReset = true }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Home & Tabs")
        .confirmationDialog("Restore the default layout?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { preferences.reset() }
        } message: {
            Text("Section order, hidden sections, pins and tab order go back to their defaults. Servers, integrations and settings aren't affected.")
        }
        .enveScreen()
    }

    private func name(_ item: PinnedItem) -> String {
        switch item {
        case .integration(let id): app.integrationInstance(id: id)?.name ?? "Removed integration"
        case .serviceCheck(let id): app.serviceChecks.check(id: id)?.name ?? "Removed service check"
        }
    }
}
