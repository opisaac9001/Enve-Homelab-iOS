import Foundation
import os

/// Synology APIs answer HTTP 200 and report failure in `success`/`error.code`, whose meaning depends on the API.
struct SynologyEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    struct APIError: Decodable, Sendable { var code: Int }
    var success: Bool
    var data: Value?
    var error: APIError?
}

struct SynologyAPIInfo: Decodable, Sendable {
    var path: String
    var minVersion: Int
    var maxVersion: Int
}

struct SynologyTask: Decodable, Sendable {
    struct Extra: Decodable, Sendable { var error_detail: String?; var unzip_progress: Int? }
    struct Additional: Decodable, Sendable {
        struct Transfer: Decodable, Sendable {
            var size_downloaded: LooseNumber?
            var size_uploaded: LooseNumber?
            var speed_download: LooseNumber?
            var speed_upload: LooseNumber?
        }
        var transfer: Transfer?
    }

    var id: String
    var type: String?
    var title: String
    var size: LooseNumber?
    var status: String
    var status_extra: Extra?
    var additional: Additional?

    var transferState: TransferState {
        switch status {
        case "downloading", "filehosting_waiting": .downloading
        case "seeding": .seeding
        case "paused": .paused
        case "waiting": .queued
        case "finishing", "hash_checking": .checking
        case "extracting": .importing
        case "finished": .completed
        case "error": .failed
        default: .unknown
        }
    }

    var transferItem: TransferItem {
        let total = size?.value ?? 0
        let done = additional?.transfer?.size_downloaded?.value ?? 0
        let rate = additional?.transfer?.speed_download?.value ?? 0
        return TransferItem(
            id: id, name: title, subtitle: type?.uppercased(), state: transferState,
            progress: status == "finished" || status == "seeding" ? 1 : (total > 0 ? done / total : 0),
            size: Int64(total), remaining: Int64(max(total - done, 0)),
            downloadRate: Int64(rate), uploadRate: additional?.transfer?.speed_upload?.value.map { Int64($0) },
            eta: rate > 0 && total > done ? (total - done) / rate : nil,
            message: status_extra?.error_detail.map { $0.replacingOccurrences(of: "_", with: " ").capitalizedFirst }
        )
    }
}

struct SynologyGuest: Decodable, Sendable {
    var guest_id: String
    var guest_name: String
    var status: String
    var vcpu_num: Int?
    var vram_size: Int?
    var storage_name: String?
}

struct SynologyHost: Decodable, Sendable {
    var host_id: String
    var host_name: String
    var status: String
    var total_cpu_core: Int?
    var free_cpu_core: Int?
    var total_ram_size: Int?
    var free_ram_size: Int?
}

struct SynologyOverview: Sendable {
    var downloadStationVersion: String?
    var tasks: [SynologyTask]?
    var downloadRate: Int64
    var uploadRate: Int64
    var guests: [SynologyGuest]?
    var hosts: [SynologyHost]
}

enum SynologyGuestAction: String, Sendable {
    case poweron, shutdown, poweroff
}

protocol SynologyOperations: Sendable {
    func tasks(_ method: String, ids: [String]) async throws
    func guest(_ action: SynologyGuestAction, id: String) async throws
}

/// Synology DSM through its documented Web APIs only: discovery, sign-in, Download Station and Virtual Machine Manager.
final class SynologyClient: DashboardService, SynologyOperations {
    let kind = IntegrationKind.synology
    static let deviceName = "Petty: Homelab"
    private let rest: RESTClient
    private let account: String
    private let password: String
    private let state = OSAllocatedUnfairLock<(apis: [String: SynologyAPIInfo]?, sessions: [String: String])>(initialState: (nil, [:]))

    init(url: URL, account: String, password: String, pinnedFingerprint: String?) {
        rest = RESTClient(baseURL: url.appending(path: "webapi"), pinnedFingerprint: pinnedFingerprint)
        self.account = account
        self.password = password
    }

    static let wanted = ["SYNO.API.Auth", "SYNO.DownloadStation.Task", "SYNO.DownloadStation.Info", "SYNO.DownloadStation.Statistic",
                         "SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Guest.Action", "SYNO.Virtualization.API.Host"]

