import SwiftUI

struct ServiceCheckRow: View {
    let check: ServiceCheck
    let result: ServiceCheckResult?
    let isChecking: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: health.systemImage)
                .foregroundStyle(health.color)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isChecking {
                ProgressView()
            } else if let time = result?.responseTime {
                Text(ServiceFormat.milliseconds(time))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(check.name)
        .accessibilityValue(accessibilityValue)
    }

    private var health: Health {
        result?.health() ?? .unknown
    }

    private var detail: String {
        guard let result else { return check.url.host() ?? check.url.absoluteString }
        var parts = [result.summary]
        if let days = result.daysUntilExpiry() {
            parts.append(ServiceFormat.expiry(days))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        guard let result else { return isChecking ? "Checking" : "Not checked yet" }
        var parts = [health.accessibilityName, result.summary]
        if let time = result.responseTime { parts.append("\(ServiceFormat.milliseconds(time)) response") }
        if let days = result.daysUntilExpiry() { parts.append(ServiceFormat.expiry(days)) }
        return parts.joined(separator: ", ")
    }
}

enum ServiceFormat {
    static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return "\(Int(ms.rounded())) ms"
    }

    static func expiry(_ days: Int) -> String {
        switch days {
        case ..<0: "certificate expired"
        case 0: "certificate expires today"
        case 1: "certificate expires tomorrow"
        default: "certificate expires in \(days) days"
        }
    }

    static func interval(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }
}

struct ServicesSummaryCard: View {
    @Environment(AppModel.self) private var app
    let serverID: UUID

