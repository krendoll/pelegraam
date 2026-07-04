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

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.url = dir?.appendingPathComponent(".hidden_ids")
        if let u = url, let data = try? Data(contentsOf: u),
           let arr = try? JSONDecoder().decode([Int64].self, from: data) {
            ids = Set(arr)
        }
    }

    /// Snapshot of all hidden peer ids. Callers filtering a list should call this
    /// ONCE per pass (not per item) — it locks + copies.
    public func all() -> Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    public func contains(_ id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.isEmpty
    }

    public func add(_ id: Int64) {
        guard id != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if ids.insert(id).inserted { persistLocked() }
    }

    public func remove(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        if ids.remove(id) != nil { persistLocked() }
    }

    // Caller must hold `lock`.
    private func persistLocked() {
        guard let u = url else { return }
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: u, options: [.atomic])
    }
}
