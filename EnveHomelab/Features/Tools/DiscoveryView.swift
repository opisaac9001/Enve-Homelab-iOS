import SwiftUI

struct DiscoveryView: View {
    @State private var discovery = LocalDiscovery()
    @State private var adding: DiscoveredService?

    var body: some View {
        List {
            Section {
                if discovery.services.isEmpty {
                    HStack(spacing: 12) {
                        if discovery.isRunning { ProgressView() }
                        Text(discovery.isRunning ? "Looking for services that advertise themselves on this network…" : "Discovery stopped.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(discovery.services) { service in
                    Button {
                        adding = service
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: service.type.systemImage)
                                .foregroundStyle(Color.enveAccent)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name).font(.body.weight(.semibold))
                                Text("\(service.type.title) · \(service.host):\(service.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(service.type.suggestion).font(.caption).foregroundStyle(Color.enveAccent)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint(service.type.suggestion)
                }
            } footer: {
                Text("Uses Bonjour (mDNS) on your local network to find SSH servers, Home Assistant and web services that announce themselves. Nothing is scanned or contacted beyond resolving each announcement, and results aren't saved unless you add them.")
            }
            if let failure = discovery.failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Discover")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(discovery.isRunning ? "Stop" : "Scan Again") {
                    discovery.isRunning ? discovery.stop() : discovery.start()
                }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(item: $adding) { service in
            editor(for: service)
        }
        .enveScreen()
    }

    @ViewBuilder
    private func editor(for service: DiscoveredService) -> some View {
        switch service.type {
        case .ssh:
            SSHHostEditorView(host: nil, prefill: SSHHost(name: service.name, host: service.host, port: service.port, username: ""))
        case .homeAssistant:
            if let url = service.url {
                NavigationStack {
                    IntegrationEditorForm(original: nil, kind: .homeassistant, serverID: nil, prefill: IntegrationInstance(kind: .homeassistant, name: service.name, url: url))
                }
            }
        case .http, .https:
            if let url = service.url {
                ServiceEditorView(check: nil, prefill: ServiceCheck(name: service.name, url: url))
            }
        }
    }
}
