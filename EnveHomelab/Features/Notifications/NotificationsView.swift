import SwiftUI

@MainActor
@Observable
final class NotificationsModel {
    var listType: NotificationListType = .unread
    var importance: NotificationImportance?
    var items = LoadState<[UnraidNotification]>()
    var overview: NotificationOverview?
    var archiveError: NetworkError?
    let service: any UnraidService

    init(service: any UnraidService) {
        self.service = service
    }

    func load() async {
        items.begin()
        let service = service
        let type = listType
        let importance = importance
        async let list = captureResult { try await service.notifications(type, importance: importance, limit: 100) }
        async let overview = try? service.notificationOverview()
        items.finish(await list)
        if let overview = await overview { self.overview = overview }
    }

    func archive(_ notification: UnraidNotification) async {
        do {
            try await service.archiveNotification(id: notification.id)
            archiveError = nil
            items.value?.removeAll { $0.id == notification.id }
            await load()
        } catch {
            archiveError = .from(error)
        }
    }
}

struct NotificationsView: View {
    let context: ServerContext
    @Environment(\.allowsActions) private var allowsActions
    @State private var model: NotificationsModel
    @State private var pending: PendingAction?

    init(context: ServerContext) {
        self.context = context
        _model = State(initialValue: NotificationsModel(service: context.service))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("List", selection: $model.listType) {
                        ForEach(NotificationListType.allCases) { type in
                            Text(label(for: type)).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if let error = model.archiveError {
                    InlineErrorBanner(error: error)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                if let items = model.items.value {
                    if let error = model.items.error {
                        InlineErrorBanner(error: error)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                    if items.isEmpty {
                        ContentUnavailableView(
                            model.listType == .unread ? "All caught up" : "No archived notifications",
                            systemImage: "bell.slash",
                            description: Text(model.importance.map { "No \($0.displayName.lowercased()) notifications." } ?? "Nothing to show.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(items) { item in
                            NotificationRow(notification: item)
                                .swipeActions(edge: .trailing) {
                                    if model.listType == .unread && allowsActions {
                                        Button {
                                            Task { await model.archive(item) }
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                        .tint(.enveAccent)
                                    }
                                }
                        }
                    }
                } else if let error = model.items.error {
                    ErrorStateView(error: error) { reload() }
                        .listRowBackground(Color.clear)
                } else {
                    LoadingStateView(message: "Loading notifications…")
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .bottomBarPadding()
            .refreshable { await model.load() }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ServerSwitcherButton() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Importance", selection: $model.importance) {
                            Text("All").tag(NotificationImportance?.none)
                            ForEach(NotificationImportance.allCases) { importance in
                                Text(importance.displayName).tag(NotificationImportance?.some(importance))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: model.importance == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    if model.listType == .unread, let unread = model.overview?.unread.total, unread > 0 {
                        Button {
                            pending = PendingAction(
                                title: "Archive All",
                                systemImage: "archivebox",
                                targetKind: "Notifications",
                                targetName: "\(unread) unread",
                                serverName: context.serverName,
                                consequence: "Every unread notification on the server moves to the archive, regardless of the filter shown here. Archived notifications can still be viewed.",
                                isPreview: context.isPreview
                            ) { [service = context.service] in
                                try await service.archiveAllNotifications()
                            }
                        } label: {
                            Label("Archive All", systemImage: "archivebox")
                        }
                    }
                }
            }
            .enveScreen()
        }
        .task(id: "\(model.listType.rawValue)-\(model.importance?.rawValue ?? "all")") { await model.load() }
        .actionConfirmation($pending) { reload() }
    }

    private func reload() {
        Task { await model.load() }
    }

    private func label(for type: NotificationListType) -> String {
        guard let overview = model.overview else { return type.displayName }
        let count = type == .unread ? overview.unread.total : overview.archive.total
        return "\(type.displayName) (\(count))"
    }
}

struct NotificationRow: View {
    let notification: UnraidNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(notification.importance.health == .unknown ? Color.enveAccent : notification.importance.health.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.subject)
                    .font(.body.weight(.semibold))
                if !notification.description.isEmpty {
                    Text(notification.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(notification.title)
                    if let when {
                        Text("·")
                        Text(when)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notification.importance.displayName): \(notification.subject)")
    }

    private var icon: String {
        switch notification.importance {
        case .alert: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info, .unknown: "info.circle.fill"
        }
    }

    private var when: String? {
        notification.timestamp.map(Format.relative) ?? notification.formattedTimestamp
    }
}