    private func apis() async throws -> [String: SynologyAPIInfo] {
        if let cached = state.withLock({ $0.apis }) { return cached }
        let query = [URLQueryItem(name: "api", value: "SYNO.API.Info"), URLQueryItem(name: "version", value: "1"),
                     URLQueryItem(name: "method", value: "query"), URLQueryItem(name: "query", value: Self.wanted.joined(separator: ","))]
        var info: [String: SynologyAPIInfo]?
        // DSM 7 serves discovery at entry.cgi; older DSM releases at query.cgi.
        for path in ["entry.cgi", "query.cgi"] {
            if let envelope = try? await rest.json(.get(path, query: query), as: SynologyEnvelope<[String: SynologyAPIInfo]>.self), envelope.success {
                info = envelope.data
                break
            }
        }
        guard let info, info["SYNO.API.Auth"] != nil else { throw NetworkError.unsupportedByServer("This doesn't look like a Synology DSM address.") }
        state.withLock { $0.apis = info }
        return info
    }

    private func version(_ api: SynologyAPIInfo, preferred: Int) -> Int { min(api.maxVersion, max(api.minVersion, preferred)) }

    static func authError(_ code: Int) -> NetworkError {
        switch code {
        case 400: .unauthorized
        case 401: .forbidden("This DSM account is disabled.")
        case 402: .forbidden("This DSM account isn't allowed to sign in here.")
        case 403, 404, 406: .forbidden("This DSM account requires two-factor codes, which the app doesn't store. Use a dedicated DSM account for the app with only Download Station and Virtual Machine Manager access.")
        case 407: .forbidden("DSM has blocked this device's IP address after failed sign-ins. Unblock it in DSM's security settings.")
        case 408, 409, 410: .forbidden("This DSM account's password has expired. Change it in DSM first.")
        default: .graphQL(["DSM refused the sign-in (error \(code))."])
        }
    }

    /// Download Station requires its own named session; other APIs share the default one.
    private func session(_ name: String?) async throws -> String {
        let key = name ?? ""
        if let sid = state.withLock({ $0.sessions[key] }) { return sid }
        let apis = try await apis()
        guard let auth = apis["SYNO.API.Auth"] else { throw NetworkError.apiNotFound }
        struct Login: Decodable { var sid: String }
        var form = ["api": "SYNO.API.Auth", "version": String(version(auth, preferred: 6)), "method": "login",
                    "account": account, "passwd": password, "format": "sid", "device_name": Self.deviceName]
        if let name { form["session"] = name }
        let envelope = try await rest.json(.post(auth.path, form: form), as: SynologyEnvelope<Login>.self)
        guard envelope.success, let sid = envelope.data?.sid else { throw Self.authError(envelope.error?.code ?? 0) }
        state.withLock { $0.sessions[key] = sid }
        return sid
    }

    /// Codes 106, 107, 119 and 150 mean the session ended or moved to another address; sign in again once.
    private func call<Value: Decodable & Sendable>(_ apiName: String, method: String, version preferred: Int = 1, session name: String? = nil,
                                                   _ parameters: [String: String] = [:], as type: Value.Type) async throws -> Value? {
        let apis = try await apis()
        guard let api = apis[apiName] else { throw NetworkError.unsupportedByServer("\(apiName) isn't available. Is the package installed?") }
        for attempt in 0..<2 {
            let sid = try await session(name)
            let form = parameters.merging(["api": apiName, "version": String(version(api, preferred: preferred)), "method": method, "_sid": sid]) { $1 }
            let envelope = try await rest.json(.post(api.path, form: form), as: SynologyEnvelope<Value>.self)
            if envelope.success { return envelope.data }
            let code = envelope.error?.code ?? 100
            if [106, 107, 119, 150].contains(code), attempt == 0 {
                state.withLock { $0.sessions[name ?? ""] = nil }
                continue
            }
            if code == 105 { throw NetworkError.forbidden("This DSM account doesn't have permission for \(apiName).") }
            throw NetworkError.graphQL(["\(apiName) failed with error \(code)."])
        }
        throw NetworkError.unauthorized
    }

    private struct DSInfo: Decodable, Sendable { var version_string: String? }
    private struct DSStatistic: Decodable, Sendable { var speed_download: Double?; var speed_upload: Double? }
    private struct Tasks: Decodable, Sendable { var tasks: [SynologyTask] }
    private struct Guests: Decodable, Sendable { var guests: [SynologyGuest] }
    private struct Hosts: Decodable, Sendable { var hosts: [SynologyHost] }

