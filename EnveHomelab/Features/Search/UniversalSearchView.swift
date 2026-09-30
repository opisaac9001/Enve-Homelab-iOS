import SwiftUI

/// Searches everything stored on this device plus the latest known status; it never contacts servers.
struct UniversalSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    @State private var query = ""

    private func matches(_ values: String?...) -> Bool {
        !query.isEmpty && values.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    var body: some View {
        List {
            if query.isEmpty {
                ContentUnavailableView("Search your homelab", systemImage: "magnifyingglass", description: Text("Find servers, integrations, service checks, SSH hosts, saved commands and alerts."))
                    .listRowBackground(Color.clear)
            } else {
                let servers = app.visibleServers.filter { profile in matches(profile.name, profile.endpoints.compactMap { $0.url.host() }.joined(separator: " ")) }
                let integrations = (app.visibleIntegrations + app.visibleSampleInstances).filter {
                    matches($0.name, $0.kind.displayName, $0.url.host(), app.integrationStatus.state(for: $0.id).value?.headline)
                }
                let checks = app.visibleChecks.filter { matches($0.name, $0.url.absoluteString, app.serviceHealth.latest(for: $0.id)?.summary) }
                let hosts = app.visibleSSHHosts.filter { matches($0.name, $0.host, $0.username) }
                let commands = app.visibleSSHHosts.flatMap { host in host.savedCommands.filter { matches($0.name, $0.command) }.map { (host, $0) } }
                let alerts = app.alerts.events.filter { app.isVisible($0) && $0.matches(query) }.prefix(25)

                if servers.isEmpty && integrations.isEmpty && checks.isEmpty && hosts.isEmpty && commands.isEmpty && alerts.isEmpty {
                    ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                }
                if !servers.isEmpty {
                    Section("Servers") {
                        ForEach(servers) { profile in
                            Button { app.open(profile) } label: { Label(profile.name, systemImage: "server.rack") }
                        }
                    }
                }
                if !integrations.isEmpty {
                    Section("Integrations") {
                        ForEach(integrations) { instance in
                            NavigationLink { IntegrationDetailView(instanceID: instance.id) } label: { IntegrationRow(instance: instance) }
                        }
                    }
                }
                if !checks.isEmpty {
                    Section("Service checks") {
                        ForEach(checks) { check in
                            NavigationLink { ServiceDetailView(checkID: check.id) } label: {
                                ServiceCheckRow(check: check, result: app.serviceHealth.latest(for: check.id), isChecking: false)
                            }
                        }
                    }
                }
                if !hosts.isEmpty {
                    Section("SSH hosts") {
                        ForEach(hosts) { host in
                            NavigationLink { TerminalScreen(hostID: host.id) } label: { SSHHostRow(host: host) }
                                .disabled(!allowsActions)
                        }
                    }
                }
                if !commands.isEmpty {
                    Section("Saved commands") {
                        ForEach(commands, id: \.1.id) { host, command in
                            NavigationLink { TerminalScreen(hostID: host.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    SavedCommandRow(command: command)
                                    Text("on \(host.name)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .disabled(!allowsActions)
                        }
                    }
                }
                if !alerts.isEmpty {
                    Section("Alerts") {
                        ForEach(Array(alerts)) { AlertEventRow(event: $0) }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Servers, services, commands, alerts…")
        .navigationTitle("Search")
        .bottomBarPadding()
        .enveScreen()
    }
}
