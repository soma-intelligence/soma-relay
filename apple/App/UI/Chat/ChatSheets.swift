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
                                .foregroundStyle(Theme.dashed)
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
                }
            }
            .navigationTitle("Sondage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer") {
                        onSend(question, filled, multi)
                        Haptics.success()
                        dismiss()
                    }
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
                            Circle().fill(Theme.net.opacity(0.18)).frame(width: 44, height: 44)
                            Circle().fill(Theme.net).frame(width: 16, height: 16)
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
                    .foregroundStyle(Theme.text)
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glassProminent)
            } else {
                Button {
                    send(live: nil)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Theme.danger, in: Circle())
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Envoyer ma position")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Text(accuracyText)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(coordinate == nil)
                Divider().overlay(Theme.cardStroke)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "location.fill.viewfinder")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Theme.mesh, in: Circle())
                            .foregroundStyle(Theme.onMesh)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Partager en direct")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Text("Ta position suit tes déplacements, chiffrée.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
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
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(coordinate == nil)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                    .foregroundStyle(.white, live ? Theme.mesh : Theme.danger)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).roundIcon()
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .padding()
            .accessibilityLabel("Fermer")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if live { Circle().fill(Theme.danger).frame(width: 8, height: 8) }
                    Text(live ? "\(name) · en direct" : name)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                }
                Text(detail(live: live, coord: coord))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    Button {
                        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Position"
                        if let url = URL(string: "https://maps.apple.com/?ll=\(coord.0),\(coord.1)&q=\(q)") { openURL(url) }
                    } label: {
                        Label("Ouvrir dans Plans", systemImage: "map")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    if live, let onStop {
                        Button(role: .destructive) {
                            onStop()
                        } label: {
                            Text("Arrêter").frame(minHeight: 30)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                        Avatar(
                            name: c.title, size: 40, tint: Theme.incoming, icon: c.kind == .channel ? "number" : c.kind == .group ? "person.3.fill" : nil,
                            photo: model.photo(of: c))
                        Text(c.title).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "arrowshape.turn.up.right").foregroundStyle(Theme.secondary)
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
                        Text(item.id).font(Theme.mono(11)).textSelection(.enabled)
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 8) {
                    ForEach(Self.emojis, id: \.self) { e in
                        Button {
                            pick(e)
                        } label: {
                            Text(e).font(.system(size: 32)).frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(e)
                    }
                }
                .padding()
                TextField("Ou tape un emoji", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .onChange(of: custom) { _, new in
                        if let first = new.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000 }) {
                            pick(String(first))
                        }
                    }
            }
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
