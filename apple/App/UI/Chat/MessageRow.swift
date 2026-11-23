import SwiftUI
import UIKit

/// What a row can ask the chat to do.
struct RowActions {
    var reply: (ChatItem) -> Void = { _ in }
    var react: (String, ChatItem) -> Void = { _, _ in }
    var moreReactions: (ChatItem) -> Void = { _ in }
    var forward: (ChatItem) -> Void = { _ in }
    var edit: (ChatItem) -> Void = { _ in }
    var deleteForMe: (ChatItem) -> Void = { _ in }
    var deleteForAll: (ChatItem) -> Void = { _ in }
    var info: (ChatItem) -> Void = { _ in }
    var sms: (ChatItem) -> Void = { _ in }
    var retry: (ChatItem) -> Void = { _ in }
    var open: (ChatItem) -> Void = { _ in }
    var openQuote: (String) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var vote: (String, ChatItem) -> Void = { _, _ in }
    var closePoll: (ChatItem) -> Void = { _ in }
    var stopLive: (ChatItem) -> Void = { _ in }
}

/// One message: sender name (groups), the bubble (text, link card, voice, photo, video,
/// document, poll, location), reactions, and the mono metadata line under the last bubble of a
/// run. Long press: reaction palette and actions. Swipe right: reply.
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: ChatItem
    let position: RunPosition
    let showSender: Bool
    let quoted: ChatItem?
    let player: VoicePlayer
    let flashing: Bool
    let maxWidth: CGFloat
    let actions: RowActions

    @State private var drag: CGFloat = 0
    @State private var armed = false
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 17

    private static let replyThreshold: CGFloat = 52
    private var alignment: HorizontalAlignment { item.isMine ? .trailing : .leading }
    private var tw: CGFloat { BubbleShape.tailWidth }

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            if showSender, let name = item.senderName {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.label2)
                    .padding(.leading, 14)
                    .padding(.top, 4)
            }
            if item.message.forwarded == true, !item.isDeleted {
                Label("Transféré", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.label3)
                    .padding(.horizontal, 10)
            }
            bubble
                .contentShape(.contextMenuPreview, contextShape)
                .contextMenu { menu }
                .offset(x: drag)
                .background(alignment: .leading) {
                    Image(systemName: "arrowshape.turn.up.left.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(armed ? DS.accent : DS.label3)
                        .scaleEffect(armed ? 1.1 : 0.8)
                        .opacity(Double(min(1, drag / Self.replyThreshold)))
                        .offset(x: item.isMine ? -34 + drag * 0.2 : -30 + drag * 0.4)
                        .accessibilityHidden(true)
                }
                .simultaneousGesture(swipeToReply, isEnabled: !item.isDeleted && !item.isSystem)
            if !item.state.reactionSummary.isEmpty {
                ReactionPill(summary: item.state.reactionSummary) { emoji in actions.react(emoji, item) }
                    .padding(item.isMine ? .trailing : .leading, 10)
                    .padding(.top, -6)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: item.isMine ? .topTrailing : .topLeading).combined(with: .opacity))
                    .zIndex(1)
            }
            if position.last || item.status == .failed || item.status == .pending && item.isMine {
                MetaText(meta: item.meta)
                    .padding(.horizontal, 6)
                    .padding(.top, 1)
                    .padding(.bottom, 6)
                    .id(item.meta)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            if item.isMine, item.status == .pending, item.message.attachment == nil, item.message.kind == .text, !item.isDeleted {
                Button { actions.sms(item) } label: {
                    Label("Envoyer par SMS chiffré", systemImage: "message")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 34)
                }
                .buttonStyle(.glass)
                .padding(.vertical, 4)
            } else if item.isMine, item.status == .failed {
                Button("Réessayer", systemImage: "arrow.clockwise") { actions.retry(item) }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.glass)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.45), value: item.state.reactions)
        .animation(.easeInOut(duration: 0.3), value: item.meta)
        .padding(.top, position.first ? 8 : 0)
        .padding(.bottom, position.last ? 2 : 0)
        .frame(maxWidth: .infinity, alignment: item.isMine ? .trailing : .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.accentSoft.opacity(flashing ? 1 : 0))
                .padding(.horizontal, -6)
                .animation(.easeOut(duration: flashing ? 0.15 : 0.9), value: flashing)
        }
        .accessibilityElement(children: isRich ? .contain : .combine)
        .accessibilityLabel(isRich ? "" : accessibilityText)
        .accessibilityActions { accessibilityActionList }
    }

    private var isRich: Bool { [.poll, .location, .file].contains(item.message.kind) && !item.isDeleted }

    private var contextShape: some Shape {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    // MARK: Gestures

    private var swipeToReply: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let dx = value.translation.width
                guard dx > 0, abs(dx) > abs(value.translation.height) * 1.4 else { return }
                let next = min(84, dx * 0.6)
                if next >= Self.replyThreshold, !armed {
                    armed = true
                    Haptics.tap()
                } else if next < Self.replyThreshold, armed {
                    armed = false
                }
                drag = next
            }
            .onEnded { _ in
                if armed { actions.reply(item) }
                armed = false
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.3)) { drag = 0 }
            }
    }

    // MARK: Menu

    @ViewBuilder private var menu: some View {
        if !item.isDeleted, !item.isSystem {
            ControlGroup {
                ForEach(AppModel.reactionChoices, id: \.self) { emoji in
                    Button {
                        actions.react(emoji, item)
                    } label: {
                        Image(uiImage: EmojiImage.make(emoji))
                    }
                    .accessibilityLabel("Réagir \(emoji)")
                }
                Button {
                    actions.moreReactions(item)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Autre réaction")
            }
            .controlGroupStyle(.palette)
            Section {
                Button("Répondre", systemImage: "arrowshape.turn.up.left") { actions.reply(item) }
                if let text = item.message.text, !text.isEmpty {
                    Button("Copier", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        Haptics.select()
                    }
                }
                if model.canForward(item) {
                    Button("Transférer", systemImage: "arrowshape.turn.up.right") { actions.forward(item) }
                }
                if model.canEdit(item) {
                    Button("Modifier", systemImage: "pencil") { actions.edit(item) }
                }
                Button("Infos", systemImage: "info.circle") { actions.info(item) }
            }
        }
        if item.isMine, item.status == .pending, !item.isDeleted {
            Button("Envoyer par SMS chiffré", systemImage: "message") { actions.sms(item) }
        }
        if item.isMine, item.status == .failed || item.status == .pending {
            Button("Réessayer", systemImage: "arrow.clockwise") { actions.retry(item) }
        }
        Section {
            Button("Supprimer pour moi", systemImage: "trash", role: .destructive) { actions.deleteForMe(item) }
            if model.canDeleteForEveryone(item) {
                Button("Supprimer pour tous", systemImage: "trash.slash", role: .destructive) { actions.deleteForAll(item) }
            }
        }
    }

    @ViewBuilder private var accessibilityActionList: some View {
        if !item.isDeleted, !item.isSystem {
            Button("Répondre") { actions.reply(item) }
            Button("Réagir 👍") { actions.react("👍", item) }
            Button("Autre réaction") { actions.moreReactions(item) }
            if model.canForward(item) { Button("Transférer") { actions.forward(item) } }
            if model.canEdit(item) { Button("Modifier") { actions.edit(item) } }
            Button("Infos") { actions.info(item) }
        }
        Button("Supprimer pour moi") { actions.deleteForMe(item) }
    }

    private var accessibilityText: String {
        let who = item.isMine ? "Toi" : (item.senderName ?? model.name(of: item.sender))
        var body = item.summary
        if let link = item.message.link { body += ", lien " + (link.title ?? link.site ?? "") }
        let via: String = switch item.transport {
        case .mesh: item.hops.map { "par le mesh, \($0) saut\($0 > 1 ? "s" : "")" } ?? "par le mesh"
        case .node: "par Internet"
        case .sms: "par SMS chiffré"
        case .local: ""
        }
        let reactions = item.state.reactionSummary.map { "\($0.emoji) \($0.count)" }.joined(separator: " ")
        return [
            who + " : " + body, item.isEdited ? "modifié" : "", item.message.forwarded == true ? "transféré" : "", item.time, via,
            item.accessibilityStatus, reactions.isEmpty ? "" : "réactions " + reactions,
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Bubbles

    @ViewBuilder private var bubble: some View {
        if item.isDeleted {
            deletedBubble
        } else {
            switch item.message.kind {
            case .audio: voice.padding(item.isMine ? .trailing : .leading, tw)
            case .image, .video: media.padding(item.isMine ? .trailing : .leading, tw)
            case .file: DocumentBubble(item: item) { actions.open(item) }.padding(item.isMine ? .trailing : .leading, tw)
            case .poll:
                PollBubble(item: item, onVote: { actions.vote($0, item) }, onClose: { actions.closePoll(item) })
                    .padding(item.isMine ? .trailing : .leading, tw)
            case .location:
                LocationBubble(item: item, onOpen: { actions.open(item) }, onStop: { actions.stopLive(item) })
                    .padding(item.isMine ? .trailing : .leading, tw)
            default: textBubble
            }
        }
    }

    /// One colour for sent, one for received, whatever the transport. In flight: outline only.
    private var colors: (fill: AnyShapeStyle, text: Color) {
        if !item.isMine { return (AnyShapeStyle(DS.bubbleIn), DS.label) }
        if item.isInFlight { return (AnyShapeStyle(Color.clear), DS.label2) }
        return (AnyShapeStyle(LinearGradient(colors: [DS.bubbleOutTop, DS.bubbleOut], startPoint: .top, endPoint: .bottom)), DS.label)
    }

    /// Lime rule around sent bubbles (0.5 pt at 20 %), stronger and solid while in flight.
    @ViewBuilder private func outline<S: Shape>(_ shape: S) -> some View {
        if item.isMine {
            shape.stroke(DS.accentFill.opacity(item.isInFlight ? 0.28 : 0.2), lineWidth: item.isInFlight ? 1 : 0.5)
        }
    }

    private var shape: BubbleShape { BubbleShape(mine: item.isMine, tail: position.last) }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quoted { quote(quoted) }
            Text(Self.linked(item.message.text ?? "", tint: colors.text))
                .font(.system(size: textSize))
                .lineSpacing(textSize * 0.35 - 4)
                .foregroundStyle(colors.text)
                .tint(colors.text)
                .environment(\.openURL, OpenURLAction { url in
                    actions.openLink(url)
                    return .handled
                })
            if let link = item.message.link {
                LinkCard(link: link, tint: colors.text) { actions.openLink($0) }
                    .frame(minWidth: 200)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(shape.fill(colors.fill))
        .overlay { outline(shape) }
        .frame(maxWidth: maxWidth, alignment: item.isMine ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var deletedBubble: some View {
        Label("Message supprimé", systemImage: "nosign")
            .font(.system(size: textSize - 1).italic())
            .foregroundStyle(DS.label3)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(shape.stroke(DS.separator, lineWidth: 1))
    }

    /// Text with tappable http(s) links.
    static func linked(_ text: String, tint: Color) -> AttributedString {
        var out = AttributedString(text)
        guard text.contains("http") || text.contains("www."),
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return out }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let r = Range(match.range, in: text), let ar = Range(r, in: out) else { continue }
            out[ar].link = url
            out[ar].underlineStyle = .single
        }
        return out
    }

    /// Quoted reply: lime rule, the author in lime, one line of the original.
    private func quote(_ q: ChatItem) -> some View {
        Button {
            actions.openQuote(q.id)
        } label: {
            HStack(spacing: 10) {
                Capsule().fill(DS.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.isMine ? "Toi" : (q.senderName ?? model.name(of: q.sender)))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.accent)
                    Text(q.summary)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.leading, 0)
            .padding(.trailing, 10)
            .background(Color.black.opacity(item.isMine ? 0.22 : 0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .padding(.top, -2)
        .accessibilityLabel("En réponse à : " + q.summary)
        .accessibilityHint("Affiche le message d'origine")
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
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(DS.fill2, in: Circle())
                    .foregroundStyle(DS.label)
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Mettre en pause" : "Lire la note vocale")
            if let levels = attachment?.levels, !levels.isEmpty {
                Waveform(levels: levels, progress: playing ? player.progress : 1, active: DS.label.opacity(0.85), inactive: DS.label3)
                    .frame(height: 30)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.label3)
                        Capsule().fill(DS.label).frame(width: geo.size.width * (playing ? player.progress : 0.35))
                    }
                }
                .frame(height: 3)
            }
            Text(Self.duration(attachment?.durationMs ?? 0))
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(DS.label2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(width: 240)
        .background(shape.fill(colors.fill))
        .overlay { outline(shape) }
    }

    private var media: some View {
        let attachment = item.message.attachment
        let image = item.mediaPath.flatMap(MediaStore.load).flatMap { item.message.kind == .image ? UIImage(data: $0) : nil }
            ?? attachment?.thumb.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
        let ratio = CGFloat(attachment?.width ?? 4) / CGFloat(max(1, attachment?.height ?? 3))
        let width: CGFloat = min(240, maxWidth)
        return Button { actions.open(item) } label: {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    DS.bubbleIn
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
                    .strokeBorder(item.isInFlight ? DS.accentFill.opacity(0.28) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.message.kind == .video ? "Vidéo" : "Photo")
        .accessibilityHint("Ouvre en plein écran")
    }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
