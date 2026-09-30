import AVFoundation
import Foundation
import SherpaOnnx

/// One decoded word with audio-relative timing.
public struct UltraWord: Sendable {
    public let text: String
    public let startTime: Double
    public let endTime: Double

    public init(text: String, startTime: Double, endTime: Double) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Locations of the bundled Ultra ONNX files (sherpa nemo_transducer layout).
public struct UltraModelFiles: Sendable {
    public let directory: URL

    public static let encoder = "encoder.int8.onnx"
    public static let decoder = "decoder.int8.onnx"
    public static let joiner = "joiner.int8.onnx"
    public static let tokens = "tokens.txt"

    public init(directory: URL) {
        self.directory = directory
    }

    /// Bundled weights installed with the app (folder reference `parakeet-ultra`).
    public static func bundled() -> UltraModelFiles? {
        guard let dir = Bundle.main.url(forResource: "parakeet-ultra", withExtension: nil) else {
            return Bundle.main.resourceURL.map { UltraModelFiles(directory: $0.appendingPathComponent("parakeet-ultra", isDirectory: true)) }
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return UltraModelFiles(directory: dir)
        }
        return nil
    }

    public var isComplete: Bool {
        let fm = FileManager.default
        return [Self.encoder, Self.decoder, Self.joiner, Self.tokens].allSatisfy {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    fileprivate var encoderURL: URL { directory.appendingPathComponent(Self.encoder) }
    fileprivate var decoderURL: URL { directory.appendingPathComponent(Self.decoder) }
    fileprivate var joinerURL: URL { directory.appendingPathComponent(Self.joiner) }
    fileprivate var tokensURL: URL { directory.appendingPathComponent(Self.tokens) }
}

/// Serial owner of the sherpa offline recognizer (600 MB model, loaded once).
public actor UltraTranscriber {
    public static let sampleRate = 16000
    /// Sequential decode window; bounds peak memory on hour-long episodes.
    public static let chunkSeconds = 300.0

    private let files: UltraModelFiles
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var cancelled = false

    public init(files: UltraModelFiles) {
        self.files = files
    }

    public func cancel() {
        cancelled = true
    }

    private func ensureRecognizer() -> Bool {
        if recognizer != nil { return true }
        guard files.isComplete else { return false }
        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: files.encoderURL.path,
            decoder: files.decoderURL.path,
            joiner: files.joinerURL.path
        )
        let threads = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        let model = sherpaOnnxOfflineModelConfig(
            tokens: files.tokensURL.path,
            transducer: transducer,
            numThreads: threads,
            modelType: "nemo_transducer"
        )
        let feat = sherpaOnnxFeatureConfig(sampleRate: Self.sampleRate, featureDim: 128)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: feat, modelConfig: model)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        return true
    }

    /// Decode 16 kHz mono samples, chunked for long audio. Times are audio-relative.
    public func transcribe(samples: [Float]) -> [UltraWord] {
        cancelled = false
        guard ensureRecognizer() else { return [] }
        var out: [UltraWord] = []
        for range in Self.chunkBounds(sampleCount: samples.count, sampleRate: Self.sampleRate, chunkSeconds: Self.chunkSeconds) {
            if cancelled || Task.isCancelled { break }
            let offset = Double(range.lowerBound) / Double(Self.sampleRate)
            out.append(contentsOf: transcribeChunk(Array(samples[range]), offset: offset))
        }
        return out
    }

    private func transcribeChunk(_ chunk: [Float], offset: Double) -> [UltraWord] {
        guard let recognizer, !chunk.isEmpty else { return [] }
        let result = recognizer.decode(samples: chunk, sampleRate: Self.sampleRate)
        let words = Self.extractWords(from: result)
        guard offset != 0 else { return words }
        return words.map { UltraWord(text: $0.text, startTime: $0.startTime + offset, endTime: $0.endTime + offset) }
    }

    /// Read per-token strings/times from the C result (the Swift wrapper
    /// surfaces text only) and group BPE pieces into words.
    static func extractWords(from result: SherpaOnnxOfflineRecognitionResult) -> [UltraWord] {
        let pointee = result.result.pointee
        let count = Int(pointee.count)
        guard count > 0, let tokenPtrs = pointee.tokens_arr, let times = pointee.timestamps else {
            return []
        }
        let durations = pointee.durations
        var tokens: [String] = []
        var starts: [Float] = []
        var durs: [Float] = []
        tokens.reserveCapacity(count)
        for i in 0..<count {
            guard let cstr = tokenPtrs[i] else { continue }
            tokens.append(String(cString: cstr))
            starts.append(times[i])
            durs.append(durations?[i] ?? 0)
        }
        return align(tokens: tokens, starts: starts, durations: durs)
    }

    /// Group BPE pieces into timed words. sherpa emits a plain space prefix
    /// for word starts (▁ accepted too, matching the vocab file on disk).
    static func align(tokens: [String], starts: [Float], durations: [Float]) -> [UltraWord] {
        var words: [UltraWord] = []
        var current = ""
        var wordStart = 0.0
        var wordEnd = 0.0
        func flush() {
            if !current.isEmpty {
                words.append(UltraWord(text: current, startTime: wordStart, endTime: max(wordEnd, wordStart + 0.01)))
                current = ""
            }
        }
        for i in tokens.indices {
            var piece = tokens[i]
            if piece.hasPrefix("<"), piece.hasSuffix(">"), piece.count > 2 { continue }
            let start = Double(starts[i])
            let dur = i < durations.count ? Double(durations[i]) : 0
            let end = dur > 0 ? start + dur : start + 0.08
            if piece.hasPrefix(" ") || piece.hasPrefix("▁") {
                flush()
                while piece.hasPrefix(" ") || piece.hasPrefix("▁") { piece.removeFirst() }
                current = piece
                wordStart = start
                wordEnd = end
            } else {
                if current.isEmpty { wordStart = start }
                current += piece
                wordEnd = end
            }
        }
        flush()
        return words
    }

    /// Sequential non-overlapping sample ranges covering the audio.
    static func chunkBounds(sampleCount: Int, sampleRate: Int, chunkSeconds: Double) -> [Range<Int>] {
        guard sampleCount > 0, sampleRate > 0, chunkSeconds > 0 else { return [] }
        let chunk = max(1, Int(chunkSeconds * Double(sampleRate)))
        return stride(from: 0, to: sampleCount, by: chunk).map { $0 ..< min($0 + chunk, sampleCount) }
    }
}

/// 16 kHz mono float32 file reading (same AVFoundation path as SilenceDetector).
enum UltraAudio {
    static func readMono16k(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ABSError.badResponse }
        var samples: [Float] = []
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            )
            guard status == kCMBlockBufferNoErr, let pointer, length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        if reader.status == .failed {
            throw reader.error ?? ABSError.badResponse
        }
        return samples
    }
}
