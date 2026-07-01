//
//  E2ECrypto.swift
//  HiddenCore
//
//  End-to-end message encryption. Mirrors the desktop
//  Telegram/SourceFiles/hidden/e2e_crypto.cpp exactly so the two clients
//  interoperate through the relay.
//
//  Scheme: AES-256-GCM with a pre-shared key (PSK).
//  Wire layout of a blob:  [iv 12][tag 16][ciphertext N]
//
//  NOTE (parity with desktop): the PSK below is the development placeholder.
//  Replace with X25519 ECDH before production on BOTH clients simultaneously,
//  otherwise they stop being able to decrypt each other.
//

import Foundation
import CryptoKit

public enum E2ECrypto {

    public static let keySize = 32
    public static let ivSize = 12
    public static let tagSize = 16

    /// Development PSK. Byte-identical to `kDevPsk` in e2e_crypto.h:
    /// sha256("hidden-layer-dev-psk-v1"). NOT SECURE for production.
    public static let devPSK: [UInt8] = [
        0x6b, 0x86, 0xb2, 0x73, 0xff, 0x34, 0xfc, 0xe1,
        0x9d, 0x6b, 0x80, 0x4e, 0xff, 0x5a, 0x3f, 0x57,
        0x47, 0xad, 0xa4, 0xea, 0xa2, 0x2f, 0x1d, 0x49,
        0xc0, 0x1e, 0x52, 0xdd, 0xb7, 0x87, 0x5b, 0x4b,
    ]

    /// Encrypt `plaintext`. Returns `[iv 12][tag 16][ciphertext]` or nil on failure.
    public static func encrypt(_ plaintext: Data, key: [UInt8] = devPSK) -> Data? {
        guard key.count == keySize else { return nil }
        let symmetricKey = SymmetricKey(data: Data(key))
        do {
            let nonce = AES.GCM.Nonce() // 12 random bytes
            let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
            var blob = Data(capacity: ivSize + tagSize + sealed.ciphertext.count)
            blob.append(contentsOf: nonce) // iv (12)
            blob.append(sealed.tag)        // tag (16)
            blob.append(sealed.ciphertext) // ciphertext (N)
            return blob
        } catch {
            return nil
        }
    }

    /// Decrypt a blob laid out as `[iv 12][tag 16][ciphertext]`.
    /// Returns plaintext, or nil on auth-tag failure / malformed input.
    public static func decrypt(_ blob: Data, key: [UInt8] = devPSK) -> Data? {
        guard key.count == keySize else { return nil }
        let minSize = ivSize + tagSize
        guard blob.count >= minSize else { return nil }

        // Re-base to 0 in case `blob` is a slice.
        let bytes = blob.startIndex == 0 ? blob : Data(blob)
        let iv = bytes.subdata(in: 0..<ivSize)
        let tag = bytes.subdata(in: ivSize..<(ivSize + tagSize))
        let ciphertext = bytes.subdata(in: (ivSize + tagSize)..<bytes.count)

        let symmetricKey = SymmetricKey(data: Data(key))
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            return nil
        }
    }
}
