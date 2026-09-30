import SwiftUI

@MainActor
@Observable
final class ContainersModel {
    var containers = LoadState<[DockerContainer]>()
    /// nil before Unraid API 4.29, which added conflict detection.
    var conflicts: DockerPortConflicts?
    let service: any UnraidService

    init(service: any UnraidService) {
        self.service = service
    }

    func load() async {
        containers.begin()
        let service = service
        async let conflicts = try? service.portConflicts()
        containers.finish(await captureResult { try await service.containers() })
        self.conflicts = await conflicts
    }

    func container(id: String) -> DockerContainer? {
        containers.value?.first { $0.id == id }
    }
}

enum ContainerFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"

    var id: String { rawValue }

    func matches(_ container: DockerContainer) -> Bool {
        switch self {
        case .all: true
        case .running: container.state == .running || container.state == .paused
        case .stopped: container.state == .exited || container.state == .unknown
        }
    }
}

struct ContainerListView: View {
    let context: ServerContext
    @State private var model: ContainersModel
    @State private var search = ""
    @State private var filter: ContainerFilter = .all
    @State private var pending: PendingAction?
    @Environment(\.allowsActions) private var allowsActions

    init(context: ServerContext) {
        self.context = context
        _model = State(initialValue: ContainersModel(service: context.service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Filter", selection: $filter) {
                        ForEach(ContainerFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if let conflicts = model.conflicts, !conflicts.isEmpty {
                        EnveCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Port conflicts", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                                ForEach(conflicts.descriptions, id: \.self) { Text($0).font(.caption.monospaced()) }
                                Text("Only one of these containers can use the port at a time. Change a port mapping in the container's template on the server.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }

                    LoadStateContainer(state: model.containers, loadingMessage: "Loading containers…", retry: reload) { containers in
                        let visible = filtered(containers)
                        if containers.isEmpty {
                            ContentUnavailableView("No containers", systemImage: "shippingbox", description: Text("Docker has no containers on this server, or the Docker service is stopped."))
                        } else if visible.isEmpty {
                            ContentUnavailableView.search(text: search)
                        } else {
                            EnveCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, container in
                                        if index > 0 { Divider().padding(.leading, 60) }
                                        NavigationLink(value: container.id) {
                                            ContainerRow(container: container)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { actionMenu(for: container) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .bottomBarPadding()
            .searchable(text: $search, prompt: "Name or image")
            .refreshable { await model.load() }
            .navigationTitle("Docker")
            .navigationDestination(for: String.self) { id in
                ContainerDetailView(context: context, model: model, containerID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ServerSwitcherButton() }
            }
            .enveScreen()
        }
        .task { await model.load() }
        .actionConfirmation($pending) { reload() }
    }

    private func reload() {
        Task { await model.load() }
    }

    private func filtered(_ containers: [DockerContainer]) -> [DockerContainer] {
        containers.filter { container in
            filter.matches(container) && (search.isEmpty
                || container.name.localizedCaseInsensitiveContains(search)
                || container.image.localizedCaseInsensitiveContains(search))
        }
    }

    @ViewBuilder
    private func actionMenu(for container: DockerContainer) -> some View {
        ForEach(allowsActions ? ContainerAction.available(for: container.state) : []) { action in
            Button {
                pending = .container(action, container, context: context)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}

extension PendingAction {
    static func container(_ action: ContainerAction, _ container: DockerContainer, context: ServerContext) -> PendingAction {
        PendingAction(
            title: "\(action.title) Container",
            systemImage: action.systemImage,
            targetKind: "Container",
            targetName: container.name,
            serverName: context.serverName,
            consequence: action.consequence,
            isDestructive: action == .stop,
            isPreview: context.isPreview
        ) { [service = context.service, id = container.id] in
            try await service.perform(action, containerID: id)
        }
    }
}

struct ContainerRow: View {
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 12) {
            ContainerIcon(container: container)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if container.isUpdateAvailable == true {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.enveAccent)
                            .accessibilityLabel("Update available")
                    }
                }
                Text(container.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(container.state.displayName)
    }
}

struct ContainerIcon: View {
    let container: DockerContainer

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = container.iconURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        fallback
                    }
                } else {
                    fallback
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Circle()
                .fill(container.state.health == .unknown ? Color.gray : container.state.health.color)
                .frame(width: 11, height: 11)
                .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.enveAccent.opacity(0.18))
            .overlay {
                Text(container.name.prefix(1).uppercased())
                    .font(.headline)
                    .foregroundStyle(Color.enveAccent)
            }
    }
}
