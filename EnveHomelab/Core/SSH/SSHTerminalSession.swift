import Foundation
import Observation

@MainActor
@Observable
final class SSHTerminalSession {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reviewHostKey(PresentedHostKey, previousFingerprint: String?)
        case failed(String)
        case ended(exitStatus: Int?)

        var isActive: Bool {
            switch self {
            case .connecting, .connected: true
            default: false
            }
        }
    }

    private enum Event: Sendable {
        case output([UInt8])
        case exit(Int?)
    }

    let hostID: UUID
    private(set) var state: State = .idle
    private(set) var size = SSHTerminalSize(columns: 80, rows: 24)

    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var sink: (([UInt8]) -> Void)?
    @ObservationIgnored private var backlog: [UInt8] = []

    init(hostID: UUID) {
        self.hostID = hostID
    }

    /// Output that arrives before the terminal view attaches is replayed on attach.
    func attach(_ sink: @escaping ([UInt8]) -> Void) {
        self.sink = sink
        if !backlog.isEmpty {
            sink(backlog)
            backlog.removeAll()
        }
    }

    func connect(using store: SSHStore) async {
        guard !state.isActive, let host = store.host(id: hostID) else { return }
        state = .connecting
        let credential: SSHCredential
        do {
            credential = try store.credential(for: host)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        do {
            let connection = try await SSHConnection.open(
                host: host,
                credential: credential,
                size: size,
                onOutput: { continuation.yield(.output($0)) },
                onExit: { status in
                    continuation.yield(.exit(status))
                    continuation.finish()
                }
            )
            guard !Task.isCancelled else {
                await connection.close()
                state = .idle
                return
            }
            self.connection = connection
            state = .connected
            pump = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case .output(let bytes): self.deliver(bytes)
                    case .exit(let status): await self.finish(exitStatus: status)
                    }
                }
            }
        } catch let error as SSHConnectionError {
            continuation.finish()
            switch error {
            case .hostKeyNotTrusted(let key): state = .reviewHostKey(key, previousFingerprint: nil)
            case .hostKeyChanged(let key, let expected): state = .reviewHostKey(key, previousFingerprint: expected)
            default: state = .failed(error.localizedDescription)
            }
        } catch {
            continuation.finish()
            state = .failed(error.localizedDescription)
        }
    }

    func send(_ bytes: [UInt8]) {
        guard state == .connected else { return }
        connection?.send(bytes)
    }

    func run(_ command: String) {
        send(Array((command + "\r").utf8))
    }

    func resize(columns: Int, rows: Int) {
        let newSize = SSHTerminalSize(columns: max(columns, 1), rows: max(rows, 1))
        guard newSize != size else { return }
        size = newSize
        connection?.resize(newSize)
    }

    func disconnect() async {
        pump?.cancel()
        pump = nil
        let connection = connection
        self.connection = nil
        await connection?.close()
        if state.isActive { state = .ended(exitStatus: nil) }
    }

    private func deliver(_ bytes: [UInt8]) {
        if let sink {
            sink(bytes)
        } else {
            backlog.append(contentsOf: bytes)
        }
    }

    private func finish(exitStatus: Int?) async {
        let connection = connection
        self.connection = nil
        await connection?.close()
        state = .ended(exitStatus: exitStatus)
    }
}
