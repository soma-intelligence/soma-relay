import MapKit
import SafariServices
import SwiftUI

// MARK: - Poll creation

struct PollComposer: View {
    let onSend: (String, [String], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options: [Option] = [Option(), Option()]
    @State private var multi = false
    @FocusState private var focus: UUID?
    @FocusState private var questionFocused: Bool

    struct Option: Identifiable, Equatable {
        let id = UUID()
        var text = ""
    }

    init(onSend: @escaping (String, [String], Bool) -> Void, demo: Bool = false) {
        self.onSend = onSend
        if demo {
            _question = State(initialValue: "On mange où ce soir ?")
            _options = State(initialValue: [Option(text: "Food truck thaï"), Option(text: "Crêpes"), Option(text: "Pizza au feu de bois"), Option()])
        }
    }

    private var filled: [String] {
        options.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var valid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (2...12).contains(filled.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Pose ta question", text: $question, axis: .vertical)
                        .font(.headline)
                        .lineLimit(1...4)
                        .focused($questionFocused)
                        .submitLabel(.next)
                }
                Section {
                    ForEach($options) { $option in
                        HStack(spacing: 10) {
                            Image(systemName: multi ? "square" : "circle")
                                .foregroundStyle(DS.label3)
                                .accessibilityHidden(true)
                            TextField("Option \((options.firstIndex(of: option) ?? 0) + 1)", text: $option.text)
                                .focused($focus, equals: option.id)
                                .submitLabel(.next)
                                .onSubmit { addIfLast(option) }
                        }
                    }
                    .onDelete { offsets in
                        guard options.count - offsets.count >= 2 else { return }
                        options.remove(atOffsets: offsets)
                    }
                    .onMove { options.move(fromOffsets: $0, toOffset: $1) }
                    if options.count < 12 {
                        Button("Ajouter une option", systemImage: "plus.circle.fill") {
                            let new = Option()
                            withAnimation(.snappy) { options.append(new) }
                            focus = new.id
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    Text("De 2 à 12 options. Chacun voit les résultats en direct.")
                }
                Section {
                    Toggle("Plusieurs réponses", isOn: $multi.animation(.snappy))
                        .tint(DS.accentFill)
                }
                .listRowBackground(DS.cell)
            }
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .navigationTitle("Sondage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer", systemImage: "arrow.up") {
                        onSend(question, filled, multi)
                        Haptics.success()
                        dismiss()
                    }
                    .tint(DS.accentFill)
                    .disabled(!valid)
                }
            }
            .onAppear { if question.isEmpty { questionFocused = true } }
        }
    }

    private func addIfLast(_ option: Option) {
        guard option.id == options.last?.id, options.count < 12, !option.text.isEmpty else { return }
        let new = Option()
        options.append(new)
        focus = new.id
    }
}

// MARK: - Location

