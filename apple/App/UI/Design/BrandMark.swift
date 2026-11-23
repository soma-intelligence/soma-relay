import SwiftUI

/// The Soma Relay mark: a glowing speech bubble with three typing dots (relay-screens/html/mark.svg,
/// the app icon). Geometry in a 100 x 100 box, scaled to the rect.
nonisolated enum BrandMarkShape {
    static let strokeWidth: CGFloat = 4.2
    static let dotRadius: CGFloat = 4.4
    static let dots: [CGPoint] = [CGPoint(x: 37, y: 49.5), CGPoint(x: 50, y: 49.5), CGPoint(x: 63, y: 49.5)]

    private static func map(_ r: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
        let s = min(r.width, r.height) / 100
        let ox = r.midX - 50 * s, oy = r.midY - 50 * s
        return { x, y in CGPoint(x: ox + x * s, y: oy + y * s) }
    }

    static func scale(in r: CGRect) -> CGFloat { min(r.width, r.height) / 100 }

    /// The bubble outline (to stroke).
    static func bubble(in r: CGRect) -> Path {
        let p = map(r)
        var path = Path()
        path.move(to: p(50, 22))
        path.addCurve(to: p(15, 49.6), control1: p(30.4, 22), control2: p(15, 34.3))
        path.addCurve(to: p(27, 70.6), control1: p(15, 58), control2: p(19.6, 65.5))
        path.addLine(to: p(23.5, 80.5))
        path.addLine(to: p(37.7, 74.6))
        path.addCurve(to: p(50, 76.3), control1: p(41.5, 75.7), control2: p(45.7, 76.3))
        path.addCurve(to: p(85, 48.7), control1: p(69.6, 76.3), control2: p(85, 64))
        path.addCurve(to: p(50, 22), control1: p(85, 33.4), control2: p(69.6, 22))
        path.closeSubpath()
        return path
    }

    /// The three typing dots (to fill).
    static func dotsPath(in r: CGRect) -> Path {
        let p = map(r)
        let radius = dotRadius * scale(in: r)
        var path = Path()
        for d in dots {
            let c = p(d.x, d.y)
            path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        }
        return path
    }
}

/// The mark alone, lime stroke and pale dots with a soft glow.
struct BrandMark: View {
    var glow = true
    var stroke: Color = Color(UIColor(hex: 0xC6F24E, alpha: 1))
    var dots: Color = Color(UIColor(hex: 0xE4FBA2, alpha: 1))

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(origin: .zero, size: geo.size)
            let s = BrandMarkShape.scale(in: r)
            ZStack {
                BrandMarkShape.bubble(in: r)
                    .stroke(stroke, style: StrokeStyle(lineWidth: BrandMarkShape.strokeWidth * s, lineCap: .round, lineJoin: .round))
                BrandMarkShape.dotsPath(in: r).fill(dots)
            }
            .shadow(color: glow ? stroke.opacity(0.75) : .clear, radius: 3.2 * s)
            .shadow(color: glow ? stroke.opacity(0.35) : .clear, radius: 9 * s)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The app icon: the mark on a near-black rounded tile (welcome screen).
struct BrandIcon: View {
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(UIColor(hex: 0x141813, alpha: 1)), Color(UIColor(hex: 0x070807, alpha: 1))],
                    startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
            BrandMark().frame(width: size * 0.66)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(UIColor(hex: 0xC6F24E, alpha: 0.10)), radius: 40)
        .accessibilityHidden(true)
    }
}

/// A soft lime halo behind the mark (lock and welcome).
struct BrandHalo: View {
    var body: some View {
        RadialGradient(
            colors: [Color(UIColor(hex: 0xC6F24E, alpha: 0.10)), Color(UIColor(hex: 0xC6F24E, alpha: 0))],
            center: .center, startRadius: 0, endRadius: 260)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
