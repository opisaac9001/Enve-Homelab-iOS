import SwiftUI

@MainActor
@Observable
final class ServerEditorModel {
    enum Route: String, CaseIterable, Identifiable {
        case automatic, localOnly, remoteOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .localOnly: "Local only"
            case .remoteOnly: "Remote only"
            }
        }
    }

    enum TestState {
        case idle
        case running
        case succeeded(UnraidIdentity, ServerEndpoint)
        case failed(ConnectionFailure)
    }

    let original: ServerProfile?
    let hasSavedKey: Bool
    var name: String
    var apiKey = ""
    var localAddress: String
    var remoteAddress: String
    var route: Route
    var test: TestState = .idle

    private var localEndpoint: ServerEndpoint?
    private var remoteEndpoint: ServerEndpoint?

    init(profile: ServerProfile?, hasSavedKey: Bool, prefill: ServerProfile? = nil) {
        original = profile
        self.hasSavedKey = hasSavedKey
        let seed = profile ?? prefill
        name = seed?.name ?? ""
        let local = seed?.endpoints.first { $0.kind == .local }
        let remote = seed?.endpoints.first { $0.kind == .remote }
        localEndpoint = local
        remoteEndpoint = remote
        localAddress = local?.url.absoluteString ?? ""
        remoteAddress = remote?.url.absoluteString ?? ""
        switch seed?.selection {
        case .pinned(let id) where id == remote?.id: route = .remoteOnly
        case .pinned: route = .localOnly
        default: route = .automatic
        }
    }

    var isEditing: Bool { original != nil }

    func parsed(_ address: String) -> Result<URL, EndpointURLParser.Failure>? {
        address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : EndpointURLParser.parse(address)
    }

    func endpoint(_ kind: ServerEndpoint.Kind) -> ServerEndpoint? {
        let address = kind == .local ? localAddress : remoteAddress
        guard case .success(let url)? = parsed(address) else { return nil }
        let existing = kind == .local ? localEndpoint : remoteEndpoint
        if let existing, existing.url == url { return existing }
        return ServerEndpoint(id: existing?.id ?? UUID(), kind: kind, url: url)
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        for address in [localAddress, remoteAddress] {
            if case .failure(let failure)? = parsed(address) { return failure.localizedDescription }
        }
        let local = endpoint(.local)
        let remote = endpoint(.remote)
        if local == nil && remote == nil { return "Enter at least one address." }
        if route == .localOnly && local == nil { return "Enter a local address, or change the route." }
        if route == .remoteOnly && remote == nil { return "Enter a remote address, or change the route." }
        if apiKey.isEmpty && !hasSavedKey { return "Enter an API key." }
        return nil
    }

    func makeProfile() -> ServerProfile {
        let endpoints = [endpoint(.local), endpoint(.remote)].compactMap { $0 }
        let selection: EndpointSelection = switch route {
        case .automatic: .automatic
        case .localOnly: endpoints.first { $0.kind == .local }.map { .pinned($0.id) } ?? .automatic
        case .remoteOnly: endpoints.first { $0.kind == .remote }.map { .pinned($0.id) } ?? .automatic
        }
        return ServerProfile(
            id: original?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            provider: .unraid,
            endpoints: endpoints,
            selection: selection
        )
    }

    func runTest(store: ServerStore) async {
        test = .running
        let profile = makeProfile()
        let key: String
        if !apiKey.isEmpty {
            key = apiKey
        } else if let saved = try? store.apiKey(for: profile) {
            key = saved
        } else {
            test = .failed(ConnectionFailure(endpoint: nil, error: .missingCredentials))
            return
        }
        switch await UnraidConnector.connect(profile: profile, apiKey: key) {
        case .success(let connection): test = .succeeded(connection.identity, connection.endpoint)
        case .failure(let failure): test = .failed(failure)
        }
    }

    func trust(_ certificate: CertificateSummary, endpointID: UUID) {
        if var local = endpoint(.local), local.id == endpointID {
            local.pinnedCertificateSHA256 = certificate.sha256Fingerprint
            local.pinnedCertificateSubject = certificate.subject
            localEndpoint = local
        } else if var remote = endpoint(.remote), remote.id == endpointID {
            remote.pinnedCertificateSHA256 = certificate.sha256Fingerprint
            remote.pinnedCertificateSubject = certificate.subject
            remoteEndpoint = remote
        }
    }

    func forgetCertificate(_ kind: ServerEndpoint.Kind) {
        switch kind {
        case .local:
            localEndpoint = endpoint(.local).map { var e = $0; e.pinnedCertificateSHA256 = nil; e.pinnedCertificateSubject = nil; return e }
        case .remote:
            remoteEndpoint = endpoint(.remote).map { var e = $0; e.pinnedCertificateSHA256 = nil; e.pinnedCertificateSubject = nil; return e }
        }
        test = .idle
    }
}

