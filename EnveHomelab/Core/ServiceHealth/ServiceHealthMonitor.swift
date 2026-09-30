import Foundation
import Observation

@MainActor
@Observable
final class ServiceCheckStore {
    private(set) var checks: [ServiceCheck] = []
    private(set) var loadError: String?
    private let file: JSONFile<[ServiceCheck]>

    init(file: JSONFile<[ServiceCheck]>) {
        self.file = file
        do {
            checks = try file.load() ?? []
        } catch {
            loadError = "Saved service checks couldn't be read: \(error.localizedDescription)"
        }
    }

    func check(id: UUID) -> ServiceCheck? {
        checks.first { $0.id == id }
    }

    func save(_ check: ServiceCheck) throws {
        if let index = checks.firstIndex(where: { $0.id == check.id }) {
            checks[index] = check
        } else {
            checks.append(check)
        }
        try file.save(checks)
    }

    func delete(_ check: ServiceCheck) throws {
        checks.removeAll { $0.id == check.id }
        try file.save(checks)
    }
}

/// Runs due checks while the app is active; the owning task is cancelled when the app leaves the foreground.
@MainActor
@Observable
final class ServiceHealthMonitor {
    static let historyLimit = 30

    private(set) var history: [UUID: [ServiceCheckResult]] = [:]
    @ObservationIgnored private let file: JSONFile<[UUID: [ServiceCheckResult]]>?

    init(file: JSONFile<[UUID: [ServiceCheckResult]]>? = nil) {
        self.file = file
        history = (try? file?.load()) ?? [:]
    }
    private(set) var inFlight: Set<UUID> = []
    @ObservationIgnored var observe: (@MainActor ([HealthObservation]) async -> Void)?

    func latest(for id: UUID) -> ServiceCheckResult? {
        history[id]?.last
    }

    func isDue(_ check: ServiceCheck, now: Date = .now) -> Bool {
        guard !inFlight.contains(check.id) else { return false }
        guard let last = latest(for: check.id) else { return true }
        return now.timeIntervalSince(last.checkedAt) >= TimeInterval(check.intervalSeconds)
    }

    func run(checks: @MainActor () -> [ServiceCheck], servers: @MainActor () -> [ServerProfile]) async {
        while !Task.isCancelled {
            let due = checks().filter { isDue($0) }
            if !due.isEmpty {
                await probe(due, allChecks: checks(), servers: servers())
            }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    func checkNow(_ check: ServiceCheck, allChecks: [ServiceCheck], servers: [ServerProfile]) async {
        guard !inFlight.contains(check.id) else { return }
        await probe([check], allChecks: allChecks, servers: servers)
    }

    func forget(_ id: UUID) {
        history[id] = nil
        try? file?.save(history)
    }

    func probe(_ due: [ServiceCheck], allChecks: [ServiceCheck], servers: [ServerProfile]) async {
        let jobs = due.map { check in
            (check, TrustReuse.reviewedFingerprints(forHost: check.url.host() ?? "", servers: servers, checks: allChecks, excluding: check.id))
        }
        inFlight.formUnion(due.map(\.id))
        await withTaskGroup(of: (UUID, ServiceCheckResult).self) { group in
            for (check, reusable) in jobs {
                group.addTask { (check.id, await ServiceProbe.run(check, reusable: reusable)) }
            }
            for await (id, result) in group {
                inFlight.remove(id)
                if Task.isCancelled, case .failed(.cancelled) = result.outcome { continue }
                record(result, for: id)
            }
        }
        let observations = due.compactMap { check -> HealthObservation? in
            // The device losing its connection says nothing about the service.
            guard let result = latest(for: check.id), result.outcome != .failed(.offline) else { return nil }
            return HealthObservation(sourceKind: .serviceCheck, sourceID: check.id.uuidString, sourceName: check.name, health: result.health(), detail: Self.detail(result))
        }
        try? file?.save(history)
        await observe?(observations)
    }

    static func detail(_ result: ServiceCheckResult) -> String {
        var parts = [result.summary]
        if let days = result.daysUntilExpiry(), days < ServiceCheckResult.expiryWarningDays {
            parts.append(days < 0 ? "certificate expired" : "certificate expires in \(days) day\(days == 1 ? "" : "s")")
        }
        if let time = result.responseTime, time > ServiceCheck.slowResponseThreshold {
            parts.append("slow response")
        }
        return parts.joined(separator: " · ")
    }

    func record(_ result: ServiceCheckResult, for id: UUID) {
        var results = history[id, default: []]
        results.append(result)
        if results.count > Self.historyLimit { results.removeFirst(results.count - Self.historyLimit) }
        history[id] = results
    }
}
