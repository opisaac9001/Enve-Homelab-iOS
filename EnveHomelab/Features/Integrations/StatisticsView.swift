import Charts
import SwiftUI

/// Library size, watch activity and request totals from the media services already set up; computed on demand, nothing is uploaded.
struct StatisticsView: View {
    @Environment(AppModel.self) private var app
    @State private var watch: [(IntegrationInstance, any WatchStatisticsSource)] = []
    @State private var libraries: [(IntegrationInstance, MediaItemCounts)] = []
    @State private var requests: [(IntegrationInstance, SeerrRequestCounts)] = []
    @State private var failures: [(IntegrationInstance, NetworkError)] = []
    @State private var isLoading = true

    static let kinds: Set<IntegrationKind> = [.tautulli, .jellyfin, .emby, .seerr]

    private var sources: [IntegrationInstance] {
        (app.visibleIntegrations + app.visibleSampleInstances).filter { $0.isEnabled && Self.kinds.contains($0.kind) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if sources.isEmpty {
                    ContentUnavailableView("No statistics yet", systemImage: "chart.bar",
                                           description: Text("Add Tautulli for watch history, Jellyfin or Emby for library totals, or Seerr for request totals."))
                } else if isLoading && watch.isEmpty && libraries.isEmpty && requests.isEmpty {
                    LoadingStateView(message: "Gathering statistics…")
                }
                ForEach(failures, id: \.0.id) { instance, error in
                    NavigationLink {
                        IntegrationDetailView(instanceID: instance.id)
                    } label: {
                        InlineNotice(text: "\(instance.name): \(error.errorDescription ?? "unavailable") Tap to diagnose or fix it.")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(watch, id: \.0.id) { instance, source in
                    WatchStatisticsCard(instance: instance, source: source)
                }
                ForEach(libraries, id: \.0.id) { instance, counts in
                    EnveCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "\(instance.name) library", systemImage: instance.kind.systemImage)
                            if counts.entries.isEmpty {
                                Text("The server reports no items.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            ForEach(counts.entries, id: \.label) { entry in
                                LabeledValue(label: entry.label, value: entry.count.formatted())
                            }
                        }
                    }
                }
                ForEach(requests, id: \.0.id) { instance, counts in
                    EnveCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "\(instance.name) requests", systemImage: instance.kind.systemImage, trailing: "\(counts.total) total")
                            LabeledValue(label: "Movies", value: "\(counts.movie ?? 0)")
                            LabeledValue(label: "Series", value: "\(counts.tv ?? 0)")
                            LabeledValue(label: "Pending approval", value: "\(counts.pending)")
                            LabeledValue(label: "Approved", value: "\(counts.approved ?? 0)")
                            LabeledValue(label: "Available", value: "\(counts.available ?? 0)")
                            LabeledValue(label: "Declined", value: "\(counts.declined ?? 0)")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Statistics")
        .refreshable { await load() }
        .task { await load() }
        .bottomBarPadding()
        .enveScreen()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        var watch: [(IntegrationInstance, any WatchStatisticsSource)] = []
        var libraries: [(IntegrationInstance, MediaItemCounts)] = []
        var requests: [(IntegrationInstance, SeerrRequestCounts)] = []
        var failures: [(IntegrationInstance, NetworkError)] = []
        for instance in sources {
            do {
                switch try app.client(for: instance) {
                case .dashboard(let service):
                    if let source = service as? any WatchStatisticsSource { watch.append((instance, source)) }
                case .media(let service):
                    if let counts = try await service.itemCounts() { libraries.append((instance, counts)) }
                case .requests(let service):
                    requests.append((instance, try await service.overview().requests))
                default:
                    break
                }
            } catch where !NetworkError.from(error).isCancellation {
                failures.append((instance, .from(error)))
            } catch {
                return
            }
        }
        self.watch = watch
        self.libraries = libraries
        self.requests = requests
        self.failures = failures
    }
}

/// Tautulli watch history for a chosen period and, optionally, one person; each card loads on its own so a slow server doesn't hold up the rest.
private struct WatchStatisticsCard: View {
    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, year = 365
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: "7 days"
            case .month: "30 days"
            case .quarter: "90 days"
            case .year: "1 year"
            }
        }
    }

    let instance: IntegrationInstance
    let source: any WatchStatisticsSource
    @State private var range: Range = .month
    @State private var userID: String?
    @State private var users: [WatchUser] = []
    @State private var stats: WatchStatistics?
    @State private var summary: WatchUserSummary?
    @State private var error: NetworkError?

    private var userName: String? { users.first { $0.id == userID }?.name }

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Plays per day", systemImage: "chart.bar", trailing: instance.name + (instance.isSample ? " (sample)" : ""))
                Picker("Period", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if !users.isEmpty {
                    Picker("Person", selection: $userID) {
                        Text("Everyone").tag(String?.none)
                        ForEach(users) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                if let error {
                    NavigationLink {
                        IntegrationDetailView(instanceID: instance.id)
                    } label: {
                        InlineNotice(text: "\(error.errorDescription ?? "Unavailable") Tap to diagnose or fix it.")
                    }
                    .buttonStyle(.plain)
                } else if let stats {
                    PlaysChart(days: stats.days, range: range.rawValue)
                    Text("\(stats.totalPlays) plays" + (userName.map { " by \($0)" } ?? "")
                         + (stats.busiestDay.map { " · busiest \($0.date.formatted(.dateTime.weekday(.abbreviated).month().day())) (\($0.plays))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if !stats.playsByType.isEmpty {
                        Divider()
                        ForEach(stats.playsByType, id: \.type) { entry in
                            LabeledValue(label: entry.type, value: "\(entry.plays) plays")
                        }
                    }
                    if let summary {
                        Divider()
                        Text("\(userName ?? "Their") watch time").font(.subheadline.weight(.semibold))
                        ForEach(summary.periods) { period in
                            LabeledValue(label: period.title, value: "\(period.plays) plays · \(Format.duration(period.seconds))")
                        }
                        RankedList(title: "Players", rows: summary.players)
                    }
                    RankedList(title: "Most watched shows", rows: stats.topShows)
                    RankedList(title: "Most watched movies", rows: stats.topMovies)
                    if userID == nil { RankedList(title: "Top users", rows: stats.topUsers) }
                    RankedList(title: "Top platforms", rows: stats.topPlatforms)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 170)
                }
            }
        }
        .task { users = (try? await source.watchUsers()) ?? [] }
        .task(id: [String(range.rawValue), userID ?? ""]) { await load() }
    }

    private func load() async {
        do {
            let loaded = try await source.statistics(days: range.rawValue, userID: userID)
            summary = if let userID { try await source.userSummary(userID: userID) } else { nil }
            stats = loaded
            error = nil
        } catch where !NetworkError.from(error).isCancellation {
            self.error = .from(error)
        } catch {}
    }
}

