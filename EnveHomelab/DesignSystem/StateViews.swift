import SwiftUI

struct LoadingStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorStateView: View {
    let error: NetworkError
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(
                error.errorDescription ?? "Something went wrong",
                systemImage: isUnsupported ? "puzzlepiece.extension" : "exclamationmark.triangle"
            )
        } description: {
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
            }
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
            RecoveryButtons(error: error)
        }
    }

    private var isUnsupported: Bool {
        if case .unsupportedByServer = error { true } else { false }
    }
}

struct InlineErrorBanner: View {
    let error: NetworkError

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "Refresh failed")
                    .font(.subheadline.weight(.semibold))
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack { RecoveryButtons(error: error) }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Ways to fix the connection an error came from, supplied by the screen that owns that connection.
struct ConnectionRecovery {
    var diagnose: @MainActor () -> Void
    var editConnection: @MainActor () -> Void
    var reviewCertificate: @MainActor (CertificateSummary) -> Void
}

extension EnvironmentValues {
    @Entry var connectionRecovery: ConnectionRecovery?
}

/// Offers only the fix that matches the failure: a certificate review, the connection editor, or diagnostics.
struct RecoveryButtons: View {
    @Environment(\.connectionRecovery) private var recovery
    @Environment(\.allowsActions) private var allowsActions
    let error: NetworkError

    var body: some View {
        if let recovery {
            if let certificate = error.reviewableCertificate, allowsActions {
                Button("Review Certificate") { recovery.reviewCertificate(certificate) }
                    .buttonStyle(.bordered)
            }
            if error.suggestsEditing, allowsActions {
                Button("Edit Connection") { recovery.editConnection() }
                    .buttonStyle(.bordered)
            }
            if error.suggestsDiagnosis {
                Button("Diagnose") { recovery.diagnose() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Keeps the last good value while a refresh is in flight or has failed.
struct LoadState<Value> {
    var value: Value?
    var error: NetworkError?
    var isLoading = false

    mutating func begin() {
        isLoading = true
    }

    mutating func finish(_ result: Result<Value, NetworkError>) {
        isLoading = false
        switch result {
        case .success(let value):
            self.value = value
            error = nil
        case .failure(let failure) where failure.isCancellation:
            break
        case .failure(let failure):
            error = failure
        }
    }
}

func captureResult<Value>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Value
) async -> Result<Value, NetworkError> {
    do {
        return .success(try await body())
    } catch {
        return .failure(.from(error))
    }
}

struct LoadStateContainer<Value, Content: View>: View {
    let state: LoadState<Value>
    let loadingMessage: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value = state.value {
            VStack(spacing: 12) {
                if let error = state.error {
                    InlineErrorBanner(error: error)
                }
                content(value)
            }
        } else if let error = state.error {
            ErrorStateView(error: error, retry: retry)
        } else {
            LoadingStateView(message: loadingMessage)
        }
    }
}

/// Server logs can reveal addresses, user names and activity from every device on the network, so View-only profiles don't see them.
private struct OwnerOnlyLogs: ViewModifier {
    @Environment(\.allowsActions) private var allowsActions

    func body(content: Content) -> some View {
        if allowsActions {
            content
        } else {
            ContentUnavailableView("Logs Are for Owner Profiles", systemImage: "lock.doc",
                                   description: Text("Server logs can show addresses, user names and activity from every device, so View-only profiles can't read them."))
                .enveScreen()
        }
    }
}

extension View {
    func ownerOnlyLogs() -> some View { modifier(OwnerOnlyLogs()) }
}
