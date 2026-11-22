import PhotosUI
import SwiftUI
import UIKit

/// Square crop for a profile photo: pan and pinch the picture under a square frame, the circle
/// shows what the avatar will look like. Returns the square at full resolution (the model
/// shrinks it to 256 px).
struct PhotoCropView: View {
    let image: UIImage
    var title = "Recadrer"
    let onDone: (UIImage?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private static let maxZoom: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 32, geo.size.height * 0.62)
            let fill = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let shown = CGSize(width: image.size.width * fill * zoom, height: image.size.height * fill * zoom)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(offset)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .accessibilityHidden(true)
                CropMask(side: side)
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)
                VStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.top, 12)
                    Text("Déplace et pince pour cadrer")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    HStack(spacing: 12) {
                        Button {
                            onDone(nil)
                        } label: {
                            Text("Annuler").font(.body.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 50)
                        }
                        .buttonStyle(.glass)
                        Button {
                            Haptics.success()
                            onDone(crop(side: side, fill: fill))
                        } label: {
                            Text("Choisir").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(side: side, fill: fill).simultaneously(with: pinch(side: side, fill: fill)))
            .onTapGesture(count: 2) {
                withAnimation(spring) {
                    zoom = zoom > 1.01 ? 1 : 2
                    baseZoom = zoom
                    offset = clamp(offset, side: side, fill: fill, zoom: zoom)
                    baseOffset = offset
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Agrandir") { setZoom(min(Self.maxZoom, zoom * 1.4), side: side, fill: fill) }
            .accessibilityAction(named: "Réduire") { setZoom(max(1, zoom / 1.4), side: side, fill: fill) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    private var spring: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.2) }

    private func setZoom(_ value: CGFloat, side: CGFloat, fill: CGFloat) {
        withAnimation(spring) {
            zoom = value
            baseZoom = value
            offset = clamp(offset, side: side, fill: fill, zoom: value)
            baseOffset = offset
        }
    }

    private func drag(side: CGFloat, fill: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                withAnimation(spring) { offset = clamp(offset, side: side, fill: fill, zoom: zoom) }
                baseOffset = offset
            }
    }

    private func pinch(side: CGFloat, fill: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = min(Self.maxZoom * 1.2, max(0.8, baseZoom * value.magnification)) }
            .onEnded { _ in
                withAnimation(spring) {
                    zoom = min(Self.maxZoom, max(1, zoom))
                    offset = clamp(offset, side: side, fill: fill, zoom: zoom)
                }
                baseZoom = zoom
                baseOffset = offset
            }
    }

    /// The picture always covers the square.
    private func clamp(_ o: CGSize, side: CGFloat, fill: CGFloat, zoom: CGFloat) -> CGSize {
        let maxX = max(0, (image.size.width * fill * zoom - side) / 2)
        let maxY = max(0, (image.size.height * fill * zoom - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    /// The part of the picture under the square, as a square image (at most 1024 px).
    private func crop(side: CGFloat, fill: CGFloat) -> UIImage {
        let o = clamp(offset, side: side, fill: fill, zoom: zoom)
        let scale = fill * zoom
        // Square origin in image points.
        let x = (image.size.width * scale - side) / 2 - o.width
        let y = (image.size.height * scale - side) / 2 - o.height
        let rect = CGRect(x: x / scale, y: y / scale, width: side / scale, height: side / scale)
        let out = min(1024, rect.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { _ in
            let k = out / rect.width
            image.draw(in: CGRect(x: -rect.minX * k, y: -rect.minY * k, width: image.size.width * k, height: image.size.height * k))
        }
    }
}

/// Everything dark except the circle.
nonisolated private struct CropMask: Shape {
    let side: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(rect.insetBy(dx: -200, dy: -200))
        p.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        return p
    }
}

/// An avatar you can tap to choose, take or remove a photo (Réglages, Ma carte, group).
struct EditablePhoto: View {
    @Environment(AppModel.self) private var model
    let name: String
    let photo: UIImage?
    var size: CGFloat = 84
    var icon: String?
    var tint: Color = Theme.mesh.opacity(0.25)
    var cropTitle = "Recadrer"
    let onPick: (UIImage?) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var flow: Flow?

    struct Flow: Identifiable {
        let id = UUID()
        var image: UIImage?
    }

    private var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) || model.demo }

    var body: some View {
        Menu {
            Button("Choisir une photo", systemImage: "photo.on.rectangle") { showPicker = true }
            if hasCamera {
                Button("Prendre une photo", systemImage: "camera") { flow = Flow(image: nil) }
            }
            if photo != nil {
                Button("Supprimer la photo", systemImage: "trash", role: .destructive) { onPick(nil) }
            }
        } label: {
            Avatar(name: name, size: size, tint: tint, icon: icon, photo: photo)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: max(10, size * 0.14), weight: .semibold))
                        .foregroundStyle(Theme.onStrong)
                        .frame(width: max(22, size * 0.32), height: max(22, size * 0.32))
                        .background(Theme.strong, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo == nil ? "Ajouter une photo" : "Modifier la photo")
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    flow = Flow(image: image)
                } else {
                    model.banner = "Impossible d'ouvrir cette photo."
                }
            }
        }
        .fullScreenCover(item: $flow) { start in
            PhotoFlowView(start: start.image, cropTitle: cropTitle) { result in
                flow = nil
                if let result { onPick(result) }
            }
        }
    }
}

/// Camera (when there is no picture yet), then the crop.
struct PhotoFlowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let start: UIImage?
    var cropTitle = "Recadrer"
    let done: (UIImage?) -> Void
    @State private var image: UIImage?

    init(start: UIImage?, cropTitle: String = "Recadrer", done: @escaping (UIImage?) -> Void) {
        self.start = start
        self.cropTitle = cropTitle
        self.done = done
        _image = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            if let image {
                PhotoCropView(image: image, title: cropTitle) { cropped in
                    if cropped == nil, start == nil {
                        withAnimation(.smooth) { self.image = nil }
                    } else {
                        done(cropped)
                    }
                }
                .transition(.opacity)
            } else {
                CameraCaptureView(front: true) { shot in
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth) { image = shot }
                } onCancel: {
                    done(nil)
                }
                .transition(.opacity)
            }
        }
    }
}
