import SwiftUI
import UIKit

/// Soma Relay design system (relay-screens/README.md, "Design system"): dark first, the light
/// scheme keeps the same structure. Lime is kept for the main action, unread, the verified seal,
/// active states and the selected tab, never for large reading surfaces.
enum DS {
    // MARK: Colours

    /// Warm white at a given opacity (fills and separators of the mockups).
    nonisolated private static let warm: UInt32 = 0xEBF5E1

    static let background = Theme.dyn(0xF2F3EF, 0x0A0B0A)
    static let backgroundRaised = Theme.dyn(0xFFFFFF, 0x121412)
    /// Grouped cell and card.
    static let cell = Theme.dyn(0xFFFFFF, 0x171917)
    static let cell2 = Theme.dyn(0xECEEE8, 0x202320)
    static let fill = Theme.dyn(0x1A1F14, warm, lightAlpha: 0.06, darkAlpha: 0.08)
    static let fill2 = Theme.dyn(0x1A1F14, warm, lightAlpha: 0.10, darkAlpha: 0.12)
    static let separator = Theme.dyn(0x1A1F14, warm, lightAlpha: 0.12, darkAlpha: 0.09)

    static let label = Theme.dyn(0x111410, 0xF2F4EF)
    static let label2 = Theme.dyn(0x111410, 0xE8EEE2, lightAlpha: 0.62, darkAlpha: 0.62)
    static let label3 = Theme.dyn(0x111410, 0xE8EEE2, lightAlpha: 0.36, darkAlpha: 0.36)

    /// Lime. In light mode, text in the accent uses the darker olive.
    static let accent = Theme.dyn(0x5E7A12, 0xC6F24E)
    /// Lime as a fill (buttons, badges, switches), the same in both schemes.
    static let accentFill = Color(UIColor(hex: 0xC6F24E, alpha: 1))
    static let onAccent = Color(UIColor(hex: 0x0B0E06, alpha: 1))
    static let accentSoft = Theme.dyn(0xC6F24E, 0xC6F24E, lightAlpha: 0.22, darkAlpha: 0.13)
    static let accentLine = Theme.dyn(0x5E7A12, 0xC6F24E, lightAlpha: 0.32, darkAlpha: 0.32)

    static let bubbleOutTop = Theme.dyn(0xE3EDC8, 0x2C3820)
    static let bubbleOut = Theme.dyn(0xDCE8BC, 0x26301A)
    static let bubbleIn = Theme.dyn(0xFFFFFF, 0x1B1E1B)

    /// Node (Internet): glyph only, never a fill.
    static let node = Theme.dyn(0x3D5BD9, 0x7C95FF)
    /// SMS fallback and warnings.
    static let sms = Theme.dyn(0xB56F00, 0xFFB547)
    static let warningText = Theme.dyn(0x7A4A00, 0xFFD696, lightAlpha: 1, darkAlpha: 0.92)
    static let danger = Theme.dyn(0xE5484D, 0xFF5F57)

    // MARK: Type scale (SF Pro, iOS sizes; SF Mono only for fingerprints)

    enum TextStyle {
        static let largeTitle = Font.system(size: 34, weight: .bold)
        static let title2 = Font.system(size: 22, weight: .bold)
        static let title3 = Font.system(size: 20, weight: .semibold)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 17)
        static let callout = Font.system(size: 16)
        static let subheadline = Font.system(size: 15)
        static let footnote = Font.system(size: 13)
        static let caption = Font.system(size: 12)
        static let caption2 = Font.system(size: 11, weight: .medium)
        static func fingerprint(_ size: CGFloat = 13) -> Font { .system(size: size, design: .monospaced) }
    }

    // MARK: Spacing (4 pt grid) and radii

    enum Space {
        static let unit: CGFloat = 4
        /// Side margin of the screen.
        static let margin: CGFloat = 20
        /// Inner padding of a cell.
        static let cell: CGFloat = 16
        /// Gap between two grouped sections.
        static let group: CGFloat = 22
    }

    enum Radius {
        static let cell: CGFloat = 26
        static let bubble: CGFloat = 20
        static let bubbleTail: CGFloat = 6
        static let sheet: CGFloat = 38
        static let chip: CGFloat = 17
        static let iconTile: CGFloat = 10
    }

    /// Main capsule button height.
    static let buttonHeight: CGFloat = 54
    /// Round toolbar button.
    static let roundButton: CGFloat = 44
}
