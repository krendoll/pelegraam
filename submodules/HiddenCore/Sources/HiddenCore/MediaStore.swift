//
//  MediaStore.swift
//  HiddenCore
//
//  Encrypted blob store for hidden-area media (spec point 5). Every photo,
//  video, audio clip or file sent/received through the relay is written to
//  <vaultDir>/media/<id> as AES-GCM ciphertext, encrypted with the SAME vault
//  key as the container. Plaintext is only ever produced in memory, on demand,
//  for display/playback — so OS media scanners, Spotlight, iCloud backup and the
//  Photos library never see the real bytes.
//
//  Files are stored with .completeFileProtection and excluded from iCloud backup.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation

public final class MediaStore {

    private let container: Container
    private let mediaDir: URL

    public init(container: Container) {
        self.container = container
        self.mediaDir = container.vaultDirectory.appendingPathComponent("media", isDirectory: true)
    }

    private func ensureDir() {
        var dir = mediaDir
        // Per-file .completeFileProtection (see store()) is the macOS-portable
        // path; the directory just needs to exist and be excluded from backup.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Encrypt `data` with the vault key and persist it. Returns the blob id
    /// (its filename) or nil if the vault is closed / write failed.
    public func store(_ data: Data) -> String? {
        guard let enc = container.encryptBlob(data) else { return nil }
        ensureDir()
        let id = UUID().uuidString.lowercased()
        let url = mediaDir.appendingPathComponent(id)
        do {
            try enc.write(to: url, options: [.atomic, .completeFileProtection])
            excludeFromBackup(url)
            return id
        } catch {
            return nil
        }
    }

    /// Decrypt and return the plaintext for a blob id (in memory only).
    public func load(_ id: String) -> Data? {
        let url = mediaDir.appendingPathComponent(id)
        guard let enc = try? Data(contentsOf: url) else { return nil }
        return container.decryptBlob(enc)
    }

    public func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(id).path)
    }

    public func delete(_ id: String) {
        guard !id.isEmpty else { return }
        try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(id))
    }

    public func delete(ids: [String]) {
        for id in ids { delete(id) }
    }
}
