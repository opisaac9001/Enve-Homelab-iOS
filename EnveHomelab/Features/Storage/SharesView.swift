import SwiftUI

struct SharesView: View {
    let service: any UnraidService
    @State private var state = LoadState<[UnraidShare]>()

    var body: some View {
        ScrollView {
            LoadStateContainer(state: state, loadingMessage: "Loading shares…", retry: { Task { await load() } }) { shares in
                if shares.isEmpty {
                    ContentUnavailableView("No shares", systemImage: "folder", description: Text("This server has no user shares, or the array is stopped."))
                } else {
                    EnveCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                                if index > 0 { Divider().padding(.leading, 16) }
                                ShareRow(share: share)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .bottomBarPadding()
        .refreshable { await load() }
        .navigationTitle("Shares")
        .navigationBarTitleDisplayMode(.inline)
        .enveScreen()
        .task { await load() }
    }

    private func load() async {
        state.begin()
        state.finish(await captureResult { try await service.shares() })
    }
}

private struct ShareRow: View {
    let share: UnraidShare

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(share.name)
                        .font(.body.weight(.semibold))
                    if let comment = share.comment {
                        Text(comment)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let used = share.usedKB {
                    Text(Format.kilobytes(used))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            if let fraction = share.usedFraction {
                UsageBar(fraction: fraction, tint: UsageBar.tint(for: fraction), height: 6)
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(share.name)
        .accessibilityValue([share.comment, share.usedKB.map { "\(Format.kilobytes($0)) used" }, details].compactMap { $0 }.joined(separator: ", "))
    }

    private var details: String {
        var parts: [String] = []
        if let free = share.freeKB { parts.append("\(Format.kilobytes(free)) free") }
        if let cache = share.usesCache { parts.append(cache ? "Uses pool" : "Array only") }
        if !share.includedDisks.isEmpty { parts.append("Disks: \(share.includedDisks.joined(separator: ", "))") }
        if let luks = share.luksStatus { parts.append("Encryption: \(luks)") }
        return parts.joined(separator: " · ")
    }
}
