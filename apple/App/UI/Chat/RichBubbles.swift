import CoreLocation
import SwiftUI
import UIKit

/// Card look shared by polls, locations and documents (both sides, neutral fill).
private struct CardBubble: ViewModifier {
    let inFlight: Bool
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.bubbleIn))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if inFlight {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(DS.accentFill.opacity(0.28), lineWidth: 1)
                }
            }
    }
}

extension View {
    func cardBubble(inFlight: Bool, radius: CGFloat = 24) -> some View { modifier(CardBubble(inFlight: inFlight, radius: radius)) }
}

// MARK: - Poll

/// Question, how many answers, options as result bars with a check mark, "N votes sur M".
/// Tap to vote, close by the creator.
struct PollBubble: View {
    @Environment(AppModel.self) private var model
    let item: ChatItem
    let onVote: (String) -> Void
    let onClose: () -> Void

    /// People who can vote: group members, 2 in a 1:1, unknown in a channel.
    private var electorate: Int? {
        guard let conversation = model.conversations.first(where: { $0.id == item.conversationId }) else { return nil }
        switch conversation.kind {
        case .direct: return 2
        case .group: return model.groups.first { $0.id == conversation.peer }?.members.count
        case .channel: return nil
        }
    }

    var body: some View {
        let poll = item.message.poll ?? .init(question: "", options: [], multi: false)
        let tally = item.state.tally()
        let voters = item.state.voterCount
        let total = max(1, tally.values.reduce(0, +))
        let mine = Set(item.state.myVote)
        let closed = model.isClosed(item)
        VStack(alignment: .leading, spacing: 0) {
            Text(poll.question)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(closed ? "Sondage clos" : poll.multi ? "Plusieurs réponses possibles" : "Une seule réponse")
                .font(DS.TextStyle.subheadline)
                .foregroundStyle(DS.label2)
                .padding(.top, 4)
            VStack(spacing: 10) {
                ForEach(poll.options) { option in
                    let count = tally[option.id] ?? 0
                    let picked = mine.contains(option.id)
                    Button {
                        onVote(option.id)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                if picked {
                                    Circle().fill(DS.accentFill)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(DS.onAccent)
                                } else {
                                    Circle().strokeBorder(DS.label3, lineWidth: 1.5)
                                }
                            }
                            .frame(width: 26, height: 26)
                            Text(option.text)
                                .font(.system(size: 17))
                                .foregroundStyle(DS.label)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Text("\(count)")
                                .font(.system(size: 17))
                                .monospacedDigit()
                                .foregroundStyle(DS.label2)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .background(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(DS.accentFill.opacity(picked ? 0.2 : 0.14))
                                    .frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                            }
                        }
                        .background(DS.cell2)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .padding(.top, 14)
            .animation(.spring(duration: 0.4, bounce: 0.15), value: tally)
            VStack(alignment: .leading, spacing: 10) {
                Text(footer(voters: voters, closed: closed))
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
                    .contentTransition(.numericText())
                if item.isMine, !closed {
                    Button("Clore le sondage", action: onClose)
                        .buttonStyle(.dsSmallCapsule)
                        .accessibilityHint("Plus personne ne pourra voter")
                }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: 300, alignment: .leading)
        .cardBubble(inFlight: item.isInFlight)
    }

    private func footer(voters: Int, closed: Bool) -> String {
        let votes = "\(voters) vote\(voters > 1 ? "s" : "")"
        let base = electorate.map { votes + " sur \($0)" } ?? votes
        if voters == 0 { return closed ? "Aucun vote" : "Aucun vote pour l'instant" }
        return closed ? base : base + " · résultats en direct"
    }
}

// MARK: - Location

/// MapKit snapshot with the pin, then "Position en direct", until when and how far from you.
/// Live shares move with each update.
struct LocationBubble: View {
    @Environment(AppModel.self) private var model
    let item: ChatItem
    let onOpen: () -> Void
    let onStop: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var pulse = false

    static let size = CGSize(width: 264, height: 132)

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
                        DS.cell2
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(live: live, wasLive: wasLive))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.label)
                    Text(subtitle(live: live, coord: coord))
                        .font(DS.TextStyle.subheadline)
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if live, item.isMine {
                    Button("Arrêter", action: onStop)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.danger)
                        .buttonStyle(.plain)
                        .accessibilityHint("Arrête le partage en direct")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
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
        ZStack {
            Circle().fill(DS.accentFill.opacity(0.22)).frame(width: 56, height: 56)
                .scaleEffect(live && pulse && !reduceMotion ? 1.12 : 0.92)
            Circle().fill(DS.accentFill).frame(width: 40, height: 40)
            Image(systemName: live ? "location.fill" : "mappin")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.onAccent)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private func title(live: Bool, wasLive: Bool) -> String {
        if live { return "Position en direct" }
        if wasLive { return "Partage terminé" }
        return item.message.location?.name ?? "Position"
    }

    private func subtitle(live: Bool, coord: (Double, Double)) -> String {
        var parts: [String] = []
        if live, let until = item.message.location?.liveUntil {
            parts.append("Jusqu'à " + Date(timeIntervalSince1970: Double(until) / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR"))))
        }
        if let distance = distance(to: coord) {
            parts.append("à " + Self.distanceText(distance))
        } else if let a = item.message.location?.accuracyM, a > 0 {
            parts.append("précision \(Int(a.rounded())) m")
        }
        if parts.isEmpty { parts.append(String(format: "%.4f, %.4f", coord.0, coord.1)) }
        return parts.joined(separator: " · ")
    }

    /// Distance from where I am (known only while my position is in use), never for my own pin.
    private func distance(to coord: (Double, Double)) -> Double? {
        guard !item.isMine, let me = model.locationSharer.coordinate ?? (model.demo ? DemoData.here : nil) else { return nil }
        return CLLocation(latitude: me.latitude, longitude: me.longitude).distance(from: CLLocation(latitude: coord.0, longitude: coord.1))
    }

    static func distanceText(_ m: Double) -> String {
        if m < 1000 { return "\(Int((m / 10).rounded() * 10)) m" }
        return String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",")
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.label)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                    Text(details(name: name, mime: mime, pages: a?.pages, size: a?.size ?? 0))
                        .font(DS.TextStyle.footnote)
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.mediaPath == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 280)
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
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.separator, lineWidth: 1))
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
                VStack(alignment: .leading, spacing: 3) {
                    if let title = link.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(tint)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(link.site ?? URL(string: link.url)?.host() ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lien : " + (link.title ?? link.url))
        .accessibilityHint("Ouvre dans Safari")
        .accessibilityAddTraits(.isLink)
    }
}
