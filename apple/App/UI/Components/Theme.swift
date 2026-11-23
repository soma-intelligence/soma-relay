import SwiftUI
import UIKit

/// Direction E ("Verre + Radar") tokens, copied from the Fusion artboards (light and dark).
enum Theme {
    /// Nonisolated: SwiftUI resolves these colors on its async render thread too.
    nonisolated static func dyn(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }

    static let background = dyn(0xEEF1F5, 0x0C0E0D)
    static let text = dyn(0x111418, 0xE9ECE6)
    static let secondary = dyn(0x5B636E, 0x9AA196)
    static let incoming = dyn(0xFFFFFF, 0x1A1E1B)
    /// Mesh bubbles: teal in light, lime in dark.
    static let mesh = dyn(0x0B6E63, 0xC6F24E)
    static let onMesh = dyn(0xFFFFFF, 0x0C0E0D)
    /// Internet (node) bubbles.
    static let net = dyn(0x1E4FD0, 0x3A62E0)
    static let onNet = Color.white
    static let sms = dyn(0x8A5A00, 0xFFB84D)
    static let dashed = dyn(0x8A93A0, 0x5A625A)
    static let glassFill = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.72, darkAlpha: 0.07)
    static let glassStroke = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.9, darkAlpha: 0.1)
    static let cardFill = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.6, darkAlpha: 0.04)
    static let cardStroke = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.9, darkAlpha: 0.08)
    static let softButton = dyn(0x111418, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)
    /// Strong round button (call, voice): ink in light, lime in dark.
    static let strong = dyn(0x111418, 0xC6F24E)
    static let onStrong = dyn(0xFFFFFF, 0x0C0E0D)
    static let ring = dyn(0xC9D0DA, 0x2A2F2A)
    static let radarDot = dyn(0x8A93A0, 0x6B7268)
    static let track = dyn(0xD5DBE3, 0x3A403A)
    static let trackFill = dyn(0x111418, 0xC6F24E)
    static let playFill = dyn(0xEEF1F5, 0x2A2F2A)
    static let playIcon = dyn(0x111418, 0xC6F24E)
    static let danger = Color(UIColor(hex: 0xE5484D, alpha: 1))
    static let shadow = Color(UIColor(hex: 0x111418, alpha: 0.08))

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func bubble(for transport: Transport) -> (fill: Color, text: Color) {
        switch transport {
        case .mesh: (mesh, onMesh)
        case .node: (net, onNet)
        case .sms: (sms, onMesh)
        case .local: (incoming, text)
        }
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

/// The floating glass bar of the artboards: 28 pt radius, 6 pt padding, light shadow in light mode.
struct GlassBar: ViewModifier {
    var radius: CGFloat = 28
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(6)
            .glassEffect(.regular.tint(Theme.glassFill), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.glassStroke, lineWidth: 1)
            }
            .shadow(color: scheme == .dark ? .clear : Theme.shadow, radius: 12, y: 8)
    }
}

extension View {
    func glassBar(radius: CGFloat = 28) -> some View { modifier(GlassBar(radius: radius)) }

    /// 44 pt round icon button look.
    func roundIcon(fill: Color = Theme.softButton, foreground: Color = Theme.text, size: CGFloat = 44) -> some View {
        frame(width: size, height: size)
            .background(fill, in: Circle())
            .foregroundStyle(foreground)
            .contentShape(Circle())
    }
}

/// Plain metadata line under the last bubble of a run: transport glyph and words, 11 pt tertiary.
struct MetaText: View {
    let meta: ChatItem.Meta
    var body: some View {
        HStack(spacing: 4) {
            if let icon = meta.icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(meta.tone == .sms ? DS.sms : meta.tone == .warning ? DS.danger : DS.label3)
            }
            Text(meta.text)
                .foregroundStyle(meta.tone == .warning ? DS.danger : DS.label3)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
}
