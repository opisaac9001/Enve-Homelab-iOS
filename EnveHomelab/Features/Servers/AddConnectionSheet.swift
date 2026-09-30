import SwiftUI

struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isProbing = false
    @State private var errorMessage: String?
    @State private var reachableURL: URL?
    @State private var trustedCertificate: CertificateSummary?
    @State private var reviewing: ReviewRequest?
    @State private var retryAfterReview = false
    @State private var destination: Destination?
    @State private var showingManual = false
    @State private var didSave = false
    @State private var probeTask: Task<Void, Never>?
    @State private var probeID = UUID()

    var serverID: UUID?

    private struct Destination: Identifiable {
        let id = UUID()
        let service: ConnectionProbe.Service
        let url: URL?
        let certificate: CertificateSummary?
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://server.example.com or 100.64.0.1", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                    Button {
                        startProbe()
                    } label: {
                        HStack {
                            Label("Find Service", systemImage: "magnifyingglass")
                            Spacer()
                            if isProbing { ProgressView() }
                        }
                    }
                    .disabled(isProbing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Server address")
                } footer: {
                    Text("Include the port if needed. An address without http:// or https:// tries HTTPS first.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        probeTask?.cancel()
                        showingManual = true
                    } label: {
                        Label("Choose a Service Manually", systemImage: "list.bullet")
                    }
                } footer: {
                    Text("Choose manually if the service needs a sign-in before it can be identified.")
                }
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingManual) { manualList }
        }
        .onChange(of: address) {
            probeTask?.cancel()
            probeID = UUID()
            isProbing = false
            reachableURL = nil
            trustedCertificate = nil
            errorMessage = nil
        }
        .onDisappear { probeTask?.cancel() }
        .sheet(item: $reviewing, onDismiss: {
            if retryAfterReview {
                retryAfterReview = false
                startProbe()
            }
        }) { request in
            CertificateReviewView(certificate: request.certificate, pinnedFingerprint: request.pinnedFingerprint) {
                trustedCertificate = request.certificate
                retryAfterReview = true
            }
        }
        .sheet(item: $destination, onDismiss: {
            if didSave { dismiss() }
        }) { selected in
            switch selected.service {
            case .unraid:
                ServerEditorView(profile: nil, hasSavedKey: false, prefill: serverPrefill(selected)) { _ in
                    didSave = true
                    destination = nil
                }
            case .integration(let kind):
                NavigationStack {
                    IntegrationEditorForm(original: nil, kind: kind, serverID: serverID, prefill: integrationPrefill(selected)) {
                        didSave = true
                        destination = nil
                    }
                }
            }
        }
    }

    private var manualList: some View {
        List {
            Section("Servers") {
                Button {
                    select(.unraid)
                } label: {
                    Label("Unraid", systemImage: "server.rack")
                }
            }
            ForEach(IntegrationCategory.allCases) { category in
                Section(category.title) {
                    ForEach(IntegrationKind.allCases.filter { $0.category == category }) { kind in
                        Button {
                            select(.integration(kind))
                        } label: {
                            Label(kind.displayName, systemImage: kind.systemImage)
                        }
                    }
                }
            }
        }
        .navigationTitle("Choose a Service")
    }

    private func startProbe() {
        probeID = UUID()
        let id = probeID
        probeTask = Task { await detect(id: id) }
    }

    private func detect(id: UUID) async {
        let enteredAddress = address
        isProbing = true
        errorMessage = nil
        defer { if probeID == id { isProbing = false } }
        let result = await ConnectionProbe.detect(address: enteredAddress, pinnedFingerprint: trustedCertificate?.sha256Fingerprint)
        guard !Task.isCancelled, probeID == id, enteredAddress == address else { return }
        switch result {
        case .identified(let service, let url):
            reachableURL = url
            select(service)
        case .unrecognized(let url):
            reachableURL = url
            errorMessage = "The server answered, but its service could not be identified. Choose it manually to continue."
        case .certificate(let url, let certificate):
            reachableURL = url
            reviewing = ReviewRequest(certificate: certificate, endpointID: UUID(), pinnedFingerprint: trustedCertificate?.sha256Fingerprint)
        case .redirected(let url):
            errorMessage = "The server redirected to \(NetworkError.withoutCredentials(url)). Enter that address if it belongs to your server."
        case .failed(let message):
            errorMessage = message
        }
    }

    private func select(_ service: ConnectionProbe.Service) {
        let url = reachableURL ?? parsedAddress
        let certificate = url?.scheme == "https" && url?.host() == trustedCertificate?.host ? trustedCertificate : nil
        destination = Destination(service: service, url: url, certificate: certificate)
    }

    private var parsedAddress: URL? {
        if case .success(let url) = EndpointURLParser.parse(address) { return url }
        return nil
    }

    private func serverPrefill(_ selected: Destination) -> ServerProfile? {
        guard let url = selected.url else { return nil }
        let kind: ServerEndpoint.Kind = ConnectionProbe.isTailnetAddress(url) ? .remote : .local
        let endpoint = ServerEndpoint(kind: kind, url: url,
                                      pinnedCertificateSHA256: selected.certificate?.sha256Fingerprint,
                                      pinnedCertificateSubject: selected.certificate?.subject)
        return ServerProfile(name: "Unraid", endpoints: [endpoint], selection: .pinned(endpoint.id))
    }

    private func integrationPrefill(_ selected: Destination) -> IntegrationInstance? {
        guard case .integration(let kind) = selected.service, kind.fixedBaseURL == nil, let url = selected.url else { return nil }
        return IntegrationInstance(kind: kind, name: kind.displayName, url: url, serverID: serverID,
                                   pinnedCertificateSHA256: selected.certificate?.sha256Fingerprint,
                                   pinnedCertificateSubject: selected.certificate?.subject)
    }
}
