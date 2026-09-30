import SwiftUI

struct IntegrationDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    let instanceID: UUID
    @State private var editing = false
    @State private var diagnosing = false
    @State private var reviewing: CertificateSummary?
    @State private var trustError: String?

    var body: some View {
        Group {
            if let instance = app.integrationInstance(id: instanceID) {
                if !instance.isEnabled {
                    ContentUnavailableView {
                        Label("\(instance.name) is turned off", systemImage: "power")
                    } description: {
                        Text("Turned-off integrations are never contacted.")
                    } actions: {
                        if allowsActions { Button("Edit") { editing = true } }
                    }
                } else {
                    switch Result(catching: { try app.client(for: instance) }) {
                    case .success(let client):
                        IntegrationScreen(instance: instance, client: client)
                            .id(instance.pinnedCertificateSHA256)
                            .environment(\.connectionRecovery, instance.isSample ? nil : ConnectionRecovery(
                                diagnose: { diagnosing = true },
                                editConnection: { editing = true },
                                reviewCertificate: { reviewing = $0 }
                            ))
                    case .failure(let error):
                        ErrorStateView(error: .from(error), retry: allowsActions ? { editing = true } : nil)
                    }
                }
            } else {
                ContentUnavailableView("Integration removed", systemImage: "xmark.circle")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if app.integrationInstance(id: instanceID)?.isSample == true {
                Label("Sample data (not a real server)", systemImage: "eye")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.enveAccent, in: Capsule())
                    .padding(.bottom, 4)
            }
        }
        .toolbar {
            if let instance = app.integrationInstance(id: instanceID), !instance.isSample, instance.isEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { diagnosing = true } label: { Label("Diagnose", systemImage: "stethoscope") }
                }
            }
            if let instance = app.integrationInstance(id: instanceID), !instance.isSample, allowsActions {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let instance = app.integrations.instance(id: instanceID) {
                IntegrationEditorView(instance: instance)
            }
        }
        .navigationDestination(isPresented: $diagnosing) {
            if let instance = app.integrations.instance(id: instanceID) {
                DiagnosticsView(title: instance.name, url: instance.url, pinnedFingerprint: instance.pinnedCertificateSHA256,
                                authenticate: (try? app.client(for: instance)).map { client in
                                    { @Sendable in let summary = try await client.service.summary(); return "\(summary.product) \(summary.version ?? "") · \(summary.headline)" }
                                })
            }
        }
        .sheet(item: $reviewing) { certificate in
            CertificateReviewView(certificate: certificate, pinnedFingerprint: app.integrations.instance(id: instanceID)?.pinnedCertificateSHA256) {
                guard var instance = app.integrations.instance(id: instanceID) else { return }
                instance.pinnedCertificateSHA256 = certificate.sha256Fingerprint
                instance.pinnedCertificateSubject = certificate.subject
                do {
                    try app.integrations.save(instance, secret: nil)
                } catch {
                    trustError = error.localizedDescription
                }
            }
        }
        .alert("Couldn't save the certificate", isPresented: Binding(get: { trustError != nil }, set: { if !$0 { trustError = nil } })) {
            Button("OK") {}
        } message: {
            Text(trustError ?? "")
        }
        .enveScreen()
    }
}

private struct IntegrationScreen: View {
    let instance: IntegrationInstance
    let client: IntegrationClient

    var body: some View {
        switch client {
        case .arr(let service): ArrView(instance: instance, service: service)
        case .download(let service): DownloadClientView(instance: instance, service: service)
        case .media(let service): MediaServerView(instance: instance, service: service)
        case .proxmox(let service): ProxmoxView(instance: instance, service: service)
        case .portainer(let service): PortainerView(instance: instance, service: service)
        case .truenas(let service): TrueNASView(instance: instance, service: service)
        case .dnsFilter(let service): DNSFilterView(instance: instance, service: service)
        case .unifi(let service): UniFiView(instance: instance, service: service)
        case .tailscale(let service): TailscaleView(instance: instance, service: service)
        case .cloudflare(let service): CloudflareView(instance: instance, service: service)
        case .homeAssistant(let service): HomeAssistantView(instance: instance, service: service)
        case .dashboard(let service): ServiceDashboardView(instance: instance, service: service)
        case .requests(let service): RequestsView(instance: instance, service: service)
        }
    }
}

struct RefreshingScroll<Value, Content: View>: View {
    let state: LoadState<Value>
    let loadingMessage: String
    var interval: Duration = .seconds(15)
    let load: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        ScrollView {
            LoadStateContainer(state: state, loadingMessage: loadingMessage, retry: { Task { await load() } }) { value in
                content(value)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .bottomBarPadding()
        .refreshable { await load() }
        .background {
            Button("Refresh") { Task { await load() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: interval)
            }
        }
    }
}

extension PendingAction {
    static func integration(
        _ instance: IntegrationInstance,
        title: String,
        systemImage: String,
        targetKind: String,
        targetName: String,
        consequence: String,
        destructive: Bool = false,
        typed: Bool = false,
        perform: @escaping @MainActor () async throws -> Void
    ) -> PendingAction {
        PendingAction(
            title: title,
            systemImage: systemImage,
            targetKind: targetKind,
            targetName: targetName,
            serverName: instance.name,
            consequence: consequence,
            isDestructive: destructive,
            requiresTypedConfirmation: typed,
            isPreview: instance.isSample,
            perform: perform
        )
    }
}
