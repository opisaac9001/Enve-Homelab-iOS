import Foundation
import Observation

@MainActor
@Observable
final class ServerStore {
    private(set) var profiles: [ServerProfile] = []
    private(set) var loadError: String?

    private let file: JSONFile<[ServerProfile]>
    private let keychain: KeychainStore

    init(file: JSONFile<[ServerProfile]>, keychain: KeychainStore) {
        self.file = file
        self.keychain = keychain
        do {
            profiles = try file.load() ?? []
        } catch {
            loadError = "Saved servers couldn't be read: \(error.localizedDescription)"
        }
    }

    func profile(id: UUID) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    func save(_ profile: ServerProfile, apiKey: String?) throws {
        if let apiKey {
            try keychain.set(apiKey, for: KeychainAccount.unraidAPIKey(profile.id))
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
    }

    func delete(_ profile: ServerProfile) throws {
        try keychain.delete(KeychainAccount.unraidAPIKey(profile.id))
        profiles.removeAll { $0.id == profile.id }
        try persist()
    }

    func move(from source: IndexSet, to destination: Int) throws {
        profiles.move(fromOffsets: source, toOffset: destination)
        try persist()
    }

    func apiKey(for profile: ServerProfile) throws -> String? {
        try keychain.string(for: KeychainAccount.unraidAPIKey(profile.id))
    }

    private func persist() throws {
        try file.save(profiles)
    }
}
