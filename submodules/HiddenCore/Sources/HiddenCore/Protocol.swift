//
//  Protocol.swift
//  HiddenCore
//
//  Wire protocol for the blind WebSocket relay.
//  MUST stay byte-compatible with the Rust server (serverside/src/main.rs) and
//  the desktop client (Telegram/SourceFiles/hidden/relay_client.cpp).
//
//  Envelope is JSON; the `blob` field is base64 of the E2E ciphertext.
//  The server never looks inside the blob.
//
//  Client -> Server:
//      { "t": "auth",  "token": "<device_token>" }
//      { "t": "send",  "msg_id": "<uuid>", "blob": "<base64 ciphertext>" }
//      { "t": "ack",   "msg_id": "<uuid>" }
//
//  Server -> Client:
//      { "t": "auth_ok" }
//      { "t": "auth_err" }
//      { "t": "deliver", "msg_id": "<uuid>", "blob": "<base64 ciphertext>" }
//      { "t": "queued" }
//

import Foundation

/// Frames the client sends to the relay.
enum RelayOutbound {
    case auth(token: String)
    case send(msgId: String, blobBase64: String)
    case ack(msgId: String)

    /// Compact JSON with keys in a stable order. `blob`/`msg_id` are already
    /// strings, so no ordering ambiguity that would matter to the server.
    func jsonData() -> Data {
        let object: [String: String]
        switch self {
        case let .auth(token):
            object = ["t": "auth", "token": token]
        case let .send(msgId, blobBase64):
            object = ["t": "send", "msg_id": msgId, "blob": blobBase64]
        case let .ack(msgId):
            object = ["t": "ack", "msg_id": msgId]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
    }
}

// MARK: - Hidden E2E payload framing (media support, spec point 3)
//
// The relay only ever sees the E2E ciphertext of these payloads, so this framing
// is invisible to the server. A plain text message is still sent as raw UTF-8
// (no framing) to stay wire-compatible with the existing desktop/test peer;
// media frames are prefixed with a 4-byte magic that valid UTF-8 text never
// begins with (leading NUL), so `decode` can tell them apart without ambiguity.
//
//   text        : <utf-8 bytes>                                (legacy compatible)
//   media magic : 0x00 'H' 'C' 'M'
//   meta        : magic, 0x01, str(fileId), u32 kind, str(name), str(mime),
//                 u64 size, u32 chunks, u32 width, u32 height, u32 durationMs
//   chunk       : magic, 0x02, str(fileId), u32 index, u32 total, u32 len, <len bytes>
//
// Chunk bytes are the *plaintext* of one slice of the media file; the whole
// frame is E2E-encrypted before it hits the wire, so media bytes are base64'd
// exactly once (by RelayClient), not twice.

public struct HiddenMediaMeta: Equatable {
    public var fileId: String
    public var kind: Int          // MediaKind.rawValue
    public var filename: String
    public var mime: String
    public var size: Int
    public var chunks: Int
    public var width: Int
    public var height: Int
    public var durationMs: Int

    public init(fileId: String, kind: Int, filename: String, mime: String,
                size: Int, chunks: Int, width: Int = 0, height: Int = 0, durationMs: Int = 0) {
        self.fileId = fileId
        self.kind = kind
        self.filename = filename
        self.mime = mime
        self.size = size
        self.chunks = chunks
        self.width = width
        self.height = height
        self.durationMs = durationMs
    }
}

public enum HiddenPayload: Equatable {
    case text(String)
    case mediaMeta(HiddenMediaMeta)
    case mediaChunk(fileId: String, index: Int, total: Int, data: Data)

    static let magic: [UInt8] = [0x00, 0x48, 0x43, 0x4D] // "\0HCM"

    /// Serialise to the E2E plaintext that gets encrypted and sent.
    public func encode() -> Data {
        switch self {
        case let .text(s):
            return Data(s.utf8)
        case let .mediaMeta(m):
            var out = Data(HiddenPayload.magic)
            out.append(0x01)
            Wire.putStr(&out, m.fileId)
            Wire.putU32(&out, UInt32(m.kind))
            Wire.putStr(&out, m.filename)
            Wire.putStr(&out, m.mime)
            Wire.putU64(&out, UInt64(max(0, m.size)))
            Wire.putU32(&out, UInt32(max(0, m.chunks)))
            Wire.putU32(&out, UInt32(max(0, m.width)))
            Wire.putU32(&out, UInt32(max(0, m.height)))
            Wire.putU32(&out, UInt32(max(0, m.durationMs)))
            return out
        case let .mediaChunk(fileId, index, total, data):
            var out = Data(HiddenPayload.magic)
            out.append(0x02)
            Wire.putStr(&out, fileId)
            Wire.putU32(&out, UInt32(max(0, index)))
            Wire.putU32(&out, UInt32(max(0, total)))
            Wire.putU32(&out, UInt32(data.count))
            out.append(data)
            return out
        }
    }

