import SwiftUI

/// The Soma Relay mark: two nodes joined by an arc over a radar ring.
nonisolated enum RelayMarkShape {
    static func arc(in r: CGRect) -> Path {
        var p = Path()
        let left = CGPoint(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.62)
        let right = CGPoint(x: r.maxX - r.width * 0.16, y: left.y)
        let radius = (right.x - left.x) / 2
        p.addArc(center: CGPoint(x: r.midX, y: left.y), radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        return p
    }

    static func nodes(in r: CGRect) -> Path {
        var p = Path()
        let y = r.minY + r.height * 0.62
        let d = r.width * 0.2
        for x in [r.minX + r.width * 0.16, r.maxX - r.width * 0.16] {
            p.addEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
        }
        return p
    }

    static func ring(in r: CGRect) -> Path {
        let d = r.width * 0.52
        return Path(ellipseIn: CGRect(x: r.midX - d / 2, y: r.minY + r.height * 0.62 - d / 2, width: d, height: d))
    }
}

struct RelayMark: View {
    var color: Color = Theme.mesh
    var body: some View {
        Canvas { context, size in
            let r = CGRect(origin: .zero, size: size)
            let w = size.width
            context.stroke(RelayMarkShape.ring(in: r), with: .color(color.opacity(0.35)), lineWidth: w * 0.035)
            context.stroke(RelayMarkShape.arc(in: r), with: .color(color), style: StrokeStyle(lineWidth: w * 0.07, lineCap: .round))
            context.fill(RelayMarkShape.nodes(in: r), with: .color(color))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

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

/// Initials in a circle, tinted by the last transport.
struct Avatar: View {
    let name: String
    var size: CGFloat = 48
    var tint: Color = Theme.incoming
    var icon: String?

    var initials: String {
        let parts = name.replacingOccurrences(of: "#", with: "").split(separator: " ")
        let letters = parts.count == 1
            ? String(parts[0].prefix(2))
            : parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(tint)
            if let icon {
                Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold))
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold))
            }
        }
        .foregroundStyle(Theme.text)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// `MESH`, `NET`, `SMS` pill.
struct TransportBadge: View {
    let transport: Transport?
    var body: some View {
        if let transport, transport != .local {
            let (fill, text) = Theme.bubble(for: transport)
            Text(label(transport))
                .font(Theme.mono(9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(fill, in: Capsule())
                .foregroundStyle(text)
                .accessibilityLabel(spoken(transport))
        }
    }

    private func label(_ t: Transport) -> String {
        switch t {
        case .mesh: "MESH"
        case .node: "NET"
        case .sms: "SMS"
        case .local: ""
        }
    }

    private func spoken(_ t: Transport) -> String {
        switch t {
        case .mesh: "par le mesh"
        case .node: "par Internet"
        case .sms: "par SMS chiffré"
        case .local: ""
        }
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

/// Centered empty state with the mark.
struct EmptyState: View {
    let title: String
    let message: String
    var systemImage: String?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            } else {
                RelayMark().frame(width: 64)
            }
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Four safety words as glass pills (call screen and verification).
struct WordPills: View {
    let words: [String]
    var font: Font = .system(size: 15)

    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word)
                    .font(font)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.glassStroke))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mots de sécurité : " + words.joined(separator: ", "))
    }
}

/// Wrapping row, centered.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.midX - row.width / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Mesh and node status, shown at the top of lists.
struct LinkStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(model.meshPeerCount > 0 ? Theme.mesh : Theme.radarDot).frame(width: 7, height: 7)
                Text("MESH \(model.meshPeerCount)")
            }
            HStack(spacing: 5) {
                Circle().fill(model.nodeState == .ready ? Theme.net : Theme.radarDot).frame(width: 7, height: 7)
                Text(model.nodeState == .ready ? "NET" : model.nodeEnabled ? "NET …" : "NET OFF")
            }
        }
        .font(Theme.mono(11, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(model.meshPeerCount) téléphone\(model.meshPeerCount > 1 ? "s" : "") à portée, Internet \(model.nodeState == .ready ? "connecté" : "hors ligne")")
    }
}
