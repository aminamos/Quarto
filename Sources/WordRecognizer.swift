import AVFoundation
import Foundation

/// Timed-word contract consumed by `AdSkipEngine.feedWord`.
/// Both on-device engines (Parakeet Ultra, Apple Speech) speak this shape,
/// so detection output is identical given identical words.
@MainActor
public protocol WordRecognizer: AnyObject, Sendable {
    var engineName: String { get }
    var isListening: Bool { get }
    var lastError: String? { get }
    func requestAuthorization() async -> Bool
    func startListening(timeOffset: Double, onWord: @escaping @MainActor (String, Double, Double) -> Void)
    func setTimeOffset(_ offset: Double)
    @discardableResult
    func transcribeFile(url: URL, onWord: @escaping @MainActor (String, Double, Double) -> Void) async -> Bool
    func cancelFileTranscription()
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer)
    func stopListening()
}

/// On-device speech engine for phone ad detection.
/// Ultra is the default: same NeMo architecture/tokenizer as
/// `parakeet-tdt-0.6b-v3` in full precision, and it runs without Photon.
public enum OnDeviceSpeechEngine: String, CaseIterable, Identifiable, Sendable {
    case parakeetUltra = "parakeet-ultra"
    case appleSpeech = "apple-speech"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .parakeetUltra: return "Parakeet Ultra"
        case .appleSpeech: return "Apple Speech"
        }
    }

    private static let defaultsKey = "quarto_ondevice_engine"

    public static var stored: OnDeviceSpeechEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let engine = OnDeviceSpeechEngine(rawValue: raw) else {
                return .parakeetUltra
            }
            return engine
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

@MainActor
public func makeOnDeviceRecognizer() -> any WordRecognizer {
    if OnDeviceSpeechEngine.stored == .appleSpeech {
        return LiveSpeechRecognizer()
    }
    return UltraSpeechRecognizer()
}

/// Parakeet Ultra on-device recognizer (sherpa nemo_transducer, no Photon,
/// no Apple Speech prompt). Weights are bundled with the app.
@MainActor
public final class UltraSpeechRecognizer: ObservableObject, WordRecognizer, Sendable {
    public let engineName = "Parakeet Ultra"
    public private(set) var isListening = false
    public private(set) var lastError: String?

    private let modelDirectory: URL?
    private var transcriber: UltraTranscriber?
    private let audioEngine = AVAudioEngine()
    private var onWordDetected: (@MainActor (String, Double, Double) -> Void)?
    private var timeOffset: Double = 0
    private nonisolated(unsafe) let mic = MicBuffer()

    public init(modelDirectory: URL? = nil) {
        if let modelDirectory {
            self.modelDirectory = modelDirectory
        } else {
            self.modelDirectory = UltraModelFiles.bundled()?.directory
        }
    }

    private var files: UltraModelFiles? {
        modelDirectory.map(UltraModelFiles.init(directory:))
    }

    /// Weights present when encoder + decoder + joiner + vocab are on disk.
    public static func modelAvailable(at directory: URL) -> Bool {
        UltraModelFiles(directory: directory).isComplete
    }

    public var isModelAvailable: Bool {
        modelDirectory.map { Self.modelAvailable(at: $0) } ?? false
    }

    /// Microphone only. Never touches the Speech framework: no Apple prompt.
    public func requestAuthorization() async -> Bool {
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

    public func startListening(timeOffset: Double = 0, onWord: @escaping @MainActor (String, Double, Double) -> Void) {
        stopListening()
        guard let files, files.isComplete else {
            lastError = "Parakeet Ultra weights are not installed."
            return
        }
        lastError = nil
        self.timeOffset = timeOffset
        self.onWordDetected = onWord
        mic.reset(converter: nil)

        #if !os(macOS)
        do {
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
            guard let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                channels: 1, interleaved: false
            ) else { return }
            mic.reset(converter: AVAudioConverter(from: inputFormat, to: outFormat))
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            lastError = "Microphone tap failed: \(error.localizedDescription)"
        }
        #endif
    }

