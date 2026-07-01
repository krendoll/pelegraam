//
//  Container.swift
//  HiddenCore
//
//  Encrypted PIN vault. Mirrors Telegram/SourceFiles/hidden/container_stub.cpp.
//
//  KDF  : PBKDF2-SHA256, 100_000 iterations, 16-byte salt -> 32-byte key
//  Enc  : AES-256-GCM, 12-byte random IV, 16-byte auth tag
//  File : <vaultDir>/.hv  ->  [salt 16][iv 12][tag 16][ciphertext N]
//
//  Plaintext payload:
//    4 bytes magic "HVT\x01" (little-endian 0x01545648)
//    4 bytes LE count of chats
//    For each chat:
//      4 bytes LE title length + title UTF-8
//      4 bytes LE lastMessage length + lastMessage UTF-8
//
//  The derived key lives in `key` and is zeroed on close().
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

public struct ChatEntry: Equatable {
    public var title: String
    public var lastMessage: String
    /// Telegram peer id for a "hidden normal chat"; 0 for the relay chat / any
    /// entry that is not a Telegram peer. Stored so the overlay can list and open
    /// hidden chats without an async peer lookup.
    public var peerId: Int64
    public init(title: String, lastMessage: String, peerId: Int64 = 0) {
        self.title = title
        self.lastMessage = lastMessage
        self.peerId = peerId
    }
}

public struct VaultState: Equatable {
    public var chats: [ChatEntry]
    /// "Disable online status" toggle, persisted behind the PIN (desktop parity:
    /// tdata/.hidden_prefs).
    public var hideOnline: Bool
    public init(chats: [ChatEntry] = [], hideOnline: Bool = false) {
        self.chats = chats
        self.hideOnline = hideOnline
    }
}

public final class Container {

    public static let keySize = 32
    public static let saltSize = 16
    public static let ivSize = 12
    public static let tagSize = 16
    public static let iterations = 100_000
    static let magic: UInt32 = 0x0154_5648   // "HVT\x01" LE — V1 (title + lastMessage only)
    static let magicV2: UInt32 = 0x0254_5648 // "HVT\x02" LE — V2 adds peerId per chat + hideOnline

    public private(set) var isOpen = false
    public private(set) var state = VaultState()

    private var key: [UInt8] = []
    private let vaultURL: URL

    /// `vaultDirectory` is the equivalent of the desktop `tdata/` folder.
    public init(vaultDirectory: URL) {
        self.vaultURL = vaultDirectory.appendingPathComponent(".hv")
    }

    // MARK: - Open / close (mirrors Container::open / close)

    /// Attempt to open (or bootstrap on first run) the vault with `pin`.
    /// Returns true on success. Intentionally slow (PBKDF2 100k).
    @discardableResult
    public func open(pin: SecurePIN) -> Bool {
        if isOpen { return true }

        let exists = FileManager.default.fileExists(atPath: vaultURL.path)

        if !exists {
            var salt = [UInt8](repeating: 0, count: Container.saltSize)
            guard randomBytes(&salt) else { return false }
            guard let derived = Container.deriveKey(pin: pin, salt: salt) else { return false }
            let ok = bootstrap(key: derived, salt: salt)
            if !ok { return false }
            self.key = derived
            self.state = VaultState()
            self.isOpen = true
            return true
        }

        guard let raw = try? Data(contentsOf: vaultURL) else { return false }
        let minSize = Container.saltSize + Container.ivSize + Container.tagSize + 1
        guard raw.count >= minSize else { return false }

        let salt = Array(raw[0..<Container.saltSize])
        guard let derived = Container.deriveKey(pin: pin, salt: salt) else { return false }

        let ivStart = Container.saltSize
        let tagStart = ivStart + Container.ivSize
        let ctStart = tagStart + Container.tagSize
        let iv = raw.subdata(in: ivStart..<tagStart)
        let tag = raw.subdata(in: tagStart..<ctStart)
        let ciphertext = raw.subdata(in: ctStart..<raw.count)

        guard let plaintext = Container.gcmDecrypt(key: derived, iv: iv, tag: tag, ciphertext: ciphertext),
              let parsed = Container.deserialise(plaintext) else {
            return false
        }

        self.key = derived
        self.state = parsed
        self.isOpen = true
        return true
    }

    /// Persist the current `state` back to disk, re-deriving nothing (reuses
    /// the on-disk salt). No-op if closed. Used when chats are added/edited.
    @discardableResult
    public func save() -> Bool {
        guard isOpen, !key.isEmpty else { return false }
        guard let raw = try? Data(contentsOf: vaultURL),
              raw.count >= Container.saltSize else { return false }
        let salt = Array(raw[0..<Container.saltSize])
        return writeVault(key: key, salt: salt, state: state)
    }

    public func close() {
        wipe(&key)
        key = []
        state = VaultState()
        isOpen = false
    }

    // MARK: - State mutation (persist with save())

    /// Append a chat to the in-memory state. Caller persists via `save()`.
    public func addChat(_ chat: ChatEntry) {
        guard isOpen else { return }
        state.chats.append(chat)
    }

    /// Mutate the vault state in place. Caller persists via `save()`.
    public func mutateState(_ body: (inout VaultState) -> Void) {
        guard isOpen else { return }
        body(&state)
    }

    // MARK: - Bootstrap / write

