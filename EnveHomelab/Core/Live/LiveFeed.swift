import Foundation

enum LiveFeedMode: Equatable, Sendable {
    case connecting
    case streaming
    case polling(reason: NetworkError?)

    var isStreaming: Bool { self == .streaming }
}

enum LiveFeedEvent<Value: Sendable>: Sendable {
    case mode(LiveFeedMode)
    case value(Result<Value, NetworkError>)
}

/// Prefers a subscription and degrades to polling; runs until the calling task is cancelled.
struct LiveFeed<Value: Sendable>: Sendable {
    let subscribe: @Sendable () -> AsyncThrowingStream<Value, any Error>
    let poll: @Sendable () async throws -> Value
    var pollInterval: Duration = .seconds(5)
    var resubscribeAfter: Duration = .seconds(120)

    func run(_ handle: @MainActor @Sendable (LiveFeedEvent<Value>) -> Void) async {
        while !Task.isCancelled {
            await handle(.mode(.connecting))
            var reason: NetworkError?
            do {
                var announced = false
                for try await value in subscribe() {
                    if !announced {
                        await handle(.mode(.streaming))
                        announced = true
                    }
                    await handle(.value(.success(value)))
                }
                reason = .subscriptionUnavailable("The server closed the live stream.")
            } catch {
                reason = NetworkError.from(error)
            }
            if Task.isCancelled || reason == .cancelled { return }

            await handle(.mode(.polling(reason: reason)))
            let clock = ContinuousClock()
            let deadline = clock.now + resubscribeAfter
            let retrySubscription = Self.shouldRetrySubscription(after: reason)
            while !Task.isCancelled && (!retrySubscription || clock.now < deadline) {
                let result: Result<Value, NetworkError>
                do {
                    result = .success(try await poll())
                } catch {
                    result = .failure(.from(error))
                }
                if case .failure(.cancelled) = result { return }
                await handle(.value(result))
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// A server that lacks the subscription or rejects the key won't change mid-session.
    static func shouldRetrySubscription(after reason: NetworkError?) -> Bool {
        switch reason {
        case .unsupportedByServer, .forbidden, .unauthorized: false
        default: true
        }
    }
}
