import Foundation
import Testing
@testable import EnveHomelab

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct ProxmoxTests {
    @Test func tokenAuthorizationHeader() {
        #expect(ProxmoxClient.authorization(tokenID: " root@pam!homelab ", secret: "aaaa-bbbb ") == "PVEAPIToken=root@pam!homelab=aaaa-bbbb")
    }

    @Test func clusterResourcesNodesAndTasks() throws {
        let guests = try decode([ProxmoxGuest].self, """
        [{"id":"qemu/100","type":"qemu","node":"pve1","vmid":100,"name":"ha","status":"running","cpu":0.02,"maxcpu":2,"mem":1024,"maxmem":4096,"uptime":60,"template":0},
         {"id":"lxc/200","type":"lxc","node":"pve2","vmid":200,"status":"stopped","maxmem":512},
         {"id":"qemu/9000","type":"qemu","node":"pve1","vmid":9000,"name":"tpl","status":"stopped","template":1},
         {"id":"qemu/101","type":"qemu","node":"pve1","vmid":101,"status":"running","lock":"backup"}]
        """)
        #expect(guests[0].isRunning && guests[0].displayName == "ha")
        #expect(guests[1].displayName == "200")
        #expect(ProxmoxPowerAction.available(for: guests[0]) == [.shutdown, .reboot, .suspend, .stop, .reset])
        #expect(ProxmoxPowerAction.available(for: guests[1]) == [.start])
        #expect(ProxmoxPowerAction.available(for: guests[2]).isEmpty, "Templates can't be powered")
        #expect(ProxmoxPowerAction.available(for: guests[3]).isEmpty, "Locked guests are left alone")
        var lxc = guests[1]
        lxc.status = "running"
        #expect(!ProxmoxPowerAction.available(for: lxc).contains(.reset), "Containers have no reset endpoint")
        #expect(ProxmoxPowerAction.stop.isDestructive && ProxmoxPowerAction.reset.isDestructive && !ProxmoxPowerAction.shutdown.isDestructive)

        let nodes = try decode([ProxmoxNode].self, #"[{"node":"pve1","status":"online","cpu":0.1,"maxcpu":8,"mem":50,"maxmem":100,"uptime":10}]"#)
        #expect(nodes[0].memoryFraction == 0.5)
        let tasks = try decode([ProxmoxTask].self, """
        [{"upid":"UPID:pve1:1:2:3:qmstart:100:root@pam:","node":"pve1","type":"qmstart","id":"100","user":"root@pam","starttime":1,"endtime":2,"status":"OK"},
         {"upid":"UPID:b","type":"vzdump","starttime":3,"endtime":4,"status":"job errors"},{"upid":"UPID:c","starttime":5}]
        """)
        #expect(tasks[0].id.hasPrefix("UPID:pve1") && tasks[0].target == "100" && tasks[0].health == .ok)
        #expect(tasks[1].health == .critical)
        #expect(tasks[2].isRunning)
    }
}

struct PortainerTests {
    @Test func environmentsStacksAndContainers() throws {
        let environments = try decode([PortainerEnvironment].self, """
        [{"Id":1,"Name":"local","Type":1,"Status":1,"URL":"unix:///var/run/docker.sock"},{"Id":3,"Name":"k8s","Type":5,"Status":2}]
        """)
        #expect(environments[0].isDocker && environments[0].isUp)
        #expect(!environments[1].isDocker && !environments[1].isUp)
        let stacks = try decode([PortainerStack].self, #"[{"Id":4,"Name":"monitoring","Type":2,"EndpointId":1,"Status":2}]"#)
        #expect(!stacks[0].isActive && stacks[0].typeName == "Compose")
        let containers = try decode([PortainerContainer].self, """
        [{"Id":"abcdef1234567890","Names":["/grafana"],"Image":"grafana/grafana","State":"running","Status":"Up 2 hours (unhealthy)","Created":1,"Labels":{"com.docker.compose.project":"monitoring"}}]
        """)
        #expect(containers[0].name == "grafana")
        #expect(containers[0].stack == "monitoring")
        #expect(containers[0].health == .warning)
        #expect(containers[0].lifecycleActions == [.restart, .stop])
    }

    @Test func dockerLogDemultiplexing() {
        func frame(_ stream: UInt8, _ text: String) -> Data {
            let payload = Data(text.utf8)
            let size = UInt32(payload.count).bigEndian
            return Data([stream, 0, 0, 0]) + withUnsafeBytes(of: size) { Data($0) } + payload
        }
        let multiplexed = frame(1, "hello\nwor") + frame(2, "ld\nerror line\n")
        #expect(DockerLogStream.lines(from: multiplexed) == ["hello", "world", "error line"])
        #expect(DockerLogStream.lines(from: Data("tty output\nsecond\n".utf8)) == ["tty output", "second"])
    }
}

struct TrueNASTests {
    @Test func jsonRPCMessages() throws {
        let request = try JSONRPCMessage.request(id: 4, method: "auth.login_with_api_key", params: ["key"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 4)
        #expect(object["params"] as? [String] == ["key"])

        #expect(try JSONRPCMessage.result(for: 4, in: #"{"jsonrpc":"2.0","method":"collection_update","params":{}}"#) == nil)
        #expect(try JSONRPCMessage.result(for: 4, in: #"{"jsonrpc":"2.0","id":3,"result":true}"#) == nil)
        let result = try #require(try JSONRPCMessage.result(for: 4, in: #"{"jsonrpc":"2.0","id":4,"result":true}"#))
        #expect(try JSONDecoder().decode(Bool.self, from: result))

        #expect(throws: NetworkError.unsupportedByServer("Method not found")) {
            _ = try JSONRPCMessage.result(for: 5, in: #"{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"Method not found"}}"#)
        }
        #expect(throws: NetworkError.unauthorized) {
            _ = try JSONRPCMessage.result(for: 6, in: #"{"jsonrpc":"2.0","id":6,"error":{"code":-32001,"message":"Method call error","data":{"errname":"ENOTAUTHENTICATED","reason":"Not authenticated"}}}"#)
        }
        #expect(throws: NetworkError.forbidden("You don't have permission")) {
            _ = try JSONRPCMessage.result(for: 7, in: #"{"jsonrpc":"2.0","id":7,"error":{"code":-32001,"message":"x","data":{"errname":"EACCES","reason":"You don't have permission"}}}"#)
        }
    }

    @Test func requiresHTTPSForAPIKeys() throws {
        #expect(throws: NetworkError.self) { try TrueNASClient.socketURL(for: URL(string: "http://truenas.local")!) }
        #expect(try TrueNASClient.socketURL(for: URL(string: "https://truenas.local:8443/ui")!).absoluteString == "wss://truenas.local:8443/api/current")
        #expect(IntegrationKind.truenas.requiresHTTPS)
    }

    @Test func poolsAlertsJobsDatasets() throws {
        let pools = try decode([TrueNASPool].self, """
        [{"id":1,"name":"tank","guid":"1","status":"ONLINE","path":"/mnt/tank","healthy":true,"warning":false,"status_code":"OK","status_detail":null,
          "size":100,"allocated":40,"free":60,"scan":{"function":"SCRUB","state":"SCANNING","percentage":12.5,"errors":0,"end_time":null}},
         {"id":2,"name":"old","guid":"2","status":"DEGRADED","path":"/mnt/old","healthy":false,"warning":true,"size":null,"allocated":null,"free":null,"scan":null}]
        """)
        #expect(pools[0].isScrubbing && pools[0].usedFraction == 0.4 && pools[0].health == .ok)
        #expect(pools[1].health == .critical)
        let alerts = try decode([TrueNASAlert].self, """
        [{"uuid":"u1","level":"WARNING","klass":"SMART","formatted":"Device <b>sda</b> failed","text":"%s","dismissed":false,"datetime":{"$date":1700000000000},"id":"x","source":"","args":null,"node":"A","key":"k","last_occurrence":{"$date":1700000000000},"mail":null,"one_shot":false}]
        """)
        #expect(alerts[0].message == "Device sda failed")
        #expect(alerts[0].datetime?.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(alerts[0].health == .warning)
        let jobs = try decode([TrueNASJob].self, """
        [{"id":9,"method":"pool.scrub.scrub","description":null,"state":"RUNNING","progress":{"percent":40,"description":"Scrubbing","extra":null},"error":null,"time_started":{"$date":1700000000000},"time_finished":null}]
        """)
        #expect(jobs[0].title == "pool.scrub.scrub" && jobs[0].progress?.percent == 40)
        let datasets = try decode([TrueNASDataset].self, """
        [{"id":"tank/media","type":"FILESYSTEM","name":"media","pool":"tank","encrypted":true,"locked":true,"used":{"parsed":1024,"rawvalue":"1024","value":"1K","source":"NONE"},"available":{"parsed":2048},"mountpoint":"/mnt/tank/media"}]
        """)
        #expect(datasets[0].used?.bytes == 1024 && datasets[0].available?.bytes == 2048 && datasets[0].locked)
    }
}

struct RESTClientTests {
    @Test func urlBuildingKeepsBasePathAndEncodesPlus() {
        let client = RESTClient(baseURL: URL(string: "https://host.local:8989/sonarr")!, pinnedFingerprint: nil)
        let url = client.url(for: "api/v3/queue", query: [URLQueryItem(name: "q", value: "a+b c"), URLQueryItem(name: "page", value: "1")])
        #expect(url.absoluteString == "https://host.local:8989/sonarr/api/v3/queue?q=a%2Bb%20c&page=1")
    }

    @Test func statusMapping() throws {
        func response(_ code: Int) -> HTTPURLResponse { HTTPURLResponse(url: URL(string: "https://x")!, statusCode: code, httpVersion: nil, headerFields: nil)! }
        #expect(throws: NetworkError.unauthorized) { try RESTClient.validate(response(401), data: Data()) }
        #expect(throws: NetworkError.apiNotFound) { try RESTClient.validate(response(404), data: Data()) }
        #expect(throws: NetworkError.forbidden("nope")) { try RESTClient.validate(response(403), data: Data(#"{"message":"nope"}"#.utf8)) }
        #expect(throws: NetworkError.graphQL(["HTTP 500: boom"])) { try RESTClient.validate(response(500), data: Data(#"[{"errorMessage":"boom"}]"#.utf8)) }
        #expect(throws: NetworkError.httpStatus(502)) { try RESTClient.validate(response(502), data: Data("<html>".utf8)) }
        try RESTClient.validate(response(204), data: Data())
    }

    @Test func nonJSONBodyIsReportedAsWrongService() {
        #expect(throws: NetworkError.apiNotFound) { _ = try RESTClient.decode([String].self, from: Data("<html>login</html>".utf8)) }
    }
}

@MainActor
struct IntegrationStoreTests {
    @Test func secretsStayInKeychain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "integrations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = KeychainStore(service: "com.isaaclamb.EnveHomelab.tests.\(UUID().uuidString)")
        let store = IntegrationStore(file: JSONFile(url: url), keychain: keychain)
        let instance = IntegrationInstance(kind: .sonarr, name: "Sonarr", url: URL(string: "http://sonarr.local:8989")!)
        try store.save(instance, secret: "super-secret-api-key")
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("super-secret-api-key"))
        #expect(try store.secret(for: instance) == "super-secret-api-key")
        let reloaded = IntegrationStore(file: JSONFile(url: url), keychain: keychain)
        #expect(reloaded.instances == [instance])
        try reloaded.delete(instance)
        #expect(try reloaded.secret(for: instance) == nil)
    }

    @Test func connectorRequiresCredentials() {
        let instance = IntegrationInstance(kind: .radarr, name: "R", url: URL(string: "http://r.local")!)
        #expect(throws: NetworkError.missingCredentials) { _ = try IntegrationConnector.client(for: instance, secret: nil) }
        let proxmox = IntegrationInstance(kind: .proxmox, name: "P", url: URL(string: "https://p.local:8006")!)
        #expect(throws: NetworkError.missingCredentials) { _ = try IntegrationConnector.client(for: proxmox, secret: "secret") }
        let qbt = IntegrationInstance(kind: .qbittorrent, name: "Q", url: URL(string: "http://q.local")!)
        #expect(throws: Never.self) { _ = try IntegrationConnector.client(for: qbt, secret: nil) }
    }

    @Test func everyKindHasSampleAndCategory() {
        for kind in IntegrationKind.allCases {
            let instance = IntegrationConnector.sampleInstance(for: kind)
            #expect(instance.isSample && instance.kind == kind)
            #expect(IntegrationCategory.allCases.contains(kind.category))
        }
        #expect(Set(IntegrationKind.allCases.map { IntegrationConnector.sampleInstance(for: $0).id }).count == IntegrationKind.allCases.count)
    }
}
