import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os

struct PresentedHostKey: Sendable, Equatable, Identifiable {
    let algorithm: String
    let fingerprint: String

    var id: String { fingerprint }
}

enum SSHConnectionError: Error, Equatable, LocalizedError {
    case hostKeyNotTrusted(PresentedHostKey)
    case hostKeyChanged(presented: PresentedHostKey, expected: String)
    case authenticationFailed
    case unsupportedAlgorithms
    case unreachable(String)
    case timedOut
    case closed(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyNotTrusted: "Review this host's key before connecting."
        case .hostKeyChanged: "The host key has changed since you trusted it."
        case .authenticationFailed: "The server rejected the username, password or key."
        case .unsupportedAlgorithms: "The server doesn't offer a host key or cipher this app supports (Ed25519 or ECDSA host keys, AES-GCM)."
        case .unreachable(let detail): "The host couldn't be reached. \(detail)"
        case .timedOut: "The connection timed out."
        case .closed(let detail): "The connection closed. \(detail)"
        }
    }
}

/// Fails every host key that doesn't match the stored fingerprint and records what the server presented.
private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let expectedFingerprint: String?
    private let presented = OSAllocatedUnfairLock<PresentedHostKey?>(initialState: nil)

    init(expectedFingerprint: String?) {
        self.expectedFingerprint = expectedFingerprint
    }

    var presentedKey: PresentedHostKey? { presented.withLock { $0 } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let algorithm = String(line.prefix { $0 != " " })
        guard let fingerprint = OpenSSHKeys.fingerprint(ofOpenSSHPublicKey: line) else {
            validationCompletePromise.fail(SSHConnectionError.unsupportedAlgorithms)
            return
        }
        let key = PresentedHostKey(algorithm: algorithm, fingerprint: fingerprint)
        presented.withLock { $0 = key }
        if let expectedFingerprint, expectedFingerprint == fingerprint {
            validationCompletePromise.succeed(())
        } else if let expectedFingerprint {
            validationCompletePromise.fail(SSHConnectionError.hostKeyChanged(presented: key, expected: expectedFingerprint))
        } else {
            validationCompletePromise.fail(SSHConnectionError.hostKeyNotTrusted(key))
        }
    }
}

/// Offers the single stored credential once; a rejection ends authentication.
private final class CredentialOffer: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private let username: String
    private let credential: SSHCredential
    private let attempts = OSAllocatedUnfairLock(initialState: 0)

    init(username: String, credential: SSHCredential) {
        self.username = username
        self.credential = credential
    }

    /// The delegate is only asked again after the server refuses the previous offer.
    var wasRejected: Bool { attempts.withLock { $0 > 1 } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let attempt = attempts.withLock { count in
            count += 1
            return count
        }
        guard attempt == 1 else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        do {
            switch credential {
            case .password(let password):
                guard availableMethods.contains(.password) else { throw SSHConnectionError.authenticationFailed }
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password))))
            case .privateKey(let material):
                guard availableMethods.contains(.publicKey) else { throw SSHConnectionError.authenticationFailed }
                let key: NIOSSHPrivateKey = switch material.algorithm {
                case .ed25519: NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: material.rawRepresentation))
                case .ecdsaP256: NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: material.rawRepresentation))
                }
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
            }
        } catch {
            nextChallengePromise.fail(error)
        }
    }
}

struct SSHTerminalSize: Sendable, Equatable {
    var columns: Int
    var rows: Int
}

/// Bridges the SSH session channel to byte callbacks; confined to the channel's event loop.
private final class ShellChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let size: SSHTerminalSize
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int?) -> Void
    private var exitStatus: Int?

    init(size: SSHTerminalSize, onOutput: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int?) -> Void) {
        self.size = size
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        onOutput(Array(buffer.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = status.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onExit(exitStatus)
        context.fireChannelInactive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

private final class ConnectionErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private let recorded = OSAllocatedUnfairLock<String?>(initialState: nil)

    var lastError: String? { recorded.withLock { $0 } }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        recorded.withLock { $0 = String(describing: error) }
        context.close(promise: nil)
    }
}

/// One interactive shell over one TCP connection. Owns its event loop group; `close()` tears everything down.
final class SSHConnection: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let shell: any Channel

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, shell: any Channel) {
        self.group = group
        self.channel = channel
        self.shell = shell
    }

    static func open(
        host: SSHHost,
        credential: SSHCredential,
        size: SSHTerminalSize,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (Int?) -> Void
    ) async throws -> SSHConnection {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let validator = HostKeyValidator(expectedFingerprint: host.knownHostKey?.fingerprint)
        let offer = CredentialOffer(username: host.username, credential: credential)
        let errors = ConnectionErrorHandler()

        do {
            let bootstrap = ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handler = NIOSSHHandler(
                            role: .client(.init(userAuthDelegate: offer, serverAuthDelegate: validator)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(handler)
                        try channel.pipeline.syncOperations.addHandler(errors)
                    }
                }
            let channel = try await bootstrap.connect(host: host.host, port: host.port).get()

            let shell = try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
                let promise = channel.eventLoop.makePromise(of: (any Channel).self)
                do {
                    let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, type in
                        guard type == .session else {
                            return child.eventLoop.makeFailedFuture(SSHConnectionError.closed("Unexpected channel type."))
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ShellChannelHandler(size: size, onOutput: onOutput, onExit: onExit))
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult
            }.get()

            shell.closeFuture.whenComplete { _ in channel.close(promise: nil) }
            return SSHConnection(group: group, channel: channel, shell: shell)
        } catch {
            try? await group.shutdownGracefully()
            throw classify(error, validator: validator, offer: offer, recorded: errors.lastError)
        }
    }

    func send(_ bytes: [UInt8]) {
        shell.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
    }

    func resize(_ size: SSHTerminalSize) {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        shell.triggerUserOutboundEvent(request, promise: nil)
    }

    func close() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private static func classify(_ error: any Error, validator: HostKeyValidator, offer: CredentialOffer, recorded: String?) -> SSHConnectionError {
        if let error = error as? SSHConnectionError { return error }
        if let presented = validator.presentedKey {
            if let expected = validator.expectedFingerprint, expected != presented.fingerprint {
                return .hostKeyChanged(presented: presented, expected: expected)
            }
            if validator.expectedFingerprint == nil {
                return .hostKeyNotTrusted(presented)
            }
        }
        if offer.wasRejected {
            return .authenticationFailed
        }
        if let error = error as? NIOSSHError, error.type == .keyExchangeNegotiationFailure {
            return .unsupportedAlgorithms
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return .timedOut
        }
        if error is NIOConnectionError || error is IOError {
            return .unreachable(String(describing: error))
        }
        return .closed(recorded ?? String(describing: error))
    }
}