    private func bootstrap(key: [UInt8], salt: [UInt8]) -> Bool {
        return writeVault(key: key, salt: salt, state: VaultState())
    }

    private func writeVault(key: [UInt8], salt: [UInt8], state: VaultState) -> Bool {
        let plaintext = Container.serialise(state)
        guard let sealed = Container.gcmEncrypt(key: key, plaintext: plaintext) else { return false }

        var file = Data()
        file.append(contentsOf: salt)          // [salt 16]
        file.append(sealed.iv)                 // [iv 12]
        file.append(sealed.tag)                // [tag 16]
        file.append(sealed.ciphertext)         // [ciphertext N]

        do {
            try FileManager.default.createDirectory(
                at: vaultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try file.write(to: vaultURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    // MARK: - KDF & AEAD

    static func deriveKey(pin: SecurePIN, salt: [UInt8]) -> [UInt8]? {
        var derived = [UInt8](repeating: 0, count: keySize)
        let status: Int32 = pin.withUnsafeBytes { pinPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                derived.withUnsafeMutableBufferPointer { outPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinPtr.baseAddress?.assumingMemoryBound(to: Int8.self), pinPtr.count,
                        saltPtr.baseAddress, saltPtr.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outPtr.baseAddress, keySize)
                }
            }
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    struct Sealed {
        let iv: Data
        let tag: Data
        let ciphertext: Data
    }

    static func gcmEncrypt(key: [UInt8], plaintext: Data) -> Sealed? {
        let symmetricKey = SymmetricKey(data: Data(key))
        do {
            let nonce = AES.GCM.Nonce()
            let box = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
            return Sealed(iv: Data(nonce), tag: box.tag, ciphertext: box.ciphertext)
        } catch {
            return nil
        }
    }

    static func gcmDecrypt(key: [UInt8], iv: Data, tag: Data, ciphertext: Data) -> Data? {
        let symmetricKey = SymmetricKey(data: Data(key))
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            return nil
        }
    }

    // MARK: - Serialisation (byte-identical to container_stub.cpp)

    static func serialise(_ s: VaultState) -> Data {
        var out = Data()
        appendU32LE(&out, magicV2)
        out.append(s.hideOnline ? 1 : 0)
        appendU32LE(&out, UInt32(s.chats.count))
        for chat in s.chats {
            let title = Data(chat.title.utf8)
            let msg = Data(chat.lastMessage.utf8)
            appendU32LE(&out, UInt32(title.count))
            out.append(title)
            appendU32LE(&out, UInt32(msg.count))
            out.append(msg)
            appendU64LE(&out, UInt64(bitPattern: chat.peerId))
        }
        return out
    }

    static func deserialise(_ data: Data) -> VaultState? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let m = readU32LE(bytes, 0)
        let v2 = (m == magicV2)
        guard v2 || m == magic else { return nil }

        var pos = 4
        var hideOnline = false
        if v2 {
            guard pos + 1 <= bytes.count else { return nil }
            hideOnline = bytes[pos] != 0; pos += 1
        }
        guard pos + 4 <= bytes.count else { return nil }
        let count = readU32LE(bytes, pos); pos += 4

        var chats: [ChatEntry] = []
        for _ in 0..<count {
            guard pos + 4 <= bytes.count else { return nil }
            let tlen = Int(readU32LE(bytes, pos)); pos += 4
            guard pos + tlen <= bytes.count else { return nil }
            let title = String(decoding: bytes[pos..<pos + tlen], as: UTF8.self); pos += tlen
            guard pos + 4 <= bytes.count else { return nil }
            let mlen = Int(readU32LE(bytes, pos)); pos += 4
            guard pos + mlen <= bytes.count else { return nil }
            let msg = String(decoding: bytes[pos..<pos + mlen], as: UTF8.self); pos += mlen
            var peerId: Int64 = 0
            if v2 {
                guard pos + 8 <= bytes.count else { return nil }
                peerId = Int64(bitPattern: readU64LE(bytes, pos)); pos += 8
            }
            chats.append(ChatEntry(title: title, lastMessage: msg, peerId: peerId))
        }
        return VaultState(chats: chats, hideOnline: hideOnline)
    }

    private static func appendU32LE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8(v & 0xff))
        out.append(UInt8((v >> 8) & 0xff))
        out.append(UInt8((v >> 16) & 0xff))
        out.append(UInt8((v >> 24) & 0xff))
    }

    private static func appendU64LE(_ out: inout Data, _ v: UInt64) {
        for i in 0..<8 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    private static func readU32LE(_ b: [UInt8], _ p: Int) -> UInt32 {
        return UInt32(b[p]) | (UInt32(b[p + 1]) << 8)
            | (UInt32(b[p + 2]) << 16) | (UInt32(b[p + 3]) << 24)
    }

    private static func readU64LE(_ b: [UInt8], _ p: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * i) }
        return v
    }
}

// MARK: - Helpers

func randomBytes(_ buffer: inout [UInt8]) -> Bool {
    return buffer.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return false }
        return SecRandomCopyBytes(kSecRandomDefault, ptr.count, base) == errSecSuccess
    }
}

/// Best-effort in-place zeroing. Uses memset_s so the compiler cannot elide it.
func wipe(_ bytes: inout [UInt8]) {
    guard !bytes.isEmpty else { return }
    bytes.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        memset_s(base, ptr.count, 0, ptr.count)
    }
}
