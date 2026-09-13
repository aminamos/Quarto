import Foundation
import Testing
@testable import Quarto

private func unsignedToken(payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let b64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "aaa.\(b64).sig"
}

struct ABSErrorTests {
    @Test func descriptions() {
        #expect(ABSError.badURL.errorDescription == "Invalid server URL")
        #expect(ABSError.badResponse.errorDescription == "Invalid response")
        #expect(
            ABSError.http(401, "session expired, please login").errorDescription
                == "Session expired"
        )
        #expect(
            ABSError.http(401, "bad credentials").errorDescription
                == "Not authorized"
        )
        #expect(
            (ABSError.http(500, "boom").errorDescription ?? "")
                .contains("Server error 500")
        )
        #expect(
            (ABSError.http(500, "").errorDescription ?? "") == "Server error 500"
        )
    }
}

struct JWTCoverageTests {
    @Test func malformedTokensHaveNoExpiry() {
        #expect(JWT.expiration(of: "abc") == nil)
        #expect(JWT.expiration(of: "a.!!!.sig") == nil)
        #expect(JWT.expiration(of: unsignedToken(payload: ["sub": "x"])) == nil)
    }

    @Test func tokensWithoutExpiryNeverNeedRefresh() {
        #expect(JWT.needsRefresh(unsignedToken(payload: ["sub": "x"])) == false)
        #expect(JWT.needsRefresh("not-a-token") == false)
    }

    @Test func expiredTokenNeedsRefreshFutureDoesNot() {
        #expect(JWT.needsRefresh(unsignedToken(payload: ["exp": 1000])) == true)
        let future = Date().timeIntervalSince1970 + 3600
        #expect(
            JWT.needsRefresh(unsignedToken(payload: ["exp": future])) == false
        )
    }
}

struct DownloadedFileKeyTests {
    @Test func episodeScopedKeys() {
        let withEpisode = DownloadedFile(
            libraryItemId: "item1", episodeId: "ep1", title: "t",
            author: "a", relativePath: "f", duration: nil
        )
        let otherEpisode = DownloadedFile(
            libraryItemId: "item1", episodeId: "ep2", title: "t",
            author: "a", relativePath: "f", duration: nil
        )
        let book = DownloadedFile(
            libraryItemId: "item1", episodeId: nil, title: "t",
            author: "a", relativePath: "f", duration: nil
        )
        #expect(withEpisode.key == "item1:ep1")
        #expect(book.key == "item1")
        #expect(withEpisode.key != otherEpisode.key)
        #expect(withEpisode.key != book.key)
    }
}

struct DownloadStoreTests {
    @Test @MainActor func missBeforeSave() {
        let store = DownloadStore()
        #expect(store.file(itemId: "missing-item", episodeId: "missing-ep") == nil)
        #expect(store.isDownloaded(itemId: "missing-item", episodeId: "missing-ep") == false)
    }

    @Test @MainActor func saveAndRemoveRoundtrip() throws {
        let store = DownloadStore()
        let itemId = "test-item-\(UUID().uuidString)"
        let episodeId = "test-ep-\(UUID().uuidString)"
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gaptest_\(UUID().uuidString).mp3")
        try "audio".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let saved = try store.save(
            itemId: itemId, episodeId: episodeId, title: "t",
            author: "a", duration: 10, tempURL: temp, ext: "mp3"
        )
        #expect(store.isDownloaded(itemId: itemId, episodeId: episodeId) == true)
        #expect(saved.key == "\(itemId):\(episodeId)")
        #expect(store.localURL(for: saved).lastPathComponent.hasSuffix(".mp3") == true)

        store.remove(itemId: itemId, episodeId: episodeId)
        #expect(store.isDownloaded(itemId: itemId, episodeId: episodeId) == false)
    }
}

struct PlayerControllerIdleTests {
    @Test @MainActor func idleStateIsSafe() {
        let player = PlayerController()
        #expect(player.isPlaying == false)
        #expect(player.progress == 0)
        player.skipAd()
        player.skip(seconds: 30)
        #expect(player.isPlaying == false)
        #expect(player.progress == 0)
    }
}

struct KeychainRoundtripTests {
    @Test func setGetDelete() {
        let account = "gaptest-\(UUID().uuidString)"
        defer { Keychain.delete(account) }
        #expect(Keychain.data(account: account) == nil)
        Keychain.set(Data("secret".utf8), account: account)
        #expect(Keychain.data(account: account) == Data("secret".utf8))
        Keychain.delete(account)
        #expect(Keychain.data(account: account) == nil)
    }
}

struct LogSinkTests {
    @Test func redactedMetaKeys() {
        let meta: [String: Sendable] = [
            "token": "secret123",
            "password": "my-password",
            "secret": "shh",
            "authorization": "Bearer xyz",
            "cookie": "session=abc",
            "apikey": "key123",
            "api_key": "key456",
            "refreshtoken": "ref123",
            "refresh_token": "ref456",
            "accessjwt": "jwt123",
            "access_jwt": "jwt456",
            "bearer": "tok123",
            "episode_id": "ep-99",
            "breaks_count": 3
        ]
        let redacted = LogSink.redactedMeta(meta)
        #expect(redacted["token"] == "[REDACTED]")
        #expect(redacted["password"] == "[REDACTED]")
        #expect(redacted["secret"] == "[REDACTED]")
        #expect(redacted["authorization"] == "[REDACTED]")
        #expect(redacted["cookie"] == "[REDACTED]")
        #expect(redacted["apikey"] == "[REDACTED]")
        #expect(redacted["api_key"] == "[REDACTED]")
        #expect(redacted["refreshtoken"] == "[REDACTED]")
        #expect(redacted["refresh_token"] == "[REDACTED]")
        #expect(redacted["accessjwt"] == "[REDACTED]")
        #expect(redacted["access_jwt"] == "[REDACTED]")
        #expect(redacted["bearer"] == "[REDACTED]")
        #expect(redacted["episode_id"] == "ep-99")
        #expect(redacted["breaks_count"] == "3")
    }

