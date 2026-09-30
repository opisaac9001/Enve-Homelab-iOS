import SwiftUI

struct AlertsInboxView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var minimum: AlertSeverity = .info
    @State private var confirmingClear = false

    private var visible: [AlertEvent] {
        app.alerts.events.filter { $0.severity >= minimum && $0.matches(query) && app.isVisible($0) }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $minimum) {
                    Text("All").tag(AlertSeverity.info)
                    Text("Warnings").tag(AlertSeverity.warning)
                    Text("Critical").tag(AlertSeverity.critical)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error = app.alerts.lastDeliveryError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if visible.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No alerts" : "No matching alerts",
                    systemImage: "bell.slash",
                    description: Text(query.isEmpty ? "Health changes from service checks and integrations, and messages from your ntfy topic, appear here." : "Try a different search.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(visible) { event in
                AlertEventRow(event: event)
                    .swipeActions {
                        if !event.isRead {
                            Button("Mark Read") { app.alerts.markRead(event) }.tint(.enveAccent)
                        }
                    }
                    .onAppear { if !event.isRead && event.isRecovery { app.alerts.markRead(event) } }
            }
        }
        .searchable(text: $query, prompt: "Search alerts")
        .navigationTitle("Alerts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { app.alerts.markAllRead() } label: { Label("Mark All Read", systemImage: "envelope.open") }
                    if app.profiles.allowsActions {
                        NavigationLink { NotificationSettingsView() } label: { Label("Notification Rules", systemImage: "bell.badge") }
                        Button(role: .destructive) { confirmingClear = true } label: { Label("Clear Inbox", systemImage: "trash") }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Clear all alerts?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Inbox", role: .destructive) { app.alerts.clear() }
        } message: {
            Text("Alerts are removed from this device only.")
        }
        .bottomBarPadding()
        .enveScreen()
    }
}

