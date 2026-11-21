import SwiftUI

/// "À portée par le mesh · toi → K7 → Inès · 2 sauts": the real route of the last message from
/// the contact, with the mini radar. Expands to the state of every link.
struct PathCard: View {
    @Environment(AppModel.self) private var model
    let conversation: ConversationRecord?
    let peer: ContactJSON?
    @Binding var expanded: Bool

    private var route: PathInfo? { peer.flatMap { model.routes[$0.fingerprint] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.select()
                withAnimation(.snappy(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    RadarView(devices: model.meshPeerCount, hops: route?.transport == .mesh ? route?.hops : nil)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(detail)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                }
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded ? "ouvert" : "fermé")
            .accessibilityHint("Affiche l'état de chaque lien")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().overlay(Theme.cardStroke)
                    linkRow("dot.radiowaves.left.and.right", "Mesh Bluetooth et Wi-Fi direct",
                        model.meshPeerCount > 0 ? "\(model.meshPeerCount) téléphone\(model.meshPeerCount > 1 ? "s" : "") relié\(model.meshPeerCount > 1 ? "s" : "")" : "personne à portée",
                        model.meshPeerCount > 0)
                    linkRow("globe", "Nœud \(host)", nodeText, model.nodeState == .ready)
                    linkRow("message", "SMS chiffré", "en dernier recours, tu valides l'envoi", true)
                    if !model.nearby.isEmpty {
                        Text(model.nearby.map { $0.connected ? $0.code : "(\($0.code))" }.joined(separator: " · "))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                            .accessibilityLabel("Relais proches : " + model.nearby.map(\.code).joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.cardStroke))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var host: String { URL(string: model.nodeURL)?.host() ?? model.nodeURL }

    private var nodeText: String {
        switch model.nodeState {
        case .ready: "connecté, boîte aux lettres chiffrée"
        case .connecting, .authenticating: "connexion…"
        case .off: "désactivé"
        case .failed: "injoignable, nouvel essai bientôt"
        }
    }

    private func linkRow(_ icon: String, _ title: String, _ value: String, _ on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Theme.mesh : Theme.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(Theme.text)
                Text(value).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let conversation else { return "" }
        if conversation.kind == .group { return model.meshPeerCount > 0 ? "Groupe à portée par le mesh" : model.nodeState == .ready ? "Groupe par Internet" : "Aucun lien" }
        switch route?.transport {
        case .mesh: return "À portée par le mesh"
        case .node: return "Par Internet"
        case .sms: return "Dernier message par SMS"
        default:
            if model.meshPeerCount > 0 { return "Mesh actif" }
            if model.nodeState == .ready { return "Par Internet" }
            return "Aucun lien pour l'instant"
        }
    }

    private var detail: String {
        let name = peer?.name ?? conversation?.title ?? ""
        if conversation?.kind == .group { return "\(model.meshPeerCount) relais · nœud \(model.nodeState == .ready ? "ok" : "hors ligne")" }
        switch route?.transport {
        case .mesh:
            let hops = route?.hops ?? 1
            if hops <= 1 { return "toi → \(name) · direct" }
            let via = route?.via ?? "?"
            let middle = hops > 2 ? "\(via) → ··· → " : "\(via) → "
            return "toi → \(middle)\(name) · \(hops) sauts"
        case .node:
            return "toi → \(host) → \(name)"
        case .sms:
            return "toi → SMS → \(name)"
        default:
            if model.meshPeerCount > 0 { return "\(model.meshPeerCount) relais, \(name) pas encore vu" }
            if model.nodeState == .ready { return "toi → \(host) → \(name)" }
            return "les messages attendent un relais"
        }
    }
}
