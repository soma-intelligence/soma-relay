import SwiftUI
import UIKit

/// Card look shared by polls, locations and documents (both sides, neutral fill).
private struct CardBubble: ViewModifier {
    let inFlight: Bool
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.incoming))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if inFlight {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .shadow(color: Theme.shadow.opacity(0.75), radius: 1, y: 1)
    }
}

extension View {
    func cardBubble(inFlight: Bool, radius: CGFloat = 20) -> some View { modifier(CardBubble(inFlight: inFlight, radius: radius)) }
}

// MARK: - Poll

/// Question, options with live bars and counts, tap to vote, close by the creator.
struct PollBubble: View {
    @Environment(AppModel.self) private var model
    let item: ChatItem
    let onVote: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        let poll = item.message.poll ?? .init(question: "", options: [], multi: false)
        let tally = item.state.tally()
        let total = max(1, item.state.voterCount)
        let mine = Set(item.state.myVote)
        let closed = model.isClosed(item)
        let leader = tally.values.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                Text(closed ? "SONDAGE CLOS" : poll.multi ? "SONDAGE · PLUSIEURS CHOIX" : "SONDAGE")
            }
            .font(Theme.mono(10, weight: .medium))
            .foregroundStyle(Theme.secondary)
            Text(poll.question)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                ForEach(poll.options) { option in
                    let count = tally[option.id] ?? 0
                    let picked = mine.contains(option.id)
                    Button {
                        onVote(option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: picked ? "checkmark.circle.fill" : poll.multi ? "square" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(picked ? Theme.mesh : Theme.dashed)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(option.text)
                                    .font(.subheadline.weight(picked ? .semibold : .regular))
                                    .foregroundStyle(Theme.text)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                Text("\(count)")
                                    .font(Theme.mono(12, weight: closed && count == leader && count > 0 ? .bold : .regular))
                                    .foregroundStyle(Theme.secondary)
                                    .contentTransition(.numericText())
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.track.opacity(0.6))
                                    Capsule()
                                        .fill(picked ? Theme.mesh : Theme.trackFill.opacity(0.55))
                                        .frame(width: max(count > 0 ? 6 : 0, geo.size.width * CGFloat(count) / CGFloat(total)))
                                }
                            }
                            .frame(height: 5)
                            .padding(.leading, 28)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(closed)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(option.text), \(count) vote\(count > 1 ? "s" : "")")
                    .accessibilityValue(picked ? "choisi" : "")
                    .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(closed ? "Sondage clos" : "Vote pour cette option")
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.15), value: tally)
            HStack {
                Text(item.state.voterCount == 0 ? "Aucun vote" : "\(item.state.voterCount) votant\(item.state.voterCount > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
                Spacer()
                if item.isMine, !closed {
                    Button("Clore", action: onClose)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.mesh)
                        .accessibilityHint("Plus personne ne pourra voter")
                }
            }
        }
        .padding(14)
        .frame(width: 272, alignment: .leading)
        .cardBubble(inFlight: item.isInFlight)
    }
}

// MARK: - Location

/// MapKit snapshot with the pin; live shares say until when and move with each update.
struct LocationBubble: View {
    let item: ChatItem
    let onOpen: () -> Void
    let onStop: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var pulse = false

    static let size = CGSize(width: 252, height: 150)

