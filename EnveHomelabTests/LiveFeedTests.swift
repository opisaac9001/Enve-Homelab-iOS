import Foundation
import os
import Testing
@testable import EnveHomelab

@MainActor
private final class FeedLog {
    var modes: [LiveFeedMode] = []
    var values: [Result<Int, NetworkError>] = []

    func record(_ event: LiveFeedEvent<Int>) {
        switch event {
        case .mode(let mode): modes.append(mode)
        case .value(let value): values.append(value)
        }
    }

    func wait(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
struct LiveFeedTests {
    @Test func streamsSubscriptionValues() async {
        let log = FeedLog()
        let feed = LiveFeed<Int>(
            subscribe: {
                AsyncThrowingStream { continuation in
                    continuation.yield(1)
                    continuation.yield(2)
                }
            },
            poll: { Issue.record("Polling shouldn't run while streaming"); return 0 }
        )
        let task = Task { await feed.run { log.record($0) } }
        await log.wait { log.values.count == 2 }
        task.cancel()
        await task.value
        #expect(log.modes == [.connecting, .streaming])
        #expect(log.values.compactMap { try? $0.get() } == [1, 2])
    }

    @Test func fallsBackToPollingAndRetriesSubscription() async {
        let log = FeedLog()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let feed = LiveFeed<Int>(
            subscribe: {
                attempts.withLock { $0 += 1 }
                return AsyncThrowingStream { $0.finish(throwing: NetworkError.subscriptionUnavailable("closed")) }
            },
            poll: { 7 },
            pollInterval: .milliseconds(5),
            resubscribeAfter: .milliseconds(40)
        )
        let task = Task { await feed.run { log.record($0) } }
        await log.wait { attempts.withLock { $0 } >= 2 }
        task.cancel()
        await task.value
        #expect(attempts.withLock { $0 } >= 2)
        #expect(log.modes.contains(.polling(reason: .subscriptionUnavailable("closed"))))
        #expect(log.values.contains { (try? $0.get()) == 7 })
    }

    @Test func neverResubscribesWhenServerLacksTheSubscription() async {
        let log = FeedLog()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let feed = LiveFeed<Int>(
            subscribe: {
                attempts.withLock { $0 += 1 }
                return AsyncThrowingStream { $0.finish(throwing: NetworkError.unsupportedByServer("Cannot query field")) }
            },
            poll: { 3 },
            pollInterval: .milliseconds(5),
            resubscribeAfter: .milliseconds(10)
        )
        let task = Task { await feed.run { log.record($0) } }
        await log.wait { log.values.count >= 8 }
        task.cancel()
        await task.value
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test func pollingFailuresAreReportedWithoutStopping() async {
        let log = FeedLog()
        let feed = LiveFeed<Int>(
            subscribe: { AsyncThrowingStream { $0.finish(throwing: NetworkError.forbidden("")) } },
            poll: { throw NetworkError.timedOut },
            pollInterval: .milliseconds(5)
        )
        let task = Task { await feed.run { log.record($0) } }
        await log.wait { log.values.count >= 3 }
        task.cancel()
        await task.value
        #expect(log.values.allSatisfy { if case .failure(.timedOut) = $0 { true } else { false } })
    }

    @Test func cancellationEndsTheFeed() async {
        let log = FeedLog()
        let feed = LiveFeed<Int>(
            subscribe: { AsyncThrowingStream { _ in } },
            poll: { 0 }
        )
        let task = Task { await feed.run { log.record($0) } }
        await log.wait { !log.modes.isEmpty }
        task.cancel()
        await task.value
        #expect(log.modes == [.connecting])
    }
}

struct GraphQLWSMessageTests {
    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func connectionInitCarriesAPIKeyInPayload() throws {
        let json = try object(GraphQLWSMessage.connectionInit(apiKey: "abc-123").encoded())
        #expect(json["type"] as? String == "connection_init")
        #expect((json["payload"] as? [String: String])?["x-api-key"] == "abc-123")
    }

    @Test func subscribeWrapsQuery() throws {
        let json = try object(GraphQLWSMessage.subscribe(id: "1", query: "subscription { a }").encoded())
        #expect(json["type"] as? String == "subscribe")
        #expect(json["id"] as? String == "1")
        #expect((json["payload"] as? [String: String])?["query"] == "subscription { a }")
    }

    @Test func decodesServerMessages() throws {
        #expect(try GraphQLWSMessage.decode(#"{"type":"connection_ack"}"#) == .connectionAck)
        #expect(try GraphQLWSMessage.decode(#"{"type":"ping"}"#) == .ping)
        #expect(try GraphQLWSMessage.decode(#"{"type":"complete","id":"9"}"#) == .complete(id: "9"))

        guard case .next(let id, let payload) = try GraphQLWSMessage.decode(#"{"type":"next","id":"1","payload":{"data":{"systemMetricsCpu":{"percentTotal":12.5}}}}"#) else {
            Issue.record("Expected next")
            return
        }
        #expect(id == "1")
        struct Event: Decodable { struct CPU: Decodable { let percentTotal: Double }; let systemMetricsCpu: CPU }
        #expect(try GraphQLClient.decodeEnvelope(payload, as: Event.self).systemMetricsCpu.percentTotal == 12.5)
    }

    @Test func errorPayloadIsClassified() throws {
        guard case .error(_, let payload) = try GraphQLWSMessage.decode(#"{"type":"error","id":"1","payload":[{"message":"Cannot query field \"upsUpdates\" on type \"Subscription\"."}]}"#) else {
            Issue.record("Expected error")
            return
        }
        let errors = try JSONDecoder().decode([GraphQLErrorPayload].self, from: payload)
        if case .unsupportedByServer = GraphQLClient.classify(errors, status: 200) {} else {
            Issue.record("Expected unsupportedByServer")
        }
    }

    @Test func rejectsUnknownMessages() {
        #expect(throws: NetworkError.self) { try GraphQLWSMessage.decode(#"{"type":"mystery"}"#) }
        #expect(throws: NetworkError.self) { try GraphQLWSMessage.decode("not json") }
    }

    @Test func subscriptionURLUsesWebSocketScheme() {
        let secure = GraphQLClient(baseURL: URL(string: "https://tower.local:8443")!, apiKey: "k", pinnedFingerprint: nil)
        let plain = GraphQLClient(baseURL: URL(string: "http://192.168.1.2")!, apiKey: "k", pinnedFingerprint: nil)
        #expect(secure.subscriptionURL.absoluteString == "wss://tower.local:8443/graphql")
        #expect(plain.subscriptionURL.absoluteString == "ws://192.168.1.2/graphql")
    }
}
