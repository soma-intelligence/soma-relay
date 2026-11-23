import Photos
import SwiftUI

/// "Joindre" (relay-screens 04): a glass sheet with the recent photos (multi-select, the camera
/// first), round actions for what Relay can send, the mesh delay note, then a caption and
/// "Envoyer N" once photos are picked. Access to the library is asked the iOS way the first time
/// the sheet opens; with limited access the strip shows the photos the user shared, with none
/// it shows only the camera and the Photos action (system picker, no permission needed).
struct AttachSheet: View {
    enum Action: String {
        case camera, photos, video, file, location, poll
    }

    let isChannel: Bool
    let canUseCamera: Bool
    let canRecordVideo: Bool
    /// Disappearing messages timer of the conversation; nil in channels.
    var timer: Binding<Int>?
    let choose: (Action) -> Void
    let send: ([PHAsset], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var library = RecentPhotos()
    @State private var selected: [String] = []
    @State private var caption = ""

    private var showsMedia: Bool { !isChannel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Joindre")
                    .font(DS.TextStyle.title2)
                    .foregroundStyle(DS.label)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.label)
                        .frame(width: DS.roundButton, height: DS.roundButton)
                        .background(DS.fill2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer")
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            if showsMedia { strip.padding(.top, 18) }

            actions
                .padding(.top, showsMedia ? 22 : 18)

            if showsMedia {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(DS.label3)
                    Text("Les fichiers partent chiffrés. Sur le mesh, une photo met quelques secondes.")
                        .font(DS.TextStyle.subheadline)
                        .foregroundStyle(DS.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 30)
                .padding(.top, 18)
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 0)

            if !selected.isEmpty {
                sendBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: selected.isEmpty)
        .presentationDetents([.height(showsMedia ? (selected.isEmpty ? 530 : 610) : 330), .large])
        .presentationCornerRadius(DS.Radius.sheet)
        .presentationDragIndicator(.visible)
        .task {
            guard showsMedia else { return }
            await library.load()
            if DemoData.screen == "attach", selected.isEmpty {
                selected = Array(library.assets.prefix(2).map(\.localIdentifier))
            }
        }
    }

    // MARK: Recent photos

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if canUseCamera {
                    Button {
                        choose(.camera)
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(DS.label)
                            .frame(width: 116, height: 154)
                            .background(DS.fill2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Prendre une photo")
                }
                ForEach(library.assets, id: \.localIdentifier) { asset in
                    PhotoTile(asset: asset, library: library, index: selected.firstIndex(of: asset.localIdentifier)) {
                        Haptics.select()
                        if let i = selected.firstIndex(of: asset.localIdentifier) {
                            selected.remove(at: i)
                        } else if selected.count < 10 {
                            selected.append(asset.localIdentifier)
                        }
                    }
                }
                if library.status == .denied || library.status == .restricted {
                    Button {
                        choose(.photos)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 22))
                            Text("Choisir dans Photos").font(DS.TextStyle.footnote).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(DS.label2)
                        .padding(10)
                        .frame(width: 116, height: 154)
                        .background(DS.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollClipDisabled()
    }

    // MARK: Actions

    private struct Item: Identifiable {
        let id: String
        let title: String
        let icon: String
        var action: Action?
    }

    private var items: [Item] {
        var out: [Item] = []
        if showsMedia {
            out.append(Item(id: "photos", title: "Photos", icon: "photo.on.rectangle", action: .photos))
            if canRecordVideo { out.append(Item(id: "video", title: "Vidéo", icon: "video.fill", action: .video)) }
            out.append(Item(id: "file", title: "Fichier", icon: "doc.fill", action: .file))
        }
        out.append(Item(id: "location", title: "Position", icon: "location.fill", action: .location))
        out.append(Item(id: "poll", title: "Sondage", icon: "chart.bar.fill", action: .poll))
        if timer != nil { out.append(Item(id: "timer", title: "Éphémère", icon: "timer")) }
        return out
    }

    private var actions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 18) {
            ForEach(items) { item in
                if let action = item.action {
                    Button {
                        Haptics.tap()
                        choose(action)
                    } label: {
                        roundLabel(item.title, icon: item.icon)
                    }
                    .buttonStyle(.plain)
                } else if let timer {
                    Menu {
                        Picker("Messages éphémères", selection: timer) {
                            ForEach(AppModel.timerChoices, id: \.self) { s in
                                Text(s == 0 ? "Désactivés" : AppModel.timerLabel(s)).tag(s)
                            }
                        }
                    } label: {
                        roundLabel(item.title, icon: item.icon, value: timer.wrappedValue == 0 ? nil : AppModel.timerLabel(timer.wrappedValue))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Messages éphémères")
                    .accessibilityValue(AppModel.timerLabel(timer.wrappedValue))
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func roundLabel(_ title: String, icon: String, value: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(value == nil ? DS.label : DS.onAccent)
                .frame(width: 62, height: 62)
                .background(value == nil ? DS.fill2 : DS.accentFill, in: Circle())
            Text(value ?? title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.label)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: Send

    private var sendBar: some View {
        HStack(spacing: 10) {
            TextField("Ajouter une légende", text: $caption, axis: .vertical)
                .font(DS.TextStyle.body)
                .lineLimit(1...3)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(minHeight: 48)
                .background(DS.fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityLabel("Légende")
            Button {
                let picked = selected.compactMap { id in library.assets.first { $0.localIdentifier == id } }
                send(picked, caption)
                Haptics.success()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text("Envoyer \(selected.count)")
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.onAccent)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .glassEffect(.regular.tint(DS.accentFill).interactive(), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Envoyer \(selected.count) photo\(selected.count > 1 ? "s" : "")")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

/// One thumbnail of the strip with its selection mark (lime check, or an empty ring).
private struct PhotoTile: View {
    let asset: PHAsset
    let library: RecentPhotos
    let index: Int?
    let toggle: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        DS.cell2
                    }
                }
                .frame(width: 116, height: 154)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                ZStack {
                    if index != nil {
                        Circle().fill(DS.accentFill)
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.onAccent)
                    } else {
                        Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                            .background(Circle().fill(.black.opacity(0.12)))
                    }
                }
                .frame(width: 26, height: 26)
                .padding(8)
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) { image = await library.thumbnail(asset, size: CGSize(width: 116, height: 154)) }
        .accessibilityLabel(asset.mediaType == .video ? "Vidéo récente" : "Photo récente")
        .accessibilityValue(index != nil ? "choisie" : "")
        .accessibilityAddTraits(index != nil ? [.isButton, .isSelected] : .isButton)
    }
}

/// The last photos of the library through PhotoKit. Read access is requested on first use;
/// limited access shows only what the user shared.
@Observable
final class RecentPhotos {
    private(set) var assets: [PHAsset] = []
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @ObservationIgnored private let manager = PHCachingImageManager()

    func load() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 30
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        assets = out
    }

    func thumbnail(_ asset: PHAsset, size: CGSize) async -> UIImage? {
        await Self.image(asset, target: CGSize(width: size.width * 3, height: size.height * 3), manager: manager)
    }

    /// One callback (high quality), off the main actor: PhotoKit may answer on any queue.
    nonisolated private static func image(_ asset: PHAsset, target: CGSize, manager: PHCachingImageManager) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (done: CheckedContinuation<UIImage?, Never>) in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { @Sendable image, _ in
                done.resume(returning: image)
            }
        }
    }

    /// Full-size original data, for the media encoder.
    nonisolated static func data(of asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, _, _, _ in
                done.resume(returning: data)
            }
        }
    }
}
