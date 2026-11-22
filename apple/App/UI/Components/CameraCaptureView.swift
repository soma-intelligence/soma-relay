@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Full-screen photo capture: live preview, shutter, front/back switch. Without a camera (the
/// simulator) the demo build shows a still scene instead, so the flow can still be walked.
struct CameraCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var front = false
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var camera = CameraController()
    @State private var flash = false
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .accessibilityLabel("Aperçu de la caméra")
            } else if model.demo {
                Image(uiImage: DemoData.cameraScene())
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .accessibilityLabel("Aperçu de la caméra (démo)")
            } else {
                EmptyState(
                    title: denied ? "Caméra refusée" : "Caméra indisponible",
                    message: denied ? "Autorise la caméra dans Réglages pour prendre une photo." : "Cet appareil n'a pas de caméra.",
                    systemImage: "camera.metering.unknown")
                    .environment(\.colorScheme, .dark)
            }
            Color.white.opacity(flash ? 0.85 : 0).ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel("Fermer")
                    Spacer()
                }
                .padding(.horizontal, 16)
                Spacer()
                HStack {
                    Color.clear.frame(width: 52, height: 52)
                    Spacer()
                    Button(action: shoot) {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                            Circle().fill(.white).frame(width: 64, height: 64)
                        }
                    }
                    .buttonStyle(ShutterStyle())
                    .disabled(!camera.available && !model.demo)
                    .accessibilityLabel("Prendre la photo")
                    Spacer()
                    Button {
                        Haptics.select()
                        camera.flip()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .opacity(camera.available ? 1 : 0)
                    .disabled(!camera.available)
                    .accessibilityLabel("Changer de caméra")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
        .statusBarHidden()
        .task {
            denied = !(await camera.start(front: front))
        }
        .onDisappear { camera.stop() }
    }

    private func shoot() {
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: reduceMotion ? 0.15 : 0.3).delay(0.08)) { flash = false }
        if camera.available {
            camera.capture { image in
                if let image { onCapture(image) }
            }
        } else if model.demo {
            onCapture(DemoData.cameraScene())
        }
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

/// AVFoundation photo session. The session runs on its own queue.
@Observable
final class CameraController {
    @ObservationIgnored nonisolated(unsafe) let session = AVCaptureSession()
    @ObservationIgnored nonisolated(unsafe) private let output = AVCapturePhotoOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "me.somalabs.relay.camera")
    @ObservationIgnored private var delegate: PhotoDelegate?
    private(set) var available = false
    private var position: AVCaptureDevice.Position = .back

    /// False when access was refused.
    func start(front: Bool) async -> Bool {
        guard AVCaptureDevice.default(for: .video) != nil else { return true }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { return false }
        position = front ? .front : .back
        configure()
        available = true
        let session = session
        queue.async { session.startRunning() }
        return true
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func flip() {
        position = position == .back ? .front : .back
        configure()
    }

    private func configure() {
        let session = session
        let output = output
        let position = position
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            for input in session.inputs { session.removeInput(input) }
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
            {
                session.addInput(input)
            }
            if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
    }

    @ObservationIgnored private var pending: ((UIImage?) -> Void)?

    func capture(_ done: @escaping (UIImage?) -> Void) {
        pending = done
        let delegate = PhotoDelegate { [weak self] image in
            Task { @MainActor in
                self?.delegate = nil
                self?.pending?(image)
                self?.pending = nil
            }
        }
        self.delegate = delegate
        let output = output
        queue.async { output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate) }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let done: @Sendable (UIImage?) -> Void
    init(done: @escaping @Sendable (UIImage?) -> Void) { self.done = done }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        done(photo.fileDataRepresentation().flatMap(UIImage.init(data:)))
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
