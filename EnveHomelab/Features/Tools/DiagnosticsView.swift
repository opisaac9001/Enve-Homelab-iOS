import SwiftUI

struct DiagnosticsView: View {
    let title: String
    let url: URL
    let pinnedFingerprint: String?
    let authenticate: (@Sendable () async throws -> String)?
    @State private var steps: [DiagnosticStep] = []
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                LabeledValue(label: "Address", value: url.absoluteString, monospaced: true)
            }
            Section {
                if steps.isEmpty && isRunning {
                    LoadingStateView(message: "Running checks…").listRowBackground(Color.clear)
                }
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(step.status))
                            .foregroundStyle(color(step.status))
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(step.title).font(.body.weight(.semibold))
                                Spacer()
                                if let duration = step.duration { Text(ServiceFormat.milliseconds(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            Text(step.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.title), \(label(step.status))")
                }
            } footer: {
                Text("Each layer is checked in order: name lookup, network connection, TLS certificate, HTTP, then sign-in. The first failure usually explains the problem.")
            }
        }
        .navigationTitle("Diagnose \(title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Run Again") { Task { await run() } }.disabled(isRunning)
            }
        }
        .task { await run() }
        .bottomBarPadding()
        .enveScreen()
    }

    private func run() async {
        isRunning = true
        steps = []
        steps = await ConnectionDiagnostics.run(url: url, pinnedFingerprint: pinnedFingerprint, authenticate: authenticate)
        isRunning = false
    }

    private func icon(_ status: DiagnosticStep.Status) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ status: DiagnosticStep.Status) -> Color {
        switch status {
        case .passed: .green
        case .warning: .yellow
        case .failed: .red
        case .skipped: .secondary
        }
    }

    private func label(_ status: DiagnosticStep.Status) -> String {
        switch status {
        case .passed: "passed"
        case .warning: "warning"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }
}
