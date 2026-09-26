import Foundation
import Observation

private struct CachedPodcastContent: Codable {
    let library: Library
    let continueItems: [LibraryItem]
    let libraryItems: [LibraryItem]
    let recentEpisodes: [PodcastEpisode]
    let progress: [MediaProgress]
}

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let key: String
    weak var model: AppModel?
    var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(key: String, model: AppModel) {
        self.key = key
        self.model = model
        super.init()
    }

    static func fraction(written: Int64, expected: Int64) -> Double? {
        guard expected > 0, written >= 0 else { return nil }
        return min(1, max(0, Double(written) / Double(expected)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = Self.fraction(
            written: totalBytesWritten,
            expected: totalBytesExpectedToWrite
        )
        Task { @MainActor [weak model] in
            model?.setDownloadProgress(fraction, for: key)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let continuation else { return }
        self.continuation = nil
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("quarto-dl-\(UUID().uuidString)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume(
                returning: (destination, downloadTask.response ?? URLResponse())
            )
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: ABSError.badResponse)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var credentials: SessionCredentials?
    var libraries: [Library] = []
    var selectedLibrary: Library?
    var continueItems: [LibraryItem] = []
    var libraryItems: [LibraryItem] = []
    var recentEpisodes: [PodcastEpisode] = []
    var progress: [String: MediaProgress] = [:]
    var isLoading = false
    var errorMessage: String?
    var showSettings = false
    var showPlayer = false
    var searchText = ""
    var downloadingKey: String?
    var downloadProgress: [String: Double] = [:]
    private(set) var pendingDownloadCount = 0
    private var downloadDelegates: [String: DownloadProgressDelegate] = [:]

    private static let loggedOutKey = "has_logged_out"

    let player = PlayerController()
    let downloads = DownloadStore()
    let adStore = AdStore()
    let silenceStore = SilenceStore()
    private let account = "session"
    private static let podcastCacheKey = "quarto_podcast_content_cache_v1"

    private var userSelectedLibrary = false
    private var lastProgressCacheWrite = Date.distantPast
    private var absClient: ABSClient?

    var client: ABSClient? { absClient }

    init() {
        loadSession()
        loadPodcastCache()
        if let credentials {
            attachClient(credentials)
        }
        downloads.cleanTemporaryAdScans()
        player.silenceStore = silenceStore
        player.onAdSkipped = { [weak self] ad in
            self?.adStore.logRemote(
                service: "ios-player",
                level: "INFO",
                message: "Skipped ad break (\(Int(ad.endTime - ad.startTime))s) at \(Format.timestamp(ad.startTime)) - \(Format.timestamp(ad.endTime))",
                extra: ["reason": ad.reason, "confidence": String(ad.confidence)]
            )
        }
        player.onSilenceSkipped = { [weak self] segment in
            self?.adStore.logRemote(
                service: "ios-player",
                level: "INFO",
                message: "Skipped \(String(format: "%.1f", segment.endTime - segment.startTime))s of silence at \(Format.timestamp(segment.startTime))",
                extra: ["kind": "skip_silence"]
            )
        }
    }

    func bootstrap() async {
        guard credentials != nil else { return }
        do {
            try await absClient?.ensureFreshAccessToken()
            await refreshProgress()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login(server: String, username: String, password: String) async {
        UserDefaults.standard.removeObject(forKey: Self.loggedOutKey)
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        guard let url = normalizedURL(server) else {
            errorMessage = "Enter a valid server URL"
            return
        }
        do {
            let client = ABSClient(baseURL: url)
            let login = try await client.login(username: username, password: password)
            credentials = SessionCredentials(
                serverURL: url.absoluteString,
                accessToken: login.user.bearerToken,
                refreshToken: login.user.refreshToken,
                username: login.user.username,
                userId: login.user.id,
                defaultLibraryId: login.userDefaultLibraryId,
                password: password
            )
            attachClient(credentials!)
            indexProgress(login.user.mediaProgress)
            persistSession()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        UserDefaults.standard.set(true, forKey: Self.loggedOutKey)
        UserDefaults.standard.removeObject(forKey: Self.podcastCacheKey)
        Task { await player.closeCurrent() }
        credentials = nil
        absClient = nil
        libraries = []
        selectedLibrary = nil
        continueItems = []
        libraryItems = []
        recentEpisodes = []
        progress = [:]
        Keychain.delete(account)
    }

    func selectLibrary(_ library: Library) async {
        userSelectedLibrary = true
        selectedLibrary = library
        await refreshLibrary()
    }

    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            await refreshProgress()
            let fetchedLibraries = try await client.libraries()
            libraries = fetchedLibraries
            if userSelectedLibrary {
                if let current = selectedLibrary,
                   let fresh = fetchedLibraries.first(where: { $0.id == current.id }) {
                    selectedLibrary = fresh
                } else {
                    selectedLibrary = Self.startupLibrary(
                        in: fetchedLibraries,
                        defaultLibraryID: credentials?.defaultLibraryId,
                        cachedLibraryID: nil
                    )
                }
            } else {
                selectedLibrary = Self.startupLibrary(
                    in: fetchedLibraries,
                    defaultLibraryID: credentials?.defaultLibraryId,
                    cachedLibraryID: selectedLibrary?.id
                )
            }
            await refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary() async {
        guard let client, let library = selectedLibrary else { return }
        player.configure(client: client)
        do {
            let items = try await client.allItems(libraryId: library.id)
            let sections = (try? await client.personalized(libraryId: library.id)) ?? []
            let episodes = library.isPodcast
                ? try await client.recentEpisodes(libraryId: library.id)
                : []
            libraryItems = items
            continueItems = sections.first { $0.id.contains("continue") }?.entities ?? []
            recentEpisodes = episodes
            if library.isPodcast {
                persistPodcastCache()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func startupLibrary(
        in libraries: [Library],
        defaultLibraryID: String?,
        cachedLibraryID: String?
    ) -> Library? {
        if let cachedLibraryID,
           let cached = libraries.first(where: { $0.id == cachedLibraryID && $0.isPodcast }) {
            return cached
        }
        if let podcast = libraries.first(where: \.isPodcast) {
            return podcast
        }
        if let defaultLibraryID,
           let preferred = libraries.first(where: { $0.id == defaultLibraryID }) {
            return preferred
        }
        return libraries.first
    }

    private func loadPodcastCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.podcastCacheKey),
              let cached = try? JSONDecoder().decode(CachedPodcastContent.self, from: data)
        else {
            return
        }
        libraries = [cached.library]
        selectedLibrary = cached.library
        continueItems = cached.continueItems
        libraryItems = cached.libraryItems
        recentEpisodes = cached.recentEpisodes
        indexProgress(cached.progress)
    }

    private func persistPodcastCache() {
        let targetLibrary: Library?
        let contItems: [LibraryItem]
        let libItems: [LibraryItem]
        let episodes: [PodcastEpisode]

        if let library = selectedLibrary, library.isPodcast {
            targetLibrary = library
            contItems = continueItems
            libItems = libraryItems
            episodes = recentEpisodes
        } else if let data = UserDefaults.standard.data(forKey: Self.podcastCacheKey),
                  let cached = try? JSONDecoder().decode(CachedPodcastContent.self, from: data) {
            targetLibrary = cached.library
            contItems = cached.continueItems
            libItems = cached.libraryItems
            episodes = cached.recentEpisodes
        } else if let podcastLib = libraries.first(where: \.isPodcast) {
            targetLibrary = podcastLib
            contItems = continueItems
            libItems = libraryItems
            episodes = recentEpisodes
        } else {
            return
        }

        guard let library = targetLibrary else { return }
        var uniqueProgress: [String: MediaProgress] = [:]
        for item in progress.values {
            uniqueProgress[item.id] = item
        }
        let cached = CachedPodcastContent(
            library: library,
            continueItems: contItems,
            libraryItems: libItems,
            recentEpisodes: episodes,
            progress: Array(uniqueProgress.values)
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.podcastCacheKey)
    }

    func coverURL(for itemId: String) -> URL? {
        client?.coverURL(itemId: itemId)
    }

    func refreshProgress() async {
        guard let client else { return }
        do {
            let user = try await client.me()
            indexProgress(user.mediaProgress)
        } catch {
            // Ignore progress refresh errors silently
        }
    }

    func progress(for itemId: String, episodeId: String?) -> MediaProgress? {
        if let episodeId {
            let key = "\(itemId)-\(episodeId)"
            if let match = progress[key] ?? progress.values.first(where: { $0.libraryItemId == itemId && $0.episodeId == episodeId }) {
                return match
            }
        }
        return progress[itemId] ?? progress.values.first { $0.libraryItemId == itemId && $0.episodeId == episodeId }
    }

    func recordProgress(itemId: String, episodeId: String?, currentTime: Double, duration: Double) {
        let key = episodeId != nil ? "\(itemId)-\(episodeId!)" : itemId
        let existing = progress[key]
        let updated = MediaProgress(
            id: existing?.id ?? UUID().uuidString,
            libraryItemId: itemId,
            episodeId: episodeId,
            duration: duration > 0 ? duration : existing?.duration,
            progress: duration > 0 ? min(1, max(0, currentTime / duration)) : existing?.progress,
            currentTime: currentTime,
            isFinished: duration > 0 && (currentTime >= duration - 15),
            lastUpdate: Date().timeIntervalSince1970 * 1000
        )
        progress[key] = updated
        progress[updated.id] = updated
        let now = Date()
        if now.timeIntervalSince(lastProgressCacheWrite) >= 5 {
            lastProgressCacheWrite = now
            persistPodcastCache()
        }
    }

    func play(item: LibraryItem, episode: PodcastEpisode? = nil) async {
        if player.itemId == item.id && player.episodeId == episode?.id {
            player.toggle()
            return
        }
        errorMessage = nil

        let downloadedFile = downloads.file(itemId: item.id, episodeId: episode?.id)
        let localURL = downloadedFile.map { downloads.localURL(for: $0) }
        let hasLocalFile = localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        if !hasLocalFile && client == nil {
            errorMessage = "Connect to server to play online content"
            return
        }

        var session: PlaybackSession? = nil

        if let client {
            do {
                session = try await client.play(itemId: item.id, episodeId: episode?.id)
            } catch {
                if !hasLocalFile {
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }

        let playbackSession = session ?? PlaybackSession(
            id: "local-\(item.id)-\(episode?.id ?? "main")",
            libraryItemId: item.id,
            episodeId: episode?.id,
            displayTitle: episode?.title ?? downloadedFile?.title ?? item.title,
            displayAuthor: episode?.showTitle ?? downloadedFile?.author ?? item.author,
            duration: episode?.resolvedDuration ?? downloadedFile?.duration ?? item.duration,
            currentTime: nil,
            audioTracks: [
                AudioTrack(
                    contentUrl: localURL?.absoluteString ?? "",
                    duration: episode?.resolvedDuration ?? downloadedFile?.duration ?? item.duration,
                    mimeType: nil,
                    title: episode?.title ?? downloadedFile?.title ?? item.title
                )
            ],
            chapters: episode?.chapters ?? item.media?.chapters
        )

        guard let effectiveClient = client else {
            errorMessage = "Sign in to your Audiobookshelf server first."
            return
        }
        let saved = progress(for: item.id, episodeId: episode?.id)
        let savedTime = (saved?.isFinished != true) ? (saved?.currentTime ?? 0) : 0
        let preAds = (episode?.id).flatMap { adStore.segments(for: $0, title: episode?.title) } ?? []

        do {
            try await player.play(
                session: playbackSession,
                client: effectiveClient,
                coverURL: coverURL(for: item.id),
                localFile: hasLocalFile ? localURL : nil,
                savedTime: savedTime,
                chapters: playbackSession.chapters ?? episode?.chapters ?? item.media?.chapters,
                description: episode?.description ?? item.media?.metadata.description,
                preDetectedAds: preAds,
                onProgressUpdate: { [weak self] cur, dur in
                    self?.recordProgress(itemId: item.id, episodeId: episode?.id, currentTime: cur, duration: dur)
                },
                onPlaybackFinished: { [weak self] in
                    Task { await self?.refreshProgress() }
                }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playEpisode(_ episode: PodcastEpisode) async {
        guard let itemId = episode.libraryItemId else { return }
        if player.itemId == itemId && player.episodeId == episode.id {
            player.toggle()
            return
        }
        let stub = LibraryItem(id: itemId, libraryId: selectedLibrary?.id, mediaType: "podcast", media: nil, recentEpisode: episode)
        await play(item: stub, episode: episode)
    }

    nonisolated static func downloadKey(itemId: String, episodeId: String?) -> String {
        DownloadedFile(
            libraryItemId: itemId,
            episodeId: episodeId,
            title: "",
            author: "",
            relativePath: "",
            duration: nil
        ).key
    }

    func downloadFraction(for key: String?) -> Double? {
        guard let key else { return nil }
        return downloadProgress[key]
    }

    func setDownloadProgress(_ fraction: Double?, for key: String) {
        if let fraction {
            downloadProgress[key] = fraction
        } else {
            downloadProgress.removeValue(forKey: key)
        }
    }

    func download(item: LibraryItem, episode: PodcastEpisode? = nil) async {
        guard let client else { return }
        let key = Self.downloadKey(itemId: item.id, episodeId: episode?.id)
        downloadingKey = key
        downloadProgress[key] = 0
        defer {
            downloadingKey = nil
            downloadProgress.removeValue(forKey: key)
            downloadDelegates.removeValue(forKey: key)
        }
        do {
            let session = try await client.play(itemId: item.id, episodeId: episode?.id)
            guard let track = session.audioTracks.first, let url = client.absoluteURL(track.contentUrl) else {
                throw ABSError.badURL
            }
            let request = client.authorizedRequest(for: url)
            let delegate = DownloadProgressDelegate(key: key, model: self)
            downloadDelegates[key] = delegate
            let urlSession = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { urlSession.finishTasksAndInvalidate() }
            let (temp, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                urlSession.downloadTask(with: request).resume()
            }
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temp)
                throw ABSError.badResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let errorData = (try? Data(contentsOf: temp)) ?? Data()
                let message = String(data: errorData, encoding: .utf8) ?? ""
                try? FileManager.default.removeItem(at: temp)
                throw ABSError.http(http.statusCode, message)
            }
            let ext = http.suggestedFilename?.split(separator: ".").last.map(String.init)
                ?? URL(string: track.contentUrl)?.pathExtension
                ?? "mp3"
            _ = try downloads.save(
                itemId: item.id,
                episodeId: episode?.id,
                title: episode?.title ?? item.title,
                author: episode?.showTitle ?? item.author,
                duration: session.duration ?? episode?.resolvedDuration ?? item.duration,
                tempURL: temp,
                ext: ext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func pendingDownloads(
        _ episodes: [PodcastEpisode],
        isDownloaded: (PodcastEpisode) -> Bool
    ) -> [PodcastEpisode] {
        episodes.filter { $0.libraryItemId != nil && !isDownloaded($0) }
    }

    func undownloadedCount(_ episodes: [PodcastEpisode]) -> Int {
        let downloaded = downloads
        return Self.pendingDownloads(episodes) { episode in
            guard let itemId = episode.libraryItemId else { return true }
            return downloaded.isDownloaded(itemId: itemId, episodeId: episode.id)
        }.count
    }

    func downloadEpisodes(_ episodes: [PodcastEpisode]) async {
        let downloaded = downloads
        let targets = Self.pendingDownloads(episodes) { episode in
            guard let itemId = episode.libraryItemId else { return true }
            return downloaded.isDownloaded(itemId: itemId, episodeId: episode.id)
        }
        guard !targets.isEmpty else { return }
        pendingDownloadCount = targets.count
        defer { pendingDownloadCount = 0 }
        for episode in targets {
            if Task.isCancelled { return }
            guard let itemId = episode.libraryItemId else { continue }
            let stub = LibraryItem(id: itemId, libraryId: selectedLibrary?.id, mediaType: "podcast", media: nil, recentEpisode: episode)
            await download(item: stub, episode: episode)
            pendingDownloadCount = max(0, pendingDownloadCount - 1)
        }
    }

    func fetchEpisodes(itemId: String) async {
        guard let client else { return }
        do {
            try await client.checkNewEpisodes(itemId: itemId)
            await refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func indexProgress(_ items: [MediaProgress]) {
        var map: [String: MediaProgress] = [:]
        for item in items {
            map[item.id] = item
            map[item.compositeKey] = item
        }
        progress = map
    }

    private func attachClient(_ credentials: SessionCredentials) {
        guard let url = URL(string: credentials.serverURL) else { return }
        let client = ABSClient(
            baseURL: url,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            username: credentials.username,
            password: credentials.password
        )
        client.onTokensUpdated = { [weak self] access, refresh in
            guard let self else { return }
            self.credentials?.accessToken = access
            if let refresh { self.credentials?.refreshToken = refresh }
            self.persistSession()
        }
        absClient = client
        player.configure(client: client)
    }

    private func persistSession() {
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return }
        Keychain.set(data, account: account)
    }

    private func loadSession() {
        if let data = Keychain.data(account: account),
           let saved = try? JSONDecoder().decode(SessionCredentials.self, from: data) {
            credentials = saved
        }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") {
            text = "https://\(text)"
        }
        return URL(string: text)
    }
}
