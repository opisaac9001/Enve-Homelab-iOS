import SwiftUI

struct ServiceDashboardView: View {
    let instance: IntegrationInstance
    let service: any DashboardService
    @Environment(\.allowsActions) private var allowsActions
    @State private var state = LoadState<DashboardSnapshot>()
    @State private var pending: PendingAction?
    @State private var running: String?
    @State private var message: String?
    @State private var actionError: NetworkError?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        RefreshingScroll(state: state, loadingMessage: "Loading \(instance.kind.displayName)…", interval: instance.kind.refreshInterval, load: load) { snapshot in
            VStack(spacing: 14) {
                IntegrationHeader(title: instance.name, version: snapshot.version, health: snapshot.health,
                                  lines: [snapshot.headline, snapshot.detail].compactMap { $0 })
                if let notice = snapshot.notice { InlineNotice(text: notice) }
                if let message { InlineNotice(text: message) }
                if let actionError { InlineErrorBanner(error: actionError) }
                if !snapshot.metrics.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(snapshot.metrics) { MetricTile(title: $0.title, value: $0.value, systemImage: $0.systemImage, health: $0.health) }
                    }
                }
                if !snapshot.actions.isEmpty {
                    EnveCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "Actions", systemImage: "bolt")
                            ForEach(snapshot.actions) { action in
                                Button { trigger(action) } label: {
                                    HStack {
                                        Label(action.title, systemImage: action.systemImage)
                                        Spacer()
                                        if running == action.id { ProgressView() }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(action.confirmation == .destructive || action.confirmation == .typed ? .red : .enveAccent)
                            }
                        }
                    }
                    .disabled(!allowsActions || running != nil)
                }
                ForEach(snapshot.sections) { section($0) }
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
        .actionConfirmation($pending) { Task { await load() } }
    }

    private func section(_ section: DashboardSection) -> some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: section.title, systemImage: section.systemImage, trailing: section.trailing)
                if section.rows.isEmpty {
                    Text(section.emptyText).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(section.rows.prefix(section.limit)) { row in
                    rowView(row)
                    Divider()
                }
                if section.rows.count > section.limit {
                    Text("and \(section.rows.count - section.limit) more").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rowView(_ row: DashboardRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if let badge = row.badge {
                        StatusBadge(text: badge, health: row.health ?? .unknown)
                    } else if let health = row.health, health != .ok {
                        Image(systemName: health.systemImage).foregroundStyle(health.color).accessibilityHidden(true)
                    }
                }
                if let progress = row.progress {
                    UsageBar(fraction: progress, tint: row.health.map { $0 >= .warning ? $0.color : .enveAccent } ?? .enveAccent, height: 6)
                }
                if let detail = row.detail {
                    Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let message = row.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(row.progress.map { Format.percent($0) } ?? "")
            .accessibilityActions {
                if allowsActions {
                    ForEach(row.actions) { action in
                        Button(action.title) { trigger(action) }
                    }
                }
            }
            if allowsActions, !row.actions.isEmpty {
                Menu {
                    ForEach(row.actions) { action in
                        Button(role: action.confirmation == .destructive || action.confirmation == .typed ? .destructive : nil) {
                            trigger(action)
                        } label: { Label(action.title, systemImage: action.systemImage) }
                    }
                } label: {
                    Image(systemName: running.map { id in row.actions.contains { $0.id == id } } == true ? "hourglass" : "ellipsis.circle")
                        .font(.title3)
                }
                .disabled(running != nil)
                .accessibilityLabel("Actions for \(row.title)")
            }
        }
        .padding(.vertical, 2)
    }

    private func trigger(_ action: DashboardAction) {
        guard allowsActions, running == nil else { return }
        guard action.confirmation != .none else {
            Task { await runDirectly(action) }
            return
        }
        // The ellipsis marks menu items that ask first; the confirmation itself shouldn't repeat it.
        pending = .integration(instance, title: action.title.trimmingCharacters(in: CharacterSet(charactersIn: "…")), systemImage: action.systemImage, targetKind: action.targetKind,
                               targetName: action.targetName, consequence: action.consequence,
                               destructive: action.confirmation == .destructive || action.confirmation == .typed,
                               typed: action.confirmation == .typed, perform: action.perform)
    }

    private func runDirectly(_ action: DashboardAction) async {
        running = action.id
        message = nil
        actionError = nil
        do {
            try await action.perform()
            message = "\(action.title) · \(action.targetName): \(instance.name) accepted the request."
        } catch {
            let failure = NetworkError.from(error)
            if !failure.isCancellation { actionError = failure }
        }
        running = nil
        await load()
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.dashboard() })
    }
}
