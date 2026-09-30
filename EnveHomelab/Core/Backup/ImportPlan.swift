import Foundation

/// How each entry in an imported file relates to what's already on the device. Importing only ever adds items or, when chosen, updates an address; nothing is removed.
struct ImportPlan: Equatable {
    enum Status: Equatable {
        case new
        case alreadyHere
        /// A different entry already points at the same service, e.g. from an export made before IDs were stable.
        case sameAs(String)
        /// Already here under the same ID, but the file has a new address.
        case moved(from: URL)
    }

    struct Entry: Equatable, Identifiable {
        var id: UUID
        var name: String
        var detail: String
        var status: Status
        var url: URL?
    }

    var servers: [Entry]
    var integrations: [Entry]
    var checks: [Entry]
    var sshHosts: [Entry]
    var rules: [Entry]
    /// Integrations and checks on the file's hosts that the file no longer lists; they stay as they are.
    var keptOnDevice: [String]

    var all: [Entry] { servers + integrations + checks + sshHosts + rules }
    var newIDs: Set<UUID> { Set(all.filter { $0.status == .new }.map(\.id)) }

    static func make(_ backup: ConfigurationBackup, integrations existingIntegrations: [IntegrationInstance], checks existingChecks: [ServiceCheck],
                     serverIDs: Set<UUID>, hostIDs: Set<UUID>, ruleIDs: Set<UUID>) -> ImportPlan {
        var matched = Set<UUID>()

        func status(id: UUID, url: URL, existing: [(id: UUID, name: String, url: URL, key: String)], key: String) -> Status {
            if let same = existing.first(where: { $0.id == id }) {
                matched.insert(same.id)
                return Self.normalized(same.url) == Self.normalized(url) ? .alreadyHere : .moved(from: same.url)
            }
            if let twin = existing.first(where: { $0.key == key }) {
                matched.insert(twin.id)
                return .sameAs(twin.name)
            }
            return .new
        }

        let knownIntegrations = existingIntegrations.map { ($0.id, $0.name, $0.url, "\($0.kind.rawValue) \(normalized($0.url))") }
        let integrations = backup.integrations.map { instance in
            Entry(id: instance.id, name: instance.name, detail: "\(instance.kind.displayName) · \(Self.address(instance.url))",
                  status: status(id: instance.id, url: instance.url, existing: knownIntegrations, key: "\(instance.kind.rawValue) \(normalized(instance.url))"),
                  url: instance.url)
        }
        let knownChecks = existingChecks.map { ($0.id, $0.name, $0.url, normalized($0.url)) }
        let checks = backup.serviceChecks.map { check in
            Entry(id: check.id, name: check.name, detail: Self.address(check.url),
                  status: status(id: check.id, url: check.url, existing: knownChecks, key: normalized(check.url)), url: check.url)
        }

        let hosts = Set((backup.integrations.map(\.url) + backup.serviceChecks.map(\.url)).compactMap { $0.host()?.lowercased() })
        let kept = backup.purpose == .companion
            ? (existingIntegrations.map { ($0.id, $0.name, $0.url) } + existingChecks.map { ($0.id, $0.name, $0.url) })
                .filter { !matched.contains($0.0) && $0.2.host().map { hosts.contains($0.lowercased()) } == true }
                .map(\.1)
            : []

        return ImportPlan(
            servers: backup.servers.map { Entry(id: $0.id, name: $0.name, detail: $0.endpoints.first.map { Self.address($0.url) } ?? "", status: serverIDs.contains($0.id) ? .alreadyHere : .new) },
            integrations: integrations,
            checks: checks,
            sshHosts: backup.sshHosts.map { Entry(id: $0.id, name: $0.name, detail: "\($0.username)@\($0.host)", status: hostIDs.contains($0.id) ? .alreadyHere : .new) },
            rules: backup.notificationRules.map { Entry(id: $0.id, name: $0.name, detail: $0.sourceKind.title, status: ruleIDs.contains($0.id) ? .alreadyHere : .new) },
            keptOnDevice: kept
        )
    }

    /// Scheme, host and effective port, ignoring case and a trailing slash, so equivalent addresses compare equal.
    static func normalized(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        var path = url.path()
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(url.host()?.lowercased() ?? ""):\(port)\(path)"
    }

    private static func address(_ url: URL) -> String {
        [url.host(), url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }
}

@MainActor
extension AppModel {
    /// Points existing integrations and checks at new addresses; credentials and trusted certificates are kept.
    func updateAddresses(_ changes: [UUID: URL]) -> [String] {
        var failed: [String] = []
        for (id, url) in changes {
            if var instance = integrations.instance(id: id) {
                instance.url = url
                do { try integrations.save(instance, secret: nil) } catch { failed.append(instance.name) }
            } else if var check = serviceChecks.check(id: id) {
                check.url = url
                do { try serviceChecks.save(check) } catch { failed.append(check.name) }
            }
        }
        return failed
    }
}
