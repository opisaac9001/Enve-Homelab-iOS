import Foundation
import Testing
@testable import EnveHomelab

struct UnraidDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func arrayDiskAcceptsBigIntAsStringOrNumber() throws {
        let disk = try decode(ArrayDisk.self, """
        {"id":"abc:disk1","idx":1,"name":"disk1","size":"17578328012","fsSize":17578328012,"fsUsed":"100",
         "fsFree":null,"status":"DISK_OK","temp":36,"type":"DATA","numErrors":"0"}
        """)
        #expect(disk.sizeKB == 17_578_328_012)
        #expect(disk.filesystemSizeKB == 17_578_328_012)
        #expect(disk.filesystemUsedKB == 100)
        #expect(disk.filesystemFreeKB == nil)
        #expect(disk.status == .ok)
        #expect(disk.displayName == "Disk1")
    }

    @Test func arrayDiskToleratesMissingTemperatureAndUnknownStatus() throws {
        let disk = try decode(ArrayDisk.self, """
        {"id":"x","idx":0,"status":"DISK_SOMETHING_NEW","temp":null,"type":"PARITY"}
        """)
        #expect(disk.status == .unknown)
        #expect(disk.temperature == nil)
        #expect(disk.type == .parity)
    }

    @Test func containerStripsLeadingSlashAndReadsMounts() throws {
        let container = try decode(DockerContainer.self, """
        {"id":"s:abc","names":["/plex"],"image":"plex:latest","state":"RUNNING","status":"Up 2 days",
         "created":1700000000,"autoStart":true,"ports":[{"ip":"0.0.0.0","privatePort":32400,"publicPort":32400,"type":"TCP"}],
         "hostConfig":{"networkMode":"host"},
         "mounts":[{"Source":"/mnt/user/appdata/plex","Destination":"/config","RW":true},{"Source":"/mnt/user/media","Destination":"/media","RW":false}]}
        """)
        #expect(container.name == "plex")
        #expect(container.networkMode == "host")
        #expect(container.mounts.count == 2)
        #expect(container.mounts[1].readOnly)
        #expect(container.ports.first?.displayValue == "32400 → 32400/tcp")
        #expect(container.created == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func notificationParsesISOTimestamp() throws {
        let notification = try decode(UnraidNotification.self, """
        {"id":"n","title":"t","subject":"s","description":"d","importance":"WARNING","timestamp":"2025-01-02T03:04:05.678Z"}
        """)
        #expect(notification.importance == .warning)
        #expect(notification.timestamp != nil)
    }

    @Test func classifiesGraphQLErrors() {
        func payload(_ message: String, code: String? = nil) -> GraphQLErrorPayload {
            var object: [String: Any] = ["message": message]
            if let code { object["extensions"] = ["code": code] }
            let data = try! JSONSerialization.data(withJSONObject: object)
            return try! JSONDecoder().decode(GraphQLErrorPayload.self, from: data)
        }
        #expect(GraphQLClient.classify([payload("Cannot query field \"logs\" on type \"Docker\".")], status: 400)
            == .unsupportedByServer("Cannot query field \"logs\" on type \"Docker\". Updating Unraid or the Unraid Connect plugin may add it."))
        #expect(GraphQLClient.classify([payload("nope", code: "UNAUTHENTICATED")], status: 200) == .unauthorized)
        #expect(GraphQLClient.classify([payload("Forbidden resource")], status: 200) == .forbidden("Forbidden resource"))
        #expect(GraphQLClient.classify([payload("VM not found")], status: 200) == .graphQL(["VM not found"]))
    }

    @Test func availableActionsMatchState() {
        #expect(ContainerAction.available(for: .exited) == [.start])
        #expect(VMAction.available(for: .shutoff) == [.start])
        #expect(VMAction.available(for: .running).contains(.forceStop))
        #expect(VMAction.forceStop.isDestructive)
    }

    @Test func fingerprintIsColonSeparatedUppercaseHex() {
        let fingerprint = CertificateInspector.fingerprint(of: Data("abc".utf8))
        #expect(fingerprint.hasPrefix("BA:78:16:BF"))
        #expect(fingerprint.split(separator: ":").count == 32)
    }
}
