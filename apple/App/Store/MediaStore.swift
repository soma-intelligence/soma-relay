import Foundation

/// Sealed local copies of attachments: `media/<id>` holds `SecretBox.seal(plain)` with complete
/// file protection. Plain files only exist briefly in the temporary folder for playback.
nonisolated enum MediaStore {
    static var folder: URL {
        let url = AppDatabase.directory().appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }

    @discardableResult static func store(_ plain: Data, name: String) -> String {
        let url = folder.appendingPathComponent(name)
        try? SecretBox.shared.seal(plain).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        if let items = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items where item.deletingPathExtension().lastPathComponent == name { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// A plain temporary copy under its original file name (Quick Look picks the type from it),
    /// in a folder of its own so two files with the same name never collide.
    static func temporaryURL(_ name: String, fileName: String) -> URL? {
        guard let plain = load(name) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-" + name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent(safe.isEmpty ? "fichier" : safe)
        try? plain.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func wipe() {
        try? FileManager.default.removeItem(at: folder)
        if let items = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
    }
}
