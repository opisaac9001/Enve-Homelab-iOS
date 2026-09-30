import Foundation
import Testing
@testable import EnveHomelab

@MainActor
struct SSHStoreTests {
    private func makeStore() -> (SSHStore, URL, KeychainStore) {
        let url = FileManager.default.temporaryDirectory.appending(path: "ssh-\(UUID().uuidString).json")
        let keychain = KeychainStore(service: "com.isaaclamb.EnveHomelab.tests.\(UUID().uuidString)")
        return (SSHStore(fileURL: url, keychain: keychain), url, keychain)
    }

    @Test func passwordsLiveInKeychainNotOnDisk() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = SSHHost(name: "Tower", host: "tower.local", username: "root")
        try store.save(host, password: "hunter2-secret")

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(!onDisk.contains("hunter2-secret"))
        guard case .password(let password) = try store.credential(for: host) else {
            Issue.record("Expected password credential")
            return
        }
        #expect(password == "hunter2-secret")

        try store.delete(host)
        #expect(throws: SSHStoreError.self) { try store.credential(for: host) }
    }

    @Test func keysCannotBeDeletedWhileInUse() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let key = try store.addKey(named: "Laptop", material: OpenSSHKeys.parsePrivateKey(Fixtures.ed25519PrivateKey))
        #expect(key.fingerprint == Fixtures.ed25519Fingerprint)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(!onDisk.contains("PRIVATE"))

        var host = SSHHost(name: "Tower", host: "tower.local", username: "root")
        host.authentication = .key(key.id)
        try store.save(host, password: nil)
        #expect(throws: SSHStoreError.self) { try store.deleteKey(key) }

        guard case .privateKey(let material) = try store.credential(for: host) else {
            Issue.record("Expected key credential")
            return
        }
        let expected = try OpenSSHKeys.parsePrivateKey(Fixtures.ed25519PrivateKey)
        #expect(material == expected)

        try store.delete(host)
        try store.deleteKey(key)
        #expect(store.keys.isEmpty)
    }

    @Test func trustedHostKeysPersist() throws {
        let (store, url, keychain) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = SSHHost(name: "Tower", host: "tower.local", username: "root")
        try store.save(host, password: "pw")
        try store.trustHostKey(algorithm: "ssh-ed25519", fingerprint: "SHA256:abc", for: host.id)

        let reloaded = SSHStore(fileURL: url, keychain: keychain)
        #expect(reloaded.host(id: host.id)?.knownHostKey?.fingerprint == "SHA256:abc")
        try reloaded.delete(host)
    }
}
