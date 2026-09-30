import Foundation
import Observation

enum SSHStoreError: Error, LocalizedError {
    case keyInUse([String])
    case missingSecret

    var errorDescription: String? {
        switch self {
        case .keyInUse(let hosts): "This key is used by \(hosts.joined(separator: ", ")). Switch those hosts to another key first."
        case .missingSecret: "The saved password or key for this host is missing. Edit the host and enter it again."
        }
    }
}

@MainActor
@Observable
final class SSHStore {
    private struct Snapshot: Codable, Sendable {
        var hosts: [SSHHost]
        var keys: [SSHKeyInfo]
    }

    private(set) var hosts: [SSHHost] = []
    private(set) var keys: [SSHKeyInfo] = []
    private(set) var loadError: String?

    private let file: JSONFile<Snapshot>
    private let keychain: KeychainStore

    init(fileURL: URL, keychain: KeychainStore) {
        file = JSONFile(url: fileURL)
        self.keychain = keychain
        do {
            let snapshot = try file.load()
            hosts = snapshot?.hosts ?? []
            keys = snapshot?.keys ?? []
        } catch {
            loadError = "Saved SSH hosts couldn't be read: \(error.localizedDescription)"
        }
    }

    func host(id: UUID) -> SSHHost? {
        hosts.first { $0.id == id }
    }

    func key(id: UUID) -> SSHKeyInfo? {
        keys.first { $0.id == id }
    }

    func hasPassword(for host: SSHHost) -> Bool {
        (try? keychain.data(for: KeychainAccount.sshPassword(host.id))) != nil
    }

    func save(_ host: SSHHost, password: String?) throws {
        if let password {
            try keychain.set(password, for: KeychainAccount.sshPassword(host.id))
        }
        if case .key = host.authentication {
            try keychain.delete(KeychainAccount.sshPassword(host.id))
        }
        upsert(host)
        try persist()
    }

    func delete(_ host: SSHHost) throws {
        try keychain.delete(KeychainAccount.sshPassword(host.id))
        hosts.removeAll { $0.id == host.id }
        try persist()
    }

    func trustHostKey(algorithm: String, fingerprint: String, for hostID: UUID) throws {
        guard var host = host(id: hostID) else { return }
        host.knownHostKey = KnownHostKey(algorithm: algorithm, fingerprint: fingerprint, trustedAt: .now)
        upsert(host)
        try persist()
    }

    func credential(for host: SSHHost) throws -> SSHCredential {
        switch host.authentication {
        case .password:
            guard let password = try keychain.string(for: KeychainAccount.sshPassword(host.id)) else { throw SSHStoreError.missingSecret }
            return .password(password)
        case .key(let keyID):
            guard let data = try keychain.data(for: KeychainAccount.sshPrivateKey(keyID)) else { throw SSHStoreError.missingSecret }
            return .privateKey(try JSONDecoder().decode(SSHPrivateKeyMaterial.self, from: data))
        }
    }

    @discardableResult
    func addKey(named name: String, material: SSHPrivateKeyMaterial) throws -> SSHKeyInfo {
        let blob = try OpenSSHKeys.publicKeyBlob(for: material)
        let info = SSHKeyInfo(
            name: name,
            algorithm: material.algorithm,
            publicKey: try OpenSSHKeys.authorizedKeysLine(for: material, comment: "enve-homelab-\(name.replacingOccurrences(of: " ", with: "-").lowercased())"),
            fingerprint: OpenSSHKeys.fingerprint(ofBlob: blob),
            createdAt: .now
        )
        try keychain.set(JSONEncoder().encode(material), for: KeychainAccount.sshPrivateKey(info.id))
        keys.append(info)
        try persist()
        return info
    }

    func deleteKey(_ key: SSHKeyInfo) throws {
        let users = hosts.filter { $0.authentication == .key(key.id) }.map(\.name)
        guard users.isEmpty else { throw SSHStoreError.keyInUse(users) }
        try keychain.delete(KeychainAccount.sshPrivateKey(key.id))
        keys.removeAll { $0.id == key.id }
        try persist()
    }

    private func upsert(_ host: SSHHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }

    private func persist() throws {
        try file.save(Snapshot(hosts: hosts, keys: keys))
    }
}
