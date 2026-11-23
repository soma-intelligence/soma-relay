import SwiftUI

// MARK: Cards and grouped lists

extension View {
    /// Grouped cell or card: `cell` fill, 26 pt continuous corners.
    func dsCard(_ fill: Color = DS.cell, radius: CGFloat = DS.Radius.cell) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Liquid Glass capsule (toolbar groups, floating controls).
    func dsGlassCapsule(interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
    }

    /// Liquid Glass card.
    func dsGlassCard(radius: CGFloat = DS.Radius.cell) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A grouped section of the mockups: optional header and footer outside the card, the rows inside
/// one 26 pt card with inset separators (`DSRow` draws its own).
struct DSSection<Content: View, Footer: View>: View {
    var header: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.label2)
                    .padding(.horizontal, DS.Space.cell)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .dsCard()
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cell, style: .continuous))
            footer
                .font(DS.TextStyle.footnote)
                .foregroundStyle(DS.label2)
                .padding(.horizontal, DS.Space.cell)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.margin)
    }
}

extension DSSection where Footer == EmptyView {
    init(header: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content, footer: { EmptyView() })
    }
}

/// One row of a grouped card: 16 pt padding, a separator above it (except the first) inset to
/// `separatorInset` from the leading edge.
struct DSRow<Content: View>: View {
    var first = false
    var minHeight: CGFloat = 52
    var separatorInset: CGFloat = DS.Space.cell
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) { content }
            .padding(.horizontal, DS.Space.cell)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay(alignment: .top) {
                if !first {
                    Rectangle().fill(DS.separator).frame(height: 0.5).padding(.leading, separatorInset)
                }
            }
    }
}

/// Tertiary chevron at the end of a row.
struct DSChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.label3)
            .accessibilityHidden(true)
    }
}

/// Rounded tile behind a row icon (30 pt, 8 pt corners) or a channel hash (40 pt, 12 pt).
struct DSIconTile: View {
    let systemName: String
    var size: CGFloat = 30
    var fill: Color = DS.cell2
    var foreground: Color = DS.label

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Chips

/// Filter chip: 34 pt high, 17 pt corners; selected = label fill with dark text.
struct DSChip: View {
    let title: String
    var count: Int?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? DS.background : DS.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .foregroundStyle(selected ? DS.background : DS.label)
            .background(selected ? DS.label : DS.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Buttons

/// Main action: lime capsule tinted glass, 54 pt, dark text on lime.
struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(DS.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: DS.buttonHeight)
            .glassEffect(.regular.tint(DS.accentFill).interactive(), in: Capsule())
            .shadow(color: DS.accentFill.opacity(0.18), radius: 12, y: 8)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// Secondary action: neutral glass capsule, 54 pt.
struct DSSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(DS.label)
            .frame(maxWidth: .infinity)
            .frame(height: DS.buttonHeight)
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// Small filled capsule inside a row ("Ajouter"): 32 pt, `fill2`.
struct DSSmallCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DS.label)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(DS.fill2, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
}

extension ButtonStyle where Self == DSSmallCapsuleButtonStyle {
    static var dsSmallCapsule: DSSmallCapsuleButtonStyle { DSSmallCapsuleButtonStyle() }
}

// MARK: Small pieces

/// Lime dot with a soft halo: an active state (mesh on, live channel).
struct DSStatusDot: View {
    var active = true
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(active ? DS.accentFill : DS.label3)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? DS.accentFill.opacity(0.16) : .clear).padding(-3))
            .accessibilityHidden(true)
    }
}

/// Lime count capsule (unread); grey when muted.
struct DSCountBadge: View {
    let count: Int
    var muted = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 13, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(muted ? DS.label2 : DS.onAccent)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(muted ? DS.fill2 : DS.accentFill, in: Capsule())
    }
}

/// Short amber warning line (no end-to-end encryption).
struct DSWarningNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.sms)
            Text(text)
        }
        .font(DS.TextStyle.footnote)
        .foregroundStyle(DS.label2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Settings rows

/// Leading part of a settings row (relay-screens 12): a 30 pt colour tile with a white glyph, the
/// title, an optional one-line subtitle. Rows using it inset their separator to 60 pt.
struct DSTileLabel: View {
    let systemName: String
    let title: String
    var subtitle: String?
    var tile: Color = DS.Tile.grey
    var glyph: Color = .white
    var titleColor: Color = DS.label

    var body: some View {
        HStack(spacing: 14) {
            DSIconTile(systemName: systemName, size: 30, fill: tile, foreground: glyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.TextStyle.body)
                    .foregroundStyle(titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.TextStyle.footnote)
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// Trailing state of a settings row ("5 téléphones", "Connecté"), a lime dot before it when active.
struct DSRowValue: View {
    let text: String
    var dot: Bool?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { DSStatusDot(active: dot) }
            Text(text)
                .font(DS.TextStyle.body)
                .foregroundStyle(DS.label2)
                .lineLimit(1)
        }
    }
}
