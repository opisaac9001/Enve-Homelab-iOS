import Foundation
import Testing
@testable import EnveHomelab

@MainActor
struct HomePreferencesTests {
    private func makeFile() -> (JSONFile<HomePreferences.Snapshot>, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "preferences-\(UUID().uuidString).json")
        return (JSONFile(url: url), url)
    }

    @Test func olderOrDamagedLayoutsStillShowEverythingOnce() {
        var stale = HomePreferences.Snapshot()
        stale.sectionOrder = [.services, .services, .overview]
        stale.tabOrder = [.docker, .docker]
        stale.pinned = [.serviceCheck(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)]
        stale.pinned += stale.pinned
        let normalized = HomePreferences.normalized(stale)
        #expect(normalized.sectionOrder.first == .services && normalized.sectionOrder[1] == .overview)
        #expect(Set(normalized.sectionOrder) == Set(HomeSection.allCases) && normalized.sectionOrder.count == HomeSection.allCases.count)
        #expect(normalized.tabOrder.first == .docker && normalized.tabOrder.count == AppTab.allCases.count)
        #expect(normalized.pinned.count == 1)
    }

    @Test func layoutChangesPersistAndReset() throws {
        let (file, url) = makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = HomePreferences(file: file)
        let check = PinnedItem.serviceCheck(UUID())
        let integration = PinnedItem.integration(UUID())
        preferences.togglePin(check)
        preferences.togglePin(integration)
        preferences.movePins(from: [1], to: 0)
        preferences.setHidden(.terminal, true)
        preferences.moveSections(from: [HomeSection.allCases.firstIndex(of: .services)!], to: 0)
        preferences.moveTabs(from: [AppTab.allCases.count - 1], to: 0)

        let reloaded = HomePreferences(file: file)
        #expect(reloaded.snapshot.pinned == [integration, check])
        #expect(reloaded.visibleSections.first == .services && !reloaded.visibleSections.contains(.terminal))
        #expect(reloaded.tabOrder.first == AppTab.allCases.last)
        #expect(reloaded.pinned { $0 == check } == [check], "Pins whose target is gone are left out")

        reloaded.togglePin(check)
        #expect(!reloaded.isPinned(check))
        reloaded.reset()
        #expect(HomePreferences(file: file).snapshot == HomePreferences.Snapshot())
    }
}