    @Test func redactedMessageFragments() {
        let msg1 = "Login failed with password=secret123 and token=abc."
        let redacted1 = LogSink.redactedMessage(msg1)
        #expect(redacted1 == "Login failed with password=[REDACTED] and token=[REDACTED].")

        let msg2 = "Using api_key: key123xyz for auth"
        let redacted2 = LogSink.redactedMessage(msg2)
        #expect(redacted2 == "Using api_key:[REDACTED] for auth")

        let msg3 = "Normal message without secrets."
        let redacted3 = LogSink.redactedMessage(msg3)
        #expect(redacted3 == "Normal message without secrets.")
    }

    @Test func payloadShape() throws {
        let entry = LogSink.LogEntry(
            ts: "2026-09-09T00:00:00.000Z",
            level: "info",
            tag: "app_start",
            message: "Quarto started",
            meta: ["episode_id": "123"]
        )

        struct Payload: Codable {
            let app: String
            let build: String?
            let deviceId: String?
            let entries: [LogSink.LogEntry]
        }

        let payload = Payload(
            app: "Quarto",
            build: "1",
            deviceId: "test-device",
            entries: [entry]
        )

        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["app"] as? String == "Quarto")
        #expect(json?["build"] as? String == "1")
        #expect(json?["deviceId"] as? String == "test-device")
        let entries = json?["entries"] as? [[String: Any]]
        #expect(entries?.count == 1)
        #expect(entries?[0]["tag"] as? String == "app_start")
        #expect(entries?[0]["level"] as? String == "info")
    }
}

struct ServerWaitTests {
    private func episode() -> PodcastEpisode {
        PodcastEpisode(
            id: "wait-test-ep", libraryItemId: "wait-test-item",
            title: "Wait Test Episode", subtitle: nil, description: nil,
            season: nil, publishedAt: nil, duration: 60,
            audioFile: nil, podcast: nil, chapters: nil
        )
    }

    @Test @MainActor func invalidURLFailsFastWithoutPolling() async {
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = "ht!tp://invalid"
        let cuts = await store.runOnServerAndWait(
            for: episode(), pollInterval: 0.1, timeout: 2
        )
        #expect(cuts.isEmpty)
    }

    @Test @MainActor func unreachableHostFailsFastWithoutPolling() async {
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = "http://127.0.0.1:9"
        let cuts = await store.runOnServerAndWait(
            for: episode(), pollInterval: 0.1, timeout: 2
        )
        #expect(cuts.isEmpty)
    }

    @Test @MainActor func plansFetchAgainstBadHostReturnsEmpty() async {
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = "http://127.0.0.1:9"
        #expect(await store.fetchDesktopPlans().isEmpty)
    }

    @Test @MainActor func unreachableHostIsNotReachable() async {
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = "http://127.0.0.1:9"
        #expect(await store.isWorkerReachable() == false)
    }

    @Test @MainActor func liveWorkerAnswersPlansShape() async {
        // Requires a live detector worker; set QUARTO_LIVE_WORKER_URL to run.
        guard let liveURL = ProcessInfo.processInfo.environment["QUARTO_LIVE_WORKER_URL"],
              !liveURL.isEmpty else { return }
        let store = AdStore()
        let saved = store.serverDetectionURL
        defer { store.serverDetectionURL = saved }
        store.serverDetectionURL = liveURL
        #expect(await store.isWorkerReachable() == true)
    }
}

struct PodcastShowsTests {
    private func item(id: String, title: String?, episodes: Int?) -> LibraryItem {
        let metadata = Metadata(
            title: title, subtitle: nil, authorName: "Author",
            author: nil, narratorName: nil, seriesName: nil,
            description: nil, genres: nil, publishedYear: nil, releaseDate: nil
        )
        let media = Media(
            metadata: metadata, duration: nil,
            episodes: episodes.map { (0..<$0).map { i in PodcastEpisode(id: "ep-\(id)-\(i)", libraryItemId: id, title: "E\(i)", subtitle: nil, description: nil, season: nil, publishedAt: nil, duration: nil, audioFile: nil, podcast: nil, chapters: nil) } },
            numEpisodes: nil, tags: nil, chapters: nil
        )
        return LibraryItem(id: id, libraryId: "lib", mediaType: "podcast", media: media, recentEpisode: nil)
    }

    @Test func sortsTitlesCaseInsensitively() {
        let entries = PodcastShows.entries(from: [
            item(id: "b", title: "zebra show", episodes: 1),
            item(id: "a", title: "Alpha Show", episodes: 1),
            item(id: "c", title: "mango show", episodes: 1),
        ])
        #expect(entries.map(\.id) == ["a", "c", "b"])
    }

    @Test func countsEpisodesFromArray() {
        let entries = PodcastShows.entries(from: [item(id: "a", title: "S", episodes: 3)])
        #expect(entries.first?.episodeCount == 3)
    }

    @Test func missingMediaCountsZero() {
        let item = LibraryItem(id: "x", libraryId: "lib", mediaType: "podcast", media: nil, recentEpisode: nil)
        #expect(PodcastShows.entries(from: [item]).first?.episodeCount == 0)
        #expect(PodcastShows.entries(from: [item]).first?.item.title == "Untitled")
    }
}
