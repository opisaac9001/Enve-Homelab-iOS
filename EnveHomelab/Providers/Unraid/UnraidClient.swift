import Foundation

struct UnraidClient: UnraidService {
    let graphQL: GraphQLClient

    init(endpoint: ServerEndpoint, apiKey: String, timeout: TimeInterval = 20) {
        graphQL = GraphQLClient(
            baseURL: endpoint.url,
            apiKey: apiKey,
            pinnedFingerprint: endpoint.pinnedCertificateSHA256,
            timeout: timeout
        )
    }

    func identity() async throws -> UnraidIdentity {
        struct Response: Decodable, Sendable {
            struct Vars: Decodable, Sendable { let name: String?; let version: String? }
            let vars: Vars
        }
        let response = try await graphQL.send(UnraidQueries.identity, as: Response.self)
        return UnraidIdentity(name: response.vars.name ?? "Unraid", unraidVersion: response.vars.version)
    }

    func systemOverview() async throws -> SystemOverview {
        struct Response: Decodable, Sendable {
            struct Info: Decodable, Sendable {
                struct OS: Decodable, Sendable { let hostname: String?; let uptime: String?; let kernel: String? }
                struct CPU: Decodable, Sendable { let brand: String?; let cores: Int?; let threads: Int? }
                struct Versions: Decodable, Sendable {
                    struct Core: Decodable, Sendable { let unraid: String?; let api: String? }
                    let core: Core
                }
                let os: OS
                let cpu: CPU
                let versions: Versions?
            }
            let info: Info
        }
        let info = try await sendWithFallback(UnraidQueries.system, compat: UnraidQueries.systemCompat, as: Response.self).info
        return SystemOverview(
            hostname: info.os.hostname,
            bootTime: APIDate.parse(info.os.uptime),
            kernel: info.os.kernel,
            cpuBrand: info.cpu.brand,
            cores: info.cpu.cores,
            threads: info.cpu.threads,
            unraidVersion: info.versions?.core.unraid,
            apiVersion: info.versions?.core.api
        )
    }

    func metrics() async throws -> SystemMetrics {
        struct Response: Decodable, Sendable {
            struct Metrics: Decodable, Sendable {
                let cpu: CPUPercent?
                let memory: MemoryUsage?
            }
            let metrics: Metrics
        }
        let metrics = try await graphQL.send(UnraidQueries.metrics, as: Response.self).metrics
        return SystemMetrics(cpuPercent: metrics.cpu?.percentTotal, memory: metrics.memory)
    }

