import Foundation
import Observation
import SwiftUI

enum HomeSection: String, Codable, Sendable, CaseIterable, Identifiable {
    case overview, pinned, servers, integrations, services, terminal, preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Health overview"
        case .pinned: "Pinned"
        case .servers: "Servers"
        case .integrations: "Integrations"
        case .services: "Services"
        case .terminal: "Terminal"
        case .preview: "Sample data"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .pinned: "pin"
        case .servers: "server.rack"
        case .integrations: "puzzlepiece.extension"
        case .services: "heart.text.square"
        case .terminal: "terminal"
        case .preview: "eye"
        }
    }
}

/// Something pinned to the top of the home screen.
enum PinnedItem: Codable, Sendable, Hashable {
    case integration(UUID)
    case serviceCheck(UUID)
}

/// Home layout and Unraid tab order. Stored with the rest of this device's data; nothing here is secret.
@MainActor
@Observable
final class HomePreferences {
    struct Snapshot: Codable, Sendable, Equatable {
        var sectionOrder: [HomeSection] = HomeSection.allCases
        var hiddenSections: Set<HomeSection> = []
        var pinned: [PinnedItem] = []
        var tabOrder: [AppTab] = AppTab.allCases
    }

    private(set) var snapshot: Snapshot
    private let file: JSONFile<Snapshot>?

    init(file: JSONFile<Snapshot>?) {
        self.file = file
        snapshot = Self.normalized((try? file?.load()) ?? Snapshot())
    }

    /// Keeps every section and tab exactly once, so data saved by an older version still shows everything.
    static func normalized(_ snapshot: Snapshot) -> Snapshot {
        var result = snapshot
        result.sectionOrder = unique(snapshot.sectionOrder) + HomeSection.allCases.filter { !snapshot.sectionOrder.contains($0) }
        result.tabOrder = unique(snapshot.tabOrder) + AppTab.allCases.filter { !snapshot.tabOrder.contains($0) }
        result.pinned = unique(snapshot.pinned)
        return result
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    var visibleSections: [HomeSection] { snapshot.sectionOrder.filter { !snapshot.hiddenSections.contains($0) } }
    var tabOrder: [AppTab] { snapshot.tabOrder }

    func isPinned(_ item: PinnedItem) -> Bool { snapshot.pinned.contains(item) }

    func togglePin(_ item: PinnedItem) {
        if let index = snapshot.pinned.firstIndex(of: item) {
            snapshot.pinned.remove(at: index)
        } else {
            snapshot.pinned.append(item)
        }
        persist()
    }

    /// Drops pins whose integration or check no longer exists.
    func pinned(existing: (PinnedItem) -> Bool) -> [PinnedItem] {
        snapshot.pinned.filter(existing)
    }

    func moveSections(from source: IndexSet, to destination: Int) {
        snapshot.sectionOrder.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setHidden(_ section: HomeSection, _ hidden: Bool) {
        if hidden { snapshot.hiddenSections.insert(section) } else { snapshot.hiddenSections.remove(section) }
        persist()
    }

    func moveTabs(from source: IndexSet, to destination: Int) {
        snapshot.tabOrder.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func movePins(from source: IndexSet, to destination: Int) {
        snapshot.pinned.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func reset() {
        snapshot = Snapshot()
        persist()
    }

    private func persist() {
        try? file?.save(snapshot)
    }
}
