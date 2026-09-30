import Foundation

struct KnownHostKey: Codable, Sendable, Hashable {
    var algorithm: String
    var fingerprint: String
    var trustedAt: Date
}

struct SavedCommand: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var command: String

    var risks: [String] { CommandRisk.assess(command) }
}

struct SSHHost: Codable, Sendable, Hashable, Identifiable {
    enum Authentication: Codable, Sendable, Hashable {
        case password
        case key(UUID)
    }

    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var authentication: Authentication = .password
    var knownHostKey: KnownHostKey?
    var serverID: UUID?
    var savedCommands: [SavedCommand] = []

    var address: String { port == 22 ? host : "\(host):\(port)" }
}

enum SSHKeyAlgorithm: String, Codable, Sendable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"

    var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        }
    }
}

struct SSHKeyInfo: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var algorithm: SSHKeyAlgorithm
    var publicKey: String
    var fingerprint: String
    var createdAt: Date
}

/// Stored only in the Keychain.
struct SSHPrivateKeyMaterial: Codable, Sendable, Equatable {
    var algorithm: SSHKeyAlgorithm
    var rawRepresentation: Data
}

enum SSHCredential: Sendable {
    case password(String)
    case privateKey(SSHPrivateKeyMaterial)
}

/// Flags commands whose effect is hard to undo so running them needs an explicit confirmation.
enum CommandRisk {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"(^|[;&|]\s*|\s)rm\s+(-\w*[rRf]\w*\s+|--recursive|--force)"#, "Deletes files recursively or without prompting"),
        (#"\b(shutdown|poweroff|halt|reboot)\b|\binit\s+[06]\b"#, "Shuts down or restarts the host"),
        (#"\bsystemctl\s+(poweroff|reboot|halt|stop|restart|disable)\b"#, "Stops, restarts or disables system services"),
        (#"\b(mkfs(\.\w+)?|wipefs|fdisk|sfdisk|parted|sgdisk)\b"#, "Changes disk partitions or filesystems"),
        (#"\bdd\b[^\n]*\bof=/dev/"#, "Writes directly to a device"),
        (#">\s*/dev/(sd|nvme|md|hd|vd)"#, "Overwrites a block device"),
        (#"\bdocker\s+(rm|rmi|kill|(system|image|container|volume|network)\s+(prune|rm))\b"#, "Removes Docker containers, images, volumes or networks"),
        (#"\bdocker\s+(stop|restart|pause)\b|\bdocker(-|\s+)compose\b[^\n]*\b(down|stop|restart)\b"#, "Stops or restarts Docker containers"),
        (#"\bvirsh\s+(shutdown|reboot|suspend)\b"#, "Shuts down or restarts a virtual machine"),
        (#"/etc/rc\.d/rc\.\w+\s+(stop|restart)\b|\bservice\s+\S+\s+(stop|restart)\b"#, "Stops or restarts a system service"),
        (#"\bzfs\s+set\b"#, "Changes ZFS dataset properties"),
        (#"\bzpool\s+(destroy|remove|detach|offline|labelclear)\b|\bzfs\s+(destroy|rollback)\b"#, "Destroys or rolls back ZFS data"),
        (#"\bvirsh\s+(destroy|undefine|reset)\b"#, "Force-stops, resets or deletes a virtual machine"),
        (#"\bmdcmd\b"#, "Changes the Unraid array directly"),
        (#"\bkill(all)?\s+(-9|-KILL|-s\s+KILL)\b"#, "Forcibly kills processes"),
        (#"\b(chmod|chown)\s+(-\w*R\w*|--recursive)\b"#, "Changes ownership or permissions recursively"),
        (#"\bnewperms\b"#, "Resets permissions across shares"),
        (#"\bumount\b"#, "Unmounts a filesystem"),
        (#"\btruncate\b|\bshred\b"#, "Destroys file contents"),
    ]

    static func assess(_ command: String) -> [String] {
        rules.compactMap { rule in
            command.range(of: rule.pattern, options: .regularExpression) == nil ? nil : rule.reason
        }
    }
}
