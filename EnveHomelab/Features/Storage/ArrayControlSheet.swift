import SwiftUI

struct ArrayControlSheet: View {
    let context: ServerContext
    let array: ArrayStatus
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    @State private var runningContainers: Int?
    @State private var runningVMs: Int?
    @State private var countsLoaded = false
    @State private var passphrase = ""
    @State private var typedName = ""
    @State private var isRunning = false
    @State private var error: NetworkError?
    @State private var resultState: ArrayState?

    private var assessment: ArrayControlAssessment {
        ArrayControlAssessment.assess(array, runningContainers: runningContainers, runningVMs: runningVMs)
    }

    private var isUnsupported: Bool {
        if case .unsupportedByServer = error { true } else { false }
    }

    private var canConfirm: Bool {
        allowsActions && assessment.isAllowed && countsLoaded && !isRunning && !isUnsupported && typedName == context.serverName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledValue(label: "Server", value: context.serverName)
                    LabeledValue(label: "Array", value: array.state.displayName)
                    if let action = assessment.action {
                        LabeledValue(label: "Operation", value: action.title)
                    }
                }

                if !assessment.blockers.isEmpty {
                    Section("Unavailable") {
                        ForEach(assessment.blockers, id: \.self) { blocker in
                            Label(blocker, systemImage: "hand.raised.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                if !assessment.warnings.isEmpty {
                    Section("What happens") {
                        if !countsLoaded {
                            ProgressView("Checking running workloads…")
                        }
                        ForEach(assessment.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                }

                if assessment.isAllowed {
                    if assessment.action == .start {
                        Section {
                            SecureField("Encryption passphrase (optional)", text: $passphrase)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } footer: {
                            Text("Only needed if the array is encrypted. It's sent once over this connection and never stored. Keyfile unlock isn't supported in the app.")
                        }
                    }

                    Section {
                        TextField(context.serverName, text: $typedName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Type the server name to confirm")
                    } header: {
                        Text("Type \(context.serverName) to confirm")
                    }

                    if context.isPreview {
                        Section {
                            Label("Preview mode: only sample data changes.", systemImage: "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let resultState {
                    Section {
                        Label("The array is now \(resultState.displayName.lowercased()).", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let error {
                    Section {
                        InlineErrorBanner(error: error)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if let action = assessment.action, assessment.isAllowed {
                    Section {
                        Button(role: .destructive) {
                            Task { await run(action) }
                        } label: {
                            HStack {
                                Spacer()
                                if isRunning {
                                    ProgressView()
                                    Text(action == .stop ? "Stopping…" : "Starting…")
                                } else {
                                    Label(action.title, systemImage: action.systemImage)
                                }
                                Spacer()
                            }
                            .font(.headline)
                        }
                        .disabled(!canConfirm)
                    } footer: {
                        Text("Stopping or starting the array can take several minutes while services shut down or start.")
                    }
                }
            }
            .navigationTitle("Array Operation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(resultState == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(isRunning)
                }
            }
        }
        .interactiveDismissDisabled(isRunning)
        .task { await loadWorkloads() }
    }

    private func loadWorkloads() async {
        guard array.state == .started else {
            countsLoaded = true
            return
        }
        let service = context.service
        async let containers = try? service.containers()
        async let vms = try? service.virtualMachines()
        runningContainers = await containers?.filter { $0.state == .running || $0.state == .paused }.count
        runningVMs = await vms?.filter { $0.state.isActive || $0.state == .paused }.count
        countsLoaded = true
    }

    private func run(_ action: ArrayStateAction) async {
        isRunning = true
        error = nil
        do {
            resultState = try await context.service.setArrayState(action, decryptionPassword: passphrase.isEmpty ? nil : passphrase)
            passphrase = ""
            typedName = ""
            onCompleted()
        } catch {
            self.error = .from(error)
        }
        isRunning = false
    }
}
