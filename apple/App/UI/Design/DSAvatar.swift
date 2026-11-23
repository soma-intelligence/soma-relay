import SwiftUI

/// Monogram avatar of the design system: a muted gradient picked from the name, the initial (or
/// an icon for groups and channels), the photo when there is one, and the lime verified seal at
/// the bottom right.
struct DSAvatar: View {
    let name: String
    var size: CGFloat = 52
    var icon: String?
    var photo: UIImage?
    var verified = false

    /// The seven gradients of the mockups (top light, bottom dark).
    nonisolated static let palette: [(UInt32, UInt32)] = [
        (0x5E8F7A, 0x2F5446), (0xB07A62, 0x6E4434), (0x7C7FB6, 0x44477A), (0xA99A5C, 0x63582D),
        (0x8B6E9E, 0x523F62), (0x5F8AA6, 0x335368), (0x6E726C, 0x3B3E3A),
    ]

    /// Stable across launches (no `hashValue`): djb2 over the scalars.
    nonisolated static func paletteIndex(for name: String) -> Int {
        var h: UInt32 = 5381
        for scalar in name.unicodeScalars { h = (h &* 33) &+ scalar.value }
        return Int(h % UInt32(palette.count))
    }

    var initials: String {
        let parts = name.replacingOccurrences(of: "#", with: "").split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var gradient: LinearGradient {
        let pair = Self.palette[Self.paletteIndex(for: name)]
        return LinearGradient(
            colors: [Color(UIColor(hex: pair.0, alpha: 1)), Color(UIColor(hex: pair.1, alpha: 1))],
            startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
    }

    var body: some View {
        ZStack {
            Circle().fill(gradient)
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if let icon {
                Image(systemName: icon).font(.system(size: size * 0.38, weight: .semibold))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.37, weight: .semibold))
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if verified {
                DSVerifiedSeal(size: max(14, size * 0.35))
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Lime `checkmark.seal.fill` on a background-coloured disc.
struct DSVerifiedSeal: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size * 0.82))
            .foregroundStyle(DS.accent)
            .frame(width: size, height: size)
            .background(Circle().fill(DS.background))
            .accessibilityLabel("vérifié")
    }
}
