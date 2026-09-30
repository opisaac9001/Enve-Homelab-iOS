import Foundation
import os
import Testing
@testable import EnveHomelab

/// Run via Scripts/run-integration-tests.sh, which starts a throwaway sshd and graphql-ws fixture.
private enum Integration {
    static let directory = ProcessInfo.processInfo.environment["INTEGRATION_DIR"].map(URL.init(fileURLWithPath:))
    static let graphQLURL = ProcessInfo.processInfo.environment["GRAPHQL_WS_URL"].flatMap(URL.init(string:))

    static func read(_ name: String) throws -> String {
        try String(contentsOf: try #require(directory).appending(path: name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite(.enabled(if: Integration.directory != nil, "Requires Scripts/run-integration-tests.sh"))
struct SSHIntegrationTests {
    private func host(fingerprint: String?) throws -> SSHHost {
        var host = SSHHost(name: "fixture", host: "127.0.0.1", username: try Integration.read("ssh_user"))
        host.port = try #require(Int(try Integration.read("ssh_port")))
        host.knownHostKey = fingerprint.map { KnownHostKey(algorithm: "ssh-ed25519", fingerprint: $0, trustedAt: .now) }
        return host
    }

    private func credential(_ file: String) throws -> SSHCredential {
        .privateKey(try OpenSSHKeys.parsePrivateKey(try Integration.read(file)))
    }

    @Test func unknownHostKeyStopsBeforeAuthentication() async throws {
        let expected = try Integration.read("host_fingerprint")
        await #expect(throws: SSHConnectionError.hostKeyNotTrusted(PresentedHostKey(algorithm: "ssh-ed25519", fingerprint: expected))) {
            _ = try await SSHConnection.open(host: try host(fingerprint: nil), credential: try credential("client_ed25519"),
                                             size: SSHTerminalSize(columns: 80, rows: 24), onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func changedHostKeyIsRefused() async throws {
        let actual = try Integration.read("host_fingerprint")
        await #expect(throws: SSHConnectionError.hostKeyChanged(presented: PresentedHostKey(algorithm: "ssh-ed25519", fingerprint: actual), expected: "SHA256:not-the-key")) {
            _ = try await SSHConnection.open(host: try host(fingerprint: "SHA256:not-the-key"), credential: try credential("client_ed25519"),
                                             size: SSHTerminalSize(columns: 80, rows: 24), onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func rejectedKeyReportsAuthenticationFailure() async throws {
        await #expect(throws: SSHConnectionError.authenticationFailed) {
            _ = try await SSHConnection.open(host: try host(fingerprint: try Integration.read("host_fingerprint")), credential: try credential("wrong_ed25519"),
                                             size: SSHTerminalSize(columns: 80, rows: 24), onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func interactiveShellRoundTrip() async throws {
        let output = OSAllocatedUnfairLock(initialState: "")
        let exit = OSAllocatedUnfairLock<Int??>(initialState: nil)
        let connection = try await SSHConnection.open(
            host: try host(fingerprint: try Integration.read("host_fingerprint")),
            credential: try credential("client_ed25519"),
            size: SSHTerminalSize(columns: 100, rows: 30),
            onOutput: { bytes in output.withLock { $0 += String(decoding: bytes, as: UTF8.self) } },
            onExit: { status in exit.withLock { $0 = .some(status) } }
        )
        connection.resize(SSHTerminalSize(columns: 120, rows: 40))
        connection.send(Array("stty size; echo enve-$((20+22))\r".utf8))
        for _ in 0..<100 where !output.withLock({ $0.contains("enve-42") }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(output.withLock { $0.contains("enve-42") })
        #expect(output.withLock { $0.contains("40 120") })

        connection.send(Array("exit 3\r".utf8))
        for _ in 0..<100 where exit.withLock({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(exit.withLock { $0 } == .some(3))
        await connection.close()
    }
}

@Suite(.enabled(if: Integration.graphQLURL != nil, "Requires Scripts/run-integration-tests.sh"))
struct GraphQLSubscriptionIntegrationTests {
    private struct Event: Decodable, Sendable {
        struct CPU: Decodable, Sendable { let percentTotal: Double }
        let systemMetricsCpu: CPU
    }

    @Test func streamsEventsUntilComplete() async throws {
        let client = GraphQLClient(baseURL: try #require(Integration.graphQLURL), apiKey: "fixture-key", pinnedFingerprint: nil)
        var values: [Double] = []
        for try await event in client.subscribe("subscription { systemMetricsCpu { percentTotal } }", as: Event.self) {
            values.append(event.systemMetricsCpu.percentTotal)
        }
        #expect(values == [10, 20, 30])
    }

    @Test func unsupportedFieldIsClassified() async throws {
        let client = GraphQLClient(baseURL: try #require(Integration.graphQLURL), apiKey: "fixture-key", pinnedFingerprint: nil)
        do {
            for try await _ in client.subscribe("subscription { unsupportedField }", as: Event.self) {}
            Issue.record("Expected an error")
        } catch let error as NetworkError {
            guard case .unsupportedByServer = error else {
                Issue.record("Unexpected \(error)")
                return
            }
        }
    }

    @Test func wrongKeyNeverStreams() async throws {
        let client = GraphQLClient(baseURL: try #require(Integration.graphQLURL), apiKey: "wrong-key", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.self) {
            for try await _ in client.subscribe("subscription { systemMetricsCpu { percentTotal } }", as: Event.self) {}
        }
    }

    @Test func wrongPathFailsAsUnavailable() async throws {
        let base = try #require(Integration.graphQLURL).appending(path: "not-here")
        let client = GraphQLClient(baseURL: base, apiKey: "fixture-key", pinnedFingerprint: nil)
        await #expect(throws: NetworkError.self) {
            for try await _ in client.subscribe("subscription { systemMetricsCpu { percentTotal } }", as: Event.self) {}
        }
    }

    @Test func liveFeedFallsBackToPollingWhenUpgradeIsRefused() async throws {
        let base = try #require(Integration.graphQLURL).appending(path: "not-here")
        let client = GraphQLClient(baseURL: base, apiKey: "fixture-key", pinnedFingerprint: nil)
        let modes = OSAllocatedUnfairLock<[LiveFeedMode]>(initialState: [])
        let feed = LiveFeed<Double>(
            subscribe: { client.subscribe("subscription { systemMetricsCpu { percentTotal } }", as: Event.self).map(\.systemMetricsCpu.percentTotal).eraseToThrowingStream() },
            poll: { 1 },
            pollInterval: .milliseconds(20)
        )
        let task = Task { await feed.run { event in if case .mode(let mode) = event { modes.withLock { $0.append(mode) } } } }
        for _ in 0..<200 where !modes.withLock({ $0.contains { if case .polling = $0 { true } else { false } } }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        task.cancel()
        await task.value
        #expect(modes.withLock { $0.contains { if case .polling = $0 { true } else { false } } })
    }
}

private extension AsyncSequence where Self: Sendable, Element: Sendable {
    func eraseToThrowingStream() -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in self { continuation.yield(element) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
