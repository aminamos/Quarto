import Foundation
import QuartoAdSkip

public struct AdSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(startTime):\(endTime)" }
    public let startTime: Double
    public let endTime: Double
    public let confidence: Float
    public let reason: String

    public init(startTime: Double, endTime: Double, confidence: Float, reason: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.reason = reason
    }
}

public struct ChapterItem: Sendable {
    public let title: String
    public let startTime: Double
    public let endTime: Double

    public init(title: String, startTime: Double, endTime: Double) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }
}

public final class AdSkipEngine: @unchecked Sendable {
    private var enginePtr: OpaquePointer?
    private let lock = NSLock()

    public init() {
        self.enginePtr = adskip_engine_new()
        if enginePtr == nil {
            // Framework init failure (SIGABRT / bad pointer on device): fall back to no-op
        }
    }

    deinit {
        if let enginePtr {
            adskip_engine_free(enginePtr)
        }
    }

    /// Fast test if a single chapter title is an advertisement or sponsor break
    public func isAdChapter(title: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let enginePtr else { return false }
        return title.withCString { adskip_is_ad_chapter(enginePtr, $0) }
    }

    /// Batch inspect chapters and return detected ad segments
    public func detectChapterAds(_ chapters: [ChapterItem]) -> [AdSegment] {
        lock.lock()
        defer { lock.unlock() }
        guard let enginePtr, !chapters.isEmpty else { return [] }

        // Prepare CChapter array
        var cChapters: [CChapter] = []
        var cStrings: [UnsafeMutablePointer<CChar>?] = []

        for ch in chapters {
            let cs = strdup(ch.title)
            cStrings.append(cs)
            cChapters.append(CChapter(title: cs, start_time: ch.startTime, end_time: ch.endTime))
        }

        defer {
            for cs in cStrings {
                if let cs { free(cs) }
            }
        }

        let list = cChapters.withUnsafeBufferPointer { buf in
            adskip_detect_chapter_ads(enginePtr, buf.baseAddress, buf.count)
        }

        defer { adskip_segment_list_free(list) }

        return convertSegmentList(list)
    }

    /// Parse WebVTT transcript file and return detected ad segments
    public func parseAndDetectVTT(_ vtt: String) -> [AdSegment] {
        lock.lock()
        defer { lock.unlock() }
        guard let enginePtr else { return [] }

        let list = vtt.withCString { cStr in
            adskip_parse_vtt(enginePtr, cStr)
        }
        defer { adskip_segment_list_free(list) }

        return convertSegmentList(list)
    }

    /// Parse SRT transcript file and return detected ad segments
    public func parseAndDetectSRT(_ srt: String) -> [AdSegment] {
        lock.lock()
        defer { lock.unlock() }
        guard let enginePtr else { return [] }

        let list = srt.withCString { cStr in
            adskip_parse_srt(enginePtr, cStr)
        }
        defer { adskip_segment_list_free(list) }

        return convertSegmentList(list)
    }

    /// Feed a real-time word token from on-device speech recognition
    public func feedWord(_ word: String, startTime: Double, endTime: Double) -> AdSegment? {
        lock.lock()
        defer { lock.unlock() }
        guard let enginePtr else { return nil }

        let normalizedWord = Self.normalizeSpeechWord(word)
        guard !normalizedWord.isEmpty else { return nil }
        var cSeg = CAdSegment()
        let matched = normalizedWord.withCString { cWord in
            adskip_feed_word(enginePtr, cWord, startTime, endTime, &cSeg)
        }

        if matched {
            defer { adskip_segment_free(&cSeg) }
            let reason = cSeg.reason != nil ? String(cString: cSeg.reason) : ""
            return AdSegment(
                startTime: cSeg.start_time,
                endTime: cSeg.end_time,
                confidence: cSeg.confidence,
                reason: reason
            )
        }
        return nil
    }

    /// Reset stream tokens (e.g. when changing track or seeking)
    public func resetStream() {
        lock.lock()
        defer { lock.unlock() }
        guard let enginePtr else { return }
        adskip_reset_stream(enginePtr)
    }

    private func convertSegmentList(_ list: CAdSegmentList) -> [AdSegment] {
        guard let ptr = list.segments, list.count > 0 else { return [] }
        var result: [AdSegment] = []
        result.reserveCapacity(list.count)

        for i in 0..<list.count {
            let seg = ptr[i]
            let reason = seg.reason != nil ? String(cString: seg.reason) : ""
            result.append(AdSegment(
                startTime: seg.start_time,
                endTime: seg.end_time,
                confidence: seg.confidence,
                reason: reason
            ))
        }
        return result
    }

    private static func normalizeSpeechWord(_ word: String) -> String {
        word
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201B}", with: "'")
            .replacingOccurrences(of: "\u{FF07}", with: "'")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}