    /// Parse decrypted plaintext. Anything that isn't a well-formed media frame
    /// is treated as a plain text message (legacy path).
    public static func decode(_ data: Data) -> HiddenPayload {
        let b = [UInt8](data)
        guard b.count >= 5, Array(b[0..<4]) == magic else {
            return .text(String(decoding: data, as: UTF8.self))
        }
        let sub = b[4]
        var pos = 5
        switch sub {
        case 0x01:
            guard let (fileId, p1) = Wire.getStr(b, pos) else { return fallback(data) }; pos = p1
            guard let (kind, p2) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p2
            guard let (name, p3) = Wire.getStr(b, pos) else { return fallback(data) }; pos = p3
            guard let (mime, p4) = Wire.getStr(b, pos) else { return fallback(data) }; pos = p4
            guard let (size, p5) = Wire.getU64(b, pos) else { return fallback(data) }; pos = p5
            guard let (chunks, p6) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p6
            guard let (w, p7) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p7
            guard let (h, p8) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p8
            guard let (dur, _) = Wire.getU32(b, pos) else { return fallback(data) }
            return .mediaMeta(HiddenMediaMeta(
                fileId: fileId, kind: Int(kind), filename: name, mime: mime,
                size: Int(size), chunks: Int(chunks),
                width: Int(w), height: Int(h), durationMs: Int(dur)))
        case 0x02:
            guard let (fileId, p1) = Wire.getStr(b, pos) else { return fallback(data) }; pos = p1
            guard let (index, p2) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p2
            guard let (total, p3) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p3
            guard let (len, p4) = Wire.getU32(b, pos) else { return fallback(data) }; pos = p4
            let n = Int(len)
            guard pos + n <= b.count else { return fallback(data) }
            return .mediaChunk(fileId: fileId, index: Int(index), total: Int(total),
                               data: Data(b[pos..<pos + n]))
        default:
            return fallback(data)
        }
    }

    private static func fallback(_ data: Data) -> HiddenPayload {
        return .text(String(decoding: data, as: UTF8.self))
    }
}

/// Little-endian length-prefixed wire helpers shared by the media framing.
enum Wire {
    static func putU32(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff))
        out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 24) & 0xff))
    }
    static func putU64(_ out: inout Data, _ v: UInt64) {
        for i in 0..<8 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }
    static func putStr(_ out: inout Data, _ s: String) {
        let d = Data(s.utf8); putU32(&out, UInt32(d.count)); out.append(d)
    }
    static func getU32(_ b: [UInt8], _ p: Int) -> (UInt32, Int)? {
        guard p + 4 <= b.count else { return nil }
        return (UInt32(b[p]) | (UInt32(b[p + 1]) << 8) | (UInt32(b[p + 2]) << 16) | (UInt32(b[p + 3]) << 24), p + 4)
    }
    static func getU64(_ b: [UInt8], _ p: Int) -> (UInt64, Int)? {
        guard p + 8 <= b.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * i) }
        return (v, p + 8)
    }
    static func getStr(_ b: [UInt8], _ p: Int) -> (String, Int)? {
        guard let (len, p1) = getU32(b, p) else { return nil }
        let n = Int(len)
        guard p1 + n <= b.count else { return nil }
        return (String(decoding: b[p1..<p1 + n], as: UTF8.self), p1 + n)
    }
}

/// Frames the relay sends back.
enum RelayInbound {
    case authOk
    case authErr
    case deliver(msgId: String, blobBase64: String)
    case queued
    case unknown(String)

    init?(jsonData: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: jsonData, options: []),
            let object = root as? [String: Any],
            let type = object["t"] as? String
        else {
            return nil
        }
        switch type {
        case "auth_ok":
            self = .authOk
        case "auth_err":
            self = .authErr
        case "queued":
            self = .queued
        case "deliver":
            let msgId = object["msg_id"] as? String ?? ""
            let blob = object["blob"] as? String ?? ""
            self = .deliver(msgId: msgId, blobBase64: blob)
        default:
            self = .unknown(type)
        }
    }
}
