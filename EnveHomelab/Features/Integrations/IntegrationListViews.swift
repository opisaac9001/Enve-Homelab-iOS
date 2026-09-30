import SwiftUI

struct IntegrationRow: View {
    @Environment(AppModel.self) private var app
    let instance: IntegrationInstance

    var body: some View {
        let state = app.integrationStatus.state(for: instance.id)
        HStack(spacing: 14) {
            Image(systemName: instance.kind.systemImage)
                .font(.title3)
                .foregroundStyle(Color.enveAccent)
                .frame(width: 40, height: 40)
                .background(Color.enveAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(instance.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if instance.isSample {
                        Text("SAMPLE")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.enveAccent.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.enveAccent)
                    }
                    Text(detail(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !instance.isEnabled {
                Text("Off").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else if state.isLoading && state.value == nil {
                ProgressView()
            } else if state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            } else if let summary = state.value {
                Image(systemName: summary.health.systemImage)
                    .foregroundStyle(summary.health == .unknown ? Color.secondary : summary.health.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(instance.name), \(instance.kind.displayName)\(instance.isSample ? ", sample data" : "")")
        .accessibilityValue(accessibilityValue(state))
        .task(id: instance) { await app.integrationStatus.refresh(instance, using: app) }
    }

    private func detail(_ state: LoadState<IntegrationSummary>) -> String {
        guard instance.isEnabled else { return instance.kind.displayName }
        if let error = state.error { return error.errorDescription ?? "Unavailable" }
        if let summary = state.value {
            let status: String
            if app.integrationStatus.isStale(instance.id), let date = app.integrationStatus.updatedAt[instance.id] {
                status = "Last connected \(Format.relative(date))"
            } else {
                status = "Connected"
            }
            return ([status, summary.headline, summary.detail].compactMap { $0 }).joined(separator: " · ")
        }
        return instance.kind.displayName
    }

    private func accessibilityValue(_ state: LoadState<IntegrationSummary>) -> String {
        guard instance.isEnabled else { return "Turned off" }
        if let error = state.error { return error.errorDescription ?? "Unavailable" }
        if let summary = state.value { return "\(summary.health.accessibilityName), \(detail(state))" }
        return "Loading"
    }
}

struct IntegrationSections: View {
    @Environment(AppModel.self) private var app
    @Environment(\.allowsActions) private var allowsActions
    @Binding var editing: IntegrationInstance?
    @Binding var deleting: IntegrationInstance?

    var body: some View {
        ForEach(IntegrationCategory.allCases) { category in
            let real = app.visibleIntegrations.filter { $0.kind.category == category }
            let samples = app.visibleSampleInstances.filter { $0.kind.category == category }
            if !real.isEmpty || !samples.isEmpty {
                Section {
                    ForEach(real + samples) { instance in
                        NavigationLink {
                            IntegrationDetailView(instanceID: instance.id)
                        } label: {
                            IntegrationRow(instance: instance)
                        }
                        .swipeActions(edge: .trailing) {
                            if !instance.isSample && allowsActions {
                                Button("Remove", role: .destructive) { deleting = instance }
                                Button("Edit") { editing = instance }.tint(.enveAccent)
                            }
                        }
                        .contextMenu { PinButton(item: .integration(instance.id)) }
                    }
                    if category == .automation, (real + samples).contains(where: { $0.isEnabled }) {
                        NavigationLink {
                            ActivityView()
                        } label: {
                            Label("Activity", systemImage: "arrow.down.left.arrow.up.right.circle")
                        }
                    }
                    if category == .media, (real + samples).contains(where: { $0.isEnabled && StatisticsView.kinds.contains($0.kind) }) {
                        NavigationLink {
                            StatisticsView()
                        } label: {
                            Label("Statistics", systemImage: "chart.bar")
                        }
                    }
                    if category == .automation, (real + samples).contains(where: { $0.isEnabled && [.radarr, .sonarr, .lidarr].contains($0.kind) }) {
                        NavigationLink {
                            UpcomingView()
                        } label: {
                            Label("Schedule", systemImage: "calendar")
                        }
                    }
                } header: {
                    Label(category.title, systemImage: category.systemImage)
                }
            }
        }
    }
}
