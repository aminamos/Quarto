import Foundation
import Testing
@testable import Quarto

struct SharedAdListTests {
    private func sampleList(episodeId: String? = "ep-\(UUID().uuidString)") -> SharedAdList {
        SharedAdList(
            showTitle: "ICHH",
            episodeTitle: "Episode 42: Test Breaks \(UUID().uuidString)",
            episodeId: episodeId,
            duration: 3600,
            segments: [
                AdSegment(startTime: 60, endTime: 150, confidence: 0.9, reason: "chapter"),
                AdSegment(startTime: 1800, endTime: 1920, confidence: 0.8, reason: "speech"),
            ]
        )
    }

    @Test func roundTrip() throws {
        let list = sampleList()
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(SharedAdList.self, from: data)
        #expect(decoded.format == SharedAdList.format)
        #expect(decoded.version == SharedAdList.version)
        #expect(decoded.segments.count == 2)
        #expect(decoded.segments[0].start == 60)
        #expect(decoded.episodeId == list.episodeId)
    }

    @Test @MainActor func importMergesAndDedupes() {
        let store = AdStore()
        let list = sampleList()
        #expect(store.importSharedList(list) == 2)
        #expect(store.importSharedList(list) == 0)
        #expect(store.segments(for: list.episodeId!).count == 2)
    }

    @Test @MainActor func importRejectsUnknownFormat() throws {
        let dict: [String: Any] = [
            "format": "something-else",
            "version": 1,
            "app": "Other",
            "exportedAt": 0.0,
            "episodeTitle": "Foreign Episode",
            "segments": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let list = try JSONDecoder().decode(SharedAdList.self, from: data)
        #expect(AdStore().importSharedList(list) == 0)
    }

    @Test @MainActor func importWithoutEpisodeIdUsesTitlePlans() {
        let store = AdStore()
        let list = sampleList(episodeId: nil)
        #expect(store.importSharedList(list) == 2)
        #expect(store.segments(for: "no-such-id", title: list.episodeTitle).count == 2)
    }

    @Test @MainActor func exportWritesReadableFile() throws {
        let store = AdStore()
        let list = sampleList()
        #expect(store.importSharedList(list) == 2)
        let url = store.exportSharedList(
            episodeId: list.episodeId,
            episodeTitle: list.episodeTitle,
            showTitle: list.showTitle,
            duration: list.duration
        )
        let file = try #require(url)
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode(SharedAdList.self, from: data)
        #expect(decoded.segments.count == 2)
        try? FileManager.default.removeItem(at: file)
    }

    @Test @MainActor func exportEmptyReturnsNil() {
        let store = AdStore()
        #expect(
            store.exportSharedList(
                episodeId: "missing-\(UUID().uuidString)",
                episodeTitle: "No Such Episode",
                showTitle: nil,
                duration: nil
            ) == nil
        )
    }
}