    func overview() async throws -> SynologyOverview {
        let apis = try await apis()
        var overview = SynologyOverview(tasks: nil, downloadRate: 0, uploadRate: 0, guests: nil, hosts: [])
        if apis["SYNO.DownloadStation.Task"] != nil {
            let ds = "DownloadStation"
            // The required call goes first so a wrong password fails once instead of being retried, which DSM can answer with an IP block.
            overview.tasks = try await call("SYNO.DownloadStation.Task", method: "list", session: ds, ["additional": "detail,transfer"], as: Tasks.self)?.tasks ?? []
            overview.downloadStationVersion = try? await call("SYNO.DownloadStation.Info", method: "getinfo", session: ds, as: DSInfo.self)?.version_string
            if let stats = try? await call("SYNO.DownloadStation.Statistic", method: "getinfo", session: ds, as: DSStatistic.self) {
                overview.downloadRate = Int64(stats.speed_download ?? 0)
                overview.uploadRate = Int64(stats.speed_upload ?? 0)
            }
        }
        if apis["SYNO.Virtualization.API.Guest"] != nil {
            overview.guests = try await call("SYNO.Virtualization.API.Guest", method: "list", as: Guests.self)?.guests ?? []
            overview.hosts = (try? await call("SYNO.Virtualization.API.Host", method: "list", as: Hosts.self)?.hosts) ?? []
        }
        if overview.tasks == nil, overview.guests == nil {
            throw NetworkError.unsupportedByServer("Neither Download Station nor Virtual Machine Manager is installed. Synology only documents APIs for those packages; system health and storage aren't available.")
        }
        return overview
    }

    func dashboard() async throws -> DashboardSnapshot {
        SynologyDashboard.snapshot(try await overview(), operations: self)
    }

    private struct TaskResult: Decodable, Sendable { var id: String; var error: Int }

    /// Task actions report success per task, so one call can partly fail.
    func tasks(_ method: String, ids: [String]) async throws {
        var parameters = ["id": ids.joined(separator: ",")]
        if method == "delete" { parameters["force_complete"] = "false" }
        let results = try await call("SYNO.DownloadStation.Task", method: method, session: "DownloadStation", parameters, as: [TaskResult].self) ?? []
        if let failure = results.first(where: { $0.error != 0 }) {
            throw NetworkError.graphQL(["Download Station couldn't \(method) task \(failure.id) (error \(failure.error))."])
        }
    }

    func guest(_ action: SynologyGuestAction, id: String) async throws {
        struct Empty: Decodable, Sendable {}
        _ = try await call("SYNO.Virtualization.API.Guest.Action", method: action.rawValue, ["guest_id": id], as: Empty.self)
    }
}

enum SynologyDashboard {
    static func guestHealth(_ status: String) -> Health {
        switch status {
        case "running": .ok
        case "shutdown": .unknown
        case "crashed", "inaccessible": .critical
        case "booting", "shutting_down", "moving", "stor_migrating", "creating", "importing", "preparing", "ha_standby": .unknown
        default: .warning
        }
    }