    var body: some View {
        let coord = AppModel.coordinate(of: item) ?? (0, 0)
        let live = AppModel.isLive(item)
        let wasLive = item.message.location?.liveUntil != nil
        VStack(spacing: 0) {
            Button(action: onOpen) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Theme.track.opacity(0.5)
                        ProgressView()
                    }
                    pin(live: live)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live ? "Position en direct" : "Position")
            .accessibilityHint("Ouvre la carte")
            HStack(spacing: 8) {
                if live {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        .opacity(pulse || reduceMotion ? 1 : 0.35)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(live: live, wasLive: wasLive))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(subtitle(live: live, wasLive: wasLive))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if live, item.isMine {
                    Button("Arrêter", action: onStop)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                        .buttonStyle(.plain)
                        .accessibilityHint("Arrête le partage en direct")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: Self.size.width, alignment: .leading)
        }
        .cardBubble(inFlight: item.isInFlight)
        .task(id: MapSnapshots.key(lat: coord.0, lon: coord.1, size: Self.size, dark: scheme == .dark)) {
            image = MapSnapshots.cached(lat: coord.0, lon: coord.1, size: Self.size, dark: scheme == .dark) ?? image
            image = await MapSnapshots.image(lat: coord.0, lon: coord.1, size: Self.size, dark: scheme == .dark)
        }
        .onAppear {
            guard live, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private func pin(live: Bool) -> some View {
        if live {
            ZStack {
                Circle().fill(Theme.mesh.opacity(0.22)).frame(width: 46, height: 46)
                    .scaleEffect(pulse && !reduceMotion ? 1.15 : 0.85)
                Circle().fill(Theme.mesh).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
        } else {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.danger)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .offset(y: -12)
        }
    }

    private func title(live: Bool, wasLive: Bool) -> String {
        if live { return "En direct" }
        if wasLive { return "Partage terminé" }
        return item.message.location?.name ?? "Position"
    }

    private func subtitle(live: Bool, wasLive: Bool) -> String {
        if live, let until = item.message.location?.liveUntil {
            return "jusqu'à " + Date(timeIntervalSince1970: Double(until) / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        if let a = item.message.location?.accuracyM, a > 0 { return "précision \(Int(a.rounded())) m" }
        let c = AppModel.coordinate(of: item) ?? (0, 0)
        return String(format: "%.4f, %.4f", c.0, c.1)
    }
}

// MARK: - Document

/// File tile (first-page thumbnail or a tinted icon), name, type, pages and size.
struct DocumentBubble: View {
    let item: ChatItem
    let onOpen: () -> Void

    var body: some View {
        let a = item.message.attachment
        let name = a?.name ?? "Fichier"
        let mime = a?.mime ?? "application/octet-stream"
        Button(action: onOpen) {
            HStack(spacing: 12) {
                tile(name: name, mime: mime, thumb: a?.thumb)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                    Text(details(name: name, mime: mime, pages: a?.pages, size: a?.size ?? 0))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.mediaPath == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .frame(width: 272)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardBubble(inFlight: item.isInFlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Document \(name), \(details(name: name, mime: mime, pages: a?.pages, size: a?.size ?? 0))")
        .accessibilityHint(item.mediaPath == nil ? "Téléchargement en cours" : "Ouvre l'aperçu")
    }

    @ViewBuilder private func tile(name: String, mime: String, thumb: String?) -> some View {
        if let thumb, let data = Data(base64Encoded: thumb), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 64, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.ring, lineWidth: 1))
                .overlay(alignment: .bottomLeading) { badge(name: name, mime: mime).padding(3) }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(DocumentInfo.tint(name: name, mime: mime)).opacity(0.14))
                .frame(width: 50, height: 64)
                .overlay {
                    Image(systemName: DocumentInfo.symbol(name: name, mime: mime))
                        .font(.system(size: 22))
                        .foregroundStyle(Color(DocumentInfo.tint(name: name, mime: mime)))
                }
                .overlay(alignment: .bottomLeading) { badge(name: name, mime: mime).padding(3) }
        }
    }

    private func badge(name: String, mime: String) -> some View {
        Text(DocumentInfo.typeLabel(name: name, mime: mime).prefix(4))
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Color(DocumentInfo.tint(name: name, mime: mime)), in: RoundedRectangle(cornerRadius: 3))
    }

    private func details(name: String, mime: String, pages: Int?, size: Int) -> String {
        var parts = [DocumentInfo.typeLabel(name: name, mime: mime)]
        if let pages, pages > 0 { parts.append("\(pages) page\(pages > 1 ? "s" : "")") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Link preview

/// The sender's preview, inside the text bubble. Tap opens Safari.
struct LinkCard: View {
    let link: AppMessage.LinkPreview
    let tint: Color
    let onOpen: (URL) -> Void

    var body: some View {
        Button {
            if let url = URL(string: link.url) { onOpen(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let b64 = link.image, let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
                    let ratio = image.size.width / max(1, image.size.height)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: min(150, max(90, 240 / max(0.6, ratio))))
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text((link.site ?? URL(string: link.url)?.host() ?? "").uppercased())
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(tint.opacity(0.75))
                        .lineLimit(1)
                    if let title = link.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let d = link.description, !d.isEmpty {
                        Text(d)
                            .font(.caption)
                            .foregroundStyle(tint.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lien : " + (link.title ?? link.url))
        .accessibilityHint("Ouvre dans Safari")
        .accessibilityAddTraits(.isLink)
    }
}
