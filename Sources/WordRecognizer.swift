import Foundation
import AVFoundation

/// Timed-word contract consumed by `AdSkipEngine.feedWord`.
/// Both on-device engines (Parakeet Ultra, Apple Speech) speak this shape,
/// so detection output is identical given identical words.
@MainActor
public protocol WordRecognizer: AnyObject, Sendable {
    var engineName: String { get }
    var isListening: Bool { get }
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
/// Apple Speech remains as automatic fallback until Ultra weights land.
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
    if OnDeviceSpeechEngine.stored == .parakeetUltra,
       UltraSpeechRecognizer.modelAvailable() {
        return UltraSpeechRecognizer()
    }
    return LiveSpeechRecognizer()
}

/// Parakeet Ultra on-device recognizer (NeMo-compatible, no Photon).
///
/// Weights are resolved from Application Support/Quarto/parakeet-ultra and are
/// NOT bundled: the full-precision 0.6B checkpoint is far too large for the
/// IPA, so it ships as a first-run download. Until weights plus a CoreML/ONNX
/// runtime land, every entry point fails closed (false / no-op) and the
/// factory routes to Apple Speech, so detection never silently degrades.
@MainActor
public final class UltraSpeechRecognizer: ObservableObject, WordRecognizer, Sendable {
    public let engineName = "Parakeet Ultra"
    public private(set) var isListening = false
    public private(set) var lastError: String?
    private let modelDirectory: URL

    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory ?? Self.defaultModelDirectory()
    }

    public static func defaultModelDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quarto/parakeet-ultra", isDirectory: true)
    }

    /// Weights present when encoder + decoder + joint + vocab are on disk.
    public static func modelAvailable(at directory: URL? = nil) -> Bool {
        let dir = directory ?? defaultModelDirectory()
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("encoder.mlmodelc").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("decoder.mlmodelc").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("joint.mlmodelc").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
    }

    public var isModelAvailable: Bool { Self.modelAvailable(at: modelDirectory) }

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
        guard isModelAvailable else {
            lastError = "Parakeet Ultra weights are not installed."
            return
        }
        lastError = "Parakeet Ultra runtime is not bundled yet."
    }

    public func setTimeOffset(_ offset: Double) {}

    @discardableResult
    public func transcribeFile(url: URL, onWord: @escaping @MainActor (String, Double, Double) -> Void) async -> Bool {
        if Task.isCancelled { return false }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Audio file not found."
            return false
        }
        guard isModelAvailable else {
            lastError = "Parakeet Ultra weights are not installed."
            return false
        }
        lastError = "Parakeet Ultra runtime is not bundled yet."
        return false
    }

    public func cancelFileTranscription() {}

    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {}

    public func stopListening() {
        isListening = false
    }
}
