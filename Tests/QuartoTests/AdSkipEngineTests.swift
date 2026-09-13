import Foundation
import Testing
import XCTest
@testable import Quarto

struct AdSkipEngineTests {

    @Test func chapterDetection() {
        let engine = AdSkipEngine()
        #expect(engine.isAdChapter(title: "Sponsor - Squarespace") == true)
        #expect(engine.isAdChapter(title: "Midroll Ad Break") == true)
        #expect(engine.isAdChapter(title: "Interview with Guest") == false)

        let chapters = [
            ChapterItem(title: "Intro", startTime: 0, endTime: 60),
            ChapterItem(title: "Sponsor Break", startTime: 60, endTime: 120),
            ChapterItem(title: "Main Segment", startTime: 120, endTime: 300)
        ]

        let ads = engine.detectChapterAds(chapters)
        #expect(ads.count == 1)
        #expect(ads.first?.startTime == 60)
        #expect(ads.first?.endTime == 120)
    }

    @Test func vttDetection() {
        let engine = AdSkipEngine()
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:05.000
        Welcome to the show.

        00:00:05.500 --> 00:00:15.000
        This episode is brought to you by Quarto. Use code AMOS for discount.

        00:00:15.500 --> 00:00:20.000
        Now welcome back to the show.
        """

        let ads = engine.parseAndDetectVTT(vtt)
        #expect(!ads.isEmpty)
        #expect(ads.first?.startTime == 5.5)
        #expect(ads.first?.endTime == 20.0)
    }

    @Test func liveWordStreaming() {
        let engine = AdSkipEngine()
        _ = engine.feedWord("hello", startTime: 0.0, endTime: 0.5)
        _ = engine.feedWord("sponsored", startTime: 1.0, endTime: 1.5)
        let ad = engine.feedWord("by", startTime: 1.6, endTime: 2.0)
        #expect(ad != nil)
        #expect(ad?.startTime ?? 0 <= 2.0)
    }

    @Test func smartQuoteStreaming() {
        let engine = AdSkipEngine()
        _ = engine.feedWord("here’s", startTime: 0.0, endTime: 0.5)
        _ = engine.feedWord("some", startTime: 0.5, endTime: 1.0)
        let ad = engine.feedWord("ads", startTime: 1.0, endTime: 1.5)
        #expect(ad != nil)
    }

    @Test func sessionChapterDecoding() throws {
        let json = """
        {
            "id": "sess_123",
            "libraryItemId": "item_1",
            "episodeId": "ep_1",
            "displayTitle": "Test Episode",
            "displayAuthor": "Host",
            "duration": 1800,
            "currentTime": 450,
            "audioTracks": [
                {
                    "contentUrl": "/api/items/1/file/1",
                    "duration": 1800,
                    "mimeType": "audio/mpeg",
                    "title": "Track 1"
                }
            ],
            "chapters": [
                { "id": 1, "start": 0, "end": 120, "title": "Intro" },
                { "id": 2, "start": 120, "end": 240, "title": "Sponsor - Quarto" },
                { "id": 3, "start": 240, "end": 1800, "title": "Interview" }
            ]
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(PlaybackSession.self, from: json)
        #expect(session.chapters?.count == 3)
        #expect(session.currentTime == 450)

        let engine = AdSkipEngine()
        let chapterItems = session.chapters?.map { ChapterItem(title: $0.title, startTime: $0.start, endTime: $0.end) } ?? []
        let ads = engine.detectChapterAds(chapterItems)
        #expect(ads.count == 1)
        #expect(ads.first?.startTime == 120)
        #expect(ads.first?.endTime == 240)
    }

    @Test func progressCompositeKey() {
        let p1 = MediaProgress(
            id: "prog-1",
            libraryItemId: "item-abc",
            episodeId: "ep-xyz",
            duration: 1000,
            progress: 0.5,
            currentTime: 500,
            isFinished: false,
            lastUpdate: 123456
        )
        #expect(p1.compositeKey == "item-abc-ep-xyz")

        let p2 = MediaProgress(
            id: "prog-2",
            libraryItemId: "book-123",
            episodeId: nil,
            duration: 2000,
            progress: 0.25,
            currentTime: 500,
            isFinished: false,
            lastUpdate: 123456
        )
        #expect(p2.compositeKey == "book-123")
    }

    @Test func realWorldPodcastAdChunk() {
        let engine = AdSkipEngine()
        let text = "Bite into a stacked sandwich made with hero bread and the only thing you'll think is delicious you won't think it has up to 19 g of protein 11 to 32 g of fiber or just 0 to 5 g in net carbs but it does hero bread no compromises just loaves buns tortillas bagels and noodles packed with flavor right now get 10% off at hero.co with code iHeart that's hero .io code iHeart all figures per serving a hero Red Sea nutrition facts on hero.com this is Tony I opened a real report with Tony and uncle you haven't noticed how everything keeps going up streaming even extra soul such a favorite burrito spot but with boost mobile you don't have to play the Willis go up zoom game boost mobile office and unlimited talk text and data plan at a price that'll never go up"

        let words = text.split(separator: " ")
        var detected: [AdSegment] = []
        var t: Double = 0.5
        for w in words {
            let end = t + 0.3
            if let ad = engine.feedWord(String(w), startTime: t, endTime: end) {
                detected.append(ad)
            }
            t = end
        }
        print("Detected count for real podcast chunk:", detected.count)
        for ad in detected {
            print("  Ad:", ad.reason, ad.startTime, ad.endTime)
        }
        #expect(!detected.isEmpty)
    }

    @Test @MainActor func adStorePersistence() {
        let store = AdStore()
        let sample = [
            AdSegment(startTime: 10, endTime: 70, confidence: 0.85, reason: "Live ad trigger: 10% off"),
            AdSegment(startTime: 600, endTime: 720, confidence: 0.95, reason: "Chapter: Sponsor")
        ]
        store.save(segments: sample, for: "test-ep-1")
        #expect(store.hasAds(for: "test-ep-1") == true)
        #expect(store.segments(for: "test-ep-1").count == 2)
        #expect(store.segments(for: "test-ep-1").first?.startTime == 10)
        #expect(store.hasAds(for: "unknown-ep") == false)
    }

    @Test @MainActor func knownAdEpisodeMustDetectSeveralBreaksOn4070Super() async {
        // Requires a live detector worker; set QUARTO_LIVE_WORKER_URL to run.
        guard let liveURL = ProcessInfo.processInfo.environment["QUARTO_LIVE_WORKER_URL"],
              !liveURL.isEmpty else { return }
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = liveURL
        let knownEpisode = PodcastEpisode(
            id: "5e87ef30-d73f-491b-9145-5723407e1166",
            libraryItemId: "12687c49-61e3-4ef1-8a12-12a410444d1e",
            title: "Counterrevolution in Egypt",
            subtitle: nil,
            description: nil,
            season: nil,
            publishedAt: nil,
            duration: 3570.83,
            audioFile: nil,
            podcast: nil,
            chapters: nil
        )

        // When requesting ad detection from the 4070 Super on an episode known to contain multiple breaks
        let cuts = await store.detectOnServer(for: knownEpisode, force: false)

        // If the server is reachable and returned cuts, assert several breaks are detected.
        // If 0 cuts are detected on an episode known to contain several breaks, that's a failure!
        if !cuts.isEmpty {
            #expect(cuts.count >= 2, "Expected several ad breaks on known episode 'Counterrevolution in Egypt', but found only \(cuts.count)")
            #expect(cuts.count == 5, "Expected 5 ad breaks on 'Counterrevolution in Egypt'")
            let firstBreak = cuts.first
            #expect(firstBreak?.startTime == 0.0, "Preroll ad break should start at 0:00")
            #expect((firstBreak?.endTime ?? 0) >= 120.0, "Preroll ad break should span multiple minutes")
        } else {
            // Check fallback from titlePlans or local cache
            let resolved = store.segments(for: knownEpisode.id, title: knownEpisode.title)
            #expect(resolved.count >= 2, "Failed: 0 ad breaks found for known ad-heavy episode 'Counterrevolution in Egypt'")
        }
    }

    @Test @MainActor func detectBothOnKnownEpisodeFailsIfZeroAds() async {
        // Requires a live detector worker; set QUARTO_LIVE_WORKER_URL to run.
        guard let liveURL = ProcessInfo.processInfo.environment["QUARTO_LIVE_WORKER_URL"],
              !liveURL.isEmpty else { return }
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = liveURL
        let knownEpisode = PodcastEpisode(
            id: "5e87ef30-d73f-491b-9145-5723407e1166",
            libraryItemId: "12687c49-61e3-4ef1-8a12-12a410444d1e",
            title: "Counterrevolution in Egypt",
            subtitle: nil,
            description: nil,
            season: nil,
            publishedAt: nil,
            duration: 3570.83,
            audioFile: nil,
            podcast: nil,
            chapters: nil
        )

        let downloads = DownloadStore()
        let adEngine = AdSkipEngine()
        let recognizer = LiveSpeechRecognizer()

        await store.detectBoth(
            for: knownEpisode,
            client: nil,
            downloads: downloads,
            adEngine: adEngine,
            recognizer: recognizer
        )

        let activeCuts = store.segments(for: knownEpisode.id, title: knownEpisode.title)
        #expect(activeCuts.count >= 2, "Failed: 'Compare Both' detected 0 or fewer than 2 ad breaks on known episode")
    }

    @Test func coolZoneMediaHostPhrasesAndExtendedAdBreak() {
        let engine = AdSkipEngine()

        // Test Robert Evans / Cool Zone Media trigger phrase: "here's some ads"
        _ = engine.feedWord("now", startTime: 10.0, endTime: 10.4)
        _ = engine.feedWord("here's", startTime: 10.5, endTime: 10.9)
        _ = engine.feedWord("some", startTime: 11.0, endTime: 11.4)
        let triggerAd = engine.feedWord("ads", startTime: 11.5, endTime: 11.9)
        #expect(triggerAd != nil, "Engine must trigger on 'here's some ads'")
        #expect((triggerAd?.startTime ?? 0) <= 11.5)

        // Feed ad content spanning 3.5 minutes (210 seconds) - well beyond old 120s limit
        _ = engine.feedWord("betterhelp", startTime: 30.0, endTime: 30.5)
        _ = engine.feedWord("promo", startTime: 80.0, endTime: 80.5)
        _ = engine.feedWord("code", startTime: 81.0, endTime: 81.5)
        _ = engine.feedWord("hellofresh", startTime: 150.0, endTime: 150.5)

        // Feed exit phrase: "and we're back" at t = 220s
        _ = engine.feedWord("and", startTime: 220.0, endTime: 220.4)
        _ = engine.feedWord("we're", startTime: 220.5, endTime: 220.9)
        let exitAd = engine.feedWord("back", startTime: 221.0, endTime: 221.5)

        #expect(exitAd != nil, "Engine must detect exit phrase 'and we're back'")
        #expect(exitAd?.endTime == 221.5)
        let duration = (exitAd?.endTime ?? 0) - (exitAd?.startTime ?? 0)
        #expect(duration > 180.0, "Ad break must encompass full 3+ minute duration without premature 120s cutoff")
    }
}

/// Live integration checks for the physical iPhone path.
///
/// These intentionally call the configured NetBird desktop worker. A zero-result
/// response is a test failure because this fixture is known to contain several
/// ad breaks. Run on AA17 with the Quarto server detector enabled.
@MainActor
final class KnownAdEpisodePhoneTests: XCTestCase {
    private let knownEpisode = PodcastEpisode(
        id: "5e87ef30-d73f-491b-9145-5723407e1166",
        libraryItemId: "12687c49-61e3-4ef1-8a12-12a410444d1e",
        title: "Counterrevolution in Egypt",
        subtitle: nil,
        description: nil,
        season: nil,
        publishedAt: nil,
        duration: 3570.83,
        audioFile: nil,
        podcast: nil,
        chapters: nil
    )

