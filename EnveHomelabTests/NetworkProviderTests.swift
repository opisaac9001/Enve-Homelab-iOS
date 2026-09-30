import Foundation
import Testing
@testable import EnveHomelab

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

struct NetworkProviderTests {
    @Test func piholeShapes() throws {
        let session = try decode(PiholeClient.Session.self, #"{"session":{"valid":true,"totp":false,"sid":null,"validity":-1,"message":"no password set"}}"#)
        #expect(session.session.valid && session.session.sid == nil)
        let summary = try decode(PiholeClient.Summary.self, #"{"queries":{"total":10,"blocked":4,"percent_blocked":40,"cached":3,"types":{"A":1}},"clients":{"active":2,"total":3},"gravity":{"domains_being_blocked":99,"last_update":1},"took":0.1}"#)
        #expect(summary.queries.blocked == 4 && summary.gravity?.domains_being_blocked == 99)
        let blocking = try decode(PiholeClient.Blocking.self, #"{"blocking":"disabled","timer":42.5,"took":0.1}"#)
        #expect(blocking.blocking == "disabled" && blocking.timer == 42.5)
    }

    @Test func pauseDurations() {
        #expect(DNSPauseDuration.untilResumed.seconds == nil)
        #expect(DNSPauseDuration.oneHour.seconds == 3_600)
        let overview = DNSFilterOverview(blockingEnabled: true, totalQueries: 0, blockedQueries: 0)
        #expect(overview.blockedFraction == 0)
    }

    @Test func unifiShapesAndHealth() throws {
        let device = try decode(UniFiDevice.self, #"{"id":"1","name":"","model":"U7-Pro","state":"CONNECTION_INTERRUPTED","features":["accessPoint"],"interfaces":[],"supported":true}"#)
        #expect(device.displayName == "U7-Pro" && device.health == .critical && device.role == "Access point")
        let client = try decode(UniFiClientDevice.self, #"{"type":"TELEPORT","id":"c","connectedAt":"2026-01-01T00:00:00Z","access":{"type":"DEFAULT"}}"#)
        #expect(client.displayName == "Client" && client.connectionName == "Teleport")
    }

    @Test func tailscaleExpiryRules() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var device = try decode(TailscaleDevice.self, #"{"id":"1","hostname":"nas","connectedToControl":true,"expires":"2027-01-20T08:00:00Z","keyExpiryDisabled":false,"authorized":true}"#)
        #expect(device.keyExpiresSoon(now: now) == (device.expiryDate!.timeIntervalSince(now) < 14 * 86_400))
        device.keyExpiryDisabled = true
        #expect(device.expiryDate == nil && !device.keyExpiresSoon(now: now))
        device.authorized = false
        #expect(device.health == .warning)
    }

    @Test func cloudflareEnvelopeAndStatus() throws {
        let envelope = try decode(CloudflareClient.Envelope<[CloudflareTunnel]>.self, #"{"success":true,"errors":[],"messages":[],"result":[{"id":"t","name":"home","status":"down","connections":[]}]}"#)
        #expect(envelope.result?.first?.health == .critical)
        #expect(CloudflareTunnel(id: "x", name: "y", status: "inactive").health == .unknown)
    }

    @Test func homeAssistantControlPolicy() throws {
        func entity(_ id: String, _ state: String) -> HomeAssistantEntity { HomeAssistantEntity(entity_id: id, state: state) }
        #expect(entity("light.a", "on").control == .toggle(isOn: true))
        #expect(entity("switch.a", "unavailable").control == nil, "Unavailable entities can't be controlled")
        #expect(entity("scene.a", "scening").control == .activate)
        if case .run = entity("script.a", "off").control {} else { Issue.record("Scripts must be confirmed") }
        #expect(entity("cover.garage", "opening").control == .cover(isOpen: true))
        for readOnly in ["lock.front", "alarm_control_panel.home", "climate.hall", "sensor.t", "camera.door"] {
            #expect(entity(readOnly, "on").control == nil, "\(readOnly) must stay read-only")
        }
        let decoded = try decode(HomeAssistantEntity.self, #"{"entity_id":"sensor.t","state":"21.5","attributes":{"friendly_name":"Temp","unit_of_measurement":"°C"}}"#)
        #expect(decoded.name == "Temp" && decoded.displayState == "21.5 °C")
        #expect(HomeAssistantClient.areasTemplate.contains("area_entities(area)"))
    }

    @Test func cloudKindsUseFixedHTTPSAndNetworkCategories() {
        #expect(IntegrationKind.tailscale.fixedBaseURL?.scheme == "https")
        #expect(IntegrationKind.cloudflare.requiresHTTPS)
        #expect(IntegrationKind.pihole.category == .network && IntegrationKind.homeassistant.category == .smartHome)
    }
}
