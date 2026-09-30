import Foundation

struct WizarrStatus: Decodable, Sendable {
    var users: Int
    var invites: Int
    var pending: Int
    var expired: Int
}

struct WizarrInvitation: Decodable, Sendable {
    var id: Int
    var code: String
    var status: String
    var created: String?
    var expires: String?
    var used_at: String?
    var used_by: WizarrUsedBy?
    var duration: String?
    var unlimited: Bool?
    var server_names: [String]?
}

/// `used_by` is null or a user reference whose exact shape varies by version; only a display name is read.
struct WizarrUsedBy: Decodable, Sendable {
    var name: String?

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let text = try? container.decode(String.self) {
            name = text
        } else if let keyed = try? decoder.container(keyedBy: Keys.self) {
            name = (try? keyed.decode(String.self, forKey: .username)) ?? (try? keyed.decode(String.self, forKey: .email))
        }
    }

    enum Keys: String, CodingKey { case username, email }
}

struct WizarrUser: Decodable, Sendable {
    var id: Int
    var username: String
    var email: String?
    var server: String?
    var server_type: String?
    var expires: String?
    var created_at: String?
}

struct WizarrServer: Decodable, Sendable {
    var id: Int
    var name: String
    var server_type: String
    var verified: Bool?
}

struct WizarrOverview: Sendable {
    var status: WizarrStatus
    var invitations: [WizarrInvitation]
    var users: [WizarrUser]
    var servers: [WizarrServer]
}

protocol WizarrOperations: Sendable {
    func deleteInvitation(id: Int) async throws
    func extend(userID: Int, days: Int) async throws
    func removeUser(id: Int) async throws
}

/// Wizarr 2025.8.3+ REST API with `X-API-Key`. It exposes no version number.
struct WizarrClient: DashboardService, WizarrOperations {
    let kind = IntegrationKind.wizarr
    private let rest: RESTClient

    init(url: URL, apiKey: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.lastPathComponent == "api" ? url : url.appending(path: "api"), pinnedFingerprint: pinnedFingerprint,
                          headers: ["X-API-Key": apiKey], timeout: 45)
    }

    private struct Invitations: Decodable { var invitations: [WizarrInvitation] }
    private struct Users: Decodable { var users: [WizarrUser] }
    private struct Servers: Decodable { var servers: [WizarrServer] }

    func overview() async throws -> WizarrOverview {
        async let status = rest.json(.get("status"), as: WizarrStatus.self)
        async let invitations = rest.json(.get("invitations"), as: Invitations.self).invitations
        async let servers = rest.json(.get("servers"), as: Servers.self).servers
        // Wizarr asks every media server for its users live, so this is the slow call.
        async let users = rest.json(.get("users"), as: Users.self).users
        return try await WizarrOverview(status: status, invitations: invitations, users: users, servers: servers)
    }

    func dashboard() async throws -> DashboardSnapshot {
        WizarrDashboard.snapshot(try await overview(), operations: self)
    }

    func deleteInvitation(id: Int) async throws {
        _ = try await rest.data(.delete("invitations/\(id)"))
    }

    func extend(userID: Int, days: Int) async throws {
        _ = try await rest.data(try .post("users/\(userID)/extend", json: ["days": days]))
    }

    func removeUser(id: Int) async throws {
        _ = try await rest.data(.delete("users/\(id)"))
    }
}

