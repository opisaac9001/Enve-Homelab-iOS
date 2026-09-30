import Foundation
import Observation

/// Latest summary per integration for list rows; refreshed when rows appear, not on a timer.
@MainActor
@Observable
final class IntegrationStatusBoard {
    struct Cached: Codable, Sendable {
        var summary: IntegrationSummary
        var updatedAt: Date
    }

    private(set) var states: [UUID: LoadState<IntegrationSummary>] = [:]
    /// When each shown summary was last confirmed by the server; persisted so launches start with last-known data.
    private(set) var updatedAt: [UUID: Date] = [:]
    private var lastRefresh: [UUID: Date] = [:]
    private let file: JSONFile<[UUID: Cached]>?

    init(file: JSONFile<[UUID: Cached]>? = nil) {
        self.file = file
        for (id, cached) in (try? file?.load()) ?? [:] {
            states[id] = LoadState(value: cached.summary)
            updatedAt[id] = cached.updatedAt
        }
    }

    static let staleAfter: TimeInterval = 5 * 60

    func isStale(_ id: UUID, now: Date = .now) -> Bool {
        guard let date = updatedAt[id] else { return false }
        return now.timeIntervalSince(date) > Self.staleAfter || states[id]?.error != nil
    }
    @ObservationIgnored var observe: (@MainActor ([HealthObservation]) async -> Void)?

    func state(for id: UUID) -> LoadState<IntegrationSummary> {
        states[id] ?? LoadState()
    }

    func refresh(_ instance: IntegrationInstance, using app: AppModel, force: Bool = false) async {
        guard instance.isEnabled, instance.isSample || !app.isOffline else { return }
        if !force, let last = lastRefresh[instance.id], Date.now.timeIntervalSince(last) < 30 { return }
        lastRefresh[instance.id] = .now
        var state = states[instance.id] ?? LoadState()
        state.begin()
        states[instance.id] = state
        let result = await captureResult { try await app.client(for: instance).service.summary() }
        state.finish(result)
        states[instance.id] = state
        if case .success = result, !instance.isSample {
            updatedAt[instance.id] = .now
            persist()
        }
        guard !instance.isSample else { return }
        let observation: HealthObservation? = switch result {
        case .success(let summary):
            HealthObservation(sourceKind: .integration, sourceID: instance.id.uuidString, sourceName: instance.name, health: summary.health,
                              detail: [summary.headline, summary.detail].compactMap { $0 }.joined(separator: " · "))
        case .failure(let error) where !error.isCancellation && error != .offline:
            HealthObservation(sourceKind: .integration, sourceID: instance.id.uuidString, sourceName: instance.name, health: .critical,
                              detail: error.errorDescription ?? "Unavailable")
        case .failure:
            nil
        }
        if let observation { await observe?([observation]) }
    }

    func forget(_ id: UUID) {
        states[id] = nil
        lastRefresh[id] = nil
        updatedAt[id] = nil
        persist()
    }

    private func persist() {
        guard let file else { return }
        let cached = updatedAt.reduce(into: [UUID: Cached]()) { result, entry in
            if let summary = states[entry.key]?.value { result[entry.key] = Cached(summary: summary, updatedAt: entry.value) }
        }
        try? file.save(cached)
    }
}
