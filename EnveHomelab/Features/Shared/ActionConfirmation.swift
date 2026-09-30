import SwiftUI

struct PendingAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let targetKind: String
    let targetName: String
    let serverName: String
    let consequence: String
    var isDestructive = false
    var requiresTypedConfirmation = false
    var isPreview = false
    let perform: @MainActor () async throws -> Void
}

struct ActionConfirmationSheet: View {
    let action: PendingAction
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    @State private var typedName = ""
    @State private var isRunning = false
    @State private var error: NetworkError?

    private var canConfirm: Bool {
        allowsActions && !isRunning && (!action.requiresTypedConfirmation || typedName == action.targetName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: action.systemImage)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(action.isDestructive ? .red : Color.enveAccent)
                            .frame(width: 48, height: 48)
                            .background((action.isDestructive ? Color.red : Color.enveAccent).opacity(0.15), in: Circle())
                            .accessibilityHidden(true)
                        Text(action.title)
                            .font(.title2.weight(.bold))
                    }

                    EnveCard {
                        VStack(spacing: 10) {
                            LabeledValue(label: action.targetKind, value: action.targetName)
                            Divider()
                            LabeledValue(label: "Server", value: action.serverName)
                        }
                    }

                    Text(action.consequence)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    if action.isPreview {
                        Label("Preview mode: only sample data changes.", systemImage: "eye")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if action.requiresTypedConfirmation {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Type **\(action.targetName)** to confirm.")
                                .font(.subheadline)
                            TextField(action.targetName, text: $typedName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Confirmation name")
                        }
                    }

                    if !allowsActions {
                        Label("This is a view-only profile. Switch to an Owner profile to run actions.", systemImage: "eye")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let error {
                        InlineErrorBanner(error: error)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button(role: action.isDestructive ? .destructive : nil) {
                    Task { await run() }
                } label: {
                    Group {
                        if isRunning {
                            ProgressView()
                        } else {
                            Text(action.title)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.isDestructive ? .red : .enveAccent)
                .disabled(!canConfirm)
                .padding(20)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isRunning)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents(action.requiresTypedConfirmation ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(isRunning)
    }

    private func run() async {
        isRunning = true
        error = nil
        do {
            try await action.perform()
            isRunning = false
            onCompleted()
            dismiss()
        } catch {
            isRunning = false
            self.error = .from(error)
        }
    }
}

extension View {
    func actionConfirmation(_ action: Binding<PendingAction?>, onCompleted: @escaping () -> Void) -> some View {
        sheet(item: action) { pending in
            ActionConfirmationSheet(action: pending, onCompleted: onCompleted)
        }
    }
}
