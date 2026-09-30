import AVFoundation
import Foundation
import Testing
@testable import Quarto

@MainActor
final class FakeWordRecognizer: WordRecognizer, Sendable {
    let engineName = "Fake"
    private(set) var isListening = false
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
}