    var body: some View {
        let checks = app.serviceChecks.checks.filter { $0.serverID == serverID }
        if !checks.isEmpty {
            EnveCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(title: "Services", systemImage: "heart.text.square.fill", trailing: summary(checks))
                        .padding(16)
                    ForEach(checks) { check in
                        Divider().padding(.leading, 16)
                        NavigationLink {
                            ServiceDetailView(checkID: check.id)
                        } label: {
                            ServiceCheckRow(check: check, result: app.serviceHealth.latest(for: check.id), isChecking: app.serviceHealth.inFlight.contains(check.id))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func summary(_ checks: [ServiceCheck]) -> String {
        let up = checks.filter { app.serviceHealth.latest(for: $0.id)?.isUp == true }.count
        return "\(up)/\(checks.count) up"
    }
}

struct ServiceDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    let checkID: UUID
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var reviewing: CertificateSummary?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let check = app.serviceChecks.check(id: checkID) {
                content(check)
            } else {
                ContentUnavailableView("Check removed", systemImage: "heart.slash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
    }

    private func content(_ check: ServiceCheck) -> some View {
        let results = app.serviceHealth.history[check.id] ?? []
        let latest = results.last
        return ScrollView {
            VStack(spacing: 14) {
                EnveCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(check.name).font(.title2.weight(.bold))
                            Spacer()
                            StatusBadge(text: latest.map { $0.health().accessibilityName } ?? "Not checked", health: latest?.health() ?? .unknown)
                        }
                        Text(check.url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let latest {
                            LabeledValue(label: "Result", value: latest.summary)
                            if let time = latest.responseTime {
                                LabeledValue(label: "Response time", value: ServiceFormat.milliseconds(time))
                            }
                            if let finalURL = latest.finalURL, finalURL != check.url {
                                LabeledValue(label: "Redirected to", value: finalURL.absoluteString)
                            }
                            LabeledValue(label: "Checked", value: Format.relative(latest.checkedAt))
                        }
                        Button {
                            Task { await app.serviceHealth.checkNow(check, allChecks: app.serviceChecks.checks, servers: app.store.profiles) }
                        } label: {
                            HStack {
                                Label("Check Now", systemImage: "arrow.clockwise")
                                if app.serviceHealth.inFlight.contains(check.id) { ProgressView() }
                            }
                        }
                        .disabled(app.serviceHealth.inFlight.contains(check.id))
                        .font(.subheadline.weight(.semibold))
                    }
                }

                if case .failed(let error) = latest?.outcome {
                    EnveCard {
                        VStack(alignment: .leading, spacing: 8) {
                            InlineErrorBanner(error: error)
                            if let certificate = error.reviewableCertificate, allowsActions {
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

                if let certificate = latest?.certificate, check.url.scheme == "https" {
                    certificateCard(certificate, result: latest, check: check)
                }

                if results.count > 1 {
                    historyCard(results)
                }

                EnveCard {
                    VStack(spacing: 10) {
                        LabeledValue(label: "Interval", value: "Every \(ServiceFormat.interval(check.intervalSeconds))")
                        LabeledValue(label: "Timeout", value: "\(check.timeoutSeconds) s")
                        LabeledValue(label: "Healthy when", value: check.acceptedStatus.title)
                        if let serverID = check.serverID, let server = app.store.profile(id: serverID) {
                            LabeledValue(label: "Server", value: server.name)
                        }
                    }
                }

                Text("Checks run at their interval while Petty: Homelab is open, and again when iOS gives it background refresh time. The latest \(ServiceHealthMonitor.historyLimit) results are kept on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .bottomBarPadding()
        .navigationTitle(check.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        DiagnosticsView(title: check.name, url: check.url, pinnedFingerprint: check.pinnedCertificateSHA256, authenticate: nil)
                    } label: {
                        Label("Diagnose", systemImage: "stethoscope")
                    }
                    if allowsActions {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { confirmingDelete = true } label: { Label("Remove", systemImage: "trash") }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $editing) {
            ServiceEditorView(check: check)
        }
        .sheet(item: $reviewing) { certificate in
            CertificateReviewView(certificate: certificate, pinnedFingerprint: check.pinnedCertificateSHA256) {
                var updated = check
                updated.pinnedCertificateSHA256 = certificate.sha256Fingerprint
                updated.pinnedCertificateSubject = certificate.subject
                save(updated)
                Task { await app.serviceHealth.checkNow(updated, allChecks: app.serviceChecks.checks, servers: app.store.profiles) }
            }
        }
        .confirmationDialog("Remove \(check.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove Check", role: .destructive) {
                do {
                    try app.serviceChecks.delete(check)
                    app.serviceHealth.forget(check.id)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("The check and any certificate you trusted for it are removed from this device.")
        }
    }

    private func certificateCard(_ certificate: CertificateSummary, result: ServiceCheckResult?, check: ServiceCheck) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "TLS certificate", systemImage: "lock.fill")
                LabeledValue(label: "Subject", value: certificate.subject)
                if let notAfter = certificate.notValidAfter {
                    LabeledValue(label: "Expires", value: notAfter.formatted(date: .abbreviated, time: .omitted))
                }
                if let days = result?.daysUntilExpiry() {
                    Text(ServiceFormat.expiry(days).capitalizedFirst)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(days < ServiceCheckResult.expiryWarningDays ? Color.orange : Color.secondary)
                }
                switch result?.trust {
                case .system?:
                    Label("Trusted by the system", systemImage: "checkmark.seal.fill").font(.footnote)
                case .pinned?:
                    Label("Trusted by fingerprint you reviewed", systemImage: "lock.shield.fill").font(.footnote)
                case .reused(let source)?:
                    Label("Same certificate you trusted for \(source)", systemImage: "lock.shield.fill").font(.footnote)
                default:
                    EmptyView()
                }
                if check.pinnedCertificateSHA256 != nil, allowsActions {
                    Button("Forget Trusted Certificate", role: .destructive) {
                        var updated = check
                        updated.pinnedCertificateSHA256 = nil
                        updated.pinnedCertificateSubject = nil
                        save(updated)
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private func historyCard(_ results: [ServiceCheckResult]) -> some View {
        let maxTime = results.compactMap(\.responseTime).max() ?? .milliseconds(1)
        return EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recent checks", systemImage: "chart.bar.fill", trailing: "\(results.filter(\.isUp).count)/\(results.count) up")
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        let fraction = result.responseTime.map { $0 / maxTime } ?? 1
                        RoundedRectangle(cornerRadius: 2)
                            .fill(result.health().color.opacity(result.isUp ? 0.85 : 1))
                            .frame(height: max(6, 60 * fraction))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 60, alignment: .bottom)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recent checks")
                .accessibilityValue("\(results.filter(\.isUp).count) of \(results.count) succeeded")
            }
        }
    }

    private func save(_ check: ServiceCheck) {
        do {
            try app.serviceChecks.save(check)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension CertificateSummary: Identifiable {
    var id: String { sha256Fingerprint }
}

struct ServiceEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let original: ServiceCheck?
    @State private var name: String
    @State private var address: String
    @State private var acceptedStatus: ServiceCheck.AcceptedStatus
    @State private var interval: Int
    @State private var timeout: Int
    @State private var serverID: UUID?
    @State private var saveError: String?

    init(check: ServiceCheck?, serverID: UUID? = nil, prefill: ServiceCheck? = nil) {
        original = check
        let check = check ?? prefill
        _name = State(initialValue: check?.name ?? "")
        _address = State(initialValue: check?.url.absoluteString ?? "")
        _acceptedStatus = State(initialValue: check?.acceptedStatus ?? .successOrRedirect)
        _interval = State(initialValue: check?.intervalSeconds ?? 60)
        _timeout = State(initialValue: check?.timeoutSeconds ?? 10)
        _serverID = State(initialValue: check?.serverID ?? serverID)
    }

    private var parsedURL: Result<URL, ServiceCheck.URLFailure> { ServiceCheck.parseURL(address) }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if case .failure(let failure) = parsedURL { return failure.localizedDescription }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("https://service.local/health", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("URL")
                    if case .success(let url) = parsedURL {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Petty: Homelab sends a GET request and reads only the response headers. Redirects are followed.")
                }

                Section("Healthy when") {
                    Picker("Response", selection: $acceptedStatus) {
                        ForEach(ServiceCheck.AcceptedStatus.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Check every", selection: $interval) {
                        ForEach(ServiceCheck.intervalChoices, id: \.self) { Text(ServiceFormat.interval($0)).tag($0) }
                    }
                    Stepper("Timeout: \(timeout) s", value: $timeout, in: 3...30)
                }

                if !app.store.profiles.isEmpty {
                    Section {
                        Picker("Server", selection: $serverID) {
                            Text("None").tag(UUID?.none)
                            ForEach(app.store.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    } footer: {
                        Text("Linked checks also appear on that server's overview.")
                    }
                }

                if let message = validationMessage ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "Add Service" : "Edit Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(validationMessage != nil)
                }
            }
        }
    }

    private func save() {
        guard case .success(let url) = parsedURL else { return }
        var check = original ?? ServiceCheck(name: name, url: url)
        let hostChanged = check.url.host() != url.host() || check.url.port != url.port
        check.name = name.trimmingCharacters(in: .whitespaces)
        check.url = url
        check.acceptedStatus = acceptedStatus
        check.intervalSeconds = interval
        check.timeoutSeconds = timeout
        check.serverID = serverID
        if hostChanged {
            check.pinnedCertificateSHA256 = nil
            check.pinnedCertificateSubject = nil
        }
        do {
            try app.serviceChecks.save(check)
            app.serviceHealth.forget(check.id)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
