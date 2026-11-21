import CryptoKit
import Foundation

/// Attachments: sealed by the core (`sealAttachment`), inline when the ciphertext is small
/// (<= 48 KiB), uploaded to the node blob store when one is up, else inline over the mesh up to
/// the 512 KiB BLE cap; bigger files wait for the node.
extension AppModel {
    static let inlineLimit = 48 * 1024
    static let meshLimit = 512 * 1024

    func sendAttachment(
        _ plain: Data, kind: AppMessage.Kind, mime: String, name: String? = nil, width: Int? = nil, height: Int? = nil,
        durationMs: Int? = nil, thumb: String? = nil, levels: [Float]? = nil, pages: Int? = nil, in conversationId: String
    ) async {
        guard let core else { return }
        let sealed = core.sealAttachment(plain)
        guard sealed.count > 64 else { return }
        let key = sealed.prefix(32)
        let sha = sealed.subdata(in: sealed.startIndex + 32..<sealed.startIndex + 64)
        let ciphertext = sealed.subdata(in: sealed.startIndex + 64..<sealed.endIndex)
        var attachment = AppMessage.Attachment(
            mime: mime, size: plain.count, sha256: sha.hex, key: Data(key).base64EncodedString(), name: name, width: width, height: height,
            durationMs: durationMs, thumb: thumb, inline: nil, url: nil, levels: levels, pages: pages)
        if ciphertext.count <= Self.inlineLimit {
            attachment.inline = ciphertext.base64EncodedString()
        } else if node.isReady, let url = try? await node.uploadBlob(ciphertext, sha: Data(SHA256.hash(data: ciphertext)).hex) {
            attachment.url = url
        } else if ciphertext.count <= Self.meshLimit || !nodeEnabled {
            attachment.inline = ciphertext.base64EncodedString()
        } else {
            banner = "Fichier trop lourd pour le mesh. Il partira dès que le nœud répond."
            attachment.inline = ciphertext.base64EncodedString()
        }
        var message = AppMessage.make(kind)
        message.attachment = attachment
        let mediaName = message.id
        MediaStore.store(plain, name: mediaName)
        post(message, in: conversationId, preview: Self.previewText(message), mediaPath: mediaName)
    }

    /// Opens an inbound attachment (inline or node blob) into the sealed media folder.
    func fetchAttachment(of message: AppMessage, recordId: String) {
        guard let attachment = message.attachment, let core, let key = Data(base64Encoded: attachment.key),
            let sha = Data(hex: attachment.sha256)
        else { return }
        Task {
            var ciphertext: Data?
            if let inline = attachment.inline { ciphertext = Data(base64Encoded: inline) }
            else if let text = attachment.url, let url = URL(string: text) { ciphertext = try? await node.downloadBlob(url) }
            guard let ciphertext, let plain = try? core.openAttachment(key: key, sha256: sha, ciphertext: ciphertext) else { return }
            MediaStore.store(plain, name: recordId)
            guard var record = db.message(recordId) else { return }
            record.mediaPath = recordId
            db.save(record)
            messageVersion += 1
        }
    }
}
