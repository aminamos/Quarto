import Foundation

/// One ad break inside a shareable list.
public struct SharedAdSegment: Codable, Sendable, Hashable {
    public let start: Double
    public let end: Double
    public let confidence: Float
    public let reason: String

    public init(start: Double, end: Double, confidence: Float, reason: String) {
        self.start = start
        self.end = end
        self.confidence = confidence
        self.reason = reason
    }

    init(_ segment: AdSegment) {
        self.start = segment.startTime
        self.end = segment.endTime
        self.confidence = segment.confidence
        self.reason = segment.reason
    }

    func toAdSegment() -> AdSegment {
        AdSegment(startTime: start, endTime: end, confidence: confidence, reason: reason)
    }
}

/// Versioned, shareable ad-break list for a single episode.
///
/// Format `"quarto-ad-list"` v1. Export on one device, import on another —
/// listeners of the same show share detected breaks with no server required.
public struct SharedAdList: Codable, Sendable {
    public static let format = "quarto-ad-list"
    public static let version = 1

    public let format: String
    public let version: Int
    public let app: String
    public let exportedAt: Date
    public let showTitle: String?
    public let episodeTitle: String
    public let episodeId: String?
    public let duration: Double?
    public let segments: [SharedAdSegment]

    public init(
        showTitle: String?,
        episodeTitle: String,
        episodeId: String?,
        duration: Double?,
        segments: [AdSegment]
    ) {
        self.format = Self.format
        self.version = Self.version
        self.app = "Quarto"
        self.exportedAt = Date()
        self.showTitle = showTitle
        self.episodeTitle = episodeTitle
        self.episodeId = episodeId
        self.duration = duration
        self.segments = segments.map(SharedAdSegment.init)
    }

    public func fileName() -> String {
        let base = episodeTitle.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        let stem = base.isEmpty ? "episode" : base
        return "quarto-ads-\(stem).json"
    }
}
