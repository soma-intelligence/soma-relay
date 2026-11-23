import SwiftUI

/// Route detail, opened from the chat's identity capsule: the real route of the last message
/// from the contact with the mini radar ("toi → K7 → Inès · 2 sauts"), then the state of every
/// link (mesh, node, SMS). Same content as the old path card, which no longer sits under the
/// header.
struct RouteDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: ConversationRecord?
    let peer: ContactJSON?
    var openContact: (() -> Void)?

    private var route: PathInfo? { peer.flatMap { model.routes[$0.fingerprint] } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.group) {
                    VStack(spacing: 12) {
                        RadarView(devices: model.meshPeerCount, hops: route?.transport == .mesh ? route?.hops : nil)
                            .frame(width: 96, height: 96)
                        Text(title)
                            .font(DS.TextStyle.title3)
                            .foregroundStyle(DS.label)
                        Text(detail)
                            .font(DS.TextStyle.subheadline)
                            .foregroundStyle(DS.label2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)

                    DSSection(header: "Liens") {
                        DSRow(first: true, separatorInset: 60) {
                            linkRow("dot.radiowaves.left.and.right", "Mesh Bluetooth et Wi-Fi direct",
                                model.meshPeerCount > 0 ? "\(model.meshPeerCount) téléphone\(model.meshPeerCount > 1 ? "s" : "") relié\(model.meshPeerCount > 1 ? "s" : "")" : "Personne à portée",
                                model.meshPeerCount > 0)
                        }
                        DSRow(separatorInset: 60) {
                            linkRow("globe", "Nœud \(host)", nodeText, model.nodeState == .ready)
                        }
                        DSRow(separatorInset: 60) {
                            linkRow("message", "SMS chiffré", "En dernier recours, tu valides l'envoi", true)
                        }
                    } footer: {
                        if !model.nearby.isEmpty {
                            Text("Relais proches : " + model.nearby.map { $0.connected ? $0.code : "(\($0.code))" }.joined(separator: " · "))
                        }
                    }

                    if let openContact, peer != nil {
                        DSSection {
                            Button(action: openContact) {
                                DSRow(first: true) {
                                    Text("Fiche du contact").font(DS.TextStyle.body).foregroundStyle(DS.label)
                                    Spacer()
                                    DSChevron()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .background(DS.background)
            .navigationTitle("Chemin des messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var host: String { URL(string: model.nodeURL)?.host() ?? model.nodeURL }

    private var nodeText: String {
        switch model.nodeState {
        case .ready: "Connecté, boîte aux lettres chiffrée"
        case .connecting, .authenticating: "Connexion…"
        case .off: "Désactivé"
        case .failed: "Injoignable, nouvel essai bientôt"
        }
    }

    private func linkRow(_ icon: String, _ title: String, _ value: String, _ on: Bool) -> some View {
        HStack(spacing: 14) {
            DSIconTile(systemName: icon, size: 30, fill: on ? DS.accentSoft : DS.cell2, foreground: on ? DS.accent : DS.label2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.TextStyle.body).foregroundStyle(DS.label).lineLimit(1)
                Text(value).font(DS.TextStyle.footnote).foregroundStyle(DS.label2)
            }
            Spacer(minLength: 0)
            DSStatusDot(active: on)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let conversation else { return "" }
        if conversation.kind == .group { return model.meshPeerCount > 0 ? "Groupe à portée par le mesh" : model.nodeState == .ready ? "Groupe par le nœud" : "Aucun lien" }
        switch route?.transport {
        case .mesh: return "À portée par le mesh"
        case .node: return "Par le nœud"
        case .sms: return "Dernier message par SMS"
        default:
            if model.meshPeerCount > 0 { return "Mesh actif" }
            if model.nodeState == .ready { return "Par le nœud" }
            return "Aucun lien pour l'instant"
        }
    }

    private var detail: String {
        let name = peer?.name ?? conversation?.title ?? ""
        if conversation?.kind == .group { return "\(model.meshPeerCount) relais · nœud \(model.nodeState == .ready ? "connecté" : "hors ligne")" }
        switch route?.transport {
        case .mesh:
            let hops = route?.hops ?? 1
            if hops <= 1 { return "toi → \(name) · en direct" }
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
            return "Les messages attendent un relais"
        }
    }
}