enum WizarrDashboard {
    static func snapshot(_ overview: WizarrOverview, operations: some WizarrOperations) -> DashboardSnapshot {
        let unverified = overview.servers.filter { $0.verified == false }
        let pending = overview.invitations.filter { $0.status == "pending" }
        let soon = Date.now.addingTimeInterval(7 * 86_400)
        let expiringUsers = overview.users.filter { APIDate.parse($0.expires).map { $0 <= soon } ?? false }
        let order = ["pending": 0, "used": 1, "expired": 2]

        return DashboardSnapshot(
            version: nil,
            health: unverified.isEmpty ? .ok : .warning,
            headline: "\(overview.status.users) user\(overview.status.users == 1 ? "" : "s") · \(overview.status.pending) pending invite\(overview.status.pending == 1 ? "" : "s")",
            detail: expiringUsers.isEmpty ? nil : "\(expiringUsers.count) user\(expiringUsers.count == 1 ? "" : "s") expiring within a week",
            notice: unverified.isEmpty ? nil : "Wizarr can't verify \(unverified.map(\.name).joined(separator: ", ")). Invitations for it won't work until it's reachable.",
            metrics: [
                DashboardMetric(title: "Users", value: "\(overview.status.users)", systemImage: "person.2"),
                DashboardMetric(title: "Pending invites", value: "\(overview.status.pending)", systemImage: "envelope"),
                DashboardMetric(title: "Expired invites", value: "\(overview.status.expired)", systemImage: "envelope.badge"),
                DashboardMetric(title: "Media servers", value: "\(overview.servers.count)", systemImage: "server.rack", health: unverified.isEmpty ? nil : .warning),
            ],
            sections: [
                DashboardSection(id: "invitations", title: "Invitations", systemImage: "envelope", trailing: "\(pending.count) pending", emptyText: "No invitations have been created.",
                                 rows: overview.invitations.sorted { order[$0.status, default: 3] < order[$1.status, default: 3] }.map { invite in
                                     var detail: [String] = []
                                     if let expires = APIDate.parse(invite.expires), invite.status == "pending" { detail.append("Link expires \(Format.relative(expires))") }
                                     if let used = invite.used_by?.name { detail.append("Used by \(used)") }
                                     detail.append(invite.unlimited == true || invite.duration == "unlimited" ? "Unlimited access" : invite.duration.map { "\($0)-day access" } ?? "")
                                     return DashboardRow(id: "i\(invite.id)", title: invite.code, subtitle: invite.server_names?.joined(separator: ", "),
                                                         detail: detail.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty,
                                                         health: invite.status == "expired" ? .unknown : .ok, badge: invite.status.capitalizedFirst,
                                                         actions: [DashboardAction(id: "delete-invite:\(invite.id)", title: "Delete Invitation…", systemImage: "trash", targetKind: "Invitation", targetName: invite.code,
                                                                                   consequence: invite.status == "pending" ? "The invitation link stops working immediately. People who already joined keep their access." : "The invitation is removed from Wizarr's list. People who joined with it keep their access.",
                                                                                   confirmation: .destructive) {
                                                             try await operations.deleteInvitation(id: invite.id)
                                                         }])
                                 }),
                DashboardSection(id: "users", title: "Users", systemImage: "person.2", trailing: "\(overview.users.count)", emptyText: "Wizarr couldn't list users from any media server.",
                                 rows: overview.users.map { user in
                                     let expiry = APIDate.parse(user.expires)
                                     return DashboardRow(id: "u\(user.id)", title: user.username, subtitle: [user.server, user.email].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                         detail: expiry.map { $0 < .now ? "Access expired \(Format.relative($0))" : "Access expires \(Format.relative($0))" } ?? "No expiry",
                                                         health: expiry.map { $0 < .now ? .warning : ($0 <= soon ? .unknown : .ok) },
                                                         actions: [
                                                             DashboardAction(id: "extend:\(user.id)", title: "Extend 30 Days", systemImage: "calendar.badge.plus", targetKind: "User", targetName: user.username,
                                                                             consequence: "Wizarr adds 30 days to \(user.username)'s access" + (expiry == nil ? ". They currently have no expiry, so this sets one 30 days from now." : ".")) {
                                                                 try await operations.extend(userID: user.id, days: 30)
                                                             },
                                                             DashboardAction(id: "remove:\(user.id)", title: "Remove User…", systemImage: "person.badge.minus", targetKind: "User", targetName: user.username,
                                                                             consequence: "Wizarr deletes \(user.username)'s account on \(user.server ?? "the media server") and removes them from Wizarr. They lose access immediately; watch history on that server may be lost.",
                                                                             confirmation: .typed) {
                                                                 try await operations.removeUser(id: user.id)
                                                             },
                                                         ])
                                 }),
                DashboardSection(id: "servers", title: "Media Servers", systemImage: "server.rack", trailing: "\(overview.servers.count)", emptyText: "No media servers are connected to Wizarr.",
                                 rows: overview.servers.map { server in
                                     DashboardRow(id: "s\(server.id)", title: server.name, subtitle: server.server_type.capitalizedFirst,
                                                  health: server.verified == false ? .warning : .ok, badge: server.verified == false ? "Unverified" : "Verified")
                                 }),
            ]
        )
    }
}
