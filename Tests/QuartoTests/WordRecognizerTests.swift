import AVFoundation
import Foundation
import Testing
@testable import Quarto

@MainActor
final class FakeWordRecognizer: WordRecognizer, Sendable {
    let engineName = "Fake"
    private(set) var isListening = false
    var lastError: String? { nil }
    var script: [(String, Double, Double)] = []
    var fileResult = true

    func requestAuthorization() async -> Bool { true }

    func startListening(timeOffset: Double = 0, onWord: @escaping @MainActor (String, Double, Double) -> Void) {
        isListening = true
        for (word, start, end) in script {
            onWord(word, start + timeOffset, end + timeOffset)
        }
    }

    func setTimeOffset(_ offset: Double) {}

    @discardableResult
    func transcribeFile(url: URL, onWord: @escaping @MainActor (String, Double, Double) -> Void) async -> Bool {
        guard fileResult else { return false }
        for (word, start, end) in script {
            onWord(word, start, end)
        }
        return true
    }

    func cancelFileTranscription() {}
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
    func stopListening() { isListening = false }
}

@MainActor
struct WordRecognizerTests {
    @Test func anyEngineWordsFeedAdDetection() async {
        let engine = AdSkipEngine()
        let recognizer: any WordRecognizer = FakeWordRecognizer()
        (recognizer as! FakeWordRecognizer).script = [
            ("now", 10.0, 10.4),
            ("here's", 10.5, 10.9),
            ("some", 11.0, 11.4),
            ("ads", 11.5, 11.9),
        ]
        engine.resetStream()
        var found: [AdSegment] = []
        let ok = await recognizer.transcribeFile(url: URL(fileURLWithPath: "/tmp/words.vtt")) { word, start, end in
            if let ad = engine.feedWord(word, startTime: start, endTime: end) {
                found.append(ad)
            }
        }
        #expect(ok == true)
        #expect(found.count == 1)
        #expect(found.first?.startTime == 10.0)
    }

    @Test func ultraFailsClosedWithoutWeights() async {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-missing-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let recognizer = UltraSpeechRecognizer(modelDirectory: empty)
        #expect(recognizer.engineName == "Parakeet Ultra")
        #expect(recognizer.isModelAvailable == false)
        #expect(UltraSpeechRecognizer.modelAvailable(at: empty) == false)

        var words = 0
        let audio = empty.appendingPathComponent("clip.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x49, 0x44, 0x33]))
        let ok = await recognizer.transcribeFile(url: audio) { _, _, _ in words += 1 }
        #expect(ok == false)
        #expect(words == 0)
        #expect(recognizer.lastError != nil)

        recognizer.startListening { _, _, _ in words += 1 }
        #expect(recognizer.isListening == false)
        #expect(words == 0)
    }

    @Test func ultraRejectsMissingFile() async {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-nofile-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let recognizer = UltraSpeechRecognizer(modelDirectory: empty)
        let ok = await recognizer.transcribeFile(url: empty.appendingPathComponent("gone.mp3")) { _, _, _ in }
        #expect(ok == false)
    }

    @Test func engineCatalogAndFactory() {
        #expect(OnDeviceSpeechEngine(rawValue: "parakeet-ultra") == .parakeetUltra)
        #expect(OnDeviceSpeechEngine.parakeetUltra.displayName == "Parakeet Ultra")
        #expect(OnDeviceSpeechEngine.appleSpeech.displayName == "Apple Speech")
        let recognizer = makeOnDeviceRecognizer()
        #expect(!recognizer.engineName.isEmpty)
        #expect(recognizer is LiveSpeechRecognizer || recognizer is UltraSpeechRecognizer)
    }

    @Test func liveRecognizerConforms() {
        let recognizer: any WordRecognizer = LiveSpeechRecognizer()
        #expect(recognizer.engineName == "Apple Speech")
    }

    @Test func ultraNeverFallsBackToApple() {
        let saved = OnDeviceSpeechEngine.stored
        defer { OnDeviceSpeechEngine.stored = saved }
        OnDeviceSpeechEngine.stored = .parakeetUltra
        #expect(makeOnDeviceRecognizer() is UltraSpeechRecognizer)
        OnDeviceSpeechEngine.stored = .appleSpeech
        #expect(makeOnDeviceRecognizer() is LiveSpeechRecognizer)
    }
}

struct UltraAlignmentTests {
    @Test func groupsBpePiecesIntoTimedWords() {
        // Real sherpa output uses plain-space word markers.
        let words = UltraTranscriber.align(
            tokens: [" Hel", "lo", " world"],
            starts: [0.0, 0.08, 0.16],
            durations: [0.08, 0.08, 0.24]
        )
        #expect(words.count == 2)
        #expect(words[0].text == "Hello")
        #expect(words[0].startTime == 0.0)
        #expect(words[0].endTime == 0.16)
        #expect(words[1].text == "world")
        #expect(words[1].startTime == 0.16)
        #expect(words[1].endTime == 0.40)
        // Vocab-file ▁ markers group identically.
        let alt = UltraTranscriber.align(
            tokens: ["▁Hel", "lo"],
            starts: [1.0, 1.08],
            durations: [0.08, 0.08]
        )
        #expect(alt.map(\.text) == ["Hello"])
        #expect(alt[0].startTime == 1.0)
    }

    @Test func skipsSpecialTokensAndFallsBackWithoutDurations() {
        let words = UltraTranscriber.align(
            tokens: ["<blk>", "▁go", "▁", "▁now"],
            starts: [0.0, 0.5, 0.6, 0.7],
            durations: []
        )
        #expect(words.map(\.text) == ["go", "now"])
        #expect(words[0].startTime == 0.5)
        #expect(words[0].endTime > words[0].startTime)
        #expect(words[1].startTime == 0.7)
    }

    @Test func emptyInputYieldsNoWords() {
        #expect(UltraTranscriber.align(tokens: [], starts: [], durations: []).isEmpty)
    }

    @Test func chunkBoundsCoverAudioSequentially() {
        let bounds = UltraTranscriber.chunkBounds(sampleCount: 70 * 16000, sampleRate: 16000, chunkSeconds: 30)
        #expect(bounds.count == 3)
        #expect(bounds[0] == 0..<(30 * 16000))
        #expect(bounds[1] == (30 * 16000)..<(60 * 16000))
        #expect(bounds[2] == (60 * 16000)..<(70 * 16000))
        #expect(UltraTranscriber.chunkBounds(sampleCount: 0, sampleRate: 16000, chunkSeconds: 30).isEmpty)
    }

    @Test func bundledLayoutProbe() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-layout-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(UltraModelFiles(directory: dir).isComplete == false)
        for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([0]))
        }
        #expect(UltraModelFiles(directory: dir).isComplete == true)
    }
}
