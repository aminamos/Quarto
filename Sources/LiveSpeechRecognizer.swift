import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

@MainActor
public final class LiveSpeechRecognizer: ObservableObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var fileRecognitionTask: SFSpeechRecognitionTask?
    private var currentFileRecognitionState: FileRecognitionState?
    private let audioEngine = AVAudioEngine()
    private var onWordDetected: (@MainActor (String, Double, Double) -> Void)?
    private var timeOffset: Double = 0
    private(set) var isListening = false

    public init() {}

    public nonisolated static func requestAuthorization() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }

        #if !os(macOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { @Sendable granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return true
        #endif
    }

    public func requestAuthorization() async -> Bool {
        await Self.requestAuthorization()
    }

    public func startListening(timeOffset: Double = 0, onWord: @escaping @MainActor (String, Double, Double) -> Void) {
        stopListening()
        self.timeOffset = timeOffset
        self.onWordDetected = onWord

        guard let speechRecognizer, speechRecognizer.isAvailable else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        let offset = self.timeOffset
        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let result else { return }
            if let lastWord = result.bestTranscription.segments.last {
                let text = lastWord.substring
                let start = offset + lastWord.timestamp
                let duration = lastWord.duration
                Task { @MainActor [weak self] in
                    self?.onWordDetected?(text, start, start + duration)
                }
            }
        }

        #if !os(macOS)
        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else { return }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            // Speech recognition audio tap failed gracefully
        }
        #endif
    }

    public func setTimeOffset(_ offset: Double) {
        self.timeOffset = offset
    }

    @discardableResult
    public func transcribeFile(
        url: URL,
        onWord: @escaping @MainActor (String, Double, Double) -> Void
    ) async -> Bool {
        if Task.isCancelled { return false }
        currentFileRecognitionState?.cancel()
        currentFileRecognitionState = nil
        fileRecognitionTask?.cancel()
        fileRecognitionTask = nil

        guard let speechRecognizer, speechRecognizer.isAvailable else { return false }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let state = FileRecognitionState()
        self.currentFileRecognitionState = state

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.setContinuation(continuation)
                guard !Task.isCancelled else {
                    state.cancel()
                    return
                }

                let task = speechRecognizer.recognitionTask(with: request) { @Sendable [weak state] result, error in
                    guard let state else { return }
                    let isFinal = result?.isFinal == true
                    let words = result.map { state.processSegments($0.bestTranscription.segments) } ?? []
                    Task { @MainActor in
                        for (text, start, end) in words {
                            onWord(text, start, end)
                        }
                        if isFinal {
                            state.resume(returning: true)
                        } else if error != nil {
                            state.resume(returning: false)
                        }
                    }
                }
                self.fileRecognitionTask = task
                state.setTask(task)

                let watchdog = Task.detached(priority: .utility) { [weak state] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard !Task.isCancelled, let state else { break }
                        let (isFinished, isStalled) = state.checkStallOrFinished(timeout: 300)
                        if isFinished { break }
                        if isStalled {
                            state.cancel()
                            break
                        }
                    }
                }
                state.setWatchdogTask(watchdog)
            }
        } onCancel: {
            state.cancel()
        }
    }

    public func cancelFileTranscription() {
        currentFileRecognitionState?.cancel()
        currentFileRecognitionState = nil
        fileRecognitionTask?.cancel()
        fileRecognitionTask = nil
    }

    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    public func stopListening() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        #if !os(macOS)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isListening {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        #endif
        isListening = false
        onWordDetected = nil
    }

    deinit {
        recognitionTask?.cancel()
        fileRecognitionTask?.cancel()
        currentFileRecognitionState?.cancel()
    }

    private final class FileRecognitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var lastProcessedIndex = 0
        private var isCompleted = false
        private weak var task: SFSpeechRecognitionTask?
        private var lastActivityTime = Date()
        private var watchdogTask: Task<Void, Never>?

        func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            defer { lock.unlock() }
            if isCompleted {
                continuation.resume(returning: false)
            } else {
                self.continuation = continuation
            }
        }

        func setTask(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
            if isCompleted {
                task.cancel()
            }
        }
        func setWatchdogTask(_ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.watchdogTask = task
            if isCompleted {
                task.cancel()
            }
        }

        func checkStallOrFinished(timeout: TimeInterval) -> (isFinished: Bool, isStalled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isCompleted { return (true, false) }
            let stalled = Date().timeIntervalSince(lastActivityTime) > timeout
            return (false, stalled)
        }

        func cancel() {
            lock.lock()
            let taskToCancel = task
            let cont = continuation
            let watchdog = watchdogTask
            watchdogTask = nil
            continuation = nil
            let shouldResume = !isCompleted
            isCompleted = true
            lock.unlock()

            watchdog?.cancel()
            taskToCancel?.cancel()
            if shouldResume {
                cont?.resume(returning: false)
            }
        }

        func resume(returning value: Bool) {
            lock.lock()
            let cont = continuation
            let watchdog = watchdogTask
            watchdogTask = nil
            continuation = nil
            let shouldResume = !isCompleted
            isCompleted = true
            lock.unlock()

            watchdog?.cancel()
            if shouldResume {
                cont?.resume(returning: value)
            }
        }

        func processSegments(_ segments: [SFTranscriptionSegment]) -> [(String, Double, Double)] {
            lock.lock()
            lastActivityTime = Date()
            let count = segments.count
            guard count > lastProcessedIndex else {
                lock.unlock()
                return []
            }
            let newSegments = Array(segments[lastProcessedIndex..<count])
            lastProcessedIndex = count
            lock.unlock()

            return newSegments.map { segment in
                (
                    segment.substring,
                    segment.timestamp,
                    segment.timestamp + segment.duration
                )
            }
        }
    }
}
