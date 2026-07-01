//
//  HiddenConfig.swift
//  HiddenCore
//
//  One place for the relay endpoint + token, mirroring the desktop constants in
//  hidden_layer_manager.h (kRelayToken) and relay_client.cpp (kHost/kPath).
//
//  Tokens are issued MANUALLY on the relay (serverside/tokens.json). For the
//  iPhone to talk to the Windows desktop, add a SECOND token that maps to the
//  SAME room_id as the desktop's token, then set `relayToken` here to it.
//

import Foundation

public struct HiddenConfig {

    /// This iPhone's relay device token. It is the peer-B slot already
    /// provisioned in the relay's tokens.json under "room1", the same room as the
    /// desktop token 3f3da505e5c5e429ec3e412b63e80b8dfc768c5a0cbd5507a09020fcff39e43e.
    /// The relay is a strict 2-client design, so the iPhone reuses this existing
    /// slot rather than adding a third token to the room.
    public static let defaultToken =
        "c39336d956cb353ff0c5db14eeb1c703dfa7a6a9767547eacfc8dfdfabd6598c"

    public var relayHost: String
    public var relayPath: String

    /// Device token for THIS client. Must be present in the relay's tokens.json
    /// mapped to the room shared with the peer (the desktop).
    public var relayToken: String

    /// Desktop parity: stealth pushes account offline every 25 s.
    public var stealthIntervalSeconds: TimeInterval

    public init(
        relayHost: String = RelayClient.defaultHost,
        relayPath: String = RelayClient.defaultPath,
        relayToken: String = HiddenConfig.defaultToken,
        stealthIntervalSeconds: TimeInterval = 25
    ) {
        self.relayHost = relayHost
        self.relayPath = relayPath
        self.relayToken = relayToken
        self.stealthIntervalSeconds = stealthIntervalSeconds
    }
}
