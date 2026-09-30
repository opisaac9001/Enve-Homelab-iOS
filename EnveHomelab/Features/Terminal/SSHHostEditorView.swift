import SwiftUI

struct SSHHostEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let original: SSHHost?

    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var usesKey: Bool
    @State private var keyID: UUID?
    @State private var password = ""
    @State private var serverID: UUID?
    @State private var knownHostKey: KnownHostKey?
    @State private var commands: [SavedCommand]
    @State private var editingCommand: SavedCommand?
    @State private var saveError: String?

    init(host: SSHHost?, serverID: UUID? = nil, prefill: SSHHost? = nil) {
        original = host
        let host = host ?? prefill
        _name = State(initialValue: host?.name ?? "")
        _host = State(initialValue: host?.host ?? "")
        _portText = State(initialValue: host.map { String($0.port) } ?? "")
        _username = State(initialValue: host?.username ?? "")
        if case .key(let id)? = host?.authentication {
            _usesKey = State(initialValue: true)
            _keyID = State(initialValue: id)
        } else {
            _usesKey = State(initialValue: false)
            _keyID = State(initialValue: nil)
        }
        _serverID = State(initialValue: host?.serverID ?? serverID)
        _knownHostKey = State(initialValue: host?.knownHostKey)
        _commands = State(initialValue: host?.savedCommands ?? [])
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var port: Int? {
        let text = portText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 22 }
        return Int(text).flatMap { (1...65_535).contains($0) ? $0 : nil }
    }

    private var effectiveUsername: String {
        let name = username.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "root" : name
    }

    private var hasSavedPassword: Bool {
        guard let original, case .password = original.authentication else { return false }
        return app.ssh.hasPassword(for: original)
    }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if trimmedHost.isEmpty || trimmedHost.contains(" ") || trimmedHost.contains("/") { return "Enter a host name or IP address." }
        if port == nil { return "Enter a port between 1 and 65535." }
        if usesKey && keyID == nil { return "Choose a key, or generate one under Keys." }
        if !usesKey && password.isEmpty && !hasSavedPassword { return "Enter the password." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $name)
                    TextField("Host name or IP address", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Port") {
                        TextField("22", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Port")
                            .accessibilityIdentifier("ssh-port")
                    }
                    TextField("Username (root)", text: $username)
                        .accessibilityLabel("Username")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Sign in with", selection: $usesKey) {
                        Text("Password").tag(false)
                        Text("Key").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if usesKey {
                        Picker("Key", selection: $keyID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(app.ssh.keys) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        if let keyID, let key = app.ssh.key(id: keyID) {
                            Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        SecureField(hasSavedPassword ? "Password (saved — leave blank to keep)" : "Password", text: $password)
                            .textContentType(.password)
                    }
                } footer: {
                    Text(usesKey
                         ? "Add the key's public half to ~/.ssh/authorized_keys on the host (on Unraid, via Users › root › SSH authorized keys)."
                         : "The password is stored only in this device's Keychain.")
                }

                Section {
                    if let knownHostKey {
                        LabeledValue(label: "Algorithm", value: knownHostKey.algorithm)
                        Text(knownHostKey.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Forget Host Key", role: .destructive) { self.knownHostKey = nil }
                    } else {
                        Text("You'll review the host key on first connection.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Host key")
                }

                Section {
                    ForEach(commands) { command in
                        Button {
                            editingCommand = command
                        } label: {
                            SavedCommandRow(command: command)
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { commands.remove(atOffsets: $0) }
                    .onMove { commands.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        editingCommand = SavedCommand(name: "", command: "")
                    } label: {
                        Label("Add Command", systemImage: "plus")
                    }
                } header: {
                    Text("Saved commands")
                } footer: {
                    Text("Commands that delete data, change disks, or stop the host ask for confirmation before running.")
                }

                if !app.store.profiles.isEmpty {
                    Section {
                        Picker("Server", selection: $serverID) {
                            Text("None").tag(UUID?.none)
                            ForEach(app.store.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    } footer: {
                        Text("Linked hosts appear on that server's overview.")
                    }
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "Add SSH Host" : "Edit SSH Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(validationMessage != nil)
                }
            }
            .sheet(item: $editingCommand) { command in
                SavedCommandEditor(command: command) { updated in
                    if let index = commands.firstIndex(where: { $0.id == updated.id }) {
                        commands[index] = updated
                    } else {
                        commands.append(updated)
                    }
                }
            }
        }
    }

    private func save() {
        var result = original ?? SSHHost(name: "", host: "", username: "")
        guard let port else { return }
        let addressChanged = result.host.lowercased() != trimmedHost.lowercased() || result.port != port
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.host = trimmedHost
        result.port = port
        result.username = effectiveUsername
        result.authentication = usesKey ? .key(keyID!) : .password
        result.serverID = serverID
        // A host key belongs to one address; changing the address requires a fresh review.
        result.knownHostKey = addressChanged ? nil : knownHostKey
        result.savedCommands = commands
        do {
            try app.ssh.save(result, password: usesKey || password.isEmpty ? nil : password)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct SavedCommandRow: View {
    let command: SavedCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(command.name).font(.body.weight(.semibold))
                if !command.risks.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs confirmation")
                }
            }
            Text(command.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SavedCommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: SavedCommand
    let onSave: (SavedCommand) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $command.name)
                        .accessibilityLabel("Command name")
                    TextField("Command", text: $command.command, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...6)
                }
                let risks = command.risks
                if !risks.isEmpty {
                    Section("Asks for confirmation because it") {
                        ForEach(risks, id: \.self) { risk in
                            Label(risk, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                }
            }
            .navigationTitle("Saved Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(command)
                        dismiss()
                    }
                    .disabled(command.name.trimmingCharacters(in: .whitespaces).isEmpty || command.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct SSHKeysView: View {
    @Environment(AppModel.self) private var app
    @State private var generating = false
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var deleting: SSHKeyInfo?

    var body: some View {
        List {
            if app.ssh.keys.isEmpty {
                ContentUnavailableView("No keys", systemImage: "key", description: Text("Generate an Ed25519 key on this device, or import an existing unencrypted key."))
            }
            ForEach(app.ssh.keys) { key in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(key.name).font(.headline)
                        Spacer()
                        Text(key.algorithm.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        ShareLink(item: key.publicKey) {
                            Label("Share Public Key", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = key.publicKey
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = key }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            Section {
                Text("Private keys never leave this device's Keychain. Only the public key is shown or shared.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { generating = true } label: { Label("Generate Ed25519 Key", systemImage: "key.fill") }
                    Button { importing = true } label: { Label("Import Private Key", systemImage: "square.and.arrow.down") }
                } label: {
                    Label("Add Key", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $generating) {
            KeyNameSheet(title: "Generate Key", showsKeyField: false) { name, _ in
                try app.ssh.addKey(named: name, material: OpenSSHKeys.generateEd25519())
            }
        }
        .sheet(isPresented: $importing) {
            KeyNameSheet(title: "Import Key", showsKeyField: true) { name, text in
                try app.ssh.addKey(named: name, material: OpenSSHKeys.parsePrivateKey(text))
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "key")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { key in
            Button("Delete Key", role: .destructive) {
                do {
                    try app.ssh.deleteKey(key)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { _ in
            Text("The private key is removed from this device. Servers that trust it keep its public key until you remove it there.")
        }
    }
}

private struct KeyNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let showsKeyField: Bool
    let action: (String, String) throws -> Void
    @State private var name = ""
    @State private var keyText = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                if showsKeyField {
                    Section {
                        TextField("-----BEGIN OPENSSH PRIVATE KEY-----", text: $keyText, axis: .vertical)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(4...12)
                    } footer: {
                        Text("Unencrypted Ed25519 or ECDSA P-256 keys in OpenSSH format. The pasted text is cleared after import.")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try action(name.trimmingCharacters(in: .whitespaces), keyText)
                            keyText = ""
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (showsKeyField && keyText.isEmpty))
                }
            }
        }
    }
}
