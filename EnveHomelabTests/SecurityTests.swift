import Foundation
import Testing
@testable import EnveHomelab

struct X509ValidityTests {
    @Test func readsUTCTimeValidityFromVersion1Certificate() throws {
        let window = try #require(X509Validity.parse(Fixtures.utcTimeCertificate))
        #expect(window.notBefore == Fixtures.utcTimeNotBefore)
        #expect(window.notAfter == Fixtures.utcTimeNotAfter)
    }

    @Test func readsGeneralizedTimeFromVersion3Certificate() throws {
        let window = try #require(X509Validity.parse(Fixtures.generalizedTimeCertificate))
        #expect(window.notAfter == Fixtures.generalizedTimeNotAfter)
    }

    @Test func rejectsTruncatedData() {
        #expect(X509Validity.parse(Fixtures.utcTimeCertificate.prefix(40)) == nil)
        #expect(X509Validity.parse(Data([0x30, 0x84, 0xFF, 0xFF])) == nil)
        #expect(X509Validity.parse(Data()) == nil)
    }

    @Test func fingerprintMatchesOpenSSL() {
        #expect(CertificateInspector.fingerprint(of: Fixtures.utcTimeCertificate) == Fixtures.utcTimeFingerprint)
    }
}

struct TrustReuseTests {
    private func summary(fingerprint: String, systemTrusted: Bool) -> CertificateSummary {
        CertificateSummary(host: "tower.local", subject: "tower", sha256Fingerprint: fingerprint, notValidBefore: nil, notValidAfter: nil, evaluationFailure: systemTrusted ? nil : "untrusted")
    }

    @Test func onlySameHostFingerprintsAreReusable() {
        var local = ServerEndpoint(kind: .local, url: URL(string: "https://Tower.local")!)
        local.pinnedCertificateSHA256 = "AA"
        var other = ServerEndpoint(kind: .remote, url: URL(string: "https://nas.example.com")!)
        other.pinnedCertificateSHA256 = "BB"
        let server = ServerProfile(name: "Tower", endpoints: [local, other])
        var sibling = ServiceCheck(name: "Plex", url: URL(string: "https://tower.local:32400/identity")!)
        sibling.pinnedCertificateSHA256 = "CC"
        var unrelated = ServiceCheck(name: "Other", url: URL(string: "https://other.local")!)
        unrelated.pinnedCertificateSHA256 = "DD"
        let target = ServiceCheck(name: "Web UI", url: URL(string: "https://tower.local:8443")!)

        let reusable = TrustReuse.reviewedFingerprints(forHost: "tower.local", servers: [server], checks: [sibling, unrelated, target], excluding: target.id)
        #expect(Set(reusable.keys) == ["AA", "CC"])
        #expect(reusable["AA"] == "Tower (local network)")
    }

    @Test func excludesTheCheckItself() {
        var check = ServiceCheck(name: "Self", url: URL(string: "https://tower.local")!)
        check.pinnedCertificateSHA256 = "EE"
        #expect(TrustReuse.reviewedFingerprints(forHost: "tower.local", servers: [], checks: [check], excluding: check.id).isEmpty)
    }

    @Test func trustSourceReflectsHowTheCertificateWasAccepted() {
        var check = ServiceCheck(name: "x", url: URL(string: "https://tower.local")!)
        check.pinnedCertificateSHA256 = "PIN"
        #expect(ServiceProbe.trustSource(certificate: summary(fingerprint: "ANY", systemTrusted: true), check: check, reusable: [:], succeeded: true) == .system)
        #expect(ServiceProbe.trustSource(certificate: summary(fingerprint: "PIN", systemTrusted: false), check: check, reusable: [:], succeeded: true) == .pinned)
        #expect(ServiceProbe.trustSource(certificate: summary(fingerprint: "R", systemTrusted: false), check: check, reusable: ["R": "Tower"], succeeded: true) == .reused("Tower"))
        #expect(ServiceProbe.trustSource(certificate: summary(fingerprint: "PIN", systemTrusted: false), check: check, reusable: [:], succeeded: false) == .none)
    }
}

struct OpenSSHKeyTests {
    @Test func parsesEd25519AndReproducesPublicKeyAndFingerprint() throws {
        let material = try OpenSSHKeys.parsePrivateKey(Fixtures.ed25519PrivateKey)
        #expect(material.algorithm == .ed25519)
        #expect(material.rawRepresentation.count == 32)
        let line = try OpenSSHKeys.authorizedKeysLine(for: material, comment: "fixture")
        #expect(line == Fixtures.ed25519PublicKey)
        #expect(OpenSSHKeys.fingerprint(ofBlob: try OpenSSHKeys.publicKeyBlob(for: material)) == Fixtures.ed25519Fingerprint)
        #expect(OpenSSHKeys.fingerprint(ofOpenSSHPublicKey: Fixtures.ed25519PublicKey) == Fixtures.ed25519Fingerprint)
    }

