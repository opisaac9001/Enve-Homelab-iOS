import Foundation
import Testing
@testable import EnveHomelab

struct EndpointURLParserTests {
    @Test func defaultsToHTTPS() throws {
        let url = try EndpointURLParser.parse("Tower.local").get()
        #expect(url.absoluteString == "https://tower.local")
    }

    @Test func keepsExplicitSchemeAndPort() throws {
        let url = try EndpointURLParser.parse("http://192.168.1.20:8080/").get()
        #expect(url.absoluteString == "http://192.168.1.20:8080")
    }

    @Test func stripsGraphQLPathAndCredentials() throws {
        let url = try EndpointURLParser.parse("https://user:pw@nas.example.com/unraid/graphql?x=1").get()
        #expect(url.absoluteString == "https://nas.example.com/unraid")
    }

    @Test func rejectsUnsupportedScheme() {
        #expect(throws: EndpointURLParser.Failure.unsupportedScheme("ftp")) { try EndpointURLParser.parse("ftp://nas").get() }
    }

    @Test func rejectsEmpty() {
        #expect(throws: EndpointURLParser.Failure.empty) { try EndpointURLParser.parse("   ").get() }
    }

    @Test func automaticOrderPrefersLocal() {
        let remote = ServerEndpoint(kind: .remote, url: URL(string: "https://remote.example")!)
        let local = ServerEndpoint(kind: .local, url: URL(string: "https://tower.local")!)
        let profile = ServerProfile(name: "t", endpoints: [remote, local])
        #expect(profile.connectionOrder.map(\.kind) == [.local, .remote])

        var pinned = profile
        pinned.selection = .pinned(remote.id)
        #expect(pinned.connectionOrder == [remote])
    }
}
