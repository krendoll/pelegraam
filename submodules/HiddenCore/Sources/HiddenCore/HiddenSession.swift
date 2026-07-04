//
//  HiddenSession.swift
//  HiddenCore
//
//  Lifecycle orchestrator for the hidden area. Mirrors
//  Telegram/SourceFiles/hidden/hidden_layer_manager.cpp (LayerManager),
//  minus the Qt UI.
//
//  Invariants carried over from the desktop:
//    1. The PIN never reaches search / index / network — enforced by PinGate at
//       the host call site.
//    2. container.close() + key zeroing happen synchronously on every dismiss.
//    3. No "is-active" flag is written to disk.
//    4. The relay connects after the vault opens, disconnects on dismiss.
//
//  Host responsibilities:
//    - call `open(pin:token:)` when PinGate matched a submitted PIN;
//    - render `messages` / `status`;
//    - forward user text via `send(_:)`;
//    - call `dismiss()` on app-background / lock / explicit close (the desktop
//      deactivation triggers).
//

import Foundation
import Combine

public struct HiddenMessage: Equatable {
    public let text: String
    public let outgoing: Bool
    public let date: Date
}

public final class HiddenSession {

    public enum Status: Equatable {
        case idle
        case connecting
        case online
        case reconnecting
        case authError
    }

    // Reactive surface (mirrors the desktop rpl streams the overlay subscribed to).
    public let status = CurrentValueSubject<Status, Never>(.idle)
    public let messages = PassthroughSubject<HiddenMessage, Never>()

    public private(set) var isActive = false

    public let container: Container
    private let relay: RelayClient
    private let e2eKey: [UInt8]

    private var seenIds = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    public init(container: Container,
                relay: RelayClient = RelayClient(),
                e2eKey: [UInt8] = E2ECrypto.devPSK) {
        self.container = container
        self.relay = relay
        self.e2eKey = e2eKey
        wireRelay()
    }

    // MARK: - Open / dismiss (mirrors tryIntercept success path + dismiss)

    /// Open the vault with `pin` and, on success, connect to the relay room
    /// identified by `token`. Returns true iff the vault opened.
    /// Intentionally slow (PBKDF2 100k) — call off the main thread if desired,
    /// but deliver the result back on main.
    @discardableResult
    public func open(pin: SecurePIN, token: String) -> Bool {
        guard container.open(pin: pin) else { return false }
        isActive = true
        seenIds.removeAll()
        status.send(.connecting)
        relay.connect(token: token)
        return true
    }

    /// Synchronous teardown — key wiped, relay disconnected. Idempotent.
    public func dismiss() {
        guard isActive else { return }
        relay.disconnect()
        container.close()
        seenIds.removeAll()
        isActive = false
        status.send(.idle)
    }

    // MARK: - Persisted preferences (behind the PIN)

    /// "Disable online status" flag, restored from the vault on open.
    public var hideOnline: Bool {
        container.state.hideOnline
    }

    public func setHideOnline(_ on: Bool) {
        guard container.isOpen, container.state.hideOnline != on else { return }
        container.mutateState { $0.hideOnline = on }
        container.save()
    }

    /// Hidden normal Telegram chats (peerId != 0), stored behind the PIN.
    public var hiddenChats: [ChatEntry] {
        container.state.chats.filter { $0.peerId != 0 }
    }

    public func addHiddenChat(peerId: Int64, title: String) {
        guard container.isOpen, peerId != 0 else { return }
        guard !container.state.chats.contains(where: { $0.peerId == peerId }) else { return }
        container.addChat(ChatEntry(title: title, lastMessage: "", peerId: peerId))
        container.save()
    }

    public func removeHiddenChat(peerId: Int64) {
        guard container.isOpen else { return }
        container.mutateState { $0.chats.removeAll { $0.peerId == peerId } }
        container.save()
    }

    // MARK: - Messaging (mirrors overlay sendRequests / delivered wiring)

    /// Relay-chat history persisted behind the PIN, oldest first. Load this into
    /// the overlay on open so messages survive dismiss/reopen.
    public var history: [HiddenMessage] {
        container.state.messages.map {
            HiddenMessage(text: $0.text, outgoing: $0.outgoing,
                          date: Date(timeIntervalSince1970: $0.timestamp))
        }
    }

    private func persist(_ text: String, outgoing: Bool) {
        guard container.isOpen else { return }
        container.mutateState {
            $0.messages.append(StoredMessage(text: text, outgoing: outgoing,
                                             timestamp: Date().timeIntervalSince1970))
        }
        container.save()
    }

    /// Encrypt and forward `text`. Echoes it locally as outgoing, like the
    /// desktop overlay does, and persists it behind the PIN.
    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, relay.isConnected else { return }
        guard let blob = E2ECrypto.encrypt(Data(trimmed.utf8), key: e2eKey) else { return }
        relay.sendBlob(blob)
        persist(trimmed, outgoing: true)
        messages.send(HiddenMessage(text: trimmed, outgoing: true, date: Date()))
    }

    // MARK: - Relay wiring

    private func wireRelay() {
        relay.authOk
            .sink { [weak self] in self?.status.send(.online) }
            .store(in: &cancellables)

        relay.authErr
            .sink { [weak self] in self?.status.send(.authError) }
            .store(in: &cancellables)

        relay.relayDisconnected
            .sink { [weak self] in
                guard let self = self, self.isActive else { return }
                self.status.send(.reconnecting)
            }
            .store(in: &cancellables)

        relay.delivered
            .sink { [weak self] msg in self?.handleDelivered(msg) }
            .store(in: &cancellables)
    }

    private func handleDelivered(_ msg: RelayMessage) {
        guard !seenIds.contains(msg.id) else { return }
        seenIds.insert(msg.id)
        guard let pt = E2ECrypto.decrypt(msg.blob, key: e2eKey) else { return } // bad tag -> ignore
        let text = String(decoding: pt, as: UTF8.self)
        persist(text, outgoing: false)
        messages.send(HiddenMessage(text: text, outgoing: false, date: Date()))
    }
}
