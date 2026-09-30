import Foundation

struct HomeAssistantEntity: Decodable, Sendable, Hashable, Identifiable {
    var entity_id: String
    var state: String
    var attributes: [String: JSONValue]?
    var last_changed: String?

    var id: String { entity_id }
    var domain: String { String(entity_id.prefix { $0 != "." }) }
    var name: String { attributes?["friendly_name"]?.stringValue ?? entity_id }
    var unit: String? { attributes?["unit_of_measurement"]?.stringValue }
    var isUnavailable: Bool { state == "unavailable" || state == "unknown" }

    var displayState: String {
        unit.map { "\(state) \($0)" } ?? state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var control: HomeAssistantControl? { HomeAssistantControl(entity: self) }
}

/// What the app lets you do with an entity. Locks, alarms and anything unlisted stay read-only.
enum HomeAssistantControl: Sendable, Equatable {
    /// Lights, switches, fans and input booleans: low-risk, toggled directly.
    case toggle(isOn: Bool)
    /// Scenes apply immediately.
    case activate
    /// Scripts and automations can do anything, so they're confirmed first.
    case run(confirm: String)
    /// Covers include garage doors and gates, so opening and closing are confirmed.
    case cover(isOpen: Bool)

    static let toggleDomains: Set = ["light", "switch", "fan", "input_boolean"]

    init?(entity: HomeAssistantEntity) {
        guard !entity.isUnavailable else { return nil }
        switch entity.domain {
        case let domain where Self.toggleDomains.contains(domain):
            self = .toggle(isOn: entity.state == "on")
        case "scene":
            self = .activate
        case "script":
            self = .run(confirm: "The script runs with Home Assistant's permissions and may change several devices.")
        case "automation":
            self = .run(confirm: "The automation's actions run now, skipping its triggers and conditions.")
        case "cover":
            self = .cover(isOpen: entity.state == "open" || entity.state == "opening")
        default:
            return nil
        }
    }
}

struct HomeAssistantArea: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var entities: [String]
}

struct HomeAssistantSnapshot: Sendable {
    var version: String?
    var locationName: String?
    var areas: [HomeAssistantArea]
    var entities: [HomeAssistantEntity]
}

/// `POST /api/config/core/check_config`: validates configuration.yaml without applying it.
struct HomeAssistantConfigCheck: Decodable, Sendable, Equatable {
    var result: String
    var errors: String?

    var isValid: Bool { result == "valid" }
}

protocol HomeAssistantService: IntegrationService {
    func snapshot() async throws -> HomeAssistantSnapshot
    func call(_ domain: String, _ service: String, entityID: String) async throws
    func checkConfiguration() async throws -> HomeAssistantConfigCheck
    /// Errors logged since Home Assistant last started (`GET /api/error_log`, plain text).
    func errorLog() async throws -> String
}

extension HomeAssistantService {
    func summary() async throws -> IntegrationSummary {
        let snapshot = try await snapshot()
        let unavailable = snapshot.entities.filter(\.isUnavailable).count
        return IntegrationSummary(
            product: "Home Assistant",
            version: snapshot.version,
            health: .ok,
            headline: "\(snapshot.entities.count) entities in \(snapshot.areas.count) areas",
            detail: unavailable > 0 ? "\(unavailable) unavailable" : snapshot.locationName
        )
    }

    func perform(_ control: HomeAssistantControl, on entity: HomeAssistantEntity, turnOn: Bool = true) async throws {
        switch control {
        case .toggle: try await call(entity.domain, turnOn ? "turn_on" : "turn_off", entityID: entity.entity_id)
        case .activate: try await call("scene", "turn_on", entityID: entity.entity_id)
        case .run: try await call(entity.domain, entity.domain == "automation" ? "trigger" : "turn_on", entityID: entity.entity_id)
        case .cover: try await call("cover", turnOn ? "open_cover" : "close_cover", entityID: entity.entity_id)
        }
    }
}

/// Home Assistant REST API with a long-lived access token. Areas come from the documented template functions.
struct HomeAssistantClient: HomeAssistantService {
    private let rest: RESTClient

    init(url: URL, token: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint, headers: ["Authorization": "Bearer \(token)"])
    }

    static let areasTemplate = """
    {%- set ns = namespace(areas=[]) -%}
    {%- for area in areas() -%}
    {%- set ns.areas = ns.areas + [{"id": area, "name": area_name(area), "entities": area_entities(area)}] -%}
    {%- endfor -%}
    {{ ns.areas | to_json }}
    """

    func checkConfiguration() async throws -> HomeAssistantConfigCheck {
        do {
            return try await rest.json(.post("config/core/check_config"), as: HomeAssistantConfigCheck.self)
        } catch NetworkError.apiNotFound {
            throw NetworkError.unsupportedByServer("Checking the configuration needs Home Assistant's config integration (included in default_config).")
        }
    }

    func errorLog() async throws -> String {
        do {
            return LogRedactor.redact(String(decoding: try await rest.data(.get("error_log")), as: UTF8.self))
        } catch NetworkError.unauthorized {
            throw NetworkError.forbidden("Reading the error log needs a token from an administrator account.")
        }
    }

    func snapshot() async throws -> HomeAssistantSnapshot {
        struct Config: Decodable { var version: String?; var location_name: String? }
        async let config = rest.json(.get("config"), as: Config.self)
        async let states = rest.json(.get("states"), as: [HomeAssistantEntity].self)
        let areaData = try await rest.data(try .post("template", json: ["template": Self.areasTemplate]))
        let areas = try RESTClient.decode([HomeAssistantArea].self, from: areaData)
        let configuration = try await config
        return HomeAssistantSnapshot(
            version: configuration.version,
            locationName: configuration.location_name,
            areas: areas.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            entities: try await states.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    func call(_ domain: String, _ service: String, entityID: String) async throws {
        _ = try await rest.data(try .post("services/\(domain)/\(service)", json: ["entity_id": entityID]))
    }
}
