import SwiftUI

/// Domain checks, the recent query log, diagnosis messages and maintenance for a DNS filter, limited to what its API documents.
struct DNSDiagnosticsView: View {
    let instance: IntegrationInstance
    let service: any DNSDiagnosticsService
    @Environment(\.allowsActions) private var allowsActions
    @State private var domainText = ""
    @State private var check: LoadState<DNSDomainCheck>?
    @State private var queries = LoadState<[DNSQueryLogEntry]>()
    @State private var messages = LoadState<[DNSDiagnosticMessage]>()
    @State private var blockedOnly = false
    @State private var pending: PendingAction?
    @State private var notice: String?

    private var capabilities: DNSDiagnosticsCapabilities { service.diagnostics }

    var body: some View {
        List {
            if let notice {
                Section { Label(notice, systemImage: "info.circle") }
            }
            if capabilities.domainCheck { checkSection }
            if capabilities.queryLog { querySection }
            if capabilities.messages { messageSection }
            if !capabilities.maintenance.isEmpty { maintenanceSection }
        }
        .navigationTitle("DNS Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadLists() }
        .task { await loadLists() }
        .actionConfirmation($pending) { Task { await loadLists() } }
        .bottomBarPadding()
        .enveScreen()
    }

    private var checkSection: some View {
        Section {
            HStack {
                TextField("example.com", text: $domainText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await runCheck() } }
                    .accessibilityLabel("Domain to check")
                Button("Check") { Task { await runCheck() } }
                    .disabled(DNSDomainInput.normalized(domainText) == nil)
            }
            if let check {
                if let result = check.value {
                    Label(result.verdict.title, systemImage: result.verdict == .blocked ? "hand.raised.fill" : (result.verdict == .allowed ? "checkmark.shield.fill" : "circle.dashed"))
                        .foregroundStyle(result.verdict == .blocked ? Color.red : (result.verdict == .allowed ? Color.green : Color.secondary))
                        .font(.headline)
                    ForEach(result.reasons, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    if result.verdict == .blocked, capabilities.allowDomain, allowsActions {
                        Button("Allow \(result.domain)…") { confirmAllow(result.domain) }
                    }
                } else if let error = check.error {
                    InlineErrorBanner(error: error)
                } else {
                    ProgressView()
                }
            }
        } header: {
            Text("Check a domain")
        } footer: {
            Text("Shows whether \(instance.kind.displayName) would block the name and which list or rule decides it. Nothing changes on the server.")
        }
    }

    @ViewBuilder
    private var querySection: some View {
        Section {
            if allowsActions {
                Picker("Show", selection: $blockedOnly) {
                    Text("All").tag(false)
                    Text("Blocked").tag(true)
                }
                .pickerStyle(.segmented)
                if let entries = queries.value {
                    let visible = entries.filter { !blockedOnly || $0.outcome == .blocked }
                    if visible.isEmpty { Text(blockedOnly ? "Nothing blocked recently." : "No recent queries.").foregroundStyle(.secondary) }
                    ForEach(visible) { entry in
                        queryRow(entry)
                    }
                } else if let error = queries.error {
                    InlineErrorBanner(error: error)
                } else {
                    ProgressView()
                }
            } else {
                Text("Recent queries are shown to Owner profiles only, because they reveal what every device on the network looks up.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Recent queries")
        } footer: {
            if allowsActions { Text("The latest 50 queries, read on request and never stored by this app.") }
        }
    }

    private func queryRow(_ entry: DNSQueryLogEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.domain).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle)
                Text([entry.client, entry.type, entry.date.map(Format.relative)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(text: entry.outcome.title, health: entry.outcome == .blocked ? .critical : (entry.outcome == .other ? .unknown : .ok))
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button { domainText = entry.domain; Task { await runCheck() } } label: { Label("Check This Domain", systemImage: "magnifyingglass") }
        }
    }

    private var messageSection: some View {
        Section("Diagnosis messages") {
            if let list = messages.value {
                if list.isEmpty { Text("No messages. \(instance.kind.displayName) hasn't reported any problems.").foregroundStyle(.secondary) }
                ForEach(list) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.text).font(.subheadline)
                        if let date = message.date { Text(Format.relative(date)).font(.caption).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else if let error = messages.error {
                InlineErrorBanner(error: error)
            } else {
                ProgressView()
            }
        }
    }

    private var maintenanceSection: some View {
        Section {
            ForEach(capabilities.maintenance) { task in
                Button {
                    pending = .integration(instance, title: task.title, systemImage: task.systemImage, targetKind: "DNS server", targetName: instance.name,
                                           consequence: task.consequence, destructive: task.isDisruptive) { [service] in
                        let outcome = try await service.perform(task)
                        notice = [task.title + " finished.", outcome].compactMap { $0 }.joined(separator: " ")
                    }
                } label: {
                    Label(task.title + "…", systemImage: task.systemImage)
                }
                .disabled(!allowsActions)
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Flushing logs or the network table, editing groups, lists, clients, settings and custom rules aren't offered: they're broad or can't be undone from here.")
        }
    }

    private func confirmAllow(_ domain: String) {
        pending = .integration(instance, title: "Allow Domain", systemImage: "checkmark.shield", targetKind: "Domain", targetName: domain,
                               consequence: "\(domain) is added to \(instance.name)'s allowlist as an exact entry, so every device can reach it even though a blocklist lists it. Remove it in \(instance.kind.displayName) to block it again.") { [service] in
            try await service.allow(domain: domain)
            notice = "\(domain) is now allowed."
            domainText = domain
        }
    }

    private func runCheck() async {
        guard let domain = DNSDomainInput.normalized(domainText) else { return }
        domainText = domain
        var state = LoadState<DNSDomainCheck>()
        state.begin()
        check = state
        state.finish(await captureResult { try await service.check(domain: domain) })
        check = state
    }

    private func loadLists() async {
        if capabilities.queryLog, allowsActions {
            queries.begin()
            queries.finish(await captureResult { try await service.recentQueries(limit: 50) })
        }
        if capabilities.messages {
            messages.begin()
            messages.finish(await captureResult { try await service.messages() })
        }
        if check?.value != nil { await runCheck() }
    }
}
