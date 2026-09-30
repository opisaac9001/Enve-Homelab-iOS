import Foundation

/// A portable copy of this device's setup. Secrets (API keys, passwords, private keys, tokens) are never included.
struct ConfigurationBackup: Codable, Sendable, Equatable {
    static let currentFormat = 1

    /// Why the file was made; older files have none and are treated as backups.
    enum Purpose: String, Codable, Sendable {
        case backup, household, companion
    }

    var format: Int
    var purpose: Purpose = .backup
    var exportedAt: Date
    var servers: [ServerProfile]
    var integrations: [IntegrationInstance]
    var serviceChecks: [ServiceCheck]
    var sshHosts: [SSHHost]
    var notificationRules: [NotificationRule]
    /// Entries left out when reading the file: unknown to this version, malformed, duplicated or unsafe.
    var rejected = 0

    private enum CodingKeys: String, CodingKey {
        case format, purpose, exportedAt, servers, integrations, serviceChecks, sshHosts, notificationRules
    }

    /// Something that was added but can't connect until its credentials are entered on this device.
    struct PendingCredential: Equatable, Identifiable, Sendable {
        enum Kind: Sendable { case server, integration, sshHost }
        var id: UUID
        var name: String
        var kind: Kind
    }

    struct ImportResult: Equatable {
        var added: Int
        var skipped: Int
        var needsCredentials: [PendingCredential]
        var failed: [String] = []
    }

    var itemCount: Int { servers.count + integrations.count + serviceChecks.count + sshHosts.count + notificationRules.count }

    /// Keeps only the chosen items, for importing part of a file.
    func selecting(_ ids: Set<UUID>) -> ConfigurationBackup {
        var copy = self
        copy.servers = servers.filter { ids.contains($0.id) }
        copy.integrations = integrations.filter { ids.contains($0.id) }
        copy.serviceChecks = serviceChecks.filter { ids.contains($0.id) }
        copy.sshHosts = sshHosts.filter { ids.contains($0.id) }
        copy.notificationRules = notificationRules.filter { ids.contains($0.id) }
        return copy
    }

    init(format: Int, purpose: Purpose = .backup, exportedAt: Date, servers: [ServerProfile], integrations: [IntegrationInstance], serviceChecks: [ServiceCheck], sshHosts: [SSHHost], notificationRules: [NotificationRule]) {
        self.format = format
        self.purpose = purpose
        self.exportedAt = exportedAt
        self.servers = servers
        self.integrations = integrations
        self.serviceChecks = serviceChecks
        self.sshHosts = sshHosts
        self.notificationRules = notificationRules
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        guard format <= Self.currentFormat else { throw BackupError.newerFormat }
        // An unknown purpose from a later version still imports, as a plain backup.
        purpose = (try? container.decodeIfPresent(Purpose.self, forKey: .purpose)) ?? .backup
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)

        var rejected = 0
        func list<Element: Decodable & Identifiable>(_ key: CodingKeys, isValid: (Element) -> Bool) throws -> [Element] where Element.ID == UUID {
            let lossy = try container.decodeIfPresent(LossyList<Element>.self, forKey: key) ?? LossyList()
            var seen = Set<UUID>()
            let kept = lossy.elements.filter { isValid($0) && seen.insert($0.id).inserted }
            rejected += lossy.dropped + lossy.elements.count - kept.count
            return kept
        }

        servers = try list(.servers) { !$0.endpoints.isEmpty && $0.endpoints.allSatisfy { Self.isSafe($0.url) } }
        integrations = try list(.integrations) { instance in
            !instance.isSample && Self.isSafe(instance.url) && (!instance.kind.requiresHTTPS || instance.url.scheme?.lowercased() == "https")
        }
        serviceChecks = try list(.serviceChecks) { Self.isSafe($0.url) }
        sshHosts = try list(.sshHosts) { host in
            !host.host.trimmingCharacters(in: .whitespaces).isEmpty && !host.username.isEmpty && (1...65_535).contains(host.port)
        }
        notificationRules = try list(.notificationRules) { _ in true }
        self.rejected = rejected
    }

    static func decode(_ data: Data) throws -> ConfigurationBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConfigurationBackup.self, from: data)
    }

    /// Credentials embedded in a URL would bypass the Keychain, so such entries are refused.
    private static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host(percentEncoded: false)?.isEmpty == false && url.user == nil && url.password == nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

private struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var dropped = 0

    init() {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skipped.self)
                dropped += 1
            }
        }
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) {}
    }
}

enum BackupError: Error, LocalizedError {
    case newerFormat

    var errorDescription: String? { "This backup was made by a newer version of Petty: Homelab." }
}

@MainActor
extension AppModel {
    /// A setup to hand to someone else in the household: only the chosen servers, integrations and checks, never SSH hosts, rules or credentials.
    func makeHouseholdShare(including ids: Set<UUID>) -> ConfigurationBackup {
        ConfigurationBackup(
            format: ConfigurationBackup.currentFormat,
            purpose: .household,
            exportedAt: .now,
            servers: store.profiles.filter { ids.contains($0.id) },
            integrations: integrations.instances.filter { ids.contains($0.id) },
            serviceChecks: serviceChecks.checks.filter { ids.contains($0.id) },
            sshHosts: [],
            notificationRules: []
        )
    }

    func makeBackup() -> ConfigurationBackup {
        ConfigurationBackup(
            format: ConfigurationBackup.currentFormat,
            exportedAt: .now,
            servers: store.profiles,
            integrations: integrations.instances,
            serviceChecks: serviceChecks.checks,
            sshHosts: ssh.hosts.map { host in
                var copy = host
                // Keys live only in this device's Keychain, so imported hosts fall back to password sign-in.
                if case .key = copy.authentication { copy.authentication = .password }
                return copy
            },
            notificationRules: alerts.rules
        )
    }

    /// Adds items whose IDs aren't already present; nothing existing is overwritten. A failed item doesn't stop the rest.
    func restore(_ backup: ConfigurationBackup) async -> ConfigurationBackup.ImportResult {
        var result = ConfigurationBackup.ImportResult(added: 0, skipped: 0, needsCredentials: [])
        // Household and companion files come from another device or host, so their certificate and host-key trust is reviewed again here.
        let keepsTrust = backup.purpose == .backup
        func add(_ name: String, pending: ConfigurationBackup.PendingCredential?, _ save: () throws -> Void) {
            do {
                try save()
                result.added += 1
                if let pending { result.needsCredentials.append(pending) }
            } catch {
                result.failed.append(name)
            }
        }
        for var server in backup.servers {
            guard store.profile(id: server.id) == nil else { result.skipped += 1; continue }
            if !keepsTrust {
                for index in server.endpoints.indices {
                    server.endpoints[index].pinnedCertificateSHA256 = nil
                    server.endpoints[index].pinnedCertificateSubject = nil
                }
            }
            add(server.name, pending: .init(id: server.id, name: server.name, kind: .server)) { try store.save(server, apiKey: nil) }
        }
        for var instance in backup.integrations {
            guard integrations.instance(id: instance.id) == nil else { result.skipped += 1; continue }
            if !keepsTrust { instance.pinnedCertificateSHA256 = nil; instance.pinnedCertificateSubject = nil }
            add(instance.name, pending: instance.kind.credentialStyle.worksWithoutSecret ? nil : .init(id: instance.id, name: instance.name, kind: .integration)) {
                try integrations.save(instance, secret: nil)
            }
        }
        for var check in backup.serviceChecks {
            guard serviceChecks.check(id: check.id) == nil else { result.skipped += 1; continue }
            if !keepsTrust { check.pinnedCertificateSHA256 = nil; check.pinnedCertificateSubject = nil }
            add(check.name, pending: nil) { try serviceChecks.save(check) }
        }
        for var host in backup.sshHosts {
            guard ssh.host(id: host.id) == nil else { result.skipped += 1; continue }
            if !keepsTrust { host.knownHostKey = nil }
            add(host.name, pending: .init(id: host.id, name: host.name, kind: .sshHost)) { try ssh.save(host, password: nil) }
        }
        for rule in backup.notificationRules {
            guard !alerts.rules.contains(where: { $0.id == rule.id }) else { result.skipped += 1; continue }
            await alerts.save(rule)
            result.added += 1
        }
        return result
    }
}
