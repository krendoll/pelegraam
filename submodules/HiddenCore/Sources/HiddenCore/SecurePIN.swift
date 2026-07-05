//
//  SecurePIN.swift
//  HiddenCore
//
//  Heap-held PIN bytes that are explicitly zeroed on deinit. Mirrors the desktop
//  SecureString (container_stub.h): the PIN must never sit in a plain String,
//  which could be copied around and left in memory.
//

import Foundation

public final class SecurePIN {

    private var buffer: [UInt8]

    /// Build from raw digit characters. The caller's source String, if any,
    /// still exists — prefer feeding this from a UITextField's bytes directly.
    public init(_ digits: String) {
        self.buffer = Array(digits.utf8)
    }

    public init(bytes: [UInt8]) {
        self.buffer = bytes
    }

    public var count: Int { buffer.count }

    /// Access the raw bytes for KDF input. Do not copy them out.
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        return buffer.withUnsafeBytes(body)
    }

    deinit {
        wipe(&buffer)
    }
}
