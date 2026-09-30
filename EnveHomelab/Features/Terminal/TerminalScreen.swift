import SwiftTerm
import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    @Environment(\.scenePhase) private var scenePhase
    let hostID: UUID
    @State private var session: SSHTerminalSession
    @State private var pendingCommand: SavedCommand?
    @State private var trustError: String?

    init(hostID: UUID) {
        self.hostID = hostID
        _session = State(initialValue: SSHTerminalSession(hostID: hostID))
    }

    private var host: SSHHost? { app.ssh.host(id: hostID) }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ZStack {
                SwiftUI.Color.black.ignoresSafeArea(edges: .bottom)
                TerminalSurface(session: session)
                    .opacity(showsTerminal ? 1 : 0)
                    .accessibilityHidden(!showsTerminal)
                overlay
            }
        }
        .navigationTitle(host?.name ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let host, !host.savedCommands.isEmpty {
                    Menu {
                        ForEach(host.savedCommands) { command in
                            Button {
                                if command.risks.isEmpty {
                                    session.run(command.command)
                                } else {
                                    pendingCommand = command
                                }
                            } label: {
                                Label(command.name, systemImage: command.risks.isEmpty ? "terminal" : "exclamationmark.triangle")
                            }
                        }
                    } label: {
                        Label("Saved Commands", systemImage: "text.badge.star")
                    }
                    .disabled(session.state != .connected)
                }
                if session.state.isActive {
                    Button {
                        Task { await session.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .task {
            guard allowsActions else { return }
            await session.connect(using: app.ssh)
        }
        .overlay {
            if !allowsActions {
                ContentUnavailableView("Terminal unavailable", systemImage: "eye", description: Text("View-only profiles can't open shells. Switch to an Owner profile in Settings."))
                    .background(.background)
            }
        }
        .onDisappear { Task { await session.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends sockets in the background; close cleanly rather than leave a dead session.
            if phase == .background { Task { await session.disconnect() } }
        }
        .alert(
            "Run “\(pendingCommand?.name ?? "")”?",
            isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } }),
            presenting: pendingCommand
        ) { command in
            Button("Run on \(host?.name ?? "host")", role: .destructive) { session.run(command.command) }
            Button("Insert Without Running") { session.send(Array(command.command.utf8)) }
            Button("Cancel", role: .cancel) {}
        } message: { command in
            Text("\(command.command)\n\n" + command.risks.map { "• \($0)" }.joined(separator: "\n"))
        }
    }

    private var showsTerminal: Bool {
        switch session.state {
        case .connected, .ended: true
        default: false
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption.weight(.semibold))
            Spacer()
            if let host {
                Text("\(host.username)@\(host.address)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed, .reviewHostKey: .red
        case .idle, .ended: .secondary
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected · \(session.size.columns)×\(session.size.rows)"
        case .reviewHostKey: "Host key needs review"
        case .failed: "Connection failed"
        case .ended(let status): status.map { "Session ended (exit \($0))" } ?? "Session ended"
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connecting:
            ProgressView("Connecting…")
                .tint(.white)
                .foregroundStyle(.white)
        case .reviewHostKey(let key, let previous):
            if let host {
                HostKeyReviewCard(host: host, key: key, previousFingerprint: previous, error: trustError) {
                    do {
                        try app.ssh.trustHostKey(algorithm: key.algorithm, fingerprint: key.fingerprint, for: host.id)
                        trustError = nil
                        Task { await session.connect(using: app.ssh) }
                    } catch {
                        trustError = error.localizedDescription
                    }
                }
            }
        case .failed(let message):
            reconnectCard(title: "Couldn't connect", message: message)
        case .ended:
            reconnectCard(title: "Session ended", message: nil)
        case .idle, .connected:
            EmptyView()
        }
    }

    private func reconnectCard(title: String, message: String?) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Reconnect") {
                    Task { await session.connect(using: app.ssh) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: 520)
    }
}

private struct HostKeyReviewCard: View {
    let host: SSHHost
    let key: PresentedHostKey
    let previousFingerprint: String?
    let error: String?
    let trust: () -> Void
    @State private var verified = false

    var body: some View {
        ScrollView {
            EnveCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        previousFingerprint == nil ? "New host key" : "Host key changed",
                        systemImage: previousFingerprint == nil ? "key.viewfinder" : "exclamationmark.shield.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(previousFingerprint == nil ? SwiftUI.Color.orange : SwiftUI.Color.red)

                    Text(previousFingerprint == nil
                         ? "This is the first connection to \(host.address). Confirm the key really belongs to your server before continuing."
                         : "\(host.address) presented a different key from the one you trusted. This happens after reinstalling or regenerating keys — or when someone is intercepting the connection.")
                        .font(.subheadline)

                    LabeledValue(label: "Algorithm", value: key.algorithm)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint").foregroundStyle(.secondary)
                        Text(key.fingerprint)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    if let previousFingerprint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Previously trusted").foregroundStyle(.secondary)
                            Text(previousFingerprint)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    Text("On the server, run: ssh-keygen -lf /etc/ssh/ssh_host_\(key.algorithm == "ssh-ed25519" ? "ed25519" : "ecdsa")_key.pub")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Toggle("The fingerprint matches my server", isOn: $verified)
                    Button(previousFingerprint == nil ? "Trust and Connect" : "Trust New Key and Connect", action: trust)
                        .buttonStyle(.borderedProminent)
                        .tint(previousFingerprint == nil ? SwiftUI.Color.enveAccent : SwiftUI.Color.red)
                        .disabled(!verified)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 560)
        }
    }
}

private struct TerminalSurface: UIViewRepresentable {
    let session: SSHTerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.caretColor = UIColor(SwiftUI.Color.enveAccent)
        view.keyboardAppearance = .dark
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.accessibilityLabel = "Terminal"
        session.attach { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if session.state == .connected, !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: SSHTerminalSession

        init(session: SSHTerminalSession) {
            self.session = session
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(columns: newCols, rows: newRows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Array(data))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        // Remote output must not open URLs or write the clipboard without the user acting in the app.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
