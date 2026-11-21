import AVKit
import SwiftUI

/// Full-screen photo, video or file, opened from its sealed local copy.
struct MediaViewer: View {
    let item: ChatItem
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                if let url = shareURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).roundIcon(fill: .white.opacity(0.15), foreground: .white)
                    }
                    .accessibilityLabel("Partager")
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).roundIcon(fill: .white.opacity(0.15), foreground: .white)
                }
                .accessibilityLabel("Fermer")
            }
            .padding()
        }
    }

    private var ext: String {
        switch item.message.kind {
        case .video: "mp4"
        case .image: item.message.attachment?.mime == "image/jpeg" ? "jpg" : "heic"
        default: (item.message.attachment?.name as NSString?)?.pathExtension ?? "bin"
        }
    }

    private var shareURL: URL? {
        guard let path = item.mediaPath else { return nil }
        if item.message.kind == .file, let name = item.message.attachment?.name, let data = MediaStore.load(path) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }
        return MediaStore.temporaryURL(path, ext: ext)
    }

    @ViewBuilder private var content: some View {
        switch item.message.kind {
        case .image:
            if let data = item.mediaPath.flatMap(MediaStore.load), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture().onChanged { zoom = max(1, $0.magnification) }.onEnded { _ in withAnimation(.snappy) { zoom = 1 } })
                    .accessibilityLabel("Photo")
            } else {
                ProgressView().tint(.white)
            }
        case .video:
            if let path = item.mediaPath, let url = MediaStore.temporaryURL(path, ext: "mp4") {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                ProgressView().tint(.white)
            }
        default:
            VStack(spacing: 12) {
                Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.white)
                Text(item.message.attachment?.name ?? "Fichier").foregroundStyle(.white)
                Text("Touche Partager pour l'ouvrir dans une autre app.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