struct ServerEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ServerEditorModel
    @State private var saveError: String?
    @State private var reviewing: ReviewRequest?
    var onSaved: (ServerProfile) -> Void = { _ in }

    init(profile: ServerProfile?, hasSavedKey: Bool, prefill: ServerProfile? = nil, onSaved: @escaping (ServerProfile) -> Void = { _ in }) {
        _model = State(initialValue: ServerEditorModel(profile: profile, hasSavedKey: hasSavedKey, prefill: prefill))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                        .textContentType(.name)
                    SecureField(model.hasSavedKey ? "API key (saved — leave blank to keep)" : "API key", text: $model.apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Unraid server")
                } footer: {
                    Text("Create a key in Unraid under Settings › Management Access › API Keys. A viewer key can monitor; actions need additional permissions. The key stays in this device's Keychain.")
                }

                addressSection(.local, text: $model.localAddress, placeholder: "192.168.1.20 or tower.local")
                addressSection(.remote, text: $model.remoteAddress, placeholder: "Optional — e.g. a VPN or reverse-proxy address")

                Section {
                    Picker("Route", selection: $model.route) {
                        ForEach(ServerEditorModel.Route.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Automatic tries the local address first and falls back to the remote one.")
                }

                testSection

                if let message = model.validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(model.isEditing ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(model.validationMessage != nil)
                }
            }
            .sheet(item: $reviewing) { request in
                CertificateReviewView(certificate: request.certificate, pinnedFingerprint: request.pinnedFingerprint) {
                    model.trust(request.certificate, endpointID: request.endpointID)
                    Task { await model.runTest(store: app.store) }
                }
            }
        }
    }

    private func addressSection(_ kind: ServerEndpoint.Kind, text: Binding<String>, placeholder: String) -> some View {
        Section {
            TextField(placeholder, text: text)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("\(kind.displayName) address")
            if let endpoint = model.endpoint(kind) {
                Text(endpoint.url.absoluteString + "/graphql")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if endpoint.usesPlainHTTP {
                    Label("HTTP sends your API key unencrypted. Use HTTPS unless this network is fully trusted.", systemImage: "lock.open.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let fingerprint = endpoint.pinnedCertificateSHA256 {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Trusted certificate", systemImage: "lock.shield.fill")
                            .font(.footnote.weight(.semibold))
                        Text(fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Forget Certificate", role: .destructive) { model.forgetCertificate(kind) }
                            .font(.footnote)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Label(kind.displayName, systemImage: kind.systemImage)
        }
    }

    @ViewBuilder
    private var testSection: some View {
        Section {
            Button {
                Task { await model.runTest(store: app.store) }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if case .running = model.test { ProgressView() }
                }
            }
            .disabled(model.validationMessage != nil || isTesting)

            switch model.test {
            case .idle, .running:
                EmptyView()
            case .succeeded(let identity, let endpoint):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connected to \(identity.name)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                    Text([identity.unraidVersion.map { "Unraid \($0)" }, "via \(endpoint.kind.displayName.lowercased())"].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let failure):
                ConnectionFailureSummary(failure: failure) { certificate, endpointID, pinned in
                    reviewing = ReviewRequest(certificate: certificate, endpointID: endpointID, pinnedFingerprint: pinned)
                }
            }
        }
    }

    private var isTesting: Bool {
        if case .running = model.test { true } else { false }
    }

    private func save() {
        let profile = model.makeProfile()
        do {
            try app.store.save(profile, apiKey: model.apiKey.isEmpty ? nil : model.apiKey)
            onSaved(profile)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct ReviewRequest: Identifiable {
    let id = UUID()
    let certificate: CertificateSummary
    let endpointID: UUID
    let pinnedFingerprint: String?
}

struct ConnectionFailureSummary: View {
    let failure: ConnectionFailure
    let review: (CertificateSummary, UUID, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.error.errorDescription ?? "Connection failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.subheadline.weight(.semibold))
            if let endpoint = failure.endpoint {
                Text("\(endpoint.kind.displayName): \(endpoint.url.absoluteString)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let suggestion = failure.error.recoverySuggestion {
                Text(suggestion)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let certificate = failure.error.reviewableCertificate, let endpoint = failure.endpoint {
                Button {
                    review(certificate, endpoint.id, pinned)
                } label: {
                    Label("Review Certificate", systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var pinned: String? {
        if case .certificateChanged(_, let pinned) = failure.error { pinned } else { nil }
    }
}
