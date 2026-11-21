import Foundation
import PDFKit
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Documents (spec v1.1 section 1): page count and a small first-page thumbnail made by the
/// sender, plus the labels the file bubble shows.
nonisolated enum DocumentInfo {
    static func pdfPages(_ data: Data) -> Int? {
        PDFDocument(data: data)?.pageCount
    }

    /// First page of a PDF, as the tiny base64 JPEG of the attachment (<= 4 KiB).
    static func pdfThumbnail(_ data: Data) -> String? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
        return tinyJPEG(image)
    }

    /// Quick Look thumbnail of any file (Word, PowerPoint, Keynote, images...).
    static func thumbnail(for url: URL) async -> String? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160), scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return tinyJPEG(rep.uiImage)
    }

    static func tinyJPEG(_ image: UIImage) -> String? {
        for side in [160.0, 128, 96] {
            let scale = side / max(image.size.width, image.size.height, 1)
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let small = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for q in [0.6, 0.45, 0.3] {
                if let d = small.jpegData(compressionQuality: q), d.count <= 4096 { return d.base64EncodedString() }
            }
        }
        return nil
    }

    /// `PDF`, `DOCX`, `KEY`... from the name, else from the MIME type.
    static func typeLabel(name: String?, mime: String) -> String {
        let ext = (name as NSString?)?.pathExtension ?? ""
        if !ext.isEmpty { return ext.uppercased() }
        return UTType(mimeType: mime)?.preferredFilenameExtension?.uppercased() ?? "FICHIER"
    }

    /// Tint of the file tile by family (PDF red, Word blue, Excel green, PowerPoint orange).
    static func tint(name: String?, mime: String) -> UIColor {
        switch typeLabel(name: name, mime: mime) {
        case "PDF": UIColor(hex: 0xE5484D, alpha: 1)
        case "DOC", "DOCX", "PAGES", "RTF": UIColor(hex: 0x2B6CDF, alpha: 1)
        case "XLS", "XLSX", "CSV", "NUMBERS": UIColor(hex: 0x1E9E5A, alpha: 1)
        case "PPT", "PPTX", "KEY": UIColor(hex: 0xE8772E, alpha: 1)
        default: UIColor(hex: 0x5B636E, alpha: 1)
        }
    }

    static func symbol(name: String?, mime: String) -> String {
        switch typeLabel(name: name, mime: mime) {
        case "PDF": "doc.richtext.fill"
        case "XLS", "XLSX", "CSV", "NUMBERS": "tablecells.fill"
        case "PPT", "PPTX", "KEY": "rectangle.on.rectangle.angled.fill"
        case "TXT", "MD", "JSON": "doc.plaintext.fill"
        case "ZIP": "doc.zipper"
        default: "doc.fill"
        }
    }
}