    @Test func parsesECDSAP256() throws {
        let material = try OpenSSHKeys.parsePrivateKey(Fixtures.ecdsaPrivateKey)
        #expect(material.algorithm == .ecdsaP256)
        #expect(try OpenSSHKeys.authorizedKeysLine(for: material, comment: "fixture") == Fixtures.ecdsaPublicKey)
        #expect(OpenSSHKeys.fingerprint(ofOpenSSHPublicKey: Fixtures.ecdsaPublicKey) == Fixtures.ecdsaFingerprint)
    }

    @Test func rejectsEncryptedAndForeignKeys() {
        #expect(throws: OpenSSHKeyError.encrypted) { try OpenSSHKeys.parsePrivateKey(Fixtures.encryptedPrivateKey) }
        #expect(throws: OpenSSHKeyError.notOpenSSHFormat) { try OpenSSHKeys.parsePrivateKey("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----") }
        #expect(throws: OpenSSHKeyError.malformed) {
            try OpenSSHKeys.parsePrivateKey("-----BEGIN OPENSSH PRIVATE KEY-----\n!!!!\n-----END OPENSSH PRIVATE KEY-----")
        }
    }

    @Test func generatedKeysRoundTrip() throws {
        let material = OpenSSHKeys.generateEd25519()
        let line = try OpenSSHKeys.authorizedKeysLine(for: material, comment: "c")
        #expect(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        #expect(OpenSSHKeys.fingerprint(ofOpenSSHPublicKey: line)?.hasPrefix("SHA256:") == true)
    }
}

struct CommandRiskTests {
    @Test(arguments: [
        "rm -rf /mnt/user/appdata/old",
        "cd /tmp && rm -f *.log",
        "reboot",
        "shutdown -h now",
        "sudo systemctl restart nginx",
        "mkfs.xfs /dev/sdb1",
        "dd if=/dev/zero of=/dev/sdc bs=1M",
        "docker rm -f plex",
        "docker system prune -af",
        "zfs destroy tank/data",
        "virsh destroy Windows",
        "mdcmd stop",
        "kill -9 1234",
        "chown -R nobody:users /mnt/user/media",
        "echo 0 > /dev/sda",
        "docker stop plex",
        "docker compose down -v",
        "virsh shutdown win11",
        "/etc/rc.d/rc.docker stop",
        "zfs set compression=lz4 tank/media",
    ])
    func flagsDestructiveCommands(_ command: String) {
        #expect(!CommandRisk.assess(command).isEmpty, "\(command) should need confirmation")
    }

    @Test(arguments: [
        "uptime",
        "df -h",
        "docker ps",
        "docker logs --tail 50 plex",
        "docker compose ps",
        "ls -la /mnt/user",
        "cat /var/log/syslog | tail -n 100",
        "zpool status",
        "virsh list --all",
        "grep -r error /var/log",
        "format-report --dry-run",
    ])
    func allowsReadOnlyCommands(_ command: String) {
        #expect(CommandRisk.assess(command).isEmpty, "\(command) shouldn't need confirmation")
    }
}

struct EraseAndRecoveryTests {
    @Test func deleteAllRemovesOnlyThisServicesItems() throws {
        let store = KeychainStore(service: "tests.erase.\(UUID().uuidString)")
        let other = KeychainStore(service: "tests.keep.\(UUID().uuidString)")
        defer { try? other.deleteAll() }
        try store.set("a", for: KeychainAccount.integrationSecret(UUID()))
        try store.set("b", for: KeychainAccount.sshPassword(UUID()))
        try other.set("c", for: "kept")
        try store.deleteAll()
        try store.deleteAll()
        #expect(try other.string(for: "kept") == "c")
        #expect(try store.data(for: "anything") == nil)
    }

    @Test func recoveryMatchesTheFailure() {
        #expect(NetworkError.unauthorized.suggestsEditing && !NetworkError.unauthorized.suggestsDiagnosis)
        #expect(NetworkError.timedOut.suggestsDiagnosis && !NetworkError.timedOut.suggestsEditing)
        #expect(!NetworkError.offline.suggestsEditing && !NetworkError.offline.suggestsDiagnosis, "Nothing to fix on the server when the device is offline")
        #expect(!NetworkError.unsupportedByServer("x").suggestsEditing && !NetworkError.unsupportedByServer("x").suggestsDiagnosis)
    }
}

struct ErrorTextRedactionTests {
    @Test func redirectDescriptionDropsTheQuery() {
        let error = NetworkError.redirected(URL(string: "https://tautulli.example.com/api/v2?apikey=secret123&cmd=get_activity")!)
        #expect(error.errorDescription == "The server redirected to https://tautulli.example.com/api/v2.")
    }

    @Test func serverMessagesAreMasked() {
        let text = Data("Error: GET /api?apikey=abc123def failed".utf8)
        #expect(RESTClient.serverMessage(text) == "Error: GET /api?apikey=[redacted] failed")
        let json = Data(#"{"message": "Invalid token=zzz999"}"#.utf8)
        #expect(RESTClient.serverMessage(json) == "Invalid token=[redacted]")
    }
}
