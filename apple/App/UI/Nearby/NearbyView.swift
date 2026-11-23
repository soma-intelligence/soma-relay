import SwiftUI

/// À proximité: the mesh (phones relaying, visibility), the people in range and the local
/// channels, which used to be spread over Conversations, the Répertoire and Réglages.
struct NearbyView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var showJoinChannel = false
    @State private var showAddContact = false
    @State private var showMyCard = false

    /// Named phones in range that are not contacts yet. Anonymous phones only relay.
    private var people: [NearbyPeer] {
        model.nearby.filter { $0.name != nil && !model.isContact(nearby: $0) }
    }

    private var channels: [ConversationRecord] {
        model.conversations.filter { $0.kind == .channel }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    meshCard
                        .padding(.horizontal, DS.Space.margin)
                        .padding(.top, 6)
                    DSSection {
                        DSRow(first: true) {
                            Toggle("Visible à proximité", isOn: $model.visibleNearby)
                                .font(DS.TextStyle.body)
                                .foregroundStyle(DS.label)
                                .tint(DS.accentFill)
                        }
                    } footer: {
                        Text("Invisible, tu relaies quand même les messages des autres sans pouvoir les lire.")
                    }
                    .padding(.top, 10)

                    DSSection(header: "Personnes à portée") {
                        if people.isEmpty {
                            DSRow(first: true, minHeight: 64) {
                                Text("Personne de visible pour l'instant. Les gens qui ont Relay ouvert près de toi apparaîtront ici.")
                                    .font(DS.TextStyle.subheadline)
                                    .foregroundStyle(DS.label2)
                            }
                        }
                        ForEach(Array(people.enumerated()), id: \.element.id) { index, peer in
                            personRow(peer, first: index == 0)
                        }
                    }
                    .padding(.top, 20)

                    DSSection(header: "Canaux locaux") {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            channelRow(channel, first: index == 0)
                        }
                        Button { showJoinChannel = true } label: {
                            DSRow(first: channels.isEmpty, separatorInset: 70) {
                                Image(systemName: "plus")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(DS.accent)
                                    .frame(width: 40)
                                Text("Rejoindre un canal")
                                    .font(DS.TextStyle.body)
                                    .foregroundStyle(DS.accent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        DSWarningNote(text: "Non chiffrés de bout en bout : tout le monde à portée peut les lire.")
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(DS.background)
            .dsTabChrome(title: "À proximité")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showMyCard = true } label: { Image(systemName: "qrcode.viewfinder").foregroundStyle(DS.label) }
                        .accessibilityLabel("Ma carte et scanner")
                    Menu {
                        Button("Ajouter un contact", systemImage: "person.badge.plus") { showAddContact = true }
                        Button("Rejoindre un canal local", systemImage: "number") { showJoinChannel = true }
                    } label: {
                        Image(systemName: "plus").foregroundStyle(DS.label)
                    }
                    .accessibilityLabel("Ajouter")
                }
            }
            .navigationDestination(for: String.self) { id in ChatView(conversationId: id) }
            .navigationDestination(for: ChatRoute.self) { route in ChatView(conversationId: route.conversationId, focus: route.focus) }
            .fullScreenCover(isPresented: $showAddContact) {
                MyCardView(initialMode: .scan) { id in
                    showAddContact = false
                    path = NavigationPath()
                    path.append(id)
                }
            }
            .fullScreenCover(isPresented: $showMyCard) {
                MyCardView { id in
                    showMyCard = false
                    path = NavigationPath()
                    path.append(id)
                }
            }
            .alert("Rejoindre un canal local", isPresented: $showJoinChannel) {
                JoinChannelField { name in
                    let id = model.joinChannel(name)
                    if !id.isEmpty { path.append(id) }
                }
            } message: {
                Text("Un nom comme festival. Tout le monde à portée qui choisit le même nom te lira.")
            }
        }
        .onAppear {
            if DemoData.screen == "channel-open", path.isEmpty { path.append(AppModel.channelId("festival")) }
        }
    }

    // MARK: Mesh card

    private var meshCard: some View {
        HStack(spacing: 16) {
            NearbyRadar(devices: model.meshPeerCount)
                .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 2) {
                Text(meshTitle)
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(DS.label)
                Text("Bluetooth et Wi-Fi direct, sans Internet.")
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.cell)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .dsCard()
        .accessibilityElement(children: .combine)
    }

    private var meshTitle: String {
        switch model.meshPeerCount {
        case 0: "Aucun téléphone à portée"
        case 1: "1 téléphone relaie tes messages"
        case let n: "\(n) téléphones relaient tes messages"
        }
    }

    // MARK: Rows

    private func personRow(_ peer: NearbyPeer, first: Bool) -> some View {
        DSRow(first: first, minHeight: 64, separatorInset: 70) {
            DSAvatar(name: peer.name ?? peer.code, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name ?? peer.code)
                    .font(DS.TextStyle.body)
                    .foregroundStyle(DS.label)
                Text(peer.connected ? "Relié directement" : "À portée, pas encore relié")
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.label2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Ajouter") {
                Haptics.tap()
                if !peer.connected { model.mesh.invite(peer.id) }
                model.requestCard(from: peer)
            }
            .buttonStyle(.dsSmallCapsule)
            .disabled(!peer.connected)
            .accessibilityLabel("Ajouter \(peer.name ?? peer.code)")
        }
        .accessibilityElement(children: .contain)
    }

    private func channelRow(_ channel: ConversationRecord, first: Bool) -> some View {
        let name = channel.peer ?? channel.title.replacingOccurrences(of: "#", with: "")
        let preview = model.preview(of: channel)
        let detail = preview.isEmpty ? ConversationRow.time(channel.lastAt) : preview
        return Button {
            path.append(channel.id)
        } label: {
            DSRow(first: first, minHeight: 64, separatorInset: 70) {
                DSIconTile(systemName: "number", size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(DS.TextStyle.body)
                        .foregroundStyle(DS.label)
                    Text(detail)
                        .font(DS.TextStyle.footnote)
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if channel.unread > 0 {
                    DSStatusDot(active: true, size: 8)
                        .accessibilityLabel("\(channel.unread) non lus")
                } else {
                    DSChevron()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Quitter le canal", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                model.leaveChannel(name)
            }
        }
        .accessibilityHint("Ouvre le canal")
    }
}

/// The mesh radar of the À proximité card: rings, me in lime, nearby phones as grey dots.
struct NearbyRadar: View {
    var devices: Int

    var body: some View {
        Canvas { context, size in
            let s = size.width / 74
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ p: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            let lime = Color(UIColor(hex: 0xC6F24E, alpha: 1))
            context.stroke(circle(c, 36 * s), with: .color(lime.opacity(0.14)), lineWidth: 1)
            context.stroke(circle(c, 18 * s), with: .color(lime.opacity(0.18)), lineWidth: 1)
            context.fill(circle(c, 9 * s), with: .color(lime.opacity(0.18)))
            context.fill(circle(c, 5 * s), with: .color(lime))
            let spots: [CGPoint] = [
                CGPoint(x: 15, y: 23), CGPoint(x: 62, y: 33), CGPoint(x: 33, y: 65), CGPoint(x: 51, y: 11), CGPoint(x: 9, y: 49),
                CGPoint(x: 58, y: 58), CGPoint(x: 24, y: 8),
            ]
            for p in spots.prefix(max(0, min(devices, spots.count))) {
                context.fill(circle(CGPoint(x: p.x * s, y: p.y * s), 3 * s), with: .color(DS.label2))
            }
        }
        .accessibilityHidden(true)
    }
}
