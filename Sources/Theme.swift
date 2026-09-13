import SwiftUI

enum QuartoTheme {
    static let bg = Color.black
    static let card = Color(white: 0.10)
    static let chip = Color(white: 0.16)
    static let hairline = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.55)
    static let titleFont = Font.system(.largeTitle, design: .serif).weight(.regular)
    static let displayFont = Font.system(.title, design: .serif).weight(.regular)
}

struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 44
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(QuartoTheme.chip))
        }
        .buttonStyle(.plain)
    }
}

struct WhitePlayPill: View {
    let title: String
    var icon: String = "play.fill"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}

struct AdSegmentCard: View {
    let segment: AdSegment
    let index: Int
    var isCurrentEpisode: Bool = false
    var currentTime: Double = 0
    var onSeek: ((Double) -> Void)? = nil

    private var isActive: Bool {
        isCurrentEpisode && segment.startTime <= currentTime && currentTime < segment.endTime
    }

    var body: some View {
        Button {
            onSeek?(segment.startTime)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.fill")
                            .foregroundStyle(isActive ? .orange : Color.orange.opacity(0.85))
                        Text("Break \(index)")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    if isActive {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                    }
                    Spacer()
                    Text(Format.durationPrecise(segment.endTime - segment.startTime))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("\(Format.timestamp(segment.startTime)) – \(Format.timestamp(segment.endTime))")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(QuartoTheme.muted)
                    Spacer()
                    if segment.confidence > 0 {
                        Text("\(Int(segment.confidence * 100))% match")
                            .font(.caption2)
                            .foregroundStyle(QuartoTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(white: 0.2)))
                    }
                }
                if !segment.reason.isEmpty {
                    Text(friendlyReason(segment.reason))
                        .font(.caption)
                        .foregroundStyle(QuartoTheme.muted)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isActive ? Color.orange.opacity(0.18) : Color(white: 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isActive ? Color.orange : Color.white.opacity(0.08), lineWidth: isActive ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func friendlyReason(_ raw: String) -> String {
        if raw.hasPrefix("Chapter: ") {
            return "Chapter: \(raw.dropFirst(9))"
        }
        if raw.hasPrefix("Trigger: ") {
            return "Phrase: \"\(raw.dropFirst(9))\""
        }
        if raw.hasPrefix("Live ad trigger: ") {
            return "Live detection: \"\(raw.dropFirst(17))\""
        }
        return raw
    }
}
