import Foundation
import LinkPresentation
import os
import UIKit

/// Sender-side link previews (spec v1.1 section 1): first http(s) URL of the text, fetched with
/// LPMetadataProvider in 5 s at most, image shrunk to a JPEG of 600 px and 40 KiB at most. The
/// receiver never fetches anything.
nonisolated enum LinkPreviewer {
    static let maxImageBytes = 40 * 1024

    static func firstURL(in text: String) -> URL? {
        guard text.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { continue }
            // Only URLs the user typed with their scheme (no "example.com" guesses).
            if let r = Range(match.range, in: text), text[r].lowercased().hasPrefix("http") { return url }
        }
        return nil
    }

    static func fetch(_ url: URL) async -> AppMessage.LinkPreview? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AppMessage.LinkPreview?, Never>) in
            let once = Once(continuation)
            let provider = LPMetadataProvider()
            provider.timeout = 5
            once.retained = provider
            provider.startFetchingMetadata(for: url) { metadata, _ in
                guard let metadata else { return once.resume(nil) }
                let final = metadata.url ?? metadata.originalURL ?? url
                var host = final.host() ?? url.host() ?? ""
                if host.hasPrefix("www.") { host.removeFirst(4) }
                let base = AppMessage.LinkPreview(url: url.absoluteString, title: metadata.title, description: nil, site: host, image: nil)
                guard let image = metadata.imageProvider ?? metadata.iconProvider, image.canLoadObject(ofClass: UIImage.self) else {
                    return once.resume(base.title == nil ? nil : base)
                }
                // The image may be slow: the preview goes without it after 3 s.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(base) }
                image.loadObject(ofClass: UIImage.self) { object, _ in
                    var out = base
                    if let ui = object as? UIImage { out.image = shrink(ui)?.base64EncodedString() }
                    once.resume(out)
                }
            }
        }
    }

    /// JPEG, longest side 600 px (then smaller), at most 40 KiB.
    static func shrink(_ image: UIImage) -> Data? {
        for side in [600.0, 480, 360, 240] {
            let scale = min(1, side / max(image.size.width * image.scale, image.size.height * image.scale))
            let size = CGSize(width: max(1, image.size.width * image.scale * scale), height: max(1, image.size.height * image.scale * scale))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.7, 0.55, 0.4, 0.3] {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= maxImageBytes { return data }
            }
        }
        return nil
    }

    /// Resumes a continuation once, whoever comes first.
    private final class Once: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<AppMessage.LinkPreview?, Never>
        /// Keeps the provider alive until it answers.
        var retained: AnyObject?
        init(_ continuation: CheckedContinuation<AppMessage.LinkPreview?, Never>) { self.continuation = continuation }
        func resume(_ value: AppMessage.LinkPreview?) {
            let first = lock.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first {
                continuation.resume(returning: value)
                DispatchQueue.main.async { self.retained = nil }
            }
        }
    }
}
