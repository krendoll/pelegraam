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
//  Plaintext payload is versioned by a 4-byte magic:
//    V1 "HVT\x01" : chats (title + lastMessage)
//    V2 "HVT\x02" : + peerId per chat + hideOnline
//    V3 "HVT\x03" : + flat relay message history
//    V4 "HVT\x04" : conversations (kind/title/token/peerId + messages with media
//                   refs) + hideOnline + autoDeleteDays  <-- current
//  Old files are migrated to V4 on read (see deserialise / migrateLegacy).
//
//  The derived key lives in `key` and is zeroed on close(). Media payloads are
//  encrypted with the SAME key via encryptBlob/decryptBlob (used by MediaStore).
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

public final class Container {

    public static let keySize = 32
    public static let saltSize = 16
    public static let ivSize = 12
    public static let tagSize = 16
    public static let iterations = 100_000
    static let magicV1: UInt32 = 0x0154_5648 // "HVT\x01"
    static let magicV2: UInt32 = 0x0254_5648 // "HVT\x02"
    static let magicV3: UInt32 = 0x0354_5648 // "HVT\x03"
    static let magicV4: UInt32 = 0x0454_5648 // "HVT\x04"

    public private(set) var isOpen = false
    public private(set) var state = VaultState()

    private var key: [UInt8] = []
    private let vaultURL: URL
    /// Directory that holds `.hv` and the `media/` blob store.
    public let vaultDirectory: URL

