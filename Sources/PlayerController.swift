import AVFoundation
import Foundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class PlayerController {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var title = ""
    private(set) var author = ""
    private(set) var itemId: String?
    private(set) var episodeId: String?
    private(set) var coverURL: URL?
    private(set) var sessionId: String?
    private(set) var episodeDescription: String?
    var rate: Float = 1 {
        didSet { player?.rate = isPlaying ? rate : 0 }
    }
    var autoSkipAds = true {
        didSet {
            UserDefaults.standard.set(autoSkipAds, forKey: "quarto_auto_skip_ads")
            if autoSkipAds && isPlaying {
                startLiveSpeechRecognition()
                if let url = currentAudioURL, detectedAdSegments.isEmpty {
                    startAdScan(audioURL: url, isLocal: false)
                }
            } else if !autoSkipAds {
                recognizer.stopListening()
                fileRecognizer.cancelFileTranscription()
                adScanTask?.cancel()
                adScanTask = nil
            }
        }
    }
    var skipSilence = false {
        didSet {
            UserDefaults.standard.set(skipSilence, forKey: "quarto_skip_silence")
            if skipSilence {
                if silenceSegments.isEmpty, let url = currentAudioURL, let key = currentSilenceKey {
                    startSilenceScan(audioURL: url, isLocal: currentAudioIsLocal, key: key)
                }
            } else {
                silenceScanTask?.cancel()
                silenceScanTask = nil
                isScanningSilence = false
            }
        }
    }
    private(set) var detectedAdSegments: [AdSegment] = []
    private(set) var activeAdSegment: AdSegment?
    private(set) var lastSkippedAd: AdSegment?
    private(set) var silenceSegments: [SilenceSegment] = []
    private(set) var isScanningSilence = false
    var onAdSkipped: ((AdSegment) -> Void)?
    var onSilenceSkipped: ((SilenceSegment) -> Void)?
    var onProgressUpdate: ((Double, Double) -> Void)?
    var silenceStore: SilenceStore?
    let adEngine = AdSkipEngine()
    let recognizer = LiveSpeechRecognizer()
    private let fileRecognizer = LiveSpeechRecognizer()
    private var adScanTask: Task<Void, Never>?
    private var silenceScanTask: Task<Void, Never>?
    private var silenceScanGeneration = 0
    private var currentTempAudioFile: URL?
    private var lastSkippedSilence: SilenceSegment?
    private var currentSilenceKey: String?
    private var currentAudioIsLocal = false
    init() {
        if let saved = UserDefaults.standard.object(forKey: "quarto_auto_skip_ads") as? Bool {
            self.autoSkipAds = saved
        }
        if let saved = UserDefaults.standard.object(forKey: "quarto_skip_silence") as? Bool {
            self.skipSilence = saved
        }
    }

    private var currentAudioURL: URL?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var lastSync = Date.distantPast
    private var listened: Double = 0
    private var lastPlaybackTime: Double?
    private var playGeneration = 0
    private var client: ABSClient?
    private var endObserver: NSObjectProtocol?

    var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    var remainingText: String {
        Format.remaining(currentTime: currentTime, duration: duration)
    }

    func configure(client: ABSClient) {
        self.client = client
    }

    func play(
        session: PlaybackSession,
        client: ABSClient,
        coverURL: URL?,
        localFile: URL?,
        savedTime: Double = 0,
        chapters: [SessionChapter]? = nil,
        description: String? = nil,
        preDetectedAds: [AdSegment] = [],
        onProgressUpdate: ((Double, Double) -> Void)? = nil
    ) async throws {
        self.client = client
        self.onProgressUpdate = onProgressUpdate
        await closeCurrent()
        playGeneration += 1
        let generation = playGeneration
        guard let track = session.audioTracks.first else { throw ABSError.badResponse }
        let url = localFile ?? client.absoluteURL(track.contentUrl)
        guard let url else { throw ABSError.badURL }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowAirPlay]
        )
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let asset: AVURLAsset
        if localFile == nil {
            asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(client.token ?? "")"]
            ])
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        let localPlayer = AVPlayer(playerItem: item)
        localPlayer.automaticallyWaitsToMinimizeStalling = true
        self.episodeDescription = description
        let initialTime: Double = {
            if let sessionTime = session.currentTime, sessionTime > 1 {
                return sessionTime
            }
            if savedTime > 1 {
                return savedTime
            }
            return 0
        }()
        let sessionDuration = session.duration ?? track.duration ?? 0
        var allChapters: [ChapterItem] = []
        let combinedChapters = session.chapters ?? chapters
        if let combinedChapters, !combinedChapters.isEmpty {
            allChapters.append(contentsOf: combinedChapters.map {
                ChapterItem(title: $0.title, startTime: $0.start, endTime: $0.end)
            })
        }
        if let description, !description.isEmpty {
            let descChapters = parseTimestampsFromDescription(description, totalDuration: sessionDuration)
            allChapters.append(contentsOf: descChapters)
        }
        if !allChapters.isEmpty {
            setChapters(allChapters)
        }

        if initialTime > 1 {
            await localPlayer.seek(to: CMTime(seconds: initialTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        guard generation == playGeneration else {
            localPlayer.pause()
            return
        }

        self.player = localPlayer
        sessionId = session.id
        itemId = session.libraryItemId
        episodeId = session.episodeId
        title = session.displayTitle ?? track.title ?? ""
        author = session.displayAuthor ?? ""
        duration = sessionDuration
        currentTime = initialTime
        self.coverURL = coverURL
        listened = 0
        lastPlaybackTime = nil
        detectedAdSegments = preDetectedAds
        activeAdSegment = nil
        adEngine.resetStream()
        lastSkippedSilence = nil
        currentSilenceKey = session.episodeId ?? session.libraryItemId
        currentAudioIsLocal = localFile != nil
        silenceSegments = currentSilenceKey.flatMap { silenceStore?.segments(for: $0) } ?? []

        timeObserver = localPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.tick(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.lastPlaybackTime = nil
                self?.recognizer.stopListening()
            }
        }
        localPlayer.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
        remoteCommands()

        startLiveSpeechRecognition()
        currentAudioURL = url
        if autoSkipAds && detectedAdSegments.isEmpty {
            startAdScan(audioURL: url, isLocal: localFile != nil)
        }
        if skipSilence && silenceSegments.isEmpty, let key = currentSilenceKey {
            startSilenceScan(audioURL: url, isLocal: localFile != nil, key: key)
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            lastPlaybackTime = nil
            recognizer.stopListening()
            Task { await sync(force: true) }
        } else {
            lastPlaybackTime = nil
            player.playImmediately(atRate: rate)
            isPlaying = true
            startLiveSpeechRecognition()
        }
        updateNowPlaying()
    }

    func skip(seconds: Double) {
        let target = max(0, min(duration, currentTime + seconds))
        lastPlaybackTime = nil
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        adEngine.resetStream()
        lastSkippedSilence = nil
        recognizer.setTimeOffset(currentTime)
        updateNowPlaying()
    }

    func seek(fraction: Double) {
        let target = max(0, min(duration, fraction * duration))
        lastPlaybackTime = nil
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        adEngine.resetStream()
        lastSkippedSilence = nil
        recognizer.setTimeOffset(currentTime)
        updateNowPlaying()
    }
    func seek(to seconds: Double) {
        let target = max(0, min(duration, seconds))
        lastPlaybackTime = nil
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        adEngine.resetStream()
        lastSkippedSilence = nil
        recognizer.setTimeOffset(currentTime)
        updateNowPlaying()
        checkAdSegments()
    }


    func skipAd() {
        guard let activeAd = activeAdSegment ?? detectedAdSegments.first(where: { $0.startTime <= currentTime && currentTime < $0.endTime }) else {
            return
        }
        let target = min(duration, activeAd.endTime + 0.5)
        lastPlaybackTime = nil
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        lastSkippedAd = activeAd
        activeAdSegment = nil
        lastSkippedSilence = nil
        onAdSkipped?(activeAd)
        updateNowPlaying()
    }

    func setChapters(_ chapters: [ChapterItem]) {
        let ads = adEngine.detectChapterAds(chapters)
        if !ads.isEmpty {
            detectedAdSegments = ads
        }
    }

    func loadTranscriptVTT(_ vtt: String) {
        let ads = adEngine.parseAndDetectVTT(vtt)
        if !ads.isEmpty {
            detectedAdSegments = ads
        }
    }

    func feedDetectedWord(_ word: String, startTime: Double, endTime: Double) {
        if let ad = adEngine.feedWord(word, startTime: startTime, endTime: endTime) {
            if let idx = detectedAdSegments.firstIndex(where: { abs($0.startTime - ad.startTime) < 5 }) {
                detectedAdSegments[idx] = ad
            } else {
                detectedAdSegments.append(ad)
            }
            checkAdSegments()
        }
    }
    func closeCurrent() async {
        playGeneration += 1
        adScanTask?.cancel()
        adScanTask = nil
        silenceScanTask?.cancel()
        silenceScanTask = nil
        isScanningSilence = false
        fileRecognizer.cancelFileTranscription()
        if let temp = currentTempAudioFile {
            try? FileManager.default.removeItem(at: temp)
            currentTempAudioFile = nil
        }
        recognizer.stopListening()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false

        #if !os(macOS)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        #endif

        let sid = sessionId
        let c = client
        let finalCurrentTime = currentTime
        let finalDuration = duration
        let finalChunk = listened

        sessionId = nil
        itemId = nil
        episodeId = nil
        title = ""
        author = ""
        duration = 0
        currentTime = 0
        coverURL = nil
        currentAudioURL = nil
        onProgressUpdate = nil
        detectedAdSegments = []
        activeAdSegment = nil
        lastSkippedAd = nil
        silenceSegments = []
        lastSkippedSilence = nil
        currentSilenceKey = nil
        currentAudioIsLocal = false
        listened = 0
        lastPlaybackTime = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        if let sid, let c {
            lastSync = Date()
            try? await c.closeSession(id: sid, currentTime: finalCurrentTime, duration: finalDuration, timeListened: finalChunk)
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        if isPlaying, let last = lastPlaybackTime {
            let delta = seconds - last
            let maxNormalDelta = max(2.5, Double(rate) * 2.5)
            if delta > 0 && delta <= maxNormalDelta {
                listened += delta
            }
        }
        lastPlaybackTime = seconds
        currentTime = seconds
        if let itemDuration = player?.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        updateNowPlaying()
        checkAdSegments()
        checkSilenceSegments()
        if Date().timeIntervalSince(lastSync) > 10 {
            Task { await sync(force: false) }
        }
        onProgressUpdate?(currentTime, duration)
    }

    private func sync(force: Bool, close: Bool = false) async {
        guard let sessionId, !sessionId.hasPrefix("local-"), let client else { return }
        if !force && Date().timeIntervalSince(lastSync) < 10 { return }
        lastSync = Date()
        let chunk = listened
        listened = 0
        do {
            if close {
                try await client.closeSession(id: sessionId, currentTime: currentTime, duration: duration, timeListened: chunk)
            } else {
                try await client.syncSession(id: sessionId, currentTime: currentTime, duration: duration, timeListened: chunk)
            }
        } catch {
            listened += chunk
        }
    }

    private func updateNowPlaying() {
        guard player != nil, itemId != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func remoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(seconds: 30) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(seconds: -10) }
            return .success
        }
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
    }
    private func checkAdSegments() {
        guard !detectedAdSegments.isEmpty else {
            activeAdSegment = nil
            return
        }

        if let ad = detectedAdSegments.first(where: { $0.startTime <= currentTime && currentTime < $0.endTime }) {
            activeAdSegment = ad
            if autoSkipAds && (lastSkippedAd?.id != ad.id) {
                skipAd()
            }
        } else {
            activeAdSegment = nil
        }
    }

    private func checkSilenceSegments() {
        guard skipSilence, isPlaying, !silenceSegments.isEmpty else { return }
        guard let segment = SilenceDetector.segment(containing: currentTime, in: silenceSegments) else { return }
        guard lastSkippedSilence?.id != segment.id else { return }
        lastSkippedSilence = segment
        let target = min(duration, segment.endTime + 0.05)
        lastPlaybackTime = nil
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        updateNowPlaying()
        onSilenceSkipped?(segment)
    }


    private func startAdScan(audioURL: URL, isLocal: Bool) {
        adScanTask?.cancel()
        fileRecognizer.cancelFileTranscription()
        adScanTask = Task.detached(priority: .utility) { [weak self] in
            let targetFile: URL
            var tempToClean: URL? = nil
            if isLocal {
                targetFile = audioURL
            } else {
                let tempPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adscan_\(UUID().uuidString).mp3")
                do {
                    let req = await self?.client?.authorizedRequest(for: audioURL) ?? URLRequest(url: audioURL)
                    let (downloaded, response) = try await URLSession.shared.download(for: req)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        return
                    }
                    try FileManager.default.moveItem(at: downloaded, to: tempPath)
                    targetFile = tempPath
                    tempToClean = tempPath
                } catch {
                    return
                }
            }

            await MainActor.run {
                self?.currentTempAudioFile = tempToClean
            }
            _ = await self?.fileRecognizer.transcribeFile(url: targetFile) { [weak self] word, start, end in
                self?.feedDetectedWord(word, startTime: start, endTime: end)
            }

            if let temp = tempToClean {
                try? FileManager.default.removeItem(at: temp)
                await MainActor.run {
                    if self?.currentTempAudioFile == temp {
                        self?.currentTempAudioFile = nil
                    }
                }
            }
        }
    }

    private func startSilenceScan(audioURL: URL, isLocal: Bool, key: String) {
        silenceScanTask?.cancel()
        silenceScanGeneration += 1
        let generation = silenceScanGeneration
        silenceScanTask = Task.detached(priority: .utility) { [weak self] in
            let targetFile: URL
            var tempToClean: URL? = nil
            if isLocal {
                targetFile = audioURL
            } else {
                let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("silencescan_\(UUID().uuidString).mp3")
                do {
                    let req = await self?.client?.authorizedRequest(for: audioURL) ?? URLRequest(url: audioURL)
                    let (downloaded, response) = try await URLSession.shared.download(for: req)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        return
                    }
                    try FileManager.default.moveItem(at: downloaded, to: tempPath)
                    targetFile = tempPath
                    tempToClean = tempPath
                } catch {
                    return
                }
            }

            await MainActor.run {
                self?.isScanningSilence = true
            }
            let segments = (try? await SilenceDetector.analyze(url: targetFile)) ?? []
            if let temp = tempToClean {
                try? FileManager.default.removeItem(at: temp)
            }

            await MainActor.run {
                guard let self else { return }
                self.silenceStore?.save(segments, for: key)
                guard self.silenceScanGeneration == generation else { return }
                if self.skipSilence, self.currentSilenceKey == key, self.currentAudioURL == audioURL {
                    self.silenceSegments = segments
                }
                self.isScanningSilence = false
            }
        }
    }

    private func startLiveSpeechRecognition() {
        guard autoSkipAds else { return }
        Task {
            _ = await recognizer.requestAuthorization()
            guard self.isPlaying && self.autoSkipAds else { return }
            self.recognizer.startListening(timeOffset: self.currentTime) { [weak self] word, start, end in
                Task { @MainActor in
                    self?.feedDetectedWord(word, startTime: start, endTime: end)
                }
            }
        }
    }

    private func parseTimestampsFromDescription(_ text: String, totalDuration: Double) -> [ChapterItem] {
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
}
