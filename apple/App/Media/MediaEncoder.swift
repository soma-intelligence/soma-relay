import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Media encoding before sealing (spec section 5): photos HEIC q 0.6 longest side 2048 px with a
/// 64 px thumbnail, video HEVC 720p, voice AAC 32 kbps mono m4a.
nonisolated enum MediaEncoder {
    struct EncodedImage: Sendable {
        var data: Data
        var mime: String
        var width: Int
        var height: Int
        var thumb: String?
    }

    static func image(from data: Data) -> EncodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var mime = "image/heic"
        var out = encode(image, type: .heic, quality: 0.6)
        if out == nil {
            mime = "image/jpeg"
            out = encode(image, type: .jpeg, quality: 0.7)
        }
        guard let out else { return nil }
        return EncodedImage(data: out, mime: mime, width: image.width, height: image.height, thumb: thumbnail(of: image))
    }

    static func image(_ uiImage: UIImage) -> EncodedImage? {
        guard let data = uiImage.jpegData(compressionQuality: 0.95) else { return nil }
        return image(from: data)
    }

    /// 64 px preview, base64, at most 4 KiB.
    static func thumbnail(of image: CGImage) -> String? {
        let scale = 64 / CGFloat(max(image.width, image.height))
        let size = CGSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let small = renderer.image { _ in UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size)) }
        guard let cg = small.cgImage else { return nil }
        for q in [0.5, 0.3, 0.15] {
            if let d = encode(cg, type: .jpeg, quality: q), d.count <= 4096 { return d.base64EncodedString() }
        }
        return nil
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// HEVC, scaled to fit 1280 x 720, 2 minutes and 40 MB at most.
    static func video(_ url: URL) async throws -> (data: Data, width: Int, height: Int, durationMs: Int, thumb: String?) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw CocoaError(.fileReadCorruptFile) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = natural.applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let scale = min(1, min(1280 / max(size.width, size.height), 720 / min(size.width, size.height)))
        let target = CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.renderSize = target
        let preset = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
            ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetMediumQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { throw CocoaError(.fileWriteUnknown) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        export.videoComposition = composition
        export.fileLengthLimit = 40 * 1024 * 1024
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 120, preferredTimescale: 600))
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: out, as: .mp4)
        let data = try Data(contentsOf: out)
        try? FileManager.default.removeItem(at: out)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let thumb = (try? await generator.image(at: .zero).image).flatMap(thumbnail(of:))
        return (data, Int(target.width), Int(target.height), Int(min(120, duration.seconds) * 1000), thumb)
    }

    static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