/// Map centred on me, "Envoyer ma position", and live sharing for 15 min, 1 h or 8 h.
struct LocationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let onSend: (Double, Double, Double?, TimeInterval?) -> Void

    @State private var position: MapCameraPosition = .automatic
    @State private var centred = false
    @State private var duration: TimeInterval = 3600

    static let durations: [(TimeInterval, String)] = [(900, "15 min"), (3600, "1 h"), (28_800, "8 h")]

    private var sharer: LocationSharer { model.locationSharer }

    private var coordinate: CLLocationCoordinate2D? {
        sharer.coordinate ?? (model.demo ? DemoData.here : nil)
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                if let coordinate {
                    Annotation("Toi", coordinate: coordinate) {
                        ZStack {
                            Circle().fill(DS.accentFill.opacity(0.22)).frame(width: 44, height: 44)
                            Circle().fill(DS.accentFill).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) { panel }
            .navigationTitle("Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", role: .cancel) { dismiss() }
                }
            }
        }
        .onAppear { sharer.startPreview() }
        .onDisappear { sharer.stopPreview() }
        .onChange(of: coordinate?.latitude, initial: true) {
            guard !centred, let coordinate else { return }
            centred = true
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
        }
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 12) {
            if sharer.denied && !model.demo {
                Text("Soma Relay n'a pas accès à ta position.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.label)
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.dsPrimary)
            } else {
                Button {
                    send(live: nil)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(DS.fill2, in: Circle())
                            .foregroundStyle(DS.label)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Envoyer ma position")
                                .font(DS.TextStyle.headline)
                                .foregroundStyle(DS.label)
                            Text(accuracyText)
                                .font(DS.TextStyle.footnote)
                                .foregroundStyle(DS.label2)
                        }
                        Spacer()
                        DSChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(coordinate == nil)
                Rectangle().fill(DS.separator).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "location.fill.viewfinder")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(DS.accentSoft, in: Circle())
                            .foregroundStyle(DS.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Partager en direct")
                                .font(DS.TextStyle.headline)
                                .foregroundStyle(DS.label)
                            Text("Ta position suit tes déplacements, chiffrée.")
                                .font(DS.TextStyle.footnote)
                                .foregroundStyle(DS.label2)
                        }
                    }
                    Picker("Durée", selection: $duration) {
                        ForEach(Self.durations, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    Button {
                        send(live: duration)
                    } label: {
                        Text("Partager pendant \(Self.durations.first { $0.0 == duration }?.1 ?? "")")
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(coordinate == nil)
                }
            }
        }
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var accuracyText: String {
        guard coordinate != nil else { return "Recherche de ta position…" }
        if let a = sharer.accuracy { return "Précision \(Int(a.rounded())) m" }
        return "Position trouvée"
    }

    private func send(live: TimeInterval?) {
        guard let coordinate else { return }
        onSend(coordinate.latitude, coordinate.longitude, sharer.accuracy, live)
        Haptics.success()
        dismiss()
    }
}