struct AlertEventRow: View {
    let event: AlertEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.isRecovery ? "checkmark.circle.fill" : event.severity.health.systemImage)
                .foregroundStyle(event.isRecovery ? .green : (event.severity == .info ? Color.enveAccent : event.severity.health.color))
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title).font(.subheadline.weight(event.isRead ? .regular : .semibold))
                    if !event.isRead && !event.isRecovery {
                        Circle().fill(Color.enveAccent).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                }
                if !event.body.isEmpty {
                    Text(event.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("\(event.sourceKind.title) · \(Format.relative(event.date))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.isRecovery ? "Recovered" : event.severity.title): \(event.title)\(event.isRead ? "" : ", unread")")
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: NotificationRule?
    @State private var editingNtfy = false
    @State private var testSent = false

    var body: some View {
        List {
            Section {
                ForEach(app.alerts.rules) { rule in
                    Button {
                        editing = rule
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.body.weight(.semibold))
                            Text(description(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                }
                .onDelete { offsets in offsets.map { app.alerts.rules[$0] }.forEach(app.alerts.delete) }
                Button {
                    editing = NotificationRule(name: "Service checks", sourceKind: .serviceCheck)
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Every alert is kept in the in-app inbox. Rules decide which ones also notify this device or go to ntfy. Checks run while the app is open; iOS may also run a background refresh roughly every 15 minutes or less often — it decides when.")
            }

            Section {
                Toggle("Quiet hours", isOn: Binding(
                    get: { app.alerts.quietHours != nil },
                    set: { app.alerts.setQuietHours($0 ? QuietHours() : nil) }
                ))
                if let hours = app.alerts.quietHours {
                    DatePicker("From", selection: time(\.startMinute, in: hours), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: time(\.endMinute, in: hours), displayedComponents: .hourAndMinute)
                    Toggle("Still notify for critical alerts", isOn: Binding(
                        get: { hours.allowCritical },
                        set: { var updated = hours; updated.allowCritical = $0; app.alerts.setQuietHours(updated) }
                    ))
                }
                Button {
                    Task {
                        await app.alerts.sendTestNotification()
                        testSent = true
                    }
                } label: {
                    Label("Send Test Notification", systemImage: "bell.and.waves.left.and.right")
                }
                if testSent {
                    Text("Sent. If nothing appeared, check Settings › Notifications › Enve Homelab and any active Focus.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("This device")
            } footer: {
                Text("During quiet hours alerts still reach the inbox and ntfy; they just don't make this device buzz. Test notifications aren't added to the inbox.")
            }

            Section {
                Button {
                    editingNtfy = true
                } label: {
                    LabeledContent("ntfy", value: app.alerts.ntfy.map { "\($0.serverURL.host() ?? "") · \($0.topic)" } ?? "Not set up")
                }
            } header: {
                Text("Self-hosted delivery")
            } footer: {
                Text("Optional. Point this at your own ntfy server to receive its messages here and forward alerts to it. No Enve account or relay is involved.")
            }
        }
        .navigationTitle("Notifications")
        .sheet(item: $editing) { rule in
            NotificationRuleEditor(rule: rule)
        }
        .sheet(isPresented: $editingNtfy) {
            NtfySettingsView()
        }
        .enveScreen()
    }

    private func time(_ keyPath: WritableKeyPath<QuietHours, Int>, in hours: QuietHours) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(hours[keyPath: keyPath] * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                var updated = hours
                updated[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                app.alerts.setQuietHours(updated)
            }
        )
    }

    private func description(_ rule: NotificationRule) -> String {
        var parts = [rule.sourceKind.title, "\(rule.minimumSeverity.title) and above"]
        if rule.notifyOnDevice { parts.append("notify") }
        if rule.forwardToNtfy { parts.append("ntfy") }
        if !rule.isEnabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }
}

private struct NotificationRuleEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var rule: NotificationRule

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $rule.name)
                Picker("Source", selection: $rule.sourceKind) {
                    ForEach(AlertSourceKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("Applies to", selection: $rule.sourceID) {
                    Text("All").tag(String?.none)
                    ForEach(sources, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
                Picker("Minimum severity", selection: $rule.minimumSeverity) {
                    ForEach(AlertSeverity.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Include recoveries", isOn: $rule.includeRecoveries)
                Toggle("Notify this device", isOn: $rule.notifyOnDevice)
                Toggle("Forward to ntfy", isOn: $rule.forwardToNtfy)
                    .disabled(app.alerts.ntfy == nil || rule.sourceKind == .ntfy)
                Toggle("Enabled", isOn: $rule.isEnabled)
            }
            .navigationTitle("Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await app.alerts.save(rule)
                            dismiss()
                        }
                    }
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: rule.sourceKind) { rule.sourceID = nil }
        }
    }

    private var sources: [(id: String, name: String)] {
        switch rule.sourceKind {
        case .serviceCheck: app.serviceChecks.checks.map { ($0.id.uuidString, $0.name) }
        case .integration: app.integrations.instances.map { ($0.id.uuidString, $0.name) }
        case .ntfy: app.alerts.ntfy.map { [($0.topic, $0.topic)] } ?? []
        }
    }
}

private struct NtfySettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var topic = ""
    @State private var token = ""
    @State private var subscribe = true
    @State private var pinned: String?
    @State private var status: String?
    @State private var reviewing: CertificateSummary?

    private var url: URL? {
        guard case .success(let url) = EndpointURLParser.parse(address) else { return nil }
        return url
    }

    private var configuration: NtfyConfiguration? {
        guard let url, NtfyConfiguration.isValidTopic(topic) else { return nil }
        return NtfyConfiguration(serverURL: url, topic: topic, subscribe: subscribe, pinnedCertificateSHA256: pinned, lastMessageID: app.alerts.ntfy?.topic == topic ? app.alerts.ntfy?.lastMessageID : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://ntfy.example.com", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                    TextField("Topic", text: $topic)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(app.alerts.hasNtfyToken() ? "Access token (saved — leave blank to keep)" : "Access token (optional)", text: $token)
                    Toggle("Show this topic's messages as alerts", isOn: $subscribe)
                } footer: {
                    Text("Topics are letters, numbers, - and _. Use your own server; a public server's topics can be read by anyone who guesses the name.")
                }
                Section {
                    Button("Send Test Message") { Task { await sendTest() } }
                        .disabled(configuration == nil)
                    if let status { Text(status).font(.footnote) }
                }
                if app.alerts.ntfy != nil {
                    Section {
                        Button("Remove ntfy", role: .destructive) {
                            try? app.alerts.configureNtfy(nil, token: nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("ntfy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try app.alerts.configureNtfy(configuration, token: token.isEmpty ? nil : token)
                            dismiss()
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                    .disabled(configuration == nil)
                }
            }
            .onAppear {
                if let current = app.alerts.ntfy {
                    address = current.serverURL.absoluteString
                    topic = current.topic
                    subscribe = current.subscribe
                    pinned = current.pinnedCertificateSHA256
                }
            }
            .sheet(item: $reviewing) { certificate in
                CertificateReviewView(certificate: certificate, pinnedFingerprint: pinned) {
                    pinned = certificate.sha256Fingerprint
                    Task { await sendTest() }
                }
            }
        }
    }

    private func sendTest() async {
        guard let configuration else { return }
        let client = NtfyClient(configuration: configuration, token: token.isEmpty ? app.alerts.ntfyToken() : token)
        let event = AlertEvent(date: .now, severity: .info, sourceKind: .ntfy, sourceID: topic, sourceName: "Enve Homelab", title: "Enve Homelab test", body: "ntfy delivery is working.")
        do {
            try await client.publish(event)
            status = "Sent. Check your ntfy subscribers."
        } catch {
            let failure = NetworkError.from(error)
            if let certificate = failure.reviewableCertificate {
                reviewing = certificate
            } else {
                status = failure.errorDescription
            }
        }
    }
}