    /// CPU and memory arrive on separate subscriptions; each event carries the latest of both.
    func metricsUpdates() -> AsyncThrowingStream<SystemMetrics, any Error> {
        struct CPUEvent: Decodable, Sendable { let systemMetricsCpu: CPUPercent }
        struct MemoryEvent: Decodable, Sendable { let systemMetricsMemory: MemoryUsage }
        enum Sample: Sendable {
            case cpu(Double)
            case memory(MemoryUsage)
        }

        let graphQL = graphQL
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        let (samples, sink) = AsyncStream.makeStream(of: Sample.self)
                        group.addTask {
                            for try await event in graphQL.subscribe(UnraidQueries.cpuSubscription, as: CPUEvent.self) {
                                sink.yield(.cpu(event.systemMetricsCpu.percentTotal))
                            }
                            throw NetworkError.subscriptionUnavailable("The CPU stream ended.")
                        }
                        group.addTask {
                            for try await event in graphQL.subscribe(UnraidQueries.memorySubscription, as: MemoryEvent.self) {
                                sink.yield(.memory(event.systemMetricsMemory))
                            }
                            throw NetworkError.subscriptionUnavailable("The memory stream ended.")
                        }
                        group.addTask {
                            var latest = SystemMetrics(cpuPercent: nil, memory: nil)
                            for await sample in samples {
                                switch sample {
                                case .cpu(let value): latest.cpuPercent = value
                                case .memory(let value): latest.memory = value
                                }
                                continuation.yield(latest)
                            }
                        }
                        defer { sink.finish() }
                        try await group.next()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func arrayStatus() async throws -> ArrayStatus {
        struct Response: Decodable, Sendable { let array: ArrayPayload }
        return try await sendWithFallback(UnraidQueries.array, compat: UnraidQueries.arrayCompat, as: Response.self).array.status
    }

    func arrayUpdates() -> AsyncThrowingStream<ArrayStatus, any Error> {
        struct Event: Decodable, Sendable { let arraySubscription: ArrayPayload }
        let events = graphQL.subscribe(UnraidQueries.arraySubscription, as: Event.self)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        continuation.yield(event.arraySubscription.status)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func parityHistory() async throws -> [ParityCheck] {
        struct Response: Decodable, Sendable { let parityHistory: [ParityCheck] }
        return try await graphQL.send(UnraidQueries.parityHistory, as: Response.self).parityHistory
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func perform(_ action: ParityAction) async throws {
        _ = try await graphQL.send(UnraidQueries.parity(action), as: JSONValue.self)
    }

    func setArrayState(_ action: ArrayStateAction, decryptionPassword: String?) async throws -> ArrayState {
        struct Response: Decodable, Sendable {
            struct Mutations: Decodable, Sendable {
                struct Result: Decodable, Sendable { let state: ArrayState }
                let setState: Result
            }
            let array: Mutations
        }
        var input: [String: GraphQLVariable] = ["desiredState": .string(action.rawValue)]
        if action == .start, let decryptionPassword, !decryptionPassword.isEmpty {
            input["decryptionPassword"] = .string(decryptionPassword)
        }
        return try await graphQL.send(UnraidQueries.setArrayState, variables: ["input": .object(input)], as: Response.self)
            .array.setState.state
    }

    func physicalDisks() async throws -> [PhysicalDisk] {
        struct Response: Decodable, Sendable { let disks: [PhysicalDisk] }
        return try await graphQL.send(UnraidQueries.physicalDisks, as: Response.self).disks
    }

    func shares() async throws -> [UnraidShare] {
        struct Response: Decodable, Sendable { let shares: [UnraidShare] }
        return try await graphQL.send(UnraidQueries.shares, as: Response.self).shares
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func upsDevices() async throws -> [UPSDevice] {
        struct Response: Decodable, Sendable { let upsDevices: [UPSDevice] }
        return try await graphQL.send(UnraidQueries.upsDevices, as: Response.self).upsDevices
    }

    /// Seeds with the full device list, then merges each pushed device update into it.
    func upsUpdates() -> AsyncThrowingStream<[UPSDevice], any Error> {
        struct Event: Decodable, Sendable { let upsUpdates: UPSDevice }
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var devices = try await client.upsDevices()
                    continuation.yield(devices)
                    for try await event in client.graphQL.subscribe(UnraidQueries.upsSubscription, as: Event.self) {
                        devices = UPSDevice.merging(event.upsUpdates, into: devices)
                        continuation.yield(devices)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func containers() async throws -> [DockerContainer] {
        struct Response: Decodable, Sendable {
            struct Docker: Decodable, Sendable { let containers: [DockerContainer] }
            let docker: Docker
        }
        return try await sendWithFallback(UnraidQueries.containers, compat: UnraidQueries.containersCompat, as: Response.self)
            .docker.containers
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func containerLogs(id: String, tail: Int, since: String?) async throws -> ContainerLogBatch {
        struct Response: Decodable, Sendable {
            struct Docker: Decodable, Sendable { let logs: ContainerLogBatch }
            let docker: Docker
        }
        var variables: [String: GraphQLVariable] = ["id": .string(id), "tail": .int(tail)]
        if let since { variables["since"] = .string(since) }
        return try await graphQL.send(UnraidQueries.containerLogs, variables: variables, as: Response.self).docker.logs
    }

    func perform(_ action: ContainerAction, containerID: String) async throws {
        _ = try await graphQL.send(UnraidQueries.container(action), variables: ["id": .string(containerID)], as: JSONValue.self)
    }

    func refreshContainerUpdateStatus() async throws {
        _ = try await graphQL.send(UnraidQueries.refreshDockerDigests, as: JSONValue.self)
    }

    func updateContainer(id: String) async throws {
        _ = try await graphQL.send(UnraidQueries.updateContainer, variables: ["id": .string(id)], as: JSONValue.self)
    }

    func containerDetails(id: String) async throws -> ContainerDetails {
        struct Response: Decodable, Sendable {
            struct Docker: Decodable, Sendable { let container: ContainerDetails? }
            let docker: Docker
        }
        guard let details = try await graphQL.send(UnraidQueries.containerDetails, variables: ["id": .string(id)], as: Response.self).docker.container else {
            throw NetworkError.unexpectedResponse("The server no longer has this container.")
        }
        return details
    }

    func portConflicts() async throws -> DockerPortConflicts {
        struct Response: Decodable, Sendable {
            struct Docker: Decodable, Sendable { let portConflicts: DockerPortConflicts }
            let docker: Docker
        }
        return try await graphQL.send(UnraidQueries.portConflicts, as: Response.self).docker.portConflicts
    }

    func temperatures() async throws -> TemperatureReport {
        struct Response: Decodable, Sendable {
            struct Metrics: Decodable, Sendable { let temperature: TemperatureReport? }
            let metrics: Metrics
        }
        return try await graphQL.send(UnraidQueries.temperatures, as: Response.self).metrics.temperature
            ?? TemperatureReport(average: nil, warningCount: 0, criticalCount: 0, sensors: [])
    }

    func logFiles() async throws -> [LogFileInfo] {
        struct Response: Decodable, Sendable { let logFiles: [LogFileInfo] }
        return try await graphQL.send(UnraidQueries.logFiles, as: Response.self).logFiles
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func logFile(path: String, lines: Int) async throws -> LogFileText {
        struct Response: Decodable, Sendable { let logFile: LogFileText }
        return try await graphQL.send(UnraidQueries.logFile, variables: ["path": .string(path), "lines": .int(lines)], as: Response.self).logFile
    }

    func virtualMachines() async throws -> [VirtualMachine] {
        struct Response: Decodable, Sendable {
            struct VMs: Decodable, Sendable { let domains: [VirtualMachine]? }
            let vms: VMs
        }
        return (try await graphQL.send(UnraidQueries.virtualMachines, as: Response.self).vms.domains ?? [])
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func perform(_ action: VMAction, vmID: String) async throws {
        struct Response: Decodable, Sendable {
            struct VM: Decodable, Sendable {
                let result: Bool
                private struct Key: CodingKey {
                    var stringValue: String
                    var intValue: Int? { nil }
                    init(stringValue: String) { self.stringValue = stringValue }
                    init?(intValue: Int) { nil }
                }
                init(from decoder: any Decoder) throws {
                    let c = try decoder.container(keyedBy: Key.self)
                    guard let key = c.allKeys.first else {
                        throw NetworkError.unexpectedResponse("The VM action returned no result.")
                    }
                    result = try c.decode(Bool.self, forKey: key)
                }
            }
            let vm: VM
        }
        let response = try await graphQL.send(UnraidQueries.vm(action), variables: ["id": .string(vmID)], as: Response.self)
        guard response.vm.result else {
            throw NetworkError.graphQL(["The server reported that “\(action.title)” did not succeed."])
        }
    }

    func notificationOverview() async throws -> NotificationOverview {
        struct Response: Decodable, Sendable {
            struct Notifications: Decodable, Sendable { let overview: NotificationOverview }
            let notifications: Notifications
        }
        return try await graphQL.send(UnraidQueries.notificationOverview, as: Response.self).notifications.overview
    }

    func notifications(_ type: NotificationListType, importance: NotificationImportance?, limit: Int) async throws -> [UnraidNotification] {
        struct Response: Decodable, Sendable {
            struct Notifications: Decodable, Sendable { let list: [UnraidNotification] }
            let notifications: Notifications
        }
        var filter: [String: GraphQLVariable] = ["type": .string(type.rawValue), "offset": .int(0), "limit": .int(limit)]
        if let importance { filter["importance"] = .string(importance.rawValue) }
        return try await graphQL.send(UnraidQueries.notifications, variables: ["filter": .object(filter)], as: Response.self)
            .notifications.list
    }

    func archiveNotification(id: String) async throws {
        _ = try await graphQL.send(UnraidQueries.archiveNotification, variables: ["id": .string(id)], as: JSONValue.self)
    }

    func archiveAllNotifications() async throws {
        _ = try await graphQL.send(UnraidQueries.archiveAll, as: JSONValue.self)
    }

    private func sendWithFallback<Response: Decodable & Sendable>(
        _ query: String,
        compat: String,
        as type: Response.Type
    ) async throws -> Response {
        do {
            return try await graphQL.send(query, as: type)
        } catch NetworkError.unsupportedByServer {
            return try await graphQL.send(compat, as: type)
        }
    }
}

private struct CPUPercent: Decodable, Sendable {
    let percentTotal: Double
}

private struct ArrayPayload: Decodable, Sendable {
    struct Capacity: Decodable, Sendable {
        struct Values: Decodable, Sendable { let free, used, total: String }
        let kilobytes: Values
    }

    let state: ArrayState
    let capacity: Capacity
    let parityCheckStatus: ParityCheck?
    let parities: [ArrayDisk]
    let disks: [ArrayDisk]
    let caches: [ArrayDisk]
    let boot: ArrayDisk?

    var status: ArrayStatus {
        let kilobytes = capacity.kilobytes
        return ArrayStatus(
            state: state,
            capacity: ArrayCapacity(
                totalKB: Int64(kilobytes.total) ?? 0,
                usedKB: Int64(kilobytes.used) ?? 0,
                freeKB: Int64(kilobytes.free) ?? 0
            ),
            parityCheck: parityCheckStatus,
            parities: parities.sorted { $0.slot < $1.slot },
            disks: disks.sorted { $0.slot < $1.slot },
            caches: caches.sorted { $0.slot < $1.slot },
            boot: boot
        )
    }
}