    func test4070SuperButtonPathFindsSeveralBreaks() async throws {
        // Requires a live detector worker; set QUARTO_LIVE_WORKER_URL to run.
        guard let liveURL = ProcessInfo.processInfo.environment["QUARTO_LIVE_WORKER_URL"],
              !liveURL.isEmpty else { throw XCTSkip("QUARTO_LIVE_WORKER_URL not set") }
        let store = AdStore()
        store.serverDetectionURL = liveURL
        let cuts = await store.detectOnServer(for: knownEpisode, force: true)

        XCTAssertGreaterThanOrEqual(
            cuts.count,
            2,
            "4070 Super returned \(cuts.count) breaks for known ad-heavy episode; expected several"
        )
    }

    func testCompareBothButtonPathKeepsSeveralServerBreaks() async throws {
        // Requires a live detector worker; set QUARTO_LIVE_WORKER_URL to run.
        guard let liveURL = ProcessInfo.processInfo.environment["QUARTO_LIVE_WORKER_URL"],
              !liveURL.isEmpty else { throw XCTSkip("QUARTO_LIVE_WORKER_URL not set") }
        let store = AdStore()
        store.serverDetectionURL = liveURL
        let downloads = DownloadStore()
        let engine = AdSkipEngine()
        let recognizer = LiveSpeechRecognizer()

        await store.detectBoth(
            for: knownEpisode,
            client: nil,
            downloads: downloads,
            adEngine: engine,
            recognizer: recognizer,
            runLocal: false
        )

        let serverCuts = store.serverSegments(for: knownEpisode.id, title: knownEpisode.title)
        XCTAssertGreaterThanOrEqual(
            serverCuts.count,
            2,
            "Compare Both returned \(serverCuts.count) desktop breaks for known ad-heavy episode; expected several"
        )
    }
}
