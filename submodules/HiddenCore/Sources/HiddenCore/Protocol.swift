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
