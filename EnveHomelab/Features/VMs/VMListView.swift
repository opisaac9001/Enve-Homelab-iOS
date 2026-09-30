import SwiftUI

@MainActor
@Observable
final class VMsModel {
    var machines = LoadState<[VirtualMachine]>()
    let service: any UnraidService

    init(service: any UnraidService) {
        self.service = service
    }

    func load() async {
        machines.begin()
        let service = service
        machines.finish(await captureResult { try await service.virtualMachines() })
    }

    func machine(id: String) -> VirtualMachine? {
        machines.value?.first { $0.id == id }
    }
}

extension PendingAction {
    static func vm(_ action: VMAction, _ machine: VirtualMachine, context: ServerContext) -> PendingAction {
        PendingAction(
            title: "\(action.title) VM",
            systemImage: action.systemImage,
            targetKind: "Virtual machine",
            targetName: machine.displayName,
            serverName: context.serverName,
            consequence: action.consequence,
            isDestructive: action.isDestructive || action == .stop,
            requiresTypedConfirmation: action.isDestructive,
            isPreview: context.isPreview
        ) { [service = context.service, id = machine.id] in
            try await service.perform(action, vmID: id)
        }
    }
}

struct VMListView: View {
    let context: ServerContext
    @State private var model: VMsModel
    @State private var pending: PendingAction?
    @Environment(\.allowsActions) private var allowsActions

    init(context: ServerContext) {
        self.context = context
        _model = State(initialValue: VMsModel(service: context.service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadStateContainer(state: model.machines, loadingMessage: "Loading virtual machines…", retry: reload) { machines in
                    if machines.isEmpty {
                        ContentUnavailableView("No virtual machines", systemImage: "desktopcomputer", description: Text("No VMs are defined, or the VM Manager is disabled on this server."))
                    } else {
                        EnveCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                                    if index > 0 { Divider().padding(.leading, 60) }
                                    NavigationLink(value: machine.id) {
                                        VMRow(machine: machine)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        ForEach(allowsActions ? VMAction.available(for: machine.state) : []) { action in
                                            Button(role: action.isDestructive ? .destructive : nil) {
                                                pending = .vm(action, machine, context: context)
                                            } label: {
                                                Label(action.title, systemImage: action.systemImage)
                                            }
                                        }
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
            .refreshable { await model.load() }
            .navigationTitle("Virtual Machines")
            .navigationDestination(for: String.self) { id in
                VMDetailView(context: context, model: model, machineID: id)
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
}

struct VMRow: View {
    let machine: VirtualMachine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.headline)
                .foregroundStyle(Color.enveAccent)
                .frame(width: 34, height: 34)
                .background(Color.enveAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text(machine.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
            StatusBadge(text: machine.state.displayName, health: machine.state.health)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct VMDetailView: View {
    let context: ServerContext
    let model: VMsModel
    let machineID: String
    @State private var pending: PendingAction?
    @Environment(\.allowsActions) private var allowsActions

    var body: some View {
        ScrollView {
            if let machine = model.machine(id: machineID) {
                VStack(spacing: 14) {
                    EnveCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(machine.displayName)
                                    .font(.title2.weight(.bold))
                                Spacer()
                                StatusBadge(text: machine.state.displayName, health: machine.state.health)
                            }
                            LabeledValue(label: "ID", value: machine.id, monospaced: true)
                                .font(.caption)
                        }
                    }

                    if let error = model.machines.error {
                        InlineErrorBanner(error: error)
                    }

                    let actions = allowsActions ? VMAction.available(for: machine.state) : []
                    if !actions.isEmpty {
                        EnveCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionTitle(title: "Power", systemImage: "power")
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                                    ForEach(actions) { action in
                                        Button(role: action.isDestructive ? .destructive : nil) {
                                            pending = .vm(action, machine, context: context)
                                        } label: {
                                            Label(action.title, systemImage: action.systemImage)
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(action.isDestructive ? .red : .enveAccent)
                                        .labelStyle(VerticalActionLabelStyle())
                                    }
                                }
                            }
                        }
                    }

                    Text("The Unraid API reports each VM's name, state, and identifier. CPU, memory, and disk assignments are managed in the server's VM Manager.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("VM not found", systemImage: "desktopcomputer", description: Text("It may have been removed from the server."))
            }
        }
        .bottomBarPadding()
        .refreshable { await model.load() }
        .navigationTitle(model.machine(id: machineID)?.displayName ?? "VM")
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
        .actionConfirmation($pending) { Task { await model.load() } }
    }
}
