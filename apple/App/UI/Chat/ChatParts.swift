import SwiftUI
import UIKit

/// Bubble outline with an optional tail at the bottom corner on the sender's side. The tail
/// width is always reserved, so bubbles of one run line up whether they have a tail or not.
nonisolated struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 6
    var mine: Bool
    var tail: Bool
    var radius: CGFloat = 20

    func path(in r: CGRect) -> Path {
        let tw = Self.tailWidth
        let body = CGRect(x: mine ? r.minX : r.minX + tw, y: r.minY, width: max(0, r.width - tw), height: r.height)
        let rounded = Path(roundedRect: body, cornerRadius: min(radius, body.height / 2), style: .continuous)
        guard tail else { return rounded }
        var t = Path()
        if mine {
            let x = body.maxX, y = body.maxY
            t.move(to: CGPoint(x: x - 14, y: y))
            t.addQuadCurve(to: CGPoint(x: x + tw, y: y), control: CGPoint(x: x - 2, y: y))
            t.addQuadCurve(to: CGPoint(x: x, y: y - 16), control: CGPoint(x: x, y: y - 4))
        } else {
            let x = body.minX, y = body.maxY
            t.move(to: CGPoint(x: x + 14, y: y))
            t.addQuadCurve(to: CGPoint(x: x - tw, y: y), control: CGPoint(x: x + 2, y: y))
            t.addQuadCurve(to: CGPoint(x: x, y: y - 16), control: CGPoint(x: x, y: y - 4))
        }
        t.closeSubpath()
        return rounded.union(t)
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

/// Reactions under a bubble: `👍 2  ❤️`, mine outlined. Pops in.
struct ReactionPill: View {
    let summary: [(emoji: String, count: Int, mine: Bool)]
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(summary, id: \.emoji) { entry in
                Button {
                    onTap(entry.emoji)
                } label: {
                    HStack(spacing: 2) {
                        Text(entry.emoji).font(.system(size: 15))
                        if entry.count > 1 {
                            Text("\(entry.count)")
                                .font(Theme.mono(11, weight: .medium))
                                .foregroundStyle(Theme.text)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(entry.mine ? Theme.mesh.opacity(0.18) : Color.clear, in: Capsule())
                    .overlay { if entry.mine { Capsule().strokeBorder(Theme.mesh.opacity(0.6), lineWidth: 1) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.emoji), \(entry.count) réaction\(entry.count > 1 ? "s" : "")\(entry.mine ? ", dont la tienne" : "")")
                .accessibilityHint(entry.mine ? "Retire ta réaction" : "Réagis pareil")
            }
        }
        .padding(3)
        .background(Theme.incoming, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.background, lineWidth: 2))
        .shadow(color: Theme.shadow, radius: 3, y: 1)
    }
}

/// "Aujourd'hui", "Hier", weekday or date, centred.
struct DaySeparator: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.cardFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardStroke))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .accessibilityAddTraits(.isHeader)
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
            Rectangle().fill(Theme.mesh.opacity(0.4)).frame(height: 1)
            Text(count > 1 ? "\(count) non lus" : "1 non lu")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mesh)
                .fixedSize()
            Rectangle().fill(Theme.mesh.opacity(0.4)).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Centred system line (timer changes).
struct SystemLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "timer")
            .font(.caption)
            .foregroundStyle(Theme.secondary)
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
                        .fill(Theme.secondary)
                        .frame(width: 7, height: 7)
                        .offset(y: reduceMotion ? 0 : -3 * max(0, wave))
                        .opacity(reduceMotion ? 0.4 + 0.6 * max(0, wave) : 0.55 + 0.45 * max(0, wave))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .padding(.leading, BubbleShape.tailWidth)
            .background(BubbleShape(mine: false, tail: true).fill(Theme.incoming))
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