private struct RankedList: View {
    let title: String
    let rows: [WatchStatistics.Ranked]

    var body: some View {
        if !rows.isEmpty {
            Divider()
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                    Text(row.name).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text(["\(row.plays) plays", row.duration.map(Format.duration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One series, so it takes the accent colour and needs no legend; selecting a bar shows that day's count.
private struct PlaysChart: View {
    let days: [WatchStatistics.Day]
    var range = 30
    @State private var selected: Date?

    private var selectedDay: WatchStatistics.Day? {
        selected.flatMap { date in days.first { Calendar.current.isDate($0.date, inSameDayAs: date) } }
    }

    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Plays", day.plays))
                .foregroundStyle(Color.enveAccent.opacity(selectedDay == nil || selectedDay?.id == day.id ? 1 : 0.4))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            if let selectedDay, selectedDay.id == day.id {
                RuleMark(x: .value("Day", day.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month().day())).font(.caption2).foregroundStyle(.secondary)
                            Text("\(day.plays) plays").font(.caption.weight(.semibold))
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXAxis {
            if range > 90 {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) }
            } else {
                AxisMarks(values: .stride(by: .day, count: range <= 7 ? 1 : (range <= 30 ? 7 : 21))) { _ in
                    AxisValueLabel(format: range <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
        .frame(height: 170)
        .accessibilityLabel("Plays per day")
        .accessibilityValue("\(days.reduce(0) { $0 + $1.plays }) plays over \(days.count) days, busiest day \(days.map(\.plays).max() ?? 0)")
    }
}
