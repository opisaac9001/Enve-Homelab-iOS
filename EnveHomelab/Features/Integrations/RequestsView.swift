import SwiftUI

struct RequestsSnapshot: Sendable {
    var overview: SeerrOverview
    var requests: [SeerrRequestItem]
    var issues: [SeerrIssueItem]
}

/// Managing requests people have already made; the app never searches for or creates requests.
struct RequestsView: View {
    @Environment(\.allowsActions) private var allowsActions
    let instance: IntegrationInstance
    let service: any RequestService
    @State private var state = LoadState<RequestsSnapshot>()
    @State private var showsIssues = false
    @State private var filter: SeerrRequestFilter = .pending
    @State private var resolvedIssues = false
    @State private var pending: PendingAction?
    @State private var approving: SeerrRequestItem?
    @State private var editingRequest: SeerrRequestItem?
    @State private var openIssue: SeerrIssueItem?
    @State private var notice: String?

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading requests…", interval: instance.kind.refreshInterval, load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(title: instance.name, version: snapshot.overview.status.version, health: SeerrMapping.summary(snapshot.overview, kind: instance.kind).health,
                                  lines: headerLines(snapshot.overview))
                if let notice { InlineNotice(text: notice) }
                metrics(snapshot.overview)
                Picker("Show", selection: $showsIssues) {
                    Text("Requests").tag(false)
                    Text("Issues").tag(true)
                }
                .pickerStyle(.segmented)
                if showsIssues {
                    issuesCard(snapshot.issues)
                } else {
                    requestsCard(snapshot.requests)
                }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: filter) { Task { await load() } }
        .onChange(of: resolvedIssues) { Task { await load() } }
        .actionConfirmation($pending) { Task { await load() } }
        .sheet(item: $approving) { item in
            ApproveRequestSheet(instance: instance, service: service, item: item) { routing in
                notice = routing.map { "Approved \(item.displayTitle) and sent it to \($0.serverName)." } ?? "Approved \(item.displayTitle)."
                Task { await load() }
            }
        }
        .sheet(item: $editingRequest) { item in
            EditRequestSheet(service: service, item: item) {
                notice = "Updated \(item.displayTitle)."
                Task { await load() }
            }
        }
        .sheet(item: $openIssue, onDismiss: { Task { await load() } }) { item in
            IssueDetailSheet(service: service, item: item)
        }
    }

    private func headerLines(_ overview: SeerrOverview) -> [String] {
        var lines: [String] = []
        if overview.status.restartRequired == true { lines.append("Seerr needs a restart to apply settings changes.") }
        if overview.status.updateAvailable == true { lines.append("An update is available.") }
        return lines
    }

    private func metrics(_ overview: SeerrOverview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            MetricTile(title: "Pending approval", value: "\(overview.requests.pending)", systemImage: "hourglass", health: overview.requests.pending > 0 ? .warning : nil)
            MetricTile(title: "Processing", value: "\(overview.requests.processing ?? 0)", systemImage: "gearshape.2")
            MetricTile(title: "Available", value: "\(overview.requests.available ?? 0)", systemImage: "checkmark.circle")
            if let issues = overview.issues {
                MetricTile(title: "Open issues", value: "\(issues.open)", systemImage: "exclamationmark.bubble", health: issues.open > 0 ? .warning : nil)
            }
            MetricTile(title: "All requests", value: "\(overview.about?.totalRequests ?? overview.requests.total)", systemImage: "tray.full")
            if let items = overview.about?.totalMediaItems {
                MetricTile(title: "Tracked titles", value: "\(items)", systemImage: "film.stack")
            }
        }
    }

    private func requestsCard(_ requests: [SeerrRequestItem]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(SeerrRequestFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if requests.isEmpty {
                    Text(filter == .pending ? "Nothing is waiting for approval." : "No \(filter.title.lowercased()) requests.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(requests) { item in
                    requestRow(item)
                    if item.id != requests.last?.id { Divider() }
                }
            }
        }
    }

    private func requestRow(_ item: SeerrRequestItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isTV ? "tv" : "film")
                .foregroundStyle(Color.enveAccent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.subheadline.weight(.semibold))
                Text(requestDetail(item)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let status = item.status { StatusBadge(text: status.title, health: health(status)) }
                    if let media = item.mediaStatus, item.status != .declined { StatusBadge(text: media.title, health: media == .available ? .ok : .unknown) }
                }
            }
            Spacer(minLength: 0)
            if allowsActions {
                Menu {
                    requestActions(item)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("Actions for \(item.title)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func requestActions(_ item: SeerrRequestItem) -> some View {
        if item.status == .pending {
            Button { approving = item } label: { Label("Approve…", systemImage: "checkmark.circle") }
            Button { editingRequest = item } label: { Label("Edit Request…", systemImage: "pencil") }
            Button {
                pending = .integration(instance, title: "Decline Request", systemImage: "xmark.circle", targetKind: "Request", targetName: item.displayTitle,
                                       consequence: "\(requester(item)) is told the request was declined. Nothing is sent to Radarr or Sonarr.", destructive: true) { [service] in
                    try await service.decline(item)
                }
            } label: { Label("Decline…", systemImage: "xmark.circle") }
        }
        if item.status == .failed {
            Button {
                pending = .integration(instance, title: "Retry Request", systemImage: "arrow.clockwise", targetKind: "Request", targetName: item.displayTitle,
                                       consequence: "Seerr sends the request to \(item.isTV ? "Sonarr" : "Radarr") again, which may start searching and downloading.") { [service] in
                    try await service.retry(item)
                }
            } label: { Label("Retry…", systemImage: "arrow.clockwise") }
        }
        Button(role: .destructive) {
            pending = .integration(instance, title: "Delete Request", systemImage: "trash", targetKind: "Request", targetName: item.displayTitle,
                                   consequence: "The request by \(requester(item)) is removed from Seerr. Anything already sent to \(item.isTV ? "Sonarr" : "Radarr") or downloaded stays.",
                                   destructive: true) { [service] in
                try await service.delete(item)
            }
        } label: { Label("Delete Request…", systemImage: "trash") }
    }

    private func requester(_ item: SeerrRequestItem) -> String {
        item.request.requestedBy?.name ?? "The requester"
    }

    private func requestDetail(_ item: SeerrRequestItem) -> String {
        var parts = [item.isTV ? "Series" : "Movie"]
        if item.request.is4k == true { parts.append("4K") }
        if item.isTV, let seasons = item.request.seasons, !seasons.isEmpty {
            parts.append(seasons.count == 1 ? "Season \(seasons[0].seasonNumber)" : "\(seasons.count) seasons")
        }
        if let user = item.request.requestedBy { parts.append(user.name) }
        if let date = APIDate.parse(item.request.createdAt) { parts.append(Format.relative(date)) }
        return parts.joined(separator: " · ")
    }

    private func health(_ status: SeerrRequestStatus) -> Health {
        switch status {
        case .pending: .warning
        case .failed: .critical
        case .approved, .completed: .ok
        case .declined: .unknown
        }
    }

    private func issuesCard(_ issues: [SeerrIssueItem]) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Issues", selection: $resolvedIssues) {
                    Text("Open").tag(false)
                    Text("Resolved").tag(true)
                }
                .pickerStyle(.segmented)
                if issues.isEmpty {
                    Text(resolvedIssues ? "No resolved issues." : "No open issues.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(issues) { item in
                    issueRow(item)
                    if item.id != issues.last?.id { Divider() }
                }
            }
        }
    }

    private func issueRow(_ item: SeerrIssueItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(resolvedIssues ? .green : .orange)
                .frame(width: 22)
                .accessibilityHidden(true)
            Button {
                openIssue = item
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Text([item.issue.typeTitle, item.issue.createdBy?.name, APIDate.parse(item.issue.createdAt).map(Format.relative)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = item.issue.comments?.first?.message?.nilIfEmpty {
                        Text(message).font(.caption).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the conversation")
            Spacer(minLength: 0)
            if allowsActions {
                Button(resolvedIssues ? "Reopen" : "Resolve") {
                    let resolve = !resolvedIssues
                    pending = .integration(instance, title: resolve ? "Resolve Issue" : "Reopen Issue", systemImage: resolve ? "checkmark.circle" : "arrow.uturn.backward",
                                           targetKind: "\(item.issue.typeTitle) issue", targetName: item.title,
                                           consequence: resolve ? "The issue is marked resolved and \(item.issue.createdBy?.name ?? "the reporter") may be notified." : "The issue is open again.") { [service] in
                        try await service.setIssue(item, resolved: resolve)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func load() async {
        state.begin()
        let filter = filter, resolved = resolvedIssues
        state.finish(await captureResult {
            async let overview = service.overview()
            async let requests = service.requests(filter, take: 30)
            async let issues = try? service.issues(resolved: resolved)
            return try await RequestsSnapshot(overview: overview, requests: requests, issues: issues ?? [])
        })
    }
}

/// Approval is its own confirmation: it names the request, where it goes and what happens next.
private struct ApproveRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    let instance: IntegrationInstance
    let service: any RequestService
    let item: SeerrRequestItem
    let onApproved: (SeerrRouting?) -> Void

    @State private var quota: SeerrQuota?
    @State private var options: [SeerrRoutingOption]?
    @State private var optionsError: NetworkError?
    @State private var serverID: Int?
    @State private var profileID: Int?
    @State private var rootFolder: String?
    @State private var changesRouting = false
    @State private var isRunning = false
    @State private var error: NetworkError?

    private var arr: String { item.isTV ? "Sonarr" : "Radarr" }
    private var option: SeerrRoutingOption? { options?.first { $0.id == serverID } }

    private var routing: SeerrRouting? {
        guard changesRouting, let option, let profile = option.profiles.first(where: { $0.id == profileID }), let rootFolder else { return nil }
        return SeerrRouting(serverID: option.server.id, serverName: option.server.name, profileID: profile.id, profileName: profile.name, rootFolder: rootFolder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Request", value: item.displayTitle)
                    LabeledContent("Requested by", value: item.request.requestedBy?.name ?? "Unknown")
                    if let limit = item.isTV ? quota?.tv : quota?.movie { LabeledContent("\(item.isTV ? "Series" : "Movie") quota", value: limit.summary) }
                    if item.request.is4k == true { LabeledContent("Quality", value: "4K") }
                } footer: {
                    Text("Approving tells Seerr to send this to \(arr), which then searches your indexers and downloads it. \(item.request.requestedBy?.name ?? "The requester") may be notified.")
                }

                Section {
                    if !item.canReroute {
                        Text("Seerr didn't report this request's seasons, so it can only be approved with its current settings.").font(.footnote).foregroundStyle(.secondary)
                    } else if let optionsError {
                        Label(optionsError.errorDescription ?? "Servers couldn't be loaded", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if let options {
                        if options.isEmpty {
                            Text("No \(item.request.is4k == true ? "4K " : "")\(arr) server is set up in Seerr.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Toggle("Choose where it goes", isOn: $changesRouting)
                            if changesRouting {
                                Picker("\(arr) server", selection: $serverID) {
                                    ForEach(options) { Text($0.server.name + ($0.server.isDefault ? " (default)" : "")).tag(Int?.some($0.id)) }
                                }
                                if let option {
                                    Picker("Quality profile", selection: $profileID) {
                                        ForEach(option.profiles) { Text($0.name).tag(Int?.some($0.id)) }
                                    }
                                    Picker("Root folder", selection: $rootFolder) {
                                        ForEach(option.rootFolders, id: \.self) { Text($0).tag(String?.some($0)) }
                                    }
                                }
                            }
                        }
                    } else {
                        ProgressView("Loading \(arr) servers…")
                    }
                } header: {
                    Text("Routing")
                } footer: {
                    Text(changesRouting ? "The request is updated first, then approved." : "Uses the server, profile and folder already on the request, or Seerr's defaults.")
                }

                if let error {
                    Section { Label(error.errorDescription ?? "Couldn't approve", systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await approve() }
                    } label: {
                        if isRunning { ProgressView() } else { Text(routing.map { "Approve and Send to \($0.serverName)" } ?? "Approve") }
                    }
                    .disabled(!allowsActions || isRunning || (changesRouting && routing == nil))
                }
            }
            .navigationTitle("Approve Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await loadOptions() }
            .onChange(of: serverID) {
                guard let option else { return }
                if !option.profiles.contains(where: { $0.id == profileID }) { profileID = option.server.activeProfileId ?? option.profiles.first?.id }
                if !option.rootFolders.contains(where: { $0 == rootFolder }) { rootFolder = option.server.activeDirectory ?? option.rootFolders.first }
            }
        }
    }

    private func loadOptions() async {
        if let requester = item.request.requestedBy?.id { quota = try? await service.quota(userID: requester) }
        guard item.canReroute else { return }
        do {
            let loaded = try await service.routingOptions(for: item)
            options = loaded
            if let initial = SeerrMapping.defaultRouting(for: item, options: loaded) {
                serverID = initial.serverID
                profileID = initial.profileID
                rootFolder = initial.rootFolder
            }
        } catch {
            optionsError = .from(error)
        }
    }

    private func approve() async {
        guard allowsActions else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let routing = routing
            try await service.approve(item, routing: routing)
            onApproved(routing)
            dismiss()
        } catch {
            self.error = .from(error)
        }
    }
}

/// Changes who a pending request belongs to and, for series, which seasons it asks for; Seerr applies its own quota and season rules.
private struct EditRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    let service: any RequestService
    let item: SeerrRequestItem
    let onSaved: () -> Void

    @State private var users: [SeerrUser]?
    @State private var seasons: [SeerrTVSeasons.Season] = []
    @State private var requesterID: Int
    @State private var chosenSeasons: Set<Int>
    @State private var quota: SeerrQuota?
    @State private var loadError: NetworkError?
    @State private var error: NetworkError?
    @State private var isRunning = false

    init(service: any RequestService, item: SeerrRequestItem, onSaved: @escaping () -> Void) {
        self.service = service
        self.item = item
        self.onSaved = onSaved
        _requesterID = State(initialValue: item.request.requestedBy?.id ?? 0)
        _chosenSeasons = State(initialValue: Set((item.request.seasons ?? []).map(\.seasonNumber)))
    }

    private var originalSeasons: Set<Int> { Set((item.request.seasons ?? []).map(\.seasonNumber)) }
    private var hasChanges: Bool { requesterID != item.request.requestedBy?.id || (item.isTV && chosenSeasons != originalSeasons) }
    private var requesterName: String { users?.first { $0.id == requesterID }?.name ?? item.request.requestedBy?.name ?? "the requester" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Request", value: item.displayTitle)
                    if let users {
                        Picker("Requested by", selection: $requesterID) {
                            ForEach(users, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    } else if let loadError {
                        Label(loadError.errorDescription ?? "Users couldn't be loaded", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        ProgressView("Loading users…")
                    }
                    if let limit = item.isTV ? quota?.tv : quota?.movie {
                        LabeledContent("\(requesterName)'s \(item.isTV ? "series" : "movie") quota", value: limit.summary)
                    }
                } footer: {
                    Text("A different requester takes this request onto their quota; Seerr refuses the change if their limit is reached. Quotas themselves are changed in Seerr.")
                }

                if item.isTV {
                    Section {
                        if !item.canReroute {
                            Text("Seerr didn't report this request's seasons, so they can't be edited here.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(seasons) { season in
                                Toggle(isOn: Binding(get: { chosenSeasons.contains(season.seasonNumber) },
                                                     set: { if $0 { chosenSeasons.insert(season.seasonNumber) } else { chosenSeasons.remove(season.seasonNumber) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(season.name?.nilIfEmpty ?? "Season \(season.seasonNumber)")
                                        if let count = season.episodeCount { Text("\(count) episodes").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Seasons")
                    } footer: {
                        Text("Seerr leaves out seasons that another request already covers or that are already available. To withdraw the whole request, delete it instead.")
                    }
                }

                if let error {
                    Section { Label(error.errorDescription ?? "Couldn't save", systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Edit Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!allowsActions || isRunning || !hasChanges || (item.isTV && item.canReroute && chosenSeasons.isEmpty))
                }
            }
            .task { await load() }
            .task(id: requesterID) { quota = requesterID == 0 ? nil : try? await service.quota(userID: requesterID) }
        }
    }

    private func load() async {
        do {
            async let people = service.users()
            async let available = service.seasons(for: item)
            users = try await people
            seasons = (try? await available) ?? []
        } catch {
            loadError = .from(error)
        }
    }

    private func save() async {
        isRunning = true
        defer { isRunning = false }
        do {
            try await service.update(item, requesterID: requesterID, seasons: item.isTV && item.canReroute ? chosenSeasons.sorted() : nil)
            onSaved()
            dismiss()
        } catch {
            self.error = .from(error)
        }
    }
}

/// The issue's conversation; the owner can reply, which Seerr may notify the reporter about.
private struct IssueDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsActions) private var allowsActions
    let service: any RequestService
    @State var item: SeerrIssueItem
    @State private var reply = ""
    @State private var isSending = false
    @State private var error: NetworkError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Title", value: item.title)
                    LabeledContent("Problem", value: item.issue.typeTitle)
                    if let reporter = item.issue.createdBy { LabeledContent("Reported by", value: reporter.name) }
                }
                Section("Conversation") {
                    let comments = item.issue.comments ?? []
                    if comments.isEmpty { Text("No comments.").foregroundStyle(.secondary) }
                    ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text([comment.user?.name, APIDate.parse(comment.createdAt).map(Format.relative)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(comment.message ?? "")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if allowsActions {
                    Section {
                        TextField("Reply", text: $reply, axis: .vertical)
                            .lineLimit(2...6)
                        Button {
                            Task { await send() }
                        } label: {
                            if isSending { ProgressView() } else { Text("Add Comment") }
                        }
                        .disabled(isSending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let error { Text(error.errorDescription ?? "Couldn't send").foregroundStyle(.red) }
                    } footer: {
                        Text("Posted as Seerr's owner account, because that's who the API key acts as. Seerr may notify the reporter.")
                    }
                }
            }
            .navigationTitle("Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { if let full = try? await service.issue(item) { item = full } }
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            try await service.comment(on: item, message: reply.trimmingCharacters(in: .whitespacesAndNewlines))
            reply = ""
            error = nil
            item = try await service.issue(item)
        } catch {
            self.error = .from(error)
        }
    }
}
