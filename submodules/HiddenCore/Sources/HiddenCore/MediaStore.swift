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

    /// Decrypt and return the plaintext for a single-blob id (in memory only).
    public func load(_ id: String) -> Data? {
        let url = mediaDir.appendingPathComponent(id)
        guard let enc = try? Data(contentsOf: url) else { return nil }
        return container.decryptBlob(enc)
    }

    // MARK: - Segmented storage (range-decryptable, so big media isn't held whole)

    /// Store `data` as a directory of independently-GCM-sealed segments of
    /// `segmentBytes` each. Returns the blob id (the directory name), or nil.
    /// Each segment can be decrypted on its own, so playback reads only the
    /// segments overlapping the requested byte range.
    public func storeSegmented(_ data: Data, segmentBytes: Int) -> String? {
        guard segmentBytes > 0 else { return store(data) }
        ensureDir()
        let id = UUID().uuidString.lowercased()
        let dir = mediaDir.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var d = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? d.setResourceValues(values)
        } catch {
            return nil
        }
        var index = 0
        var offset = 0
        while offset < data.count {
            let end = min(offset + segmentBytes, data.count)
            guard let enc = container.encryptBlob(data.subdata(in: offset..<end)) else {
                try? FileManager.default.removeItem(at: dir); return nil
            }
            let url = dir.appendingPathComponent("\(index)")
            do {
                try enc.write(to: url, options: [.atomic, .completeFileProtection])
                excludeFromBackup(url)
            } catch {
                try? FileManager.default.removeItem(at: dir); return nil
            }
            index += 1
            offset = end
        }
        return id
    }

    /// Decrypt an entire blob (single-blob if `segmentBytes == 0`, else all
    /// segments). Use for images; prefer `loadRange` for video/audio.
    public func loadWhole(id: String, segmentBytes: Int, size: Int) -> Data? {
        if segmentBytes <= 0 { return load(id) }
        return loadRange(id: id, segmentBytes: segmentBytes, size: size, offset: 0, length: size)
    }

    /// Decrypt only the segments overlapping `[offset, offset+length)`.
    public func loadRange(id: String, segmentBytes: Int, size: Int, offset: Int, length: Int) -> Data? {
        if segmentBytes <= 0 {
            guard let whole = load(id) else { return nil }
            let lo = max(0, offset), hi = min(whole.count, offset + max(0, length))
            guard lo < hi else { return Data() }
            return whole.subdata(in: lo..<hi)
        }
        guard offset >= 0, length > 0, offset < size else { return Data() }
        let end = min(offset + length, size)
        let first = offset / segmentBytes
        let last = (end - 1) / segmentBytes
        let dir = mediaDir.appendingPathComponent(id, isDirectory: true)
        var buf = Data()
        for i in first...last {
            guard let enc = try? Data(contentsOf: dir.appendingPathComponent("\(i)")),
                  let seg = container.decryptBlob(enc) else { return nil }
            buf.append(seg)
        }
        let base = first * segmentBytes
        let lo = offset - base
        let hi = end - base
        guard lo >= 0, hi <= buf.count, lo <= hi else { return nil }
        return buf.subdata(in: lo..<hi)
    }

    public func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent(id).path)
    }

    /// Remove a blob whether it's a single file or a segmented directory.
    public func delete(_ id: String) {
        guard !id.isEmpty else { return }
        try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(id))
    }

    public func delete(ids: [String]) {
        for id in ids { delete(id) }
    }
}
