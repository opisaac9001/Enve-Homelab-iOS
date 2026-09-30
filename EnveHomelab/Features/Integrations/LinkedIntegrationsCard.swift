import SwiftUI

struct LinkedIntegrationsCard: View {
    @Environment(AppModel.self) private var app
    let serverID: UUID
    @State private var adding = false

    var body: some View {
        let linked = app.integrations.instances.filter { $0.serverID == serverID }
        EnveCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitle(title: "Integrations", systemImage: "puzzlepiece.extension", trailing: linked.isEmpty ? nil : "\(linked.count)")
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("Add integration for this server")
                }
                .padding(16)
                if linked.isEmpty {
                    Text("Link Plex, Sonarr, qBittorrent or other services running on this server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding([.horizontal, .bottom], 16)
                }
                ForEach(linked) { instance in
                    Divider().padding(.leading, 16)
                    NavigationLink {
                        IntegrationDetailView(instanceID: instance.id)
                    } label: {
                        IntegrationRow(instance: instance)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddConnectionSheet(serverID: serverID)
        }
    }
}
