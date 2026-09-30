import Foundation
import Testing
@testable import EnveHomelab

/// Every GraphQL document the Unraid client can send. `Scripts/validate-unraid-documents.mjs` checks them against the official schema.
struct UnraidDocumentTests {
    static var documents: [String: String] {
        var documents: [String: String] = [
            "identity": UnraidQueries.identity, "system": UnraidQueries.system, "systemCompat": UnraidQueries.systemCompat,
            "metrics": UnraidQueries.metrics, "array": UnraidQueries.array, "arraySubscription": UnraidQueries.arraySubscription,
            "arrayCompat": UnraidQueries.arrayCompat, "parityHistory": UnraidQueries.parityHistory,
            "containers": UnraidQueries.containers, "containersCompat": UnraidQueries.containersCompat, "containerLogs": UnraidQueries.containerLogs,
            "virtualMachines": UnraidQueries.virtualMachines, "notificationOverview": UnraidQueries.notificationOverview,
            "notifications": UnraidQueries.notifications, "archiveNotification": UnraidQueries.archiveNotification, "archiveAll": UnraidQueries.archiveAll,
            "cpuSubscription": UnraidQueries.cpuSubscription, "memorySubscription": UnraidQueries.memorySubscription,
            "setArrayState": UnraidQueries.setArrayState, "physicalDisks": UnraidQueries.physicalDisks, "shares": UnraidQueries.shares,
            "upsDevices": UnraidQueries.upsDevices, "upsSubscription": UnraidQueries.upsSubscription,
            "refreshDockerDigests": UnraidQueries.refreshDockerDigests, "updateContainer": UnraidQueries.updateContainer,
            "containerDetails": UnraidQueries.containerDetails, "portConflicts": UnraidQueries.portConflicts,
            "temperatures": UnraidQueries.temperatures, "logFiles": UnraidQueries.logFiles, "logFile": UnraidQueries.logFile,
        ]
        for action in [ParityAction.startCheck, .pause, .resume, .cancel] { documents["parity.\(action.rawValue)"] = UnraidQueries.parity(action) }
        for action in ContainerAction.allCases { documents["container.\(action.rawValue)"] = UnraidQueries.container(action) }
        for action in VMAction.allCases { documents["vm.\(action.rawValue)"] = UnraidQueries.vm(action) }
        return documents
    }

    @Test func documentsAreNamedOperationsAndCanBeExported() throws {
        for (name, document) in Self.documents {
            let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(["query ", "mutation ", "subscription ", "fragment "].contains { trimmed.hasPrefix($0) }, "\(name) must be a named operation")
        }
        // The integration script passes a path so the documents can be validated against the published schema.
        if let path = ProcessInfo.processInfo.environment["UNRAID_DOCUMENTS"] {
            let data = try JSONSerialization.data(withJSONObject: Self.documents, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
