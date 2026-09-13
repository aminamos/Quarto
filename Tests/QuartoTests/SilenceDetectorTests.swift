import Foundation
import Testing
@testable import Quarto

struct SilenceDetectorTests {
    private let options = SilenceDetector.Options(
        thresholdDB: -40,
        minSilence: 0.5,
        padding: 0.1,
        windowSeconds: 0.05,
        hopSeconds: 0.025
    )

    @Test func mergesQuietRunAndTrimsPadding() {
        var levels = [Float](repeating: -20, count: 10)
        levels += [Float](repeating: -60, count: 20)
        levels += [Float](repeating: -20, count: 10)

        let segments = SilenceDetector.segments(decibels: levels, secondsPerWindow: 0.05, options: options)
        #expect(segments.count == 1)
        #expect(abs((segments.first?.startTime ?? 0) - 0.6) < 0.0001)
        #expect(abs((segments.first?.endTime ?? 0) - 1.4) < 0.0001)
    }

    @Test func dropsRunsShorterThanMinimum() {
        var levels = [Float](repeating: -20, count: 10)
        levels += [Float](repeating: -60, count: 8)
        levels += [Float](repeating: -20, count: 10)
        #expect(SilenceDetector.segments(decibels: levels, secondsPerWindow: 0.05, options: options).isEmpty)
    }

    @Test func runAtEndClosesAtTotalDuration() {
        var levels = [Float](repeating: -20, count: 10)
        levels += [Float](repeating: -60, count: 20)
        let segments = SilenceDetector.segments(decibels: levels, secondsPerWindow: 0.05, options: options)
        #expect(segments.count == 1)
        #expect(abs((segments.first?.endTime ?? 0) - 1.4) < 0.0001)
    }

    @Test func noQuietWindowsYieldsNothing() {
        let levels = [Float](repeating: -10, count: 40)
        #expect(SilenceDetector.segments(decibels: levels, secondsPerWindow: 0.05, options: options).isEmpty)
        #expect(SilenceDetector.segments(decibels: [], secondsPerWindow: 0.05, options: options).isEmpty)
    }

    @Test func containmentLookup() {
        let segments = [
            SilenceSegment(startTime: 1, endTime: 2),
            SilenceSegment(startTime: 5, endTime: 6.5)
        ]
        #expect(SilenceDetector.segment(containing: 1.5, in: segments)?.endTime == 2)
        #expect(SilenceDetector.segment(containing: 6.0, in: segments)?.startTime == 5)
        #expect(SilenceDetector.segment(containing: 0.5, in: segments) == nil)
        #expect(SilenceDetector.segment(containing: 6.5, in: segments) == nil)
    }

    @Test func decibelWindowsMeasureLevel() {
        let loud = [Float](repeating: 0.5, count: 1000)
        let loudDB = SilenceDetector.decibels(samples: loud, windowLength: 500, hop: 250)
        #expect(loudDB.count == 3)
        #expect((loudDB.first ?? 0) < -5.5 && (loudDB.first ?? 0) > -6.5)

        let silent = [Float](repeating: 0, count: 1000)
        let silentDB = SilenceDetector.decibels(samples: silent, windowLength: 500, hop: 250)
        #expect((silentDB.first ?? 0) < -100)
    }
}

struct SilenceStoreTests {
    @Test @MainActor func roundtripAndRemove() {
        let store = SilenceStore()
        let key = "silence-test-\(UUID().uuidString)"
        #expect(store.segments(for: key).isEmpty)

        let segments = [
            SilenceSegment(startTime: 1, endTime: 2.5),
            SilenceSegment(startTime: 5, endTime: 6.5)
        ]
        store.save(segments, for: key)
        #expect(store.hasSegments(for: key) == true)
        #expect(store.segments(for: key).count == 2)

        store.save([], for: key)
        #expect(store.segments(for: key).isEmpty)
    }
}

struct PendingDownloadTests {
    private func episode(id: String, itemId: String?) -> PodcastEpisode {
        PodcastEpisode(
            id: id, libraryItemId: itemId, title: "Episode \(id)",
            subtitle: nil, description: nil, season: nil,
            publishedAt: nil, duration: 60,
            audioFile: nil, podcast: nil, chapters: nil
        )
    }

    @Test func filtersDownloadedAndItemlessEpisodes() {
        let episodes = [
            episode(id: "ep1", itemId: "item1"),
            episode(id: "ep2", itemId: "item1"),
            episode(id: "ep3", itemId: nil),
            episode(id: "ep4", itemId: "item2")
        ]
        let pending = AppModel.pendingDownloads(episodes) { candidate in
            candidate.id == "ep1" || candidate.id == "ep4"
        }
        #expect(pending.map(\.id) == ["ep2"])
    }

    @Test func keepsEverythingWhenNothingDownloaded() {
        let episodes = [episode(id: "ep1", itemId: "item1"), episode(id: "ep2", itemId: "item2")]
        let pending = AppModel.pendingDownloads(episodes) { _ in false }
        #expect(pending.count == 2)
    }
}

struct SkipSilenceSettingTests {
    @Test @MainActor func defaultsOffAndPersistsToggle() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "quarto_skip_silence")
        defer {
            if let saved {
                defaults.set(saved, forKey: "quarto_skip_silence")
            } else {
                defaults.removeObject(forKey: "quarto_skip_silence")
            }
        }

        defaults.removeObject(forKey: "quarto_skip_silence")
        let player = PlayerController()
        #expect(player.skipSilence == false)
        #expect(player.silenceSegments.isEmpty)

        player.skipSilence = true
        #expect(defaults.bool(forKey: "quarto_skip_silence") == true)

        let reloaded = PlayerController()
        #expect(reloaded.skipSilence == true)
    }
}
