//
//  HiddenModels.swift
//  HiddenCore
//
//  Data model for the hidden area, persisted inside the encrypted vault (V4).
//  Everything here lives behind the PIN and is written to disk only as AES-GCM
//  ciphertext (see Container). Media *payloads* are stored separately by
//  MediaStore, also as ciphertext; a StoredMessage only carries a MediaRef
//  (metadata + blob id), never plaintext bytes.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation

/// The three kinds of chat that live in the hidden area (spec point 2).
public enum ConversationKind: Int, Equatable {
    /// E2E chat with another person, carried by our blind relay.
    case relayPerson = 0
    /// E2E chat with a local-PC application (bot-style), carried by the relay.
    case relayApp = 1
    /// A normal Telegram chat, UI-hidden from the main app. Its data still lives
    /// in Telegram; this is purely a UI hide (spec point 2, invariant).
    case telegramHidden = 2

    /// Relay kinds open a WebSocket; telegramHidden does not.
    public var usesRelay: Bool { self == .relayPerson || self == .relayApp }
}

/// What a piece of attached media is, so the UI can render it Telegram-style.
public enum MediaKind: Int, Equatable {
    case image = 0
    case video = 1
    case audio = 2
    case file  = 3

    /// Best-effort classification from a MIME type / filename.
    public static func classify(mime: String, filename: String) -> MediaKind {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return .image }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .image
        case "mp4", "mov", "m4v": return .video
        case "mp3", "m4a", "aac", "wav", "ogg": return .audio
        default: return .file
        }
    }
}

/// Metadata pointing at an encrypted blob in MediaStore. No plaintext here.
public struct MediaRef: Equatable {
    public var id: String        // blob id inside MediaStore (== on-disk filename)
    public var kind: MediaKind
    public var filename: String
    public var mime: String
    public var size: Int         // plaintext byte length
    public var width: Int        // 0 if unknown
    public var height: Int       // 0 if unknown
    public var durationMs: Int   // 0 if unknown / not applicable

    public init(id: String, kind: MediaKind, filename: String, mime: String,
                size: Int, width: Int = 0, height: Int = 0, durationMs: Int = 0) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mime = mime
        self.size = size
        self.width = width
        self.height = height
        self.durationMs = durationMs
    }
}

/// A persisted message inside a conversation. Text and/or a single media item.
public struct StoredMessage: Equatable {
    public var id: String
    public var text: String
    public var outgoing: Bool
    public var timestamp: Double   // seconds since 1970
    public var media: MediaRef?

    public init(id: String = UUID().uuidString.lowercased(),
                text: String,
                outgoing: Bool,
                timestamp: Double,
                media: MediaRef? = nil) {
        self.id = id
        self.text = text
        self.outgoing = outgoing
        self.timestamp = timestamp
        self.media = media
    }
}

/// One chat thread in the hidden area.
public struct Conversation: Equatable {
    public var id: String
    public var kind: ConversationKind
    public var title: String
    /// Relay room token for relay kinds; empty for telegramHidden.
    public var relayToken: String
    /// Telegram peer id for telegramHidden; 0 for relay kinds.
    public var peerId: Int64
    public var messages: [StoredMessage]

    public init(id: String = UUID().uuidString.lowercased(),
                kind: ConversationKind,
                title: String,
                relayToken: String = "",
                peerId: Int64 = 0,
                messages: [StoredMessage] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.relayToken = relayToken
        self.peerId = peerId
        self.messages = messages
    }

    public var lastMessage: StoredMessage? { messages.last }
}

/// Everything persisted behind the PIN.
public struct VaultState: Equatable {
    /// "Disable online status" toggle (spec point 4).
    public var hideOnline: Bool
    /// Auto-delete window in days for RELAY conversations only. 0 = off (spec point 4).
    public var autoDeleteDays: Int
    public var conversations: [Conversation]

    public init(hideOnline: Bool = false,
                autoDeleteDays: Int = 0,
                conversations: [Conversation] = []) {
        self.hideOnline = hideOnline
        self.autoDeleteDays = autoDeleteDays
        self.conversations = conversations
    }
}

/// Legacy V1/V2/V3 chat row, retained only so the vault can migrate old files
/// into `Conversation`s. Not used by new code paths.
public struct LegacyChatEntry: Equatable {
    public var title: String
    public var lastMessage: String
    public var peerId: Int64
    public init(title: String, lastMessage: String, peerId: Int64 = 0) {
        self.title = title
        self.lastMessage = lastMessage
        self.peerId = peerId
    }
}
