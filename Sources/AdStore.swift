import Foundation
import Observation
import Speech

public enum TipType: String, Codable, CaseIterable, Identifiable, Sendable {
    case trigger = "Trigger (Ad Start)"
    case exit = "Exit (Ad End)"
    case ignore = "Ignore (False Positive)"
    public var id: String { rawValue }
}

public struct AdDetectionTip: Codable, Identifiable, Hashable, Sendable {
    public var id: String { phrase }
    public let phrase: String
    public let type: TipType
    public let note: String?
    public let createdAt: Date

    public init(phrase: String, type: TipType, note: String? = nil, createdAt: Date = Date()) {
        self.phrase = phrase
        self.type = type
        self.note = note
        self.createdAt = createdAt
    }
}

public enum DetectionSource: String, CaseIterable, Identifiable, Sendable {
    case server = "Server (4070 Super)"
    case local = "Local (On-Device)"
    public var id: String { rawValue }
}

@MainActor
@Observable
final class AdStore {
    private let fileURL: URL
    private let serverStoreURL: URL
    private let localStoreURL: URL
    private let tipsURL: URL
    private let titlePlansURL: URL

    private(set) var store: [String: [AdSegment]] = [:]
    private(set) var serverStore: [String: [AdSegment]] = [:]
    private(set) var localStore: [String: [AdSegment]] = [:]
    private(set) var titlePlans: [String: [AdSegment]] = [:]
    private(set) var tips: [AdDetectionTip] = []

    var lastSyncCount: Int? = nil
    var lastSyncDate: Date? = nil
    var isSyncing: Bool = false
    var isScanning = false
    private var isBatchScanning = false
    var currentScanTitle = ""
    var completedCount = 0
    var totalToScan = 0
    var lastDetectedCount = 0
    var lastDetectionError: String?
    private var lastServerTimedOut = false
    struct DesktopPlanItem: Decodable {
        let title: String
        let file: String
        let duration: Double
        let segments: [AdSegment]
    }
    struct DesktopPlansResponse: Decodable {
        let status: String
        let count: Int
        let plans: [DesktopPlanItem]
    }
    
    var scanStatusMessage = "Analyzing audio for ads..."
    private var scanTask: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quarto", isDirectory: true)
        fileURL = base.appendingPathComponent("detected_ads.json")
        serverStoreURL = base.appendingPathComponent("server_detected_ads.json")
        localStoreURL = base.appendingPathComponent("local_detected_ads.json")
        titlePlansURL = base.appendingPathComponent("title_plans.json")
        tipsURL = base.appendingPathComponent("ad_tips.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    var useServerDetection: Bool {
        get { UserDefaults.standard.object(forKey: "quarto_detect_on_server") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quarto_detect_on_server") }
    }

    var serverDetectionURL: String {
        get {
            if let val = UserDefaults.standard.string(forKey: "quarto_server_detector_url"),
               !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
            let defaultURL = ""
            UserDefaults.standard.set(defaultURL, forKey: "quarto_server_detector_url")
            return defaultURL
        }
        set { UserDefaults.standard.set(newValue, forKey: "quarto_server_detector_url") }
    }

    var useLogSink: Bool {
        get { UserDefaults.standard.bool(forKey: "quarto_use_log_sink") }
        set {
            UserDefaults.standard.set(newValue, forKey: "quarto_use_log_sink")
            Task { await LogSink.shared.configureFromDefaults() }
        }
    }

    var logSinkURL: String {
        get { UserDefaults.standard.string(forKey: "quarto_log_sink_url") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "quarto_log_sink_url")
            Task { await LogSink.shared.configureFromDefaults() }
        }
    }

