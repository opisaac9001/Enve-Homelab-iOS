import Foundation

/// Implemented by the live GraphQL client and by the sample-data preview.
protocol UnraidService: Sendable {
    func identity() async throws -> UnraidIdentity
    func systemOverview() async throws -> SystemOverview
    func metrics() async throws -> SystemMetrics
    func metricsUpdates() -> AsyncThrowingStream<SystemMetrics, any Error>
    func arrayStatus() async throws -> ArrayStatus
    func arrayUpdates() -> AsyncThrowingStream<ArrayStatus, any Error>
    func parityHistory() async throws -> [ParityCheck]
    func perform(_ action: ParityAction) async throws
    func setArrayState(_ action: ArrayStateAction, decryptionPassword: String?) async throws -> ArrayState
    func physicalDisks() async throws -> [PhysicalDisk]
    func shares() async throws -> [UnraidShare]
    func upsDevices() async throws -> [UPSDevice]
    func upsUpdates() -> AsyncThrowingStream<[UPSDevice], any Error>
    func containers() async throws -> [DockerContainer]
    func containerLogs(id: String, tail: Int, since: String?) async throws -> ContainerLogBatch
    func perform(_ action: ContainerAction, containerID: String) async throws
    func refreshContainerUpdateStatus() async throws
    func updateContainer(id: String) async throws
    func containerDetails(id: String) async throws -> ContainerDetails
    func portConflicts() async throws -> DockerPortConflicts
    func temperatures() async throws -> TemperatureReport
    func logFiles() async throws -> [LogFileInfo]
    func logFile(path: String, lines: Int) async throws -> LogFileText
    func virtualMachines() async throws -> [VirtualMachine]
    func perform(_ action: VMAction, vmID: String) async throws
    func notificationOverview() async throws -> NotificationOverview
    func notifications(_ type: NotificationListType, importance: NotificationImportance?, limit: Int) async throws -> [UnraidNotification]
    func archiveNotification(id: String) async throws
    func archiveAllNotifications() async throws
}
