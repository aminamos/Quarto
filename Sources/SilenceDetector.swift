import AVFoundation
import Foundation

public struct SilenceSegment: Codable, Hashable, Identifiable, Sendable {
    public let startTime: Double
    public let endTime: Double

    public init(startTime: Double, endTime: Double) {
        self.startTime = startTime
        self.endTime = endTime
    }

    public var id: String { "\(startTime):\(endTime)" }
}

public enum SilenceDetector {
    public struct Options: Sendable {
        public var thresholdDB: Float
        public var minSilence: Double
        public var padding: Double
        public var windowSeconds: Double
        public var hopSeconds: Double

        public init(
            thresholdDB: Float = -45,
            minSilence: Double = 0.75,
            padding: Double = 0.2,
            windowSeconds: Double = 0.05,
            hopSeconds: Double = 0.025
        ) {
            self.thresholdDB = thresholdDB
            self.minSilence = minSilence
            self.padding = padding
            self.windowSeconds = windowSeconds
            self.hopSeconds = hopSeconds
        }
    }

    public static func segments(
        decibels: [Float],
        secondsPerWindow: Double,
        options: Options = Options()
    ) -> [SilenceSegment] {
        guard !decibels.isEmpty, secondsPerWindow > 0 else { return [] }

        var runs: [(start: Double, end: Double)] = []
        var runStart: Int?
        for (index, level) in decibels.enumerated() {
            if level < options.thresholdDB {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append((Double(start) * secondsPerWindow, Double(index) * secondsPerWindow))
                runStart = nil
            }
        }
        if let start = runStart {
            runs.append((Double(start) * secondsPerWindow, Double(decibels.count) * secondsPerWindow))
        }

        return runs.compactMap { run in
            let start = run.start + options.padding
            let end = run.end - options.padding
            guard end - start >= options.minSilence else { return nil }
            return SilenceSegment(startTime: start, endTime: end)
        }
    }

    public static func segment(containing time: Double, in segments: [SilenceSegment]) -> SilenceSegment? {
        segments.first { $0.startTime <= time && time < $0.endTime }
    }

    public static func decibels(samples: [Float], windowLength: Int, hop: Int) -> [Float] {
        guard windowLength > 0, hop > 0, samples.count >= windowLength else { return [] }
        var levels: [Float] = []
        var index = 0
        while index + windowLength <= samples.count {
            var sum: Float = 0
            for offset in index..<(index + windowLength) {
                let sample = samples[offset]
                sum += sample * sample
            }
            let rms = sqrtf(sum / Float(windowLength))
            levels.append(20 * log10f(max(rms, 1e-6)))
            index += hop
        }
        return levels
    }

    public static func analyze(url: URL, options: Options = Options()) async throws -> [SilenceSegment] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return [] }

        let sampleRate = 16000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ABSError.badResponse }

        let windowLength = max(1, Int(sampleRate * options.windowSeconds))
        let hop = max(1, Int(sampleRate * options.hopSeconds))
        var buffer: [Float] = []
        var consumed = 0
        var levels: [Float] = []

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            guard status == kCMBlockBufferNoErr, let pointer, length > 0 else { continue }

            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                buffer.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }

            while buffer.count - consumed >= windowLength {
                var sum: Float = 0
                for offset in consumed..<(consumed + windowLength) {
                    let sample = buffer[offset]
                    sum += sample * sample
                }
                let rms = sqrtf(sum / Float(windowLength))
                levels.append(20 * log10f(max(rms, 1e-6)))
                consumed += hop
            }

            if consumed > hop * 128 {
                buffer.removeFirst(consumed)
                consumed = 0
            }
        }

        if reader.status == .failed {
            throw reader.error ?? ABSError.badResponse
        }

        return segments(decibels: levels, secondsPerWindow: Double(hop) / sampleRate, options: options)
    }
}
