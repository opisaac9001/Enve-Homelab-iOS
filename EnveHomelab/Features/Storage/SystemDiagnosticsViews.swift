import Charts
import SwiftUI

/// Sensor readings and the server's own recent history (`metrics.temperature`, Unraid API 4.32+).
struct TemperaturesView: View {
    let service: any UnraidService
    @State private var state = LoadState<TemperatureReport>()

    var body: some View {
        ScrollView {
            LoadStateContainer(state: state, loadingMessage: "Reading sensors…", retry: { Task { await load() } }) { report in
                VStack(spacing: 14) {
                    if report.sensors.isEmpty {
                        ContentUnavailableView("No sensors reported", systemImage: "thermometer.medium.slash",
                                               description: Text("Unraid found no temperature sensors. Sensor sources (lm-sensors, IPMI, drives) are configured on the server."))
                    } else {
                        EnveCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    SectionTitle(title: "Summary", systemImage: "thermometer.medium")
                                    StatusBadge(text: report.health.accessibilityName, health: report.health)
                                }
                                if let average = report.average { LabeledValue(label: "Average", value: Self.format(average)) }
                                LabeledValue(label: "At warning", value: "\(report.warningCount)")
                                LabeledValue(label: "At critical", value: "\(report.criticalCount)")
                            }
                        }
                        ForEach(report.sensors) { sensor in
                            SensorCard(sensor: sensor)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Temperatures")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .bottomBarPadding()
        .enveScreen()
    }

    static func format(_ celsius: Double) -> String {
        Format.temperature(Int(celsius.rounded()))
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.temperatures() })
    }
}

private struct SensorCard: View {
    let sensor: TemperatureReport.Sensor

    var body: some View {
        EnveCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sensor.name).font(.headline)
                        Text([kindTitle, sensor.location].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(TemperaturesView.format(sensor.current.celsius))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(sensor.status.health == .ok || sensor.status == .unknown ? Color.primary : sensor.status.health.color)
                }
                if sensor.history.count >= 2 {
                    Chart(Array(sensor.history.enumerated()), id: \.offset) { index, reading in
                        LineMark(x: .value("Reading", reading.date ?? Date(timeIntervalSince1970: Double(index))), y: .value("°C", reading.celsius))
                            .foregroundStyle(Color.enveAccent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        if let warning = sensor.warning {
                            RuleMark(y: .value("Warning", warning))
                                .foregroundStyle(.orange.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis(.hidden)
                    .frame(height: 90)
                    .accessibilityLabel("Recent readings for \(sensor.name)")
                    .accessibilityValue("\(sensor.history.count) readings")
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var kindTitle: String {
        switch sensor.kind {
        case "CPU_PACKAGE": "CPU package"
        case "CPU_CORE": "CPU core"
        case "MOTHERBOARD": "Motherboard"
        case "CHIPSET": "Chipset"
        case "GPU": "GPU"
        case "DISK": "Drive"
        case "NVME": "NVMe drive"
        case "AMBIENT": "Ambient"
        case "VRM": "Voltage regulator"
        default: "Sensor"
        }
    }

    private var details: String {
        var parts: [String] = []
        if let minimum = sensor.minimum, let maximum = sensor.maximum { parts.append("Range \(TemperaturesView.format(minimum))–\(TemperaturesView.format(maximum))") }
        if let warning = sensor.warning { parts.append("warning \(TemperaturesView.format(warning))") }
        if let critical = sensor.critical { parts.append("critical \(TemperaturesView.format(critical))") }
        if sensor.status == .warning || sensor.status == .critical { parts.append(sensor.status == .critical ? "Critical" : "Above warning") }
        return parts.joined(separator: " · ")
    }
}

/// Read-only view of the server's log files (`logFiles` / `logFile`); nothing is stored or sent anywhere.
struct SystemLogsView: View {
    let service: any UnraidService
    @State private var state = LoadState<[LogFileInfo]>()

    var body: some View {
        List {
            if let files = state.value {
                if files.isEmpty {
                    ContentUnavailableView("No log files", systemImage: "doc.text", description: Text("The server listed no log files."))
                }
                ForEach(files) { file in
                    NavigationLink {
                        LogFileView(service: service, file: file)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.body.weight(.semibold))
                            Text([file.path, Format.bytes(file.size), APIDate.parse(file.modifiedAt).map(Format.relative)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let error = state.error {
                ErrorStateView(error: error) { Task { await load() } }
            } else {
                LoadingStateView(message: "Listing log files…")
            }
        }
        .navigationTitle("System Logs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .bottomBarPadding()
        .enveScreen()
        .ownerOnlyLogs()
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.logFiles() })
    }
}

private struct LogFileView: View {
    let service: any UnraidService
    let file: LogFileInfo
    @State private var state = LoadState<LogFileText>()
    @State private var lines = 200
    @State private var query = ""

    private var visible: [String] {
        let all = state.value?.lines ?? []
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker("Lines", selection: $lines) {
                    ForEach([100, 200, 500, 1000], id: \.self) { Text("Last \($0)").tag($0) }
                }
                if let text = state.value {
                    Text("Showing \(text.lines.count) of \(text.totalLines) lines").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.error, state.value == nil {
                ErrorStateView(error: error) { Task { await load() } }
            } else if state.value == nil {
                LoadingStateView(message: "Reading \(file.name)…")
            } else if visible.isEmpty {
                Text(query.isEmpty ? "The file is empty." : "No lines match.").foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(Self.isProblem(line) ? Color.orange : Color.primary)
                }
            }
        }
        .searchable(text: $query, prompt: "Filter lines")
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: lines) { await load() }
        .enveScreen()
    }

    static func isProblem(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["error", "fail", "warning", "critical", "i/o error"].contains { lower.contains($0) }
    }

    private func load() async {
        state.begin()
        let lines = lines
        state.finish(await captureResult { try await service.logFile(path: file.path, lines: lines) })
    }
}
