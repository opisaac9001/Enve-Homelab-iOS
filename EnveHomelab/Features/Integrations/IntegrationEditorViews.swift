import SwiftUI

struct IntegrationEditorView: View {
    let instance: IntegrationInstance

    var body: some View {
        NavigationStack {
            IntegrationEditorForm(original: instance, kind: instance.kind, serverID: instance.serverID)
        }
    }
}

struct IntegrationEditorForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let original: IntegrationInstance?
    let kind: IntegrationKind
    var onSaved: () -> Void = {}

    @State private var name: String
    @State private var address: String
    @State private var identifier: String
    @State private var secret = ""
    @State private var serverID: UUID?
    @State private var isEnabled: Bool
    @State private var pinnedFingerprint: String?
    @State private var pinnedSubject: String?
    @State private var test: TestState = .idle
    @State private var reviewing: CertificateSummary?
    @State private var saveError: String?

    enum TestState {
        case idle, running
        case passed(IntegrationSummary)
        case failed(NetworkError)
    }

    init(original: IntegrationInstance?, kind: IntegrationKind, serverID: UUID?, prefill: IntegrationInstance? = nil, onSaved: @escaping () -> Void = {}) {
        self.original = original
        self.kind = kind
        self.onSaved = onSaved
        let original = original ?? prefill
        _name = State(initialValue: original?.name ?? kind.displayName)
        _address = State(initialValue: original?.url.absoluteString ?? kind.fixedBaseURL?.absoluteString ?? "")
        _identifier = State(initialValue: original?.identifier ?? "")
        _serverID = State(initialValue: original?.serverID ?? serverID)
        _isEnabled = State(initialValue: original?.isEnabled ?? true)
        _pinnedFingerprint = State(initialValue: original?.pinnedCertificateSHA256)
        _pinnedSubject = State(initialValue: original?.pinnedCertificateSubject)
    }

    private var parsedURL: URL? {
        guard case .success(let url) = EndpointURLParser.parse(address) else { return nil }
        return url
    }

    private var hasSavedSecret: Bool {
        original.map { app.integrations.hasSecret(for: $0) } ?? false
    }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if case .failure(let failure) = EndpointURLParser.parse(address) { return failure.localizedDescription }
        if kind == .truenas, parsedURL?.scheme != "https" { return "TrueNAS needs an https:// address; it revokes API keys sent over plain HTTP." }
        switch kind.credentialStyle {
        case .secret(let label):
            if secret.isEmpty && !hasSavedSecret { return "Enter the \(label.lowercased())." }
        case .identifierAndSecret(let identifierLabel, _, let secretLabel):
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the \(identifierLabel.lowercased())." }
            if secret.isEmpty && !hasSavedSecret { return "Enter the \(secretLabel.lowercased())." }
        case .usernamePassword(let optional):
            if !optional, identifier.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the username." }
            if !optional, secret.isEmpty && !hasSavedSecret { return "Enter the password." }
        case .optionalSecret:
            break
        }
        return nil
    }

    private func draft() -> IntegrationInstance? {
        guard let url = parsedURL else { return nil }
        var instance = original ?? IntegrationInstance(kind: kind, name: name, url: url)
        let addressChanged = instance.url.host() != url.host() || instance.url.port != url.port
        instance.name = name.trimmingCharacters(in: .whitespaces)
        instance.url = url
        instance.identifier = identifier.trimmingCharacters(in: .whitespaces).nilIfEmpty
        instance.serverID = serverID
        instance.isEnabled = isEnabled
        instance.pinnedCertificateSHA256 = addressChanged && original != nil && pinnedFingerprint == original?.pinnedCertificateSHA256 ? nil : pinnedFingerprint
        instance.pinnedCertificateSubject = instance.pinnedCertificateSHA256 == nil ? nil : pinnedSubject
        return instance
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                if let fixed = kind.fixedBaseURL {
                    LabeledValue(label: "Service", value: fixed.host() ?? fixed.absoluteString)
                } else {
                    TextField(kind.exampleAddress, text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Address")
                }
                if kind.fixedBaseURL == nil, let url = parsedURL {
                    Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if url.scheme == "http" && !kind.requiresHTTPS {
                        Label("HTTP sends credentials unencrypted. Use HTTPS unless this network is fully trusted.", systemImage: "lock.open.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                if let pinnedFingerprint {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Trusted certificate", systemImage: "lock.shield.fill").font(.footnote.weight(.semibold))
                        Text(pinnedFingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Button("Forget Certificate", role: .destructive) {
                            self.pinnedFingerprint = nil
                            pinnedSubject = nil
                        }
                        .font(.footnote)
                    }
                }
            } header: {
                Label(kind.displayName, systemImage: kind.systemImage)
            }

            Section {
                NavigationLink {
                    IntegrationGuideView(kind: kind)
                } label: {
                    Label("How to connect \(kind.displayName)", systemImage: "questionmark.circle")
                }
            }

            credentialSection

            Section {
                Toggle("Enabled", isOn: $isEnabled)
                if !app.store.profiles.isEmpty {
                    Picker("Unraid server", selection: $serverID) {
                        Text("None").tag(UUID?.none)
                        ForEach(app.store.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
            } footer: {
                Text("Linked integrations also appear on that server's overview. Turned-off integrations are never contacted.")
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if case .running = test { ProgressView() }
                    }
                }
                .disabled(validationMessage != nil)
                switch test {
                case .idle, .running:
                    EmptyView()
                case .passed(let summary):
                    Label("\(summary.product) \(summary.version ?? "") · \(summary.headline)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                case .failed(let error):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error.errorDescription ?? "Failed", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline.weight(.semibold))
                        if let suggestion = error.recoverySuggestion {
                            Text(suggestion).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let certificate = error.reviewableCertificate {
                            Button {
                                reviewing = certificate
                            } label: {
                                Label("Review Certificate", systemImage: "lock.shield")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if let message = validationMessage ?? saveError {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle(original == nil ? "Add \(kind.displayName)" : "Edit \(kind.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if original != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(validationMessage != nil)
            }
        }
        .sheet(item: $reviewing) { certificate in
            CertificateReviewView(certificate: certificate, pinnedFingerprint: pinnedFingerprint) {
                pinnedFingerprint = certificate.sha256Fingerprint
                pinnedSubject = certificate.subject
                Task { await runTest() }
            }
        }
    }

    @ViewBuilder
    private var credentialSection: some View {
        Section {
            switch kind.credentialStyle {
            case .secret(let label), .optionalSecret(let label):
                SecureField(hasSavedSecret ? "\(label) (saved — leave blank to keep)" : label, text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(label)
            case .identifierAndSecret(let identifierLabel, let prompt, let secretLabel):
                TextField(prompt, text: $identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(identifierLabel)
                SecureField(hasSavedSecret ? "\(secretLabel) (saved — leave blank to keep)" : secretLabel, text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(secretLabel)
            case .usernamePassword(let optional):
                TextField(optional ? "Username (optional)" : "Username", text: $identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Username")
                SecureField(hasSavedSecret ? "Password (saved — leave blank to keep)" : "Password", text: $secret)
                    .accessibilityLabel("Password")
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text(kind.credentialHelp + " Stored only in this device's Keychain.")
        }
    }

    private func runTest() async {
        guard let instance = draft() else { return }
        test = .running
        let secretValue: String? = secret.isEmpty ? (original.flatMap { try? app.integrations.secret(for: $0) }) : secret
        do {
            let client = try IntegrationConnector.client(for: instance, secret: secretValue)
            test = .passed(try await client.service.summary())
        } catch {
            test = .failed(.from(error))
        }
    }

    private func save() {
        guard let instance = draft() else { return }
        do {
            try app.integrations.save(instance, secret: secret.isEmpty ? nil : secret)
            app.integrationStatus.forget(instance.id)
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
