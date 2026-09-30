import Foundation
import Observation

struct IntegrationInstance: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var kind: IntegrationKind
    var name: String
    var url: URL
    var identifier: String?
    var serverID: UUID?
    var isEnabled = true
    var pinnedCertificateSHA256: String?
    var pinnedCertificateSubject: String?
    /// Jellyfin and Emby resolve "continue watching" per user.
    var mediaUserID: String?
    var isSample = false

    var usesPlainHTTP: Bool { url.scheme?.lowercased() == "http" }
}

/// What the home screen and editor show for any integration.
struct IntegrationSummary: Sendable, Equatable, Codable {
    var product: String
    var version: String?
    var health: Health
    var headline: String
    var detail: String?
}

protocol IntegrationService: Sendable {
    func summary() async throws -> IntegrationSummary
}

@MainActor
@Observable
final class IntegrationStore {
    private(set) var instances: [IntegrationInstance] = []
    private(set) var loadError: String?
    private let file: JSONFile<[IntegrationInstance]>
    private let keychain: KeychainStore

    init(file: JSONFile<[IntegrationInstance]>, keychain: KeychainStore) {
        self.file = file
        self.keychain = keychain
        do {
            instances = try file.load() ?? []
        } catch {
            loadError = "Saved integrations couldn't be read: \(error.localizedDescription)"
        }
    }

    func instance(id: UUID) -> IntegrationInstance? {
        instances.first { $0.id == id }
    }

    func instances(in category: IntegrationCategory) -> [IntegrationInstance] {
        instances.filter { $0.kind.category == category }
    }

    func hasSecret(for instance: IntegrationInstance) -> Bool {
        (try? keychain.data(for: KeychainAccount.integrationSecret(instance.id))) != nil
    }

    func secret(for instance: IntegrationInstance) throws -> String? {
        try keychain.string(for: KeychainAccount.integrationSecret(instance.id))
    }

    func save(_ instance: IntegrationInstance, secret: String?) throws {
        if let secret {
            try keychain.set(secret, for: KeychainAccount.integrationSecret(instance.id))
        }
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        } else {
            instances.append(instance)
        }
        try file.save(instances)
    }

    func delete(_ instance: IntegrationInstance) throws {
        try keychain.delete(KeychainAccount.integrationSecret(instance.id))
        instances.removeAll { $0.id == instance.id }
        try file.save(instances)
    }
}
