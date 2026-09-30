import Foundation
import LocalAuthentication
import Observation
import SwiftUI

enum ProfileRole: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Can run actions, open terminals and change connections.
    case owner
    /// Sees status only; every action, terminal and editor is unavailable.
    case viewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .owner: "Owner"
        case .viewer: "View only"
        }
    }

    var summary: String {
        switch self {
        case .owner: "Full control: actions, terminals and editing connections."
        case .viewer: "Status only. Actions, terminals and settings that change servers are hidden or disabled."
        }
    }
}

struct HouseholdProfile: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var role: ProfileRole
    /// View-only profiles can be limited to these integrations and service checks; nil shows everything.
    var visibleItems: Set<UUID>?
    /// Whether a View-only profile sees Unraid servers and SSH hosts.
    var showsServers = true

    init(id: UUID = UUID(), name: String, role: ProfileRole, visibleItems: Set<UUID>? = nil, showsServers: Bool = true) {
        self.id = id
        self.name = name
        self.role = role
        self.visibleItems = visibleItems
        self.showsServers = showsServers
    }

    // Profiles saved before visibility existed have neither key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(ProfileRole.self, forKey: .role)
        visibleItems = try container.decodeIfPresent(Set<UUID>.self, forKey: .visibleItems)
        showsServers = try container.decodeIfPresent(Bool.self, forKey: .showsServers) ?? true
    }

    /// Owners always see everything; the limits only apply to View-only profiles.
    func shows(_ id: UUID) -> Bool { role == .owner || visibleItems?.contains(id) ?? true }
    var seesServers: Bool { role == .owner || showsServers }
    var isLimited: Bool { role == .viewer && (visibleItems != nil || !showsServers) }
}

/// Profiles live only on this device; there are no accounts and nothing is synced.
@MainActor
@Observable
final class ProfileStore {
    struct Snapshot: Codable, Sendable {
        var profiles: [HouseholdProfile]
        var activeID: UUID
        var requireAuthenticationForOwner: Bool
    }

    private(set) var profiles: [HouseholdProfile]
    private(set) var activeID: UUID
    private(set) var requireAuthenticationForOwner: Bool
    private let file: JSONFile<Snapshot>
    private let authenticate: @Sendable (String) async throws -> Void

    static let deviceAuthentication: @Sendable (String) async throws -> Void = { reason in
        _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    init(file: JSONFile<Snapshot>, authenticate: @escaping @Sendable (String) async throws -> Void = ProfileStore.deviceAuthentication) {
        self.file = file
        self.authenticate = authenticate
        if let snapshot = try? file.load(), !snapshot.profiles.isEmpty {
            profiles = snapshot.profiles
            activeID = snapshot.profiles.contains { $0.id == snapshot.activeID } ? snapshot.activeID : snapshot.profiles[0].id
            requireAuthenticationForOwner = snapshot.requireAuthenticationForOwner
        } else {
            let owner = HouseholdProfile(name: "Owner", role: .owner)
            profiles = [owner]
            activeID = owner.id
            requireAuthenticationForOwner = false
        }
    }

    var active: HouseholdProfile { profiles.first { $0.id == activeID } ?? profiles[0] }
    var allowsActions: Bool { active.role == .owner }

    /// Switching into an owner profile can require Face ID, Touch ID or the device passcode.
    func activate(_ profile: HouseholdProfile) async throws {
        if profile.role == .owner, requireAuthenticationForOwner, profile.id != activeID {
            try await authenticate("Switch to \(profile.name)")
        }
        activeID = profile.id
        persist()
    }

    func save(_ profile: HouseholdProfile) throws {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        guard updated.contains(where: { $0.role == .owner }) else { throw ProfileError.needsOwner }
        profiles = updated
        persist()
    }

    func delete(_ profile: HouseholdProfile) throws {
        let remaining = profiles.filter { $0.id != profile.id }
        guard remaining.contains(where: { $0.role == .owner }) else { throw ProfileError.needsOwner }
        profiles = remaining
        if activeID == profile.id { activeID = remaining[0].id }
        persist()
    }

    /// Authenticates before turning the requirement on, so it can't lock anyone out of a device that can't unlock.
    func setRequireAuthentication(_ value: Bool) async throws {
        if value { try await authenticate("Require Face ID, Touch ID or the passcode to switch to an Owner profile") }
        requireAuthenticationForOwner = value
        persist()
    }

    /// What changes when switching profiles, shown before a switch that removes control.
    func transitionNotice(to profile: HouseholdProfile) -> String? {
        guard active.role == .owner, profile.role == .viewer, profile.id != activeID else { return nil }
        let back = requireAuthenticationForOwner
            ? "Switching back to an Owner profile will ask for Face ID, Touch ID or the passcode."
            : "Anyone holding this device can switch back to an Owner profile. Turn on “Require Face ID or passcode” first to prevent that."
        return "\(profile.name) can see status but can't run actions, open terminals, edit connections or restore backups. \(back)"
    }

    /// A view-only profile without the Owner-switch requirement is easy to leave.
    var viewerProtectionMissing: Bool {
        profiles.contains { $0.role == .viewer } && !requireAuthenticationForOwner
    }

    private func persist() {
        try? file.save(Snapshot(profiles: profiles, activeID: activeID, requireAuthenticationForOwner: requireAuthenticationForOwner))
    }
}

enum ProfileError: Error, LocalizedError {
    case needsOwner

    var errorDescription: String? {
        "Keep at least one Owner profile so someone can manage this device's connections."
    }
}

private struct AllowsActionsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False for view-only profiles; every control that changes a server honours it.
    var allowsActions: Bool {
        get { self[AllowsActionsKey.self] }
        set { self[AllowsActionsKey.self] = newValue }
    }
}
