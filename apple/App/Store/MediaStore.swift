import Foundation

/// Sealed local copies of attachments: `media/<id>` holds `SecretBox.seal(plain)` with complete
/// file protection. Plain files only exist briefly in the temporary folder for playback.
nonisolated enum MediaStore {
    static var folder: URL {
        let url = AppDatabase.directory().appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        return url
    }

    @discardableResult static func store(_ plain: Data, name: String) -> String {
        let url = folder.appendingPathComponent(name)
        try? SecretBox.shared.seal(plain).write(to: url, options: [.atomic, .completeFileProtection])
        return name
    }

    static func load(_ name: String) -> Data? {
        guard let sealed = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return SecretBox.shared.open(sealed)
    }

    /// A plain temporary copy for players that need a URL (AVPlayer, Quick Look).
    static func temporaryURL(_ name: String, ext: String) -> URL? {
        guard let plain = load(name) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? plain.write(to: url, options: [.atomic, .completeFileProtection])
        }
        return url
    }

    static func wipe() {
        try? FileManager.default.removeItem(at: folder)
        if let items = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
    }
}
