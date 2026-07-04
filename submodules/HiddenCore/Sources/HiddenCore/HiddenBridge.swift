//
//  HiddenBridge.swift
//  HiddenCore
//
//  Structured message envelopes produced by the local-PC relay bridge that
//  fronts the bots (D:\AI release stack: relaybridge/relay_bridge.py). The bridge
//  wraps ONLY images as a JSON envelope; plain text is sent as raw UTF-8. This
//  mirrors the bridge's own `decode_payload` so the two ends agree exactly:
//
//      image : {"t":"img","mime":"image/png","b64":"<base64>","cap":"<caption>"}
//      text  : <raw utf-8 bytes>            (no framing)
//
//  `mime` defaults to image/png (the bridge may recompress to image/jpeg to fit
//  the relay frame limit). `cap` is an optional caption, possibly empty.
//
//  Unknown / malformed envelopes return nil so the caller falls back to treating
//  the payload as plain text (graceful degradation — never break on new types).
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation

public enum BridgeEnvelope: Equatable {
    /// A complete image in one message (not chunked), base64-decoded.
    case image(mime: String, data: Data, caption: String)

    /// Parse a decrypted relay payload. Returns a recognized bridge envelope, or
    /// nil if this isn't one (plain text, iOS `\0HCM` media framing, unknown `t`).
    public static func parse(_ plaintext: Data) -> BridgeEnvelope? {
        // Fast reject: a bridge envelope is a JSON object, so it starts with '{'.
        // Raw text and the iOS media framing (leading NUL) never do.
        guard plaintext.first == 0x7B /* { */ else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: plaintext),
              let obj = root as? [String: Any],
              let t = obj["t"] as? String else { return nil }

        switch t {
        case "img":
            guard let b64 = obj["b64"] as? String,
                  let data = Data(base64Encoded: b64), !data.isEmpty else { return nil }
            let mime = (obj["mime"] as? String) ?? "image/png"
            let caption = (obj["cap"] as? String) ?? ""
            return .image(mime: mime, data: data, caption: caption)
        default:
            // Known-JSON but unknown type -> let the caller show it as text.
            return nil
        }
    }

    /// A filename extension for a stored image, derived from its MIME type.
    public static func imageExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png":               return "png"
        case "image/gif":               return "gif"
        case "image/webp":              return "webp"
        case "image/heic":              return "heic"
        default:                        return "img"
        }
    }
}