    static func snapshot(_ overview: SynologyOverview, operations: some SynologyOperations) -> DashboardSnapshot {
        let tasks = overview.tasks ?? []
        let guests = overview.guests ?? []
        let failedTasks = tasks.filter { $0.status == "error" }
        let crashed = guests.filter { guestHealth($0.status) == .critical }
        var sections: [DashboardSection] = []
        var metrics: [DashboardMetric] = []

        if overview.guests != nil {
            metrics.append(DashboardMetric(title: "VMs running", value: "\(guests.filter { $0.status == "running" }.count)/\(guests.count)", systemImage: "desktopcomputer", health: crashed.isEmpty ? nil : .critical))
            sections.append(DashboardSection(id: "vms", title: "Virtual Machines", systemImage: "desktopcomputer", trailing: "\(guests.count)", emptyText: "No virtual machines.",
                                             rows: guests.map { guest in
                                                 var actions: [DashboardAction] = []
                                                 if guest.status == "running" {
                                                     actions.append(DashboardAction(id: "vm:\(guest.guest_id):shutdown", title: "Shut Down…", systemImage: "power", targetKind: "Virtual machine", targetName: guest.guest_name,
                                                                                    consequence: "VMM asks \(guest.guest_name)'s operating system to shut down cleanly. Services inside it stop.") {
                                                         try await operations.guest(.shutdown, id: guest.guest_id)
                                                     })
                                                     actions.append(DashboardAction(id: "vm:\(guest.guest_id):poweroff", title: "Force Power Off…", systemImage: "bolt.slash", targetKind: "Virtual machine", targetName: guest.guest_name,
                                                                                    consequence: "VMM cuts power to \(guest.guest_name) immediately, like pulling the plug. Unsaved data inside it can be lost or corrupted.",
                                                                                    confirmation: .typed) {
                                                         try await operations.guest(.poweroff, id: guest.guest_id)
                                                     })
                                                 } else if guest.status == "shutdown" {
                                                     actions.append(DashboardAction(id: "vm:\(guest.guest_id):poweron", title: "Power On…", systemImage: "power", targetKind: "Virtual machine", targetName: guest.guest_name,
                                                                                    consequence: "VMM starts \(guest.guest_name) on this NAS, using its memory and CPU.") {
                                                         try await operations.guest(.poweron, id: guest.guest_id)
                                                     })
                                                 }
                                                 return DashboardRow(id: "vm:\(guest.guest_id)", title: guest.guest_name,
                                                                     subtitle: [guest.vcpu_num.map { "\($0) vCPU" }, guest.vram_size.map { "\($0 / 1024) GB RAM" }, guest.storage_name].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                                     health: guestHealth(guest.status), badge: guest.status.replacingOccurrences(of: "_", with: " ").capitalizedFirst, actions: actions)
                                             }))
            if !overview.hosts.isEmpty {
                sections.append(DashboardSection(id: "hosts", title: "VMM Hosts", systemImage: "server.rack", emptyText: "",
                                                 rows: overview.hosts.map { host in
                                                     let ram = host.total_ram_size.flatMap { total in host.free_ram_size.map { total > 0 ? Double(total - $0) / Double(total) : 0 } }
                                                     return DashboardRow(id: "host:\(host.host_id)", title: host.host_name,
                                                                         detail: [host.total_cpu_core.map { total in "\(total - (host.free_cpu_core ?? 0)) of \(total) cores assigned" },
                                                                                  host.total_ram_size.map { "\(Format.bytes(Int64($0) * 1_048_576)) RAM" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                                                         health: host.status == "running" ? .ok : .warning, badge: host.status.replacingOccurrences(of: "_", with: " ").capitalizedFirst, progress: ram)
                                                 }))
            }
        }
        if overview.tasks != nil {
            metrics.append(DashboardMetric(title: "Downloads", value: "\(tasks.filter { $0.status == "downloading" }.count) active", systemImage: "arrow.down.circle",
                                           health: failedTasks.isEmpty ? nil : .warning))
            metrics.append(DashboardMetric(title: "Download speed", value: Format.rate(overview.downloadRate), systemImage: "speedometer"))
            sections.append(DashboardSection(id: "tasks", title: "Download Station", systemImage: "arrow.down.circle", trailing: overview.downloadStationVersion, emptyText: "No download tasks.",
                                             rows: tasks.map { task in
                                                 let item = task.transferItem
                                                 var actions: [DashboardAction] = []
                                                 if item.state.isPausable {
                                                     actions.append(DashboardAction(id: "task:\(task.id):pause", title: "Pause", systemImage: "pause.fill", targetKind: "Download", targetName: task.title,
                                                                                    consequence: "Download Station pauses this task.", confirmation: .none) { try await operations.tasks("pause", ids: [task.id]) })
                                                 } else if task.status == "paused" || task.status == "error" {
                                                     actions.append(DashboardAction(id: "task:\(task.id):resume", title: "Resume", systemImage: "play.fill", targetKind: "Download", targetName: task.title,
                                                                                    consequence: "Download Station resumes this task.", confirmation: .none) { try await operations.tasks("resume", ids: [task.id]) })
                                                 }
                                                 actions.append(DashboardAction(id: "task:\(task.id):delete", title: "Remove Task…", systemImage: "trash", targetKind: "Download", targetName: task.title,
                                                                                consequence: "Download Station removes this task. Incomplete files are discarded; completed files already in the destination folder stay.",
                                                                                confirmation: .destructive) { try await operations.tasks("delete", ids: [task.id]) })
                                                 return DashboardRow(id: "task:\(task.id)", title: task.title, subtitle: item.subtitle,
                                                                     detail: [item.state.displayName, item.size.map(Format.bytes), (item.downloadRate ?? 0) > 0 ? "↓ \(Format.rate(item.downloadRate ?? 0))" : nil].compactMap { $0 }.joined(separator: " · "),
                                                                     health: item.state == .failed ? .warning : nil, progress: item.progress, message: item.message, actions: actions)
                                             }))
        }

        return DashboardSnapshot(
            version: nil,
            health: !crashed.isEmpty ? .critical : (failedTasks.isEmpty ? .ok : .warning),
            headline: [overview.guests.map { _ in "\(guests.filter { $0.status == "running" }.count) of \(guests.count) VMs running" },
                       overview.tasks.map { _ in "\(tasks.filter { $0.status == "downloading" }.count) downloading" }].compactMap { $0 }.joined(separator: " · "),
            detail: failedTasks.isEmpty ? nil : "\(failedTasks.count) download\(failedTasks.count == 1 ? "" : "s") failed",
            notice: "Synology documents APIs for Download Station and Virtual Machine Manager only; system health, storage and Container Manager aren't available through them.",
            metrics: metrics,
            sections: sections
        )
    }
}
