import SwiftUI
import UIKit

/// Bubble outline of the design system: 20 pt continuous corners, and on the last bubble of a
/// run (the "tail") the bottom corner on the sender's side tightens to 6 pt.
nonisolated struct BubbleShape: Shape {
    /// Kept for callers that reserved room for the old drawn tail; the new tail is a corner.
    static let tailWidth: CGFloat = 0
    var mine: Bool
    var tail: Bool
    var radius: CGFloat = 20

    func path(in r: CGRect) -> Path {
        let big = min(radius, r.height / 2)
        let small = tail ? min(6, big) : big
        return UnevenRoundedRectangle(
            topLeadingRadius: big, bottomLeadingRadius: mine ? big : small,
            bottomTrailingRadius: mine ? small : big, topTrailingRadius: big, style: .continuous
        ).path(in: r)
    }
}

/// Where a bubble sits in a run of messages from the same sender.
struct RunPosition: Equatable {
    var first: Bool
    var last: Bool
    static let single = RunPosition(first: true, last: true)
}

/// Emoji drawn as an image, for the reaction palette of the context menu (palettes show images).
enum EmojiImage {
    private static var cache: [String: UIImage] = [:]

    static func make(_ emoji: String, size: CGFloat = 30) -> UIImage {
        if let hit = cache[emoji] { return hit }
        let font = UIFont.systemFont(ofSize: size)
        let text = emoji as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let bounds = text.size(withAttributes: attributes)
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height))).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        cache[emoji] = image
        return image
    }
}

/// Reactions under a bubble: one chip per emoji (`👍 2`), yours tinted lime. Pops in.
struct ReactionPill: View {
    let summary: [(emoji: String, count: Int, mine: Bool)]
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(summary, id: \.emoji) { entry in
                Button {
                    onTap(entry.emoji)
                } label: {
                    HStack(spacing: 4) {
                        Text(entry.emoji).font(.system(size: 13))
                        if entry.count > 1 || entry.mine {
                            Text("\(entry.count)")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(entry.mine ? DS.accent : DS.label2)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(entry.mine ? DS.accentSoft : DS.cell2, in: Capsule())
                    .background(Capsule().fill(DS.cell2))
                    .overlay(Capsule().strokeBorder(DS.background, lineWidth: 2).padding(-2))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.emoji), \(entry.count) réaction\(entry.count > 1 ? "s" : "")\(entry.mine ? ", dont la tienne" : "")")
                .accessibilityHint(entry.mine ? "Retire ta réaction" : "Réagis pareil")
            }
        }
    }
}

/// "Aujourd'hui 10:42", "Hier", weekday or date, centred plain text.
struct DaySeparator: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.label2)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// Day label followed by the time of the first message of that day.
    static func label(withTime ms: Int64) -> String {
        let time = Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR")))
        return label(for: ms) + " " + time
    }

    static func label(for ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        let fr = Locale(identifier: "fr_FR")
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInYesterday(date) { return "Hier" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide).locale(fr)).capitalized(with: fr)
        }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(fr)).capitalized(with: fr)
        }
        return date.formatted(.dateTime.day().month(.wide).year().locale(fr))
    }
}

/// "Non lus" line above the first unread message.
struct UnreadSeparator: View {
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(DS.accentLine).frame(height: 1)
            Text(count > 1 ? "\(count) non lus" : "1 non lu")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.accent)
                .fixedSize()
            Rectangle().fill(DS.accentLine).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Centred system line (timer changes).
struct SystemLine: View {
    let text: String
    var icon = "timer"
    var body: some View {
        Label(text, systemImage: icon)
            .font(DS.TextStyle.caption)
            .foregroundStyle(DS.label2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

/// Three dots that bob, in an incoming bubble.
struct TypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let wave = sin(t * 6 - Double(i) * 0.9)
                    Circle()
                        .fill(DS.label2)
                        .frame(width: 7, height: 7)
                        .offset(y: reduceMotion ? 0 : -3 * max(0, wave))
                        .opacity(reduceMotion ? 0.4 + 0.6 * max(0, wave) : 0.55 + 0.45 * max(0, wave))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .padding(.leading, BubbleShape.tailWidth)
            .background(BubbleShape(mine: false, tail: true).fill(DS.bubbleIn))
        }
        .accessibilityElement()
        .accessibilityLabel("En train d'écrire")
    }
}

extension Theme {
    /// Stable colour per group member (names in group chats).
    static func senderColor(_ fp: String?) -> Color {
        let palette: [Color] = [
            dyn(0xB4442F, 0xFF8A70), dyn(0x1E6FB8, 0x6DB3FF), dyn(0x7A4CC2, 0xC09BFF),
            dyn(0x0B7A55, 0x5EDDA8), dyn(0xA35A00, 0xFFB45C), dyn(0xB0336F, 0xFF86BE),
        ]
        guard let fp, !fp.isEmpty else { return secondary }
        let sum = fp.unicodeScalars.prefix(16).reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}
