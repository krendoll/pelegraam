//
//  HiddenPeers.swift
//  HiddenCore
//
//  Unprotected registry of "hidden" Telegram peer ids — the iOS analogue of the
//  desktop `tdata/.hidden_ids`. It MUST be readable without the PIN, because the
//  main chat-list UI (which builds long before any PIN is entered) needs it to
//  filter hidden chats out of every list, folder tab, archive and dialog search.
//
//  That means the id set is stored in the clear (a small JSON array). This is an
//  accepted trade-off for the product's threat model: hide from a casual glance
//  and from OS filesystem/media scanners — NOT from targeted forensics. (The
//  actual chats + messages behind the relay stay in the encrypted vault; this is
//  only the list of which normal Telegram peers to hide from the UI.)
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation

public final class HiddenPeers {

    public static let shared = HiddenPeers()

    private let lock = NSLock()
    private var ids: Set<Int64> = []
    private let url: URL?
    /// mtime of `.hidden_ids` last loaded into `ids`; -1 = never loaded / no file.
    private var loadedMtime: TimeInterval = -2

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.url = dir?.appendingPathComponent(".hidden_ids")
        lock.lock(); reloadIfChangedLocked(); lock.unlock()
    }

    /// Snapshot of all hidden peer ids. Callers filtering a list should call this
    /// ONCE per pass (not per item) — it locks + copies. Reloads from disk if the
    /// file changed, so the set is never stale (e.g. this instance was created
    /// before the first chat was hidden, or a separate module instance wrote it).
    public func all() -> Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return ids
    }

    public func contains(_ id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return ids.contains(id)
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        return ids.isEmpty
    }

    public func add(_ id: Int64) {
        guard id != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        if ids.insert(id).inserted { persistLocked() }
    }

    public func remove(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        reloadIfChangedLocked()
        if ids.remove(id) != nil { persistLocked() }
    }

    // MARK: - Disk sync (caller must hold `lock`)

    private func fileMtime() -> TimeInterval {
        guard let u = url,
              let m = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
        else { return -1 }
        return m.timeIntervalSince1970
    }

    private func reloadIfChangedLocked() {
        let mtime = fileMtime()
        if mtime == loadedMtime { return }   // unchanged since last load
        loadedMtime = mtime
        guard mtime >= 0, let u = url,
              let data = try? Data(contentsOf: u),
              let arr = try? JSONDecoder().decode([Int64].self, from: data)
        else { return }                       // file missing/unreadable -> keep current
        ids = Set(arr)
    }

    private func persistLocked() {
        guard let u = url else { return }
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u, options: [.atomic])
        loadedMtime = fileMtime()             // don't re-read our own write
    }
}