/// Full map of a location message, following live updates. Open in Maps, stop my share.
struct MapViewer: View {
    let item: ChatItem
    let name: String
    let onStop: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        let coord = AppModel.coordinate(of: item) ?? (0, 0)
        let point = CLLocationCoordinate2D(latitude: coord.0, longitude: coord.1)
        let live = AppModel.isLive(item)
        Map(position: $position) {
            Annotation(name, coordinate: point) {
                Image(systemName: live ? "location.circle.fill" : "mappin.circle.fill")
                    .font(.system(size: 36))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(live ? DS.onAccent : .white, live ? DS.accentFill : DS.danger)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.label)
                    .frame(width: DS.roundButton, height: DS.roundButton)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel("Fermer")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if live { DSStatusDot() }
                    Text(live ? "\(name) · en direct" : name)
                        .font(DS.TextStyle.headline)
                        .foregroundStyle(DS.label)
                }
                Text(detail(live: live, coord: coord))
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.label2)
                HStack(spacing: 10) {
                    Button {
                        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Position"
                        if let url = URL(string: "https://maps.apple.com/?ll=\(coord.0),\(coord.1)&q=\(q)") { openURL(url) }
                    } label: {
                        Label("Ouvrir dans Plans", systemImage: "map")
                    }
                    .buttonStyle(.dsPrimary)
                    if live, let onStop {
                        Button(role: .destructive) {
                            onStop()
                        } label: {
                            Text("Arrêter").foregroundStyle(DS.danger).padding(.horizontal, 20)
                        }
                        .buttonStyle(.dsSecondary)
                        .fixedSize()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.horizontal, 12)
        }
        .onChange(of: coord.0 + coord.1, initial: true) {
            withAnimation(.smooth) {
                position = .region(MKCoordinateRegion(center: point, latitudinalMeters: 800, longitudinalMeters: 800))
            }
        }
    }

    private func detail(live: Bool, coord: (Double, Double)) -> String {
        var parts = [String(format: "%.5f, %.5f", coord.0, coord.1)]
        if live, let until = item.message.location?.liveUntil {
            parts.append("jusqu'à " + Date(timeIntervalSince1970: Double(until) / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR"))))
        } else if let ts = item.state.live?.ts ?? Optional(item.message.ts) {
            parts.append(Date(timeIntervalSince1970: Double(ts) / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR"))))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Forward

struct ForwardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: ChatItem
    @State private var query = ""

    private var rows: [ConversationRecord] {
        model.conversations.filter { c in
            (item.message.attachment == nil || c.kind != .channel)
                && (query.isEmpty || c.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    var body: some View {
        NavigationStack {
            List(rows) { c in
                Button {
                    model.forward(item, to: c.id)
                    Haptics.success()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        DSAvatar(
                            name: c.title, size: 40, icon: c.kind == .channel ? "number" : c.kind == .group ? "person.3.fill" : nil,
                            photo: model.photo(of: c))
                        Text(c.title).foregroundStyle(DS.label)
                        Spacer()
                        Image(systemName: "arrowshape.turn.up.right").foregroundStyle(DS.label2)
                    }
                }
            }
            .overlay {
                if rows.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Conversation")
            .navigationTitle("Transférer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler", role: .cancel) { dismiss() } }
            }
        }
    }
}

// MARK: - Info

struct MessageInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: ChatItem

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(item.isMine ? "Envoyé" : "Reçu", value: format(item.message.ts))
                    if let edited = item.state.editedAt { LabeledContent("Modifié", value: format(edited)) }
                    if let at = item.expireAt { LabeledContent("Disparaît", value: format(at)) }
                    if item.message.forwarded == true { LabeledContent("Transféré", value: "oui") }
                }
                Section("Chemin") {
                    LabeledContent("Transport", value: transport)
                    if let hops = item.hops { LabeledContent("Sauts", value: "\(hops)") }
                    if let relays = item.relays, relays > 0 { LabeledContent("Relais", value: "\(relays)") }
                    if item.isMine { LabeledContent("État", value: item.accessibilityStatus) }
                }
                if let a = item.message.attachment {
                    Section("Pièce jointe") {
                        if let name = a.name { LabeledContent("Nom", value: name) }
                        LabeledContent("Taille", value: ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                        LabeledContent("Type", value: a.mime)
                        LabeledContent("Stockage", value: a.url != nil ? "nœud (chiffré)" : "dans le message")
                    }
                }
                Section {
                    LabeledContent("Identifiant") {
                        Text(item.id).font(DS.TextStyle.fingerprint(11)).textSelection(.enabled)
                    }
                } footer: {
                    Text("Chiffré de bout en bout. Ces détails ne quittent pas ton téléphone.")
                }
            }
            .navigationTitle("Infos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }

    private var transport: String {
        switch item.transport {
        case .mesh: "Mesh (Bluetooth, Wi-Fi direct)"
        case .node: "Internet (nœud)"
        case .sms: "SMS chiffré"
        case .local: "Pas encore parti"
        }
    }

    private func format(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().second().locale(Locale(identifier: "fr_FR")))
    }
}

// MARK: - Any emoji

struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    static let emojis = [
        "👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "🎉", "👏", "😍", "🤔", "😅",
        "🙌", "💯", "✅", "❌", "👀", "🤝", "💪", "🥲", "😎", "🤯", "😴", "🥳",
        "😡", "🤗", "🙈", "💡", "⚡️", "📍", "🎶", "☀️", "🌧️", "🍕", "☕️", "🍻",
        "🚀", "🏃", "🎯", "📎", "🔒", "📡", "🛰️", "🧭", "⛺️", "🚲", "🫶", "👋",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Self.emojis, id: \.self) { e in
                        Button {
                            pick(e)
                        } label: {
                            Text(e).font(.system(size: 30))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(DS.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(e)
                    }
                }
                .padding(.horizontal, DS.Space.margin)
                .padding(.top, 8)
                TextField("Ou tape un emoji", text: $custom)
                    .font(DS.TextStyle.body)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(DS.fill, in: Capsule())
                    .padding(.horizontal, DS.Space.margin)
                    .padding(.vertical, 16)
                    .onChange(of: custom) { _, new in
                        if let first = new.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000 }) {
                            pick(String(first))
                        }
                    }
            }
            .background(DS.background)
            .navigationTitle("Réagir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler", role: .cancel) { dismiss() } }
            }
        }
    }

    private func pick(_ emoji: String) {
        onPick(emoji)
        dismiss()
    }
}

// MARK: - Safari

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