    var logSinkToken: String {
        get { UserDefaults.standard.string(forKey: "quarto_log_sink_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "quarto_log_sink_token")
            Task { await LogSink.shared.configureFromDefaults() }
        }
    }

    static func slugify(_ title: String) -> String {
        let lower = title.lowercased()
        let stripped = lower.replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
        return stripped.replacingOccurrences(of: #"[-\s]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func segments(for episodeId: String, title: String? = nil) -> [AdSegment] {
        if let direct = store[episodeId], !direct.isEmpty {
            return direct
        }
        if let server = serverStore[episodeId], !server.isEmpty {
            return server
        }
        if let title, !title.isEmpty {
            let slug = Self.slugify(title)
            if let matched = titlePlans[slug], !matched.isEmpty {
                return matched
            }
            for (key, segs) in titlePlans {
                if key.contains(slug) || slug.contains(key) {
                    return segs
                }
            }
        }
        return []
    }

    func serverSegments(for episodeId: String, title: String? = nil) -> [AdSegment] {
        if let server = serverStore[episodeId], !server.isEmpty {
            return server
        }
        if let title, !title.isEmpty {
            let slug = Self.slugify(title)
            if let matched = titlePlans[slug], !matched.isEmpty {
                return matched
            }
            for (key, segs) in titlePlans {
                if key.contains(slug) || slug.contains(key) {
                    return segs
                }
            }
        }
        return []
    }
    func localSegments(for episodeId: String) -> [AdSegment] {
        localStore[episodeId] ?? []
    }

    func hasAds(for episodeId: String, title: String? = nil) -> Bool {
        !segments(for: episodeId, title: title).isEmpty
    }

    func save(segments: [AdSegment], for episodeId: String) {
        store[episodeId] = segments
        persist()
    }

    enum SharedListError: Error {
        case unreadable
    }

    /// Writes the episode's detected breaks to a shareable JSON file and
    /// returns its URL. Returns nil when there is nothing to share.
    func exportSharedList(
        episodeId: String?,
        episodeTitle: String,
        showTitle: String?,
        duration: Double?
    ) -> URL? {
        let key = (episodeId?.isEmpty == false) ? episodeId! : nil
        let ads: [AdSegment]
        if let key {
            ads = segments(for: key, title: episodeTitle)
        } else {
            ads = segments(for: "title:" + Self.slugify(episodeTitle), title: episodeTitle)
        }
        guard !ads.isEmpty else { return nil }
        let list = SharedAdList(
            showTitle: showTitle,
            episodeTitle: episodeTitle,
            episodeId: key,
            duration: duration,
            segments: ads
        )
        guard let data = try? JSONEncoder().encode(list) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(list.fileName())
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Merges a shareable list file into the local index. Returns the
    /// episode title and the number of newly added breaks.
    func importSharedList(from url: URL) throws -> (title: String, added: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(SharedAdList.self, from: data)
        else { throw SharedListError.unreadable }
        return (list.episodeTitle, importSharedList(list))
    }

    /// Merges a decoded shareable list into the local index. Returns the
    /// number of newly added breaks.
    @discardableResult
    func importSharedList(_ list: SharedAdList) -> Int {
        guard list.format == SharedAdList.format, !list.segments.isEmpty else { return 0 }
        let incoming = list.segments.map { $0.toAdSegment() }
        if let id = list.episodeId, !id.isEmpty {
            let existing = store[id] ?? []
            let known = Set(existing.map(\.id))
            let fresh = incoming.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return 0 }
            store[id] = existing + fresh
            persist()
            return fresh.count
        }
        let slug = Self.slugify(list.episodeTitle)
        let existing = titlePlans[slug] ?? []
        let known = Set(existing.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        titlePlans[slug] = existing + fresh
        persistTitlePlans()
        return fresh.count
    }

    func applyCuts(from source: DetectionSource, for episodeId: String) {
        let cuts: [AdSegment] = switch source {
        case .server: serverStore[episodeId] ?? []
        case .local: localStore[episodeId] ?? []
        }
        if !cuts.isEmpty {
            save(segments: cuts, for: episodeId)
        }
    }

    func addTip(phrase: String, type: TipType, note: String? = nil) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        tips.removeAll { $0.phrase == trimmed }
        let tip = AdDetectionTip(phrase: trimmed, type: type, note: note)
        tips.append(tip)
        persistTips()

        // Sync with desktop server in background if configured
        if let serverURL = URL(string: serverDetectionURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Task.detached {
                let endpoint = serverURL.appendingPathComponent("api/tips")
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: String] = [
                    "phrase": trimmed,
                    "type": type.rawValue,
                    "note": note ?? ""
                ]
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    func removeTip(id: String) {
        tips.removeAll { $0.id == id }
        persistTips()
    }

    func clearLocalCache() {
        store.removeAll()
        localStore.removeAll()
        titlePlans.removeAll()
        persist()
        persistLocalStore()
        persistTitlePlans()
        logRemote(service: "ios-adstore", level: "INFO", message: "User cleared local ad cache")
    }

    func clearEpisodeCache(episodeId: String) {
        store.removeValue(forKey: episodeId)
        localStore.removeValue(forKey: episodeId)
        serverStore.removeValue(forKey: episodeId)
        persist()
        persistLocalStore()
        persistServerStore()
    }

    @discardableResult
    func clearServerCache(for episodeTitle: String? = nil) async -> Bool {
        if episodeTitle == nil {
            serverStore.removeAll()
            persistServerStore()
        }
        guard let serverURL = URL(string: serverDetectionURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let endpoint = serverURL.appendingPathComponent("api/clear-cache")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = episodeTitle != nil ? ["title": episodeTitle!] : [:]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }


    @discardableResult
    func fetchDesktopPlans() async -> [DesktopPlanItem] {
        (await fetchDesktopPlansRaw())?.plans ?? []
    }

    /// True when the worker answers the plans endpoint with a valid shape,
    /// even when it holds zero plans. This is the only GPU-alive signal the
    /// worker exposes, so a timeout followed by reachable here means the job
    /// is still processing. Timeout followed by unreachable means trouble.
    func isWorkerReachable() async -> Bool {
        await fetchDesktopPlansRaw() != nil
    }

    private func fetchDesktopPlansRaw() async -> DesktopPlansResponse? {
        guard let serverURL = URL(string: serverDetectionURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let endpoint = serverURL.appendingPathComponent("api/plans")
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15.0
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(DesktopPlansResponse.self, from: data)
        } catch {
            return nil
        }
    }
    @discardableResult
    func syncAllPlansFromDesktop() async -> Int {
        isSyncing = true
        defer { isSyncing = false }
        let plans = await fetchDesktopPlans()
        guard !plans.isEmpty else { return 0 }
        var count = 0
        for plan in plans {
            if !plan.segments.isEmpty {
                let slug = Self.slugify(plan.title)
                titlePlans[slug] = plan.segments
                count += 1
            }
        }
        persistTitlePlans()
        lastSyncCount = count
        lastSyncDate = Date()
        logRemote(service: "ios-adstore", level: "INFO", message: "Synced \(count) plans from 4070 Super into local cache")
        return count
    }

    /// User-triggered server run that survives slow GPU jobs. The direct call
    /// covers fast and cached runs. If it times out, the job is usually still
    /// running on the worker, so poll the finished plans by episode title
    /// instead of failing. Other errors fail fast as before.
    @discardableResult
    func runOnServerAndWait(
        for episode: PodcastEpisode,
        pollInterval: TimeInterval = 15,
        timeout: TimeInterval = 600
    ) async -> [AdSegment] {
        isScanning = true
        currentScanTitle = episode.title ?? "Episode"
        defer {
            if !isBatchScanning {
                isScanning = false
            }
        }
        let fast = await detectOnServer(for: episode, force: true)
        if !fast.isEmpty { return fast }
        guard lastServerTimedOut else { return [] }
        guard await isWorkerReachable() else {
            lastDetectionError = "The 4070 Super is unreachable. Check that Tailscale is connected and the worker is running."
            return []
        }
        scanStatusMessage = "The 4070 Super is still working. Waiting for the finished plan..."
        let deadline = Date().addingTimeInterval(timeout)
        let wanted = Self.slugify(episode.title ?? "")
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            let plans = await fetchDesktopPlans()
            if let match = plans.first(where: { Self.slugify($0.title) == wanted && !$0.segments.isEmpty }) {
                let sorted = match.segments.sorted(by: { $0.startTime < $1.startTime })
                serverStore[episode.id] = sorted
                persistServerStore()
                lastDetectionError = nil
                logRemote(service: "ios-adstore", level: "INFO", message: "Picked up slow 4070 Super plan for '\(episode.title ?? "")': \(sorted.count) breaks found", extra: ["breaks_count": String(sorted.count)])
                save(segments: sorted, for: episode.id)
                return sorted
            }
        }
        lastDetectionError = "The 4070 Super is still working. Open Settings and use Sync All Plans from 4070 Super later to pick up the finished plan."
        return []
    }
    func clearAllCaches() async {
        clearLocalCache()
        _ = await clearServerCache()
    }

    func logRemote(service: String, level: String, message: String, extra: [String: String] = [:]) {
        guard let serverURL = URL(string: serverDetectionURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        Task.detached {
            let endpoint = serverURL.appendingPathComponent("api/log")
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "app": "quarto",
                "service": service,
                "level": level,
                "message": message
            ]
            for (k, v) in extra {
                body[k] = v
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func scanEpisodes(
        _ episodes: [PodcastEpisode],
        client: ABSClient?,
        downloads: DownloadStore,
        adEngine: AdSkipEngine
    ) {
        guard !episodes.isEmpty else { return }
        cancelScan()

        isBatchScanning = true
        isScanning = true
        totalToScan = episodes.count
        completedCount = 0
        currentScanTitle = episodes.first?.title ?? "Episode"

        let recognizer = LiveSpeechRecognizer()
        scanTask = Task { [weak self] in
            _ = await recognizer.requestAuthorization()
            for (index, episode) in episodes.enumerated() {
                if Task.isCancelled { break }

                self?.currentScanTitle = episode.title ?? "Episode"
                self?.completedCount = index

                guard let self else { break }
                let foundAds = await self.detectAds(
                    for: episode,
                    client: client,
                    downloads: downloads,
                    adEngine: adEngine,
                    recognizer: recognizer
                )

                if Task.isCancelled { break }

                self.save(segments: foundAds, for: episode.id)
                self.lastDetectedCount = foundAds.count
                self.completedCount = index + 1
            }
            self?.isBatchScanning = false
            self?.isScanning = false
            self?.scanTask = nil
        }
    }
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isBatchScanning = false
        isScanning = false
    }

    private func detectAds(
        for episode: PodcastEpisode,
        client: ABSClient?,
        downloads: DownloadStore,
        adEngine: AdSkipEngine,
        recognizer: LiveSpeechRecognizer
    ) async -> [AdSegment] {
        if useServerDetection {
            let serverCuts = await detectOnServer(for: episode)
            if !serverCuts.isEmpty {
                return serverCuts
            }
        }
        return await detectLocally(
            for: episode,
            client: client,
            downloads: downloads,
            adEngine: adEngine,
            recognizer: recognizer
        )
    }
    func detectOnServer(for episode: PodcastEpisode, force: Bool = false) async -> [AdSegment] {
        isScanning = true
        currentScanTitle = episode.title ?? "Episode"
        scanStatusMessage = "Analyzing on 4070 Super GPU..."
        lastServerTimedOut = false
        defer {
            if !isBatchScanning {
                isScanning = false
            }
        }
        let trimmedDetectorURL = serverDetectionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDetectorURL.isEmpty, let serverURL = URL(string: trimmedDetectorURL) else {
            if !trimmedDetectorURL.isEmpty {
                lastDetectionError = "The 4070 Super URL is invalid."
            }
            return []
        }
        let endpoint = serverURL.appendingPathComponent("api/detect")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180.0
        let body: [String: Any] = [
            "episodeId": episode.id,
            "title": episode.title ?? "",
            "podcast": episode.showTitle ?? "It Could Happen Here",
            "force": force
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            lastDetectionError = "Could not create the 4070 Super request."
            return []
        }
        req.httpBody = data
        do {
            let (respData, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastDetectionError = "The 4070 Super returned an invalid response."
                return []
            }
            guard (200...299).contains(http.statusCode) else {
                lastDetectionError = "The 4070 Super returned HTTP \(http.statusCode)."
                return []
            }
            struct ServerDetectResponse: Decodable {
                let status: String
                let cached: Bool?
                let segments: [AdSegment]
            }
            let decoded = try JSONDecoder().decode(ServerDetectResponse.self, from: respData)
            let sorted = decoded.segments.sorted(by: { $0.startTime < $1.startTime })
            serverStore[episode.id] = sorted
            persistServerStore()
            logRemote(service: "ios-adstore", level: "INFO", message: "Server detection completed for '\(episode.title ?? "")': \(sorted.count) breaks found", extra: ["breaks_count": String(sorted.count)])
            save(segments: sorted, for: episode.id)
            return sorted
        } catch {
            lastServerTimedOut = (error as? URLError)?.code == .timedOut
            lastDetectionError = "4070 Super analysis failed: \(error.localizedDescription)"
            Task { await LogSink.shared.log(level: "error", tag: "detectOnServer", message: error.localizedDescription, meta: ["episode_id": episode.id]) }
            return []
        }
    }

    func detectLocally(
        for episode: PodcastEpisode,
        client: ABSClient?,
        downloads: DownloadStore,
        adEngine: AdSkipEngine,
        recognizer: LiveSpeechRecognizer
    ) async -> [AdSegment] {
        isScanning = true
        currentScanTitle = episode.title ?? "Episode"
        scanStatusMessage = "Analyzing on-device with Apple Speech..."
        lastDetectionError = nil
        defer {
            if !isBatchScanning {
                isScanning = false
            }
        }

        _ = await recognizer.requestAuthorization()
        var results: [AdSegment] = []

        // 1. Check embedded chapters
        if let chapters = episode.chapters, !chapters.isEmpty {
            let items = chapters.map { ChapterItem(title: $0.title, startTime: $0.start, endTime: $0.end) }
            let chapterAds = adEngine.detectChapterAds(items)
            results.append(contentsOf: chapterAds)
        }

        // 2. Check description timestamps
        if let desc = episode.description, !desc.isEmpty {
            let descChapters = Self.parseTimestamps(desc, totalDuration: episode.resolvedDuration ?? 0)
            if !descChapters.isEmpty {
                let descAds = adEngine.detectChapterAds(descChapters)
                for ad in descAds {
                    if !results.contains(where: { abs($0.startTime - ad.startTime) < 5 }) {
                        results.append(ad)
                    }
                }
            }
        }

        // 3. Audio transcription scan
        var audioFileToScan: URL? = nil
        var tempFileToClean: URL? = nil

        if let itemId = episode.libraryItemId, let local = downloads.file(itemId: itemId, episodeId: episode.id) {
            audioFileToScan = downloads.localURL(for: local)
        } else if let client, let itemId = episode.libraryItemId {
            // Download audio stream chunk or full file for transcription
            do {
                let session = try await client.play(itemId: itemId, episodeId: episode.id)
                if let track = session.audioTracks.first, let remoteURL = client.absoluteURL(track.contentUrl) {
                    let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("batch_adscan_\(episode.id).mp3")
                    let request = client.authorizedRequest(for: remoteURL)
                    let (downloaded, response) = try await URLSession.shared.download(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        return results
                    }
                    try? FileManager.default.removeItem(at: tempPath)
                    try FileManager.default.moveItem(at: downloaded, to: tempPath)
                    audioFileToScan = tempPath
                    tempFileToClean = tempPath
                }
            } catch {
                // Network or session error
            }
        }

        if let fileURL = audioFileToScan {
            adEngine.resetStream()
            var collectedAds: [AdSegment] = []

            _ = await recognizer.transcribeFile(url: fileURL) { [weak self] word, start, end in
                if let ad = adEngine.feedWord(word, startTime: start, endTime: end) {
                    if let idx = collectedAds.firstIndex(where: { abs($0.startTime - ad.startTime) < 5 }) {
                        collectedAds[idx] = ad
                    } else {
                        collectedAds.append(ad)
                    }
                    self?.lastDetectedCount = collectedAds.count
                }
            }

            for ad in collectedAds {
                if let idx = results.firstIndex(where: { abs($0.startTime - ad.startTime) < 5 }) {
                    results[idx] = ad
                } else {
                    results.append(ad)
                }
            }
        }

        if let temp = tempFileToClean {
            try? FileManager.default.removeItem(at: temp)
        }

        let sorted = results.sorted(by: { $0.startTime < $1.startTime })
        localStore[episode.id] = sorted
        persistLocalStore()
        logRemote(service: "ios-adstore", level: "INFO", message: "On-device detection completed for '\(episode.title ?? "")': \(sorted.count) breaks found", extra: ["breaks_count": String(sorted.count)])
        if !sorted.isEmpty {
            save(segments: sorted, for: episode.id)
        }
        return sorted
    }

    func detectBoth(
        for episode: PodcastEpisode,
        client: ABSClient?,
        downloads: DownloadStore,
        adEngine: AdSkipEngine,
        recognizer: LiveSpeechRecognizer,
        runLocal: Bool = true
    ) async {
        isScanning = true
        currentScanTitle = episode.title ?? "Episode"
        scanStatusMessage = "Analyzing on 4070 Super GPU..."
        defer {
            if !isBatchScanning {
                isScanning = false
            }
        }

        _ = await runOnServerAndWait(for: episode)

        guard runLocal else { return }

        // 2. Run Local Detection
        isScanning = true
        scanStatusMessage = "Analyzing on-device with Apple Speech..."
        _ = await detectLocally(
            for: episode,
            client: client,
            downloads: downloads,
            adEngine: adEngine,
            recognizer: recognizer
        )
    }

    private static func parseTimestamps(_ text: String, totalDuration: Double) -> [ChapterItem] {
        let lines = text.components(separatedBy: .newlines)
        var items: [(time: Double, title: String)] = []
        let pattern = try? NSRegularExpression(pattern: #"(?:^|\s)(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\s*[-:–\]]?\s*(.+)$"#)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pattern, let match = pattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) else {
                continue
            }
            let ns = trimmed as NSString
            let hStr = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : nil
            let mStr = ns.substring(with: match.range(at: 2))
            let sStr = ns.substring(with: match.range(at: 3))
            let title = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces) : ""

            let hours = Double(hStr ?? "0") ?? 0
            let minutes = Double(mStr) ?? 0
            let seconds = Double(sStr) ?? 0
            let timestamp = hours * 3600 + minutes * 60 + seconds
            if !title.isEmpty {
                items.append((time: timestamp, title: title))
            }
        }

        guard !items.isEmpty else { return [] }
        var chapters: [ChapterItem] = []
        for i in 0..<items.count {
            let start = items[i].time
            let end = (i + 1 < items.count) ? items[i + 1].time : (totalDuration > start ? totalDuration : start + 60)
            if end > start {
                chapters.append(ChapterItem(title: items[i].title, startTime: start, endTime: end))
            }
        }
        return chapters
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL) {
            store = (try? JSONDecoder().decode([String: [AdSegment]].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: serverStoreURL) {
            serverStore = (try? JSONDecoder().decode([String: [AdSegment]].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: localStoreURL) {
            localStore = (try? JSONDecoder().decode([String: [AdSegment]].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: titlePlansURL) {
            titlePlans = (try? JSONDecoder().decode([String: [AdSegment]].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: tipsURL) {
            tips = (try? JSONDecoder().decode([AdDetectionTip].self, from: data)) ?? []
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func persistServerStore() {
        if let data = try? JSONEncoder().encode(serverStore) {
            try? data.write(to: serverStoreURL, options: .atomic)
        }
    }

    private func persistLocalStore() {
        if let data = try? JSONEncoder().encode(localStore) {
            try? data.write(to: localStoreURL, options: .atomic)
        }
    }

    private func persistTips() {
        if let data = try? JSONEncoder().encode(tips) {
            try? data.write(to: tipsURL, options: .atomic)
        }
    }

    private func persistTitlePlans() {
        if let data = try? JSONEncoder().encode(titlePlans) {
            try? data.write(to: titlePlansURL, options: .atomic)
        }
    }
}