    private nonisolated func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let (segment, base) = mic.append(buffer: buffer) else { return }
        Task { [weak self] in
            await self?.decodeLiveSegment(segment, base: base)
        }
    }

    private func decodeLiveSegment(_ segment: [Float], base: Double) async {
        guard let files, files.isComplete else { return }
        if transcriber == nil {
            transcriber = UltraTranscriber(files: files)
        }
        guard let words = await transcriber?.transcribe(samples: segment) else { return }
        for word in words {
            let start = timeOffset + base + word.startTime
            onWordDetected?(word.text, start, timeOffset + base + word.endTime)
        }
    }

    public func setTimeOffset(_ offset: Double) {
        timeOffset = offset
    }

    @discardableResult
    public func transcribeFile(url: URL, onWord: @escaping @MainActor (String, Double, Double) -> Void) async -> Bool {
        if Task.isCancelled { return false }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Audio file not found."
            return false
        }
        guard let files, files.isComplete else {
            lastError = "Parakeet Ultra weights are not installed."
            return false
        }
        lastError = nil
        let samples: [Float]
        do {
            samples = try await UltraAudio.readMono16k(url: url)
        } catch is CancellationError {
            return false
        } catch {
            lastError = "Could not read audio: \(error.localizedDescription)"
            return false
        }
        if transcriber == nil {
            transcriber = UltraTranscriber(files: files)
        }
        let words = await transcriber?.transcribe(samples: samples) ?? []
        if Task.isCancelled { return false }
        for word in words {
            onWord(word.text, word.startTime, word.endTime)
        }
        return true
    }

    public func cancelFileTranscription() {
        Task { [weak self] in
            await self?.transcriber?.cancel()
        }
    }

    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {}

    public func stopListening() {
        #if !os(macOS)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isListening {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        #endif
        isListening = false
        let (leftover, base) = mic.takeLeftover()
        if leftover.count >= 2 * 16000 {
            Task { [weak self] in
                await self?.decodeLiveSegment(leftover, base: base)
            }
        }
        onWordDetected = nil
    }
}

/// Lock-guarded mic accumulation for the realtime tap (never touches actor state).
private final class MicBuffer: @unchecked Sendable {
    private static let segmentSeconds = 30.0
    private let lock = NSLock()
    private var pending: [Float] = []
    private var converter: AVAudioConverter?
    private var decoded = 0.0

    func reset(converter: AVAudioConverter?) {
        lock.lock()
        defer { lock.unlock() }
        self.converter = converter
        pending.removeAll(keepingCapacity: true)
        decoded = 0
    }

    /// Convert to 16 kHz mono, accumulate, and carve a segment when full.
    func append(buffer: AVAudioPCMBuffer) -> (segment: [Float], base: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let converter else { return nil }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000,
            channels: 1, interleaved: false
        ) else { return nil }
        let frames = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / max(1.0, buffer.format.sampleRate)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames) else { return nil }
        do {
            try converter.convert(to: out, from: buffer)
        } catch {
            return nil
        }
        guard let floats = out.floatChannelData?[0] else { return nil }
        pending.append(contentsOf: UnsafeBufferPointer(start: floats, count: Int(out.frameLength)))
        let window = Int(Self.segmentSeconds * 16000.0)
        guard pending.count >= window else { return nil }
        let segment = Array(pending.prefix(window))
        pending.removeFirst(window)
        let base = decoded
        decoded += Self.segmentSeconds
        return (segment, base)
    }

    func takeLeftover() -> (samples: [Float], base: Double) {
        lock.lock()
        defer { lock.unlock() }
        let left = pending
        pending.removeAll()
        let base = decoded
        decoded += Double(left.count) / 16000.0
        return (left, base)
    }
}