    /// `vaultDirectory` is the equivalent of the desktop `tdata/` folder.
    public init(vaultDirectory: URL) {
        self.vaultDirectory = vaultDirectory
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

    /// Persist the current `state` back to disk, reusing the on-disk salt.
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

    /// Mutate the vault state in place. Caller persists via `save()`.
    public func mutateState(_ body: (inout VaultState) -> Void) {
        guard isOpen else { return }
        body(&state)
    }

    // MARK: - Blob crypto for MediaStore (uses the SAME vault key)

    /// Seal arbitrary bytes with the vault key -> [iv 12][tag 16][ciphertext].
    /// Only valid while the vault is open.
    public func encryptBlob(_ data: Data) -> Data? {
        guard isOpen, !key.isEmpty, let sealed = Container.gcmEncrypt(key: key, plaintext: data) else {
            return nil
        }
        var out = Data(capacity: Container.ivSize + Container.tagSize + sealed.ciphertext.count)
        out.append(sealed.iv)
        out.append(sealed.tag)
        out.append(sealed.ciphertext)
        return out
    }

    /// Open a blob laid out as [iv 12][tag 16][ciphertext]. Nil on bad tag.
    public func decryptBlob(_ blob: Data) -> Data? {
        guard isOpen, !key.isEmpty else { return nil }
        let need = Container.ivSize + Container.tagSize
        guard blob.count >= need else { return nil }
        let b = blob.startIndex == 0 ? blob : Data(blob)
        let iv = b.subdata(in: 0..<Container.ivSize)
        let tag = b.subdata(in: Container.ivSize..<need)
        let ct = b.subdata(in: need..<b.count)
        return Container.gcmDecrypt(key: key, iv: iv, tag: tag, ciphertext: ct)
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
            // Keep the vault (all history + media metadata) out of iCloud/iTunes
            // backups, matching MediaStore's blob handling.
            var url = vaultURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
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

    // MARK: - Serialisation (V4)

    static func serialise(_ s: VaultState) -> Data {
        var out = Data()
        appendU32LE(&out, magicV4)
        out.append(s.hideOnline ? 1 : 0)
        appendU32LE(&out, UInt32(max(0, s.autoDeleteDays)))
        appendU32LE(&out, UInt32(s.conversations.count))
        for c in s.conversations {
            appendStr(&out, c.id)
            appendU32LE(&out, UInt32(c.kind.rawValue))
            appendStr(&out, c.title)
            appendStr(&out, c.relayToken)
            appendU64LE(&out, UInt64(bitPattern: c.peerId))
            appendU32LE(&out, UInt32(c.messages.count))
            for m in c.messages {
                appendStr(&out, m.id)
                appendStr(&out, m.text)
                out.append(m.outgoing ? 1 : 0)
                appendU64LE(&out, m.timestamp.bitPattern)
                if let media = m.media {
                    out.append(1)
                    appendStr(&out, media.id)
                    appendU32LE(&out, UInt32(media.kind.rawValue))
                    appendStr(&out, media.filename)
                    appendStr(&out, media.mime)
                    appendU64LE(&out, UInt64(max(0, media.size)))
                    appendU32LE(&out, UInt32(max(0, media.width)))
                    appendU32LE(&out, UInt32(max(0, media.height)))
                    appendU32LE(&out, UInt32(max(0, media.durationMs)))
                } else {
                    out.append(0)
                }
            }
        }
        return out
    }

    static func deserialise(_ data: Data) -> VaultState? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let m = readU32LE(bytes, 0)
        if m == magicV4 { return deserialiseV4(bytes) }
        if m == magicV1 || m == magicV2 || m == magicV3 { return migrateLegacy(bytes, magic: m) }
        return nil
    }

    private static func deserialiseV4(_ bytes: [UInt8]) -> VaultState? {
        var pos = 4
        guard pos + 1 <= bytes.count else { return nil }
        let hideOnline = bytes[pos] != 0; pos += 1
        guard let (autoDelete, p1) = takeU32(bytes, pos) else { return nil }; pos = p1
        guard let (ccount, p2) = takeU32(bytes, pos) else { return nil }; pos = p2

        var conversations: [Conversation] = []
        for _ in 0..<ccount {
            guard let (id, p3) = takeStr(bytes, pos) else { return nil }; pos = p3
            guard let (kindRaw, p4) = takeU32(bytes, pos) else { return nil }; pos = p4
            guard let (title, p5) = takeStr(bytes, pos) else { return nil }; pos = p5
            guard let (token, p6) = takeStr(bytes, pos) else { return nil }; pos = p6
            guard let (peerRaw, p7) = takeU64(bytes, pos) else { return nil }; pos = p7
            guard let (mcount, p8) = takeU32(bytes, pos) else { return nil }; pos = p8

            var messages: [StoredMessage] = []
            for _ in 0..<mcount {
                guard let (mid, q1) = takeStr(bytes, pos) else { return nil }; pos = q1
                guard let (text, q2) = takeStr(bytes, pos) else { return nil }; pos = q2
                guard pos + 1 <= bytes.count else { return nil }
                let outgoing = bytes[pos] != 0; pos += 1
                guard let (tsBits, q3) = takeU64(bytes, pos) else { return nil }; pos = q3
                guard pos + 1 <= bytes.count else { return nil }
                let hasMedia = bytes[pos] != 0; pos += 1
                var media: MediaRef? = nil
                if hasMedia {
                    guard let (blobId, r1) = takeStr(bytes, pos) else { return nil }; pos = r1
                    guard let (mkRaw, r2) = takeU32(bytes, pos) else { return nil }; pos = r2
                    guard let (fname, r3) = takeStr(bytes, pos) else { return nil }; pos = r3
                    guard let (mime, r4) = takeStr(bytes, pos) else { return nil }; pos = r4
                    guard let (sz, r5) = takeU64(bytes, pos) else { return nil }; pos = r5
                    guard let (w, r6) = takeU32(bytes, pos) else { return nil }; pos = r6
                    guard let (h, r7) = takeU32(bytes, pos) else { return nil }; pos = r7
                    guard let (dur, r8) = takeU32(bytes, pos) else { return nil }; pos = r8
                    media = MediaRef(id: blobId,
                                     kind: MediaKind(rawValue: Int(mkRaw)) ?? .file,
                                     filename: fname, mime: mime, size: Int(sz),
                                     width: Int(w), height: Int(h), durationMs: Int(dur))
                }
                messages.append(StoredMessage(id: mid, text: text, outgoing: outgoing,
                                              timestamp: Double(bitPattern: tsBits), media: media))
            }
            conversations.append(Conversation(
                id: id,
                kind: ConversationKind(rawValue: Int(kindRaw)) ?? .relayPerson,
                title: title, relayToken: token,
                peerId: Int64(bitPattern: peerRaw), messages: messages))
        }
        return VaultState(hideOnline: hideOnline, autoDeleteDays: Int(autoDelete),
                          conversations: conversations)
    }

    /// Read a V1/V2/V3 file and fold it into the V4 model:
    ///  - flat relay `messages` become one relayPerson conversation ("legacy-relay")
    ///    on the default relay token, so the existing working chat is preserved;
    ///  - chats with peerId != 0 become telegramHidden conversations.
    private static func migrateLegacy(_ bytes: [UInt8], magic m: UInt32) -> VaultState? {
        let v3 = (m == magicV3)
        let hasExtended = (m == magicV2 || v3)
        var pos = 4
        var hideOnline = false
        if hasExtended {
            guard pos + 1 <= bytes.count else { return nil }
            hideOnline = bytes[pos] != 0; pos += 1
        }
        guard let (count, p1) = takeU32(bytes, pos) else { return nil }; pos = p1

        var legacyChats: [LegacyChatEntry] = []
        for _ in 0..<count {
            guard let (title, q1) = takeStr(bytes, pos) else { return nil }; pos = q1
            guard let (msg, q2) = takeStr(bytes, pos) else { return nil }; pos = q2
            var peerId: Int64 = 0
            if hasExtended {
                guard let (pr, q3) = takeU64(bytes, pos) else { return nil }; pos = q3
                peerId = Int64(bitPattern: pr)
            }
            legacyChats.append(LegacyChatEntry(title: title, lastMessage: msg, peerId: peerId))
        }

        var relayMessages: [StoredMessage] = []
        if v3 {
            guard let (mcount, q4) = takeU32(bytes, pos) else { return nil }; pos = q4
            for _ in 0..<mcount {
                guard let (text, r1) = takeStr(bytes, pos) else { return nil }; pos = r1
                guard pos + 1 + 8 <= bytes.count else { return nil }
                let outgoing = bytes[pos] != 0; pos += 1
                guard let (tsBits, r2) = takeU64(bytes, pos) else { return nil }; pos = r2
                relayMessages.append(StoredMessage(text: text, outgoing: outgoing,
                                                   timestamp: Double(bitPattern: tsBits)))
            }
        }

        var conversations: [Conversation] = []
        conversations.append(Conversation(
            id: "legacy-relay", kind: .relayPerson, title: "Relay",
            relayToken: HiddenConfig.defaultToken, peerId: 0, messages: relayMessages))
        for c in legacyChats where c.peerId != 0 {
            conversations.append(Conversation(
                id: "peer-\(c.peerId)", kind: .telegramHidden, title: c.title,
                relayToken: "", peerId: c.peerId, messages: []))
        }
        return VaultState(hideOnline: hideOnline, autoDeleteDays: 0, conversations: conversations)
    }

    // MARK: - Byte helpers

    private static func appendU32LE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8(v & 0xff))
        out.append(UInt8((v >> 8) & 0xff))
        out.append(UInt8((v >> 16) & 0xff))
        out.append(UInt8((v >> 24) & 0xff))
    }

    private static func appendU64LE(_ out: inout Data, _ v: UInt64) {
        for i in 0..<8 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    private static func appendStr(_ out: inout Data, _ s: String) {
        let d = Data(s.utf8)
        appendU32LE(&out, UInt32(d.count))
        out.append(d)
    }

    private static func readU32LE(_ b: [UInt8], _ p: Int) -> UInt32 {
        return UInt32(b[p]) | (UInt32(b[p + 1]) << 8)
            | (UInt32(b[p + 2]) << 16) | (UInt32(b[p + 3]) << 24)
    }

    /// Bounds-checked readers returning the next position, so parsing untrusted
    /// (decrypted) bytes can never index out of range.
    private static func takeU32(_ b: [UInt8], _ p: Int) -> (UInt32, Int)? {
        guard p + 4 <= b.count else { return nil }
        return (readU32LE(b, p), p + 4)
    }

    private static func takeU64(_ b: [UInt8], _ p: Int) -> (UInt64, Int)? {
        guard p + 8 <= b.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * i) }
        return (v, p + 8)
    }

    private static func takeStr(_ b: [UInt8], _ p: Int) -> (String, Int)? {
        guard let (len, p1) = takeU32(b, p) else { return nil }
        let n = Int(len)
        guard p1 + n <= b.count else { return nil }
        let s = String(decoding: b[p1..<p1 + n], as: UTF8.self)
        return (s, p1 + n)
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
