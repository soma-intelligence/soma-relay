import SwiftUI

/// The mini radar of the path card (76 x 76 artboard units): rings, nearby phones, and the route
/// to the contact drawn dashed in the mesh colour.
struct RadarView: View {
    var devices: Int
    var hops: Int?
    var highlight: Bool = true
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let s = size.width / 76
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s)) }
            context.stroke(circle(pt(38, 38), 36), with: .color(Theme.ring), lineWidth: 1)
            context.stroke(circle(pt(38, 38), 22), with: .color(Theme.ring), lineWidth: 1)
            context.fill(circle(pt(38, 38), 4), with: .color(Theme.text))
            let spots: [CGPoint] = [pt(54, 26), pt(20, 50), pt(58, 56), pt(18, 22), pt(40, 66), pt(66, 38), pt(28, 10)]
            for p in spots.prefix(max(0, min(devices, spots.count))) {
                context.fill(circle(p, 3.5), with: .color(Theme.radarDot))
            }
            if highlight, let hops {
                let target = pt(64, 14)
                context.fill(circle(target, 5), with: .color(Theme.mesh))
                var path = Path()
                path.move(to: pt(38, 38))
                if hops > 1 { path.addLine(to: pt(54, 26)) }
                path.addLine(to: target)
                context.stroke(path, with: .color(Theme.mesh), style: StrokeStyle(lineWidth: 2 * s, dash: [3 * s, 3 * s]))
            }
        }
        .overlay {
            if !reduceMotion && devices > 0 {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(AngularGradient(colors: [Theme.mesh.opacity(0), Theme.mesh.opacity(0.35)], center: .center), lineWidth: 10)
                    .padding(6)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .animation(.linear(duration: 4).repeatForever(autoreverses: false), value: sweep)
                    .onAppear { sweep = true }
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Radar : \(devices) appareil\(devices > 1 ? "s" : "") à portée")
    }
}

/// Voice note levels.
struct Waveform: View {
    let levels: [Float]
    var progress: Double = 0
    var active: Color = Theme.trackFill
    var inactive: Color = Theme.track

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let step = size.width / CGFloat(levels.count)
            let bar = max(1.5, step * 0.55)
            for (i, level) in levels.enumerated() {
                let h = max(3, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: bar, height: h)
                let done = Double(i) / Double(levels.count) < progress
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(done ? active : inactive))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Centered empty state: the mark (or a glyph on a tile), a title, one line, an optional lime action.
struct EmptyState: View {
    let title: String
    let message: String
    var systemImage: String?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let systemImage {
                DSIconTile(systemName: systemImage, size: 64, fill: DS.cell, foreground: DS.label2)
                    .padding(.bottom, 18)
            } else {
                BrandMark().frame(width: 64)
                    .padding(.bottom, 18)
            }
            Text(title)
                .font(DS.TextStyle.title3)
                .foregroundStyle(DS.label)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 6)
            }
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.dsPrimary)
                    .frame(maxWidth: 280)
                    .padding(.top, 22)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
