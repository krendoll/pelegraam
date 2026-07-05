//
//  HiddenViewModel.swift
//  HiddenAreaUI  (pelegram)
//
//  Observable bridge between the HiddenCore session and the SwiftUI screens.
//  Holds no plaintext media — media is loaded on demand through the session,
//  which decrypts from the vault in memory only.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation
import SwiftUI
import Combine
import HiddenCore
import AccountContext

@available(iOS 15.0, *)
@MainActor
final class HiddenViewModel: ObservableObject {

    @Published var conversations: [Conversation] = []
    @Published var statuses: [String: HiddenSession.Status] = [:]
    @Published var hideOnline: Bool
    @Published var autoDeleteDays: Int

    // Wired by the host controller (needs AccountContext + navigation).
    var onOpenTelegramChat: ((Int64) -> Void)?
    var onHideTelegramChat: ((String, @escaping (Int64, String) -> Void) -> Void)?
    var onUnhideTelegramChat: ((Int64) -> Void)?

    let session: HiddenSession
    private let stealth: StealthKeeper
    private let context: AccountContext
    private var cancellables = Set<AnyCancellable>()

    init(session: HiddenSession, stealth: StealthKeeper, context: AccountContext) {
        self.session = session
        self.stealth = stealth
        self.context = context
        self.hideOnline = session.hideOnline
        self.autoDeleteDays = session.autoDeleteDays

        stealth.setEnabled(session.hideOnline)

        session.conversations
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.conversations = $0 }
            .store(in: &cancellables)
        session.statusByConversation
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.statuses = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Reads

    func conversation(_ id: String) -> Conversation? { conversations.first { $0.id == id } }
    func messages(for id: String) -> [StoredMessage] { conversation(id)?.messages ?? [] }
    func status(for id: String) -> HiddenSession.Status { statuses[id] ?? .idle }

    var relayConversations: [Conversation] { conversations.filter { $0.kind == .relayPerson } }
    var appConversations: [Conversation] { conversations.filter { $0.kind == .relayApp } }
    var telegramConversations: [Conversation] { conversations.filter { $0.kind == .telegramHidden } }

    // MARK: - Messaging

    func sendText(_ text: String, to id: String) { session.sendText(text, to: id) }

    func sendMedia(data: Data, filename: String, mime: String,
                   width: Int = 0, height: Int = 0, durationMs: Int = 0,
                   caption: String = "", to id: String) {
        session.sendMedia(data: data, filename: filename, mime: mime,
                          width: width, height: height, durationMs: durationMs,
                          caption: caption, to: id)
    }

    // MARK: - Settings

    func setHideOnline(_ on: Bool) {
        hideOnline = on
        stealth.setEnabled(on)
        session.setHideOnline(on)
    }

    func setAutoDeleteDays(_ days: Int) {
        autoDeleteDays = days
        session.setAutoDeleteDays(days)
    }

    // MARK: - New chat

    func addRelayPerson(title: String, token: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !k.isEmpty else { return }
        _ = session.addRelayConversation(title: t, token: k, kind: .relayPerson)
    }

    func addRelayApp(title: String, token: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !k.isEmpty else { return }
        _ = session.addRelayConversation(title: t, token: k, kind: .relayApp)
    }

    func hideTelegramChat(username: String) {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onHideTelegramChat?(name) { [weak self] peerId, title in
            self?.session.addTelegramHidden(peerId: peerId, title: title)
        }
    }

    func removeConversation(_ conv: Conversation) {
        if conv.kind == .telegramHidden, conv.peerId != 0 {
            onUnhideTelegramChat?(conv.peerId)
        }
        session.removeConversation(conv.id)
    }

    /// Restore a hidden Telegram chat back to the normal lists (un-archive,
    /// un-mute, drop from .hidden_ids) and remove it from the hidden area.
    func unhideTelegramChat(_ conv: Conversation) {
        removeConversation(conv)
    }

    /// Safety net: restore EVERY hidden Telegram chat, including any that are in
    /// .hidden_ids but no longer have a listed conversation (orphans).
    func unhideAllTelegramChats() {
        for id in HiddenPeers.shared.all() {
            onUnhideTelegramChat?(id)           // engine: HiddenPeers.remove + unarchive + unmute
        }
        for conv in telegramConversations {
            session.removeConversation(conv.id) // drop from the hidden-area list/vault
        }
    }

    func openTelegramChat(_ peerId: Int64) { onOpenTelegramChat?(peerId) }
}
