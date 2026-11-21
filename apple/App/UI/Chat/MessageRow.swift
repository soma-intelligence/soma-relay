import SwiftUI
import UIKit

/// One message: optional sender name, the bubble (text, voice, image, video, file), the mono
/// metadata line, and the SMS fallback for messages with no link.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let item: ChatItem
    let showSender: Bool
    let quoted: ChatItem?
    let player: VoicePlayer
    let onReply: () -> Void
    let onSMS: () -> Void
    let onRetry: () -> Void
    let onOpen: () -> Void

    @State private var drag: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 16

    private var alignment: HorizontalAlignment { item.isMine ? .trailing : .leading }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            if showSender, let name = item.senderName {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 8)
            }
            bubble
                .offset(x: drag)
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let dx = item.isMine ? min(0, value.translation.width) : max(0, value.translation.width)
                            drag = dx * 0.5
                        }
                        .onEnded { _ in
                            if abs(drag) > 32 {
                                Haptics.select()
                                onReply()
                            }
                            withAnimation(.snappy) { drag = 0 }
                        })
                .contextMenu { menu }
            MetaText(text: item.meta)
                .padding(item.isMine ? .trailing : .leading, 8)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            if item.isMine, item.status == .pending, item.message.attachment == nil {
                Button(action: onSMS) {
                    Label("Envoyer par SMS chiffré", systemImage: "message")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 34)
                }
                .buttonStyle(.glass)
                .padding(.bottom, 6)
            } else if item.isMine, item.status == .failed {
                Button("Réessayer", systemImage: "arrow.clockwise", action: onRetry)
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: item.isMine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Répondre", onReply)
    }

    private var accessibilityText: String {
        let who = item.isMine ? "Toi" : (item.senderName ?? model.name(of: item.sender))
        let body = item.message.kind == .text ? (item.message.text ?? "") : AppModel.previewText(item.message)
        let via: String = switch item.transport {
        case .mesh: item.hops.map { "par le mesh, \($0) saut\($0 > 1 ? "s" : "")" } ?? "par le mesh"
        case .node: "par Internet"
        case .sms: "par SMS chiffré"
        case .local: ""
        }
        return [who + " : " + body, via, item.accessibilityStatus].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder private var menu: some View {
        Button("Répondre", systemImage: "arrowshape.turn.up.left", action: onReply)
        if let text = item.message.text {
            Button("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        if item.isMine, item.status == .pending {
            Button("Envoyer par SMS chiffré", systemImage: "message", action: onSMS)
        }
        if item.isMine, item.status == .failed || item.status == .pending {
            Button("Réessayer", systemImage: "arrow.clockwise", action: onRetry)
        }
    }

    // MARK: Bubbles

    @ViewBuilder private var bubble: some View {
        switch item.message.kind {
        case .audio: voice
        case .image, .video: media
        case .file: file
        default: textBubble
        }
    }

    private var colors: (fill: Color, text: Color) {
        if !item.isMine { return (Theme.incoming, Theme.text) }
        if item.isInFlight { return (.clear, Theme.text) }
        return Theme.bubble(for: item.transport)
    }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quoted { quote(quoted) }
            Text(item.message.text ?? "")
                .font(.system(size: textSize))
                .lineSpacing(textSize * 0.35 - 4)
                .foregroundStyle(colors.text)
                .textSelection(.enabled)
        }
        .padding(.horizontal, item.isInFlight ? 13 : 14)
        .padding(.vertical, item.isInFlight ? 9 : 10)
        .background(shape.fill(colors.fill))
        .overlay { if item.isInFlight { shape.strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) } }
        .shadow(color: item.isMine ? .clear : Theme.shadow.opacity(0.75), radius: 1, y: 1)
        .frame(maxWidth: UIScreen.main.bounds.width * 0.76, alignment: item.isMine ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    private func quote(_ q: ChatItem) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(colors.text.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(q.isMine ? "Toi" : (q.senderName ?? model.name(of: q.sender)))
                    .font(.caption.weight(.semibold))
                Text(q.message.kind == .text ? (q.message.text ?? "") : AppModel.previewText(q.message))
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(colors.text.opacity(0.85))
        .padding(.vertical, 2)
        .accessibilityLabel("En réponse à : " + (q.message.text ?? AppModel.previewText(q.message)))
    }

    private var voice: some View {
        let playing = player.playing == item.id
        let attachment = item.message.attachment
        return HStack(spacing: 10) {
            Button {
                Haptics.tap()
                player.toggle(id: item.id, data: item.mediaPath.flatMap(MediaStore.load))
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 36, height: 36)
                    .background(Theme.playFill, in: Circle())
                    .foregroundStyle(Theme.playIcon)
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Mettre en pause" : "Lire la note vocale")
            if let levels = attachment?.levels, !levels.isEmpty {
                Waveform(levels: levels, progress: playing ? player.progress : 0)
                    .frame(height: 22)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.trackFill).frame(width: geo.size.width * (playing ? player.progress : 0.35))
                    }
                }
                .frame(height: 3)
            }
            Text(Self.duration(attachment?.durationMs ?? 0))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(item.isMine && !item.isInFlight ? Theme.incoming : Theme.incoming))
        .overlay { if item.isInFlight { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) } }
        .shadow(color: Theme.shadow.opacity(0.75), radius: 1, y: 1)
    }

    private var media: some View {
        let attachment = item.message.attachment
        let image = item.mediaPath.flatMap(MediaStore.load).flatMap { item.message.kind == .image ? UIImage(data: $0) : nil }
            ?? attachment?.thumb.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        let ratio = CGFloat(attachment?.width ?? 4) / CGFloat(max(1, attachment?.height ?? 3))
        let width: CGFloat = 240
        return Button(action: onOpen) {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.incoming
                    ProgressView()
                }
                if item.message.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular, in: Circle())
                }
            }
            .frame(width: width, height: min(320, max(140, width / max(0.3, ratio))))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(item.isInFlight ? Theme.dashed : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.message.kind == .video ? "Vidéo" : "Photo")
        .accessibilityHint("Ouvre en plein écran")
    }

    private var file: some View {
        let attachment = item.message.attachment
        return Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .background(Theme.playFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.playIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment?.name ?? "Fichier")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment?.size ?? 0), countStyle: .file))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.incoming))
            .overlay { if item.isInFlight { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) } }
        }
        .buttonStyle(.plain)
    }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
