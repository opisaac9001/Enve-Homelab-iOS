import SwiftUI

/// Release dates, missing items and download queues for what Radarr, Sonarr and Lidarr already track; nothing here searches for or requests content.
struct UpcomingView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case upcoming, missing, queue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .upcoming: "Upcoming"
            case .missing: "Missing"
            case .queue: "In Queue"
            }
        }
    }

    typealias Entry = (instance: IntegrationInstance, item: UpcomingItem)

    @Environment(AppModel.self) private var app
    @State private var mode: Mode = .upcoming
    @State private var includeUnmonitored = false
    @State private var items: [Entry] = []
    @State private var missingTotals: [(IntegrationInstance, Int)] = []
    @State private var queue: [(instance: IntegrationInstance, item: ArrQueueItem)] = []
    @State private var failures: [(IntegrationInstance, NetworkError)] = []
    @State private var isLoading = true

    static let daysAhead = 14
    static let missingLimit = 20

    private var sources: [IntegrationInstance] {
        (app.visibleIntegrations + app.visibleSampleInstances).filter { $0.isEnabled && [.radarr, .sonarr, .lidarr].contains($0.kind) }
    }

    private var days: [(day: Date, entries: [Entry])] {
        Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.item.date) }
            .map { ($0.key, $0.value.sorted { ($0.item.isAllDay ? 0 : 1, $0.item.date) < ($1.item.isAllDay ? 0 : 1, $1.item.date) }) }
            .sorted { mode == .missing ? $0.0 > $1.0 : $0.0 < $1.0 }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if mode == .upcoming {
                    Toggle("Include unmonitored", isOn: $includeUnmonitored)
                }
            } footer: {
                Text(footer)
            }

            if sources.isEmpty {
                ContentUnavailableView("Nothing to schedule", systemImage: "calendar",
                                       description: Text("Add Radarr, Sonarr or Lidarr to see release dates, missing items and download queues for what you already track."))
                    .listRowBackground(Color.clear)
            } else if isLoading && items.isEmpty && queue.isEmpty {
                LoadingStateView(message: "Loading…").listRowBackground(Color.clear)
            } else if failures.isEmpty && (mode == .queue ? queue.isEmpty : items.isEmpty) {
                ContentUnavailableView(emptyTitle, systemImage: "calendar.badge.checkmark", description: Text(emptyDetail))
                    .listRowBackground(Color.clear)
            }

            if !failures.isEmpty {
                Section {
                    ForEach(failures, id: \.0.id) { instance, error in
                        NavigationLink {
                            IntegrationDetailView(instanceID: instance.id)
                        } label: {
                            Label("\(instance.name): \(error.errorDescription ?? "unavailable")", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("Open one to diagnose the connection or fix its credentials.")
                }
            }

            if mode == .missing, !missingTotals.isEmpty {
                Section("Missing in total") {
                    ForEach(missingTotals, id: \.0.id) { instance, total in
                        LabeledContent(instance.name + (instance.isSample ? " (sample)" : ""), value: "\(total)")
                    }
                }
            }

            if mode == .queue {
                ForEach(queue, id: \.item.id) { instance, item in
                    queueRow(instance: instance, item: item)
                }
            } else {
                ForEach(days, id: \.day) { day, entries in
                    Section {
                        ForEach(entries, id: \.item.id) { instance, item in
                            row(instance: instance, item: item)
                        }
                    } header: {
                        Text(dayTitle(day))
                    }
                }
            }
        }
        .navigationTitle("Schedule")
        .refreshable { await load() }
        .task(id: [mode.rawValue, String(includeUnmonitored)]) { await load() }
        .bottomBarPadding()
        .enveScreen()
    }

    private var footer: String {
        switch mode {
        case .upcoming: "Release and air dates from yesterday to \(Self.daysAhead) days ahead."
        case .missing: "Monitored items that are out but have no file, newest first (up to \(Self.missingLimit) per server)."
        case .queue: "Downloads Radarr, Sonarr and Lidarr are tracking right now."
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .upcoming: "Nothing coming up"
        case .missing: "Nothing missing"
        case .queue: "Queues are empty"
        }
    }

    private var emptyDetail: String {
        switch mode {
        case .upcoming: "No \(includeUnmonitored ? "" : "monitored ")releases or episodes in the next \(Self.daysAhead) days."
        case .missing: "Every released, monitored item has a file."
        case .queue: "Nothing is downloading or waiting to import."
        }
    }

    private func row(instance: IntegrationInstance, item: UpcomingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: instance.kind.systemImage)
                .foregroundStyle(Color.enveAccent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold))
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Text([item.isAllDay ? nil : item.date.formatted(date: .omitted, time: .shortened), item.detail, item.isMonitored ? nil : "Unmonitored",
                      instance.name + (instance.isSample ? " (sample)" : "")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: statusSymbol(item)).foregroundStyle(statusColor(item)).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText(item))
    }

    private func isOverdue(_ item: UpcomingItem) -> Bool {
        !item.hasFile && (item.isAllDay ? Calendar.current.startOfDay(for: item.date) < Calendar.current.startOfDay(for: .now) : item.date < .now)
    }

    private func statusSymbol(_ item: UpcomingItem) -> String {
        if item.hasFile { return "checkmark.circle.fill" }
        if !item.isMonitored { return "bookmark.slash" }
        return isOverdue(item) ? "clock.badge.exclamationmark" : "clock"
    }

    private func statusColor(_ item: UpcomingItem) -> Color {
        if item.hasFile { return .green }
        if !item.isMonitored { return .secondary }
        return isOverdue(item) ? .orange : .secondary
    }

    private func statusText(_ item: UpcomingItem) -> String {
        if item.hasFile { return "Downloaded" }
        if !item.isMonitored { return "Unmonitored" }
        return isOverdue(item) ? "Out, not downloaded" : "Not out yet"
    }

    private func queueRow(instance: IntegrationInstance, item: ArrQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: instance.kind.systemImage).foregroundStyle(Color.enveAccent).accessibilityHidden(true)
                Text(item.mediaTitle ?? item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(item.state.displayName).font(.caption.weight(.semibold)).foregroundStyle(item.state == .failed ? .red : .secondary)
            }
            UsageBar(fraction: item.progress)
            Text([Format.percent(item.progress), item.timeLeft.map { "\(Format.duration($0)) left" }, item.downloadClient, instance.name + (instance.isSample ? " (sample)" : "")]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
            if let problem = item.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = Calendar.current.isDate(day, equalTo: .now, toGranularity: .year)
        return sameYear ? day.formatted(.dateTime.weekday(.wide).month().day()) : day.formatted(date: .abbreviated, time: .omitted)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        let end = Calendar.current.date(byAdding: .day, value: Self.daysAhead + 1, to: start) ?? .now
        var collected: [Entry] = []
        var totals: [(IntegrationInstance, Int)] = []
        var queued: [(instance: IntegrationInstance, item: ArrQueueItem)] = []
        var failed: [(IntegrationInstance, NetworkError)] = []
        for instance in sources {
            do {
                guard case .arr(let service) = try app.client(for: instance) else { continue }
                switch mode {
                case .upcoming:
                    collected += try await service.calendar(from: start, to: end, includeUnmonitored: includeUnmonitored).map { (instance, $0) }
                case .missing:
                    let missing = try await service.missing(limit: Self.missingLimit)
                    totals.append((instance, missing.total))
                    collected += missing.items.map { (instance, $0) }
                case .queue:
                    queued += try await service.snapshot().queue.map { (instance, $0) }
                }
            } catch where !NetworkError.from(error).isCancellation {
                failed.append((instance, .from(error)))
            } catch {
                return
            }
        }
        items = collected
        missingTotals = totals
        queue = queued.sorted { ($0.item.state == .failed ? 0 : 1, $0.item.timeLeft ?? .infinity) < ($1.item.state == .failed ? 0 : 1, $1.item.timeLeft ?? .infinity) }
        failures = failed
    }
}
