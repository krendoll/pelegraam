//
//  HiddenSession.swift
//  HiddenCore
//
//  Lifecycle orchestrator for the hidden area. Mirrors
//  Telegram/SourceFiles/hidden/hidden_layer_manager.cpp (LayerManager), minus
//  the Qt UI, and extended for the iOS spec:
//    - many conversations (relay-person / relay-app / telegram-hidden),
//    - file/photo/video transfer over the relay (chunked, E2E, encrypted at rest),
//    - auto-delete of old relay messages/media,
//    - appear-offline toggle.
//
//  Invariants carried over from the desktop:
//    1. The PIN never reaches search / index / network.
//    2. container.close() + key zeroing happen synchronously on every dismiss.
//    3. No "is-active" flag is written to disk.
//    4. Relay connections open after the vault opens, close on dismiss.
//    5. The relay is blind: it only ever sees E2E ciphertext.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import Foundation
import Combine

public final class HiddenSession {

    public enum Status: Equatable {
        case idle, connecting, online, reconnecting, authError
    }

    // Reactive surface for the UI.
    public let conversations = CurrentValueSubject<[Conversation], Never>([])
    public let statusByConversation = CurrentValueSubject<[String: Status], Never>([:])

    public private(set) var isActive = false

    public let container: Container
    public let mediaStore: MediaStore
    private let e2eKey: [UInt8]

    /// One relay socket per relay conversation, keyed by conversation id.
    private var clients: [String: RelayClient] = [:]
    private var clientCancellables: [String: Set<AnyCancellable>] = [:]
    private var seenIds: [String: Set<String>] = [:]   // convId -> delivered msg ids

    /// In-flight inbound media reassembly, keyed by wire fileId.
    private struct Incoming { var meta: HiddenMediaMeta; var convId: String; var chunks: [Int: Data] }
    private var incoming: [String: Incoming] = [:]

    private let chunkSize = 48 * 1024
    private let maxMediaBytes = 200 * 1024 * 1024
    private let sendQueue = DispatchQueue(label: "hiddencore.media.send", qos: .userInitiated)

    public init(container: Container,
                e2eKey: [UInt8] = E2ECrypto.devPSK) {
        self.container = container
        self.mediaStore = MediaStore(container: container)
        self.e2eKey = e2eKey
    }

    // MARK: - Open / dismiss

    /// Open the vault with `pin`; on success, seed a default relay chat if empty,
    /// run the auto-delete sweep, and connect every relay conversation.
    @discardableResult
    public func open(pin: SecurePIN) -> Bool {
        guard container.open(pin: pin) else { return false }
        isActive = true

        // Fresh vault: seed the default relay conversation so the user has a
        // working E2E chat immediately (existing devices migrate a "legacy-relay").
        if container.state.conversations.isEmpty {
            container.mutateState {
                $0.conversations.append(Conversation(
                    id: "default-relay", kind: .relayPerson, title: "Relay",
                    relayToken: HiddenConfig.defaultToken))
            }
            container.save()
        }

        runAutoDeleteSweep()
        publishConversations()
        connectAllRelays()
        return true
    }

    /// Synchronous teardown — sockets closed, key wiped. Idempotent.
    public func dismiss() {
        guard isActive else { return }
        for (_, c) in clients { c.disconnect() }
        clients.removeAll()
        clientCancellables.removeAll()
        seenIds.removeAll()
        incoming.removeAll()
        container.close()
        isActive = false
        conversations.send([])
        statusByConversation.send([:])
    }

    // MARK: - Conversation management

    public func conversation(_ id: String) -> Conversation? {
        container.state.conversations.first { $0.id == id }
    }

    /// Add a relay chat (person or app) identified by its room token.
    @discardableResult
    public func addRelayConversation(title: String, token: String, kind: ConversationKind) -> String {
        let id = UUID().uuidString.lowercased()
        container.mutateState {
            $0.conversations.append(Conversation(id: id, kind: kind, title: title, relayToken: token))
        }
        container.save()
        publishConversations()
        connect(convId: id, token: token)
        return id
    }

    /// Add a normal Telegram chat to the hidden area (UI hide handled by host).
    public func addTelegramHidden(peerId: Int64, title: String) {
        guard peerId != 0,
              !container.state.conversations.contains(where: { $0.peerId == peerId }) else { return }
        container.mutateState {
            $0.conversations.append(Conversation(
                id: "peer-\(peerId)", kind: .telegramHidden, title: title, peerId: peerId))
        }
        container.save()
        publishConversations()
    }

    public func removeConversation(_ id: String) {
        // Purge any media blobs owned by this conversation.
        if let conv = conversation(id) {
            mediaStore.delete(ids: conv.messages.compactMap { $0.media?.id })
        }
        if let client = clients[id] { client.disconnect() }
        clients[id] = nil
        clientCancellables[id] = nil
        seenIds[id] = nil
        container.mutateState { $0.conversations.removeAll { $0.id == id } }
        container.save()
        publishConversations()
    }

    // MARK: - Preferences (behind the PIN)

    public var hideOnline: Bool { container.state.hideOnline }

    public func setHideOnline(_ on: Bool) {
        guard container.isOpen, container.state.hideOnline != on else { return }
        container.mutateState { $0.hideOnline = on }
        container.save()
    }

    public var autoDeleteDays: Int { container.state.autoDeleteDays }

    public func setAutoDeleteDays(_ days: Int) {
        guard container.isOpen else { return }
        container.mutateState { $0.autoDeleteDays = max(0, days) }
        container.save()
        runAutoDeleteSweep()
        publishConversations()
    }

    // MARK: - Sending

    /// Send a plain text message (raw UTF-8 on the wire, legacy compatible).
    public func sendText(_ text: String, to convId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conv = conversation(convId), conv.kind.usesRelay else { return }
        let msg = StoredMessage(text: trimmed, outgoing: true, timestamp: Date().timeIntervalSince1970)
        append(msg, to: convId)
        if let blob = E2ECrypto.encrypt(HiddenPayload.text(trimmed).encode(), key: e2eKey) {
            clients[convId]?.sendBlob(blob)
        }
    }

    /// Send a media item. Stores it encrypted locally (echo) and streams it to
    /// the peer as E2E-encrypted chunks.
    public func sendMedia(data: Data, filename: String, mime: String,
                          width: Int = 0, height: Int = 0, durationMs: Int = 0,
                          caption: String = "", to convId: String) {
        guard let conv = conversation(convId), conv.kind.usesRelay,
              data.count > 0, data.count <= maxMediaBytes else { return }
        let kind = MediaKind.classify(mime: mime, filename: filename)
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            guard let blobId = self.mediaStore.store(data) else { return }
            let ref = MediaRef(id: blobId, kind: kind, filename: filename, mime: mime,
                               size: data.count, width: width, height: height, durationMs: durationMs)
            let msg = StoredMessage(text: caption, outgoing: true,
                                    timestamp: Date().timeIntervalSince1970, media: ref)
            DispatchQueue.main.async { self.append(msg, to: convId) }

            // Stream to the peer: meta first, then ordered chunks.
            let transferId = UUID().uuidString.lowercased()
            let total = (data.count + self.chunkSize - 1) / self.chunkSize
            let meta = HiddenMediaMeta(fileId: transferId, kind: kind.rawValue,
                                       filename: filename, mime: mime, size: data.count,
                                       chunks: total, width: width, height: height, durationMs: durationMs)
            self.encryptAndSend(.mediaMeta(meta), convId: convId)
            var index = 0
            var offset = 0
            while offset < data.count {
                let end = min(offset + self.chunkSize, data.count)
                let slice = data.subdata(in: offset..<end)
                self.encryptAndSend(.mediaChunk(fileId: transferId, index: index, total: total, data: slice),
                                    convId: convId)
                index += 1
                offset = end
            }
        }
    }

    private func encryptAndSend(_ payload: HiddenPayload, convId: String) {
        guard let blob = E2ECrypto.encrypt(payload.encode(), key: e2eKey) else { return }
        DispatchQueue.main.async { [weak self] in self?.clients[convId]?.sendBlob(blob) }
    }

    // MARK: - Media access

    public func loadMedia(_ ref: MediaRef) -> Data? { mediaStore.load(ref.id) }

    // MARK: - Relay wiring

    private func connectAllRelays() {
        for conv in container.state.conversations where conv.kind.usesRelay && !conv.relayToken.isEmpty {
            connect(convId: conv.id, token: conv.relayToken)
        }
    }

    private func connect(convId: String, token: String) {
        guard clients[convId] == nil else { return }
        let client = RelayClient()
        var bag = Set<AnyCancellable>()
        client.authOk.sink { [weak self] in self?.setStatus(.online, convId) }.store(in: &bag)
        client.authErr.sink { [weak self] in self?.setStatus(.authError, convId) }.store(in: &bag)
        client.relayDisconnected.sink { [weak self] in
            guard let self = self, self.isActive else { return }
            self.setStatus(.reconnecting, convId)
        }.store(in: &bag)
        client.delivered.sink { [weak self] msg in self?.handleDelivered(msg, convId: convId) }.store(in: &bag)
        clients[convId] = client
        clientCancellables[convId] = bag
        setStatus(.connecting, convId)
        client.connect(token: token)
    }

    private func setStatus(_ s: Status, _ convId: String) {
        var map = statusByConversation.value
        map[convId] = s
        statusByConversation.send(map)
    }

    private func handleDelivered(_ msg: RelayMessage, convId: String) {
        var seen = seenIds[convId] ?? []
        guard !seen.contains(msg.id) else { return }
        seen.insert(msg.id); seenIds[convId] = seen

        guard let pt = E2ECrypto.decrypt(msg.blob, key: e2eKey) else { return } // bad tag -> ignore
        switch HiddenPayload.decode(pt) {
        case let .text(text):
            let m = StoredMessage(text: text, outgoing: false, timestamp: Date().timeIntervalSince1970)
            append(m, to: convId)
        case let .mediaMeta(meta):
            guard meta.size <= maxMediaBytes, meta.chunks >= 0 else { return }
            // Preserve any chunks that arrived before the meta.
            let existing = incoming[meta.fileId]?.chunks ?? [:]
            incoming[meta.fileId] = Incoming(meta: meta, convId: convId, chunks: existing)
            tryComplete(meta.fileId)
        case let .mediaChunk(fileId, index, _, data):
            if var inflight = incoming[fileId] {
                inflight.chunks[index] = data
                incoming[fileId] = inflight
            } else {
                // Chunk before meta: stash under a placeholder (chunks = -1 keeps
                // tryComplete waiting until the real meta arrives).
                var placeholder = Incoming(
                    meta: HiddenMediaMeta(fileId: fileId, kind: MediaKind.file.rawValue,
                                          filename: "file", mime: "application/octet-stream",
                                          size: 0, chunks: -1),
                    convId: convId, chunks: [:])
                placeholder.chunks[index] = data
                incoming[fileId] = placeholder
            }
            tryComplete(fileId)
        }
    }

    /// Assemble a media transfer once meta + all chunks have arrived.
    private func tryComplete(_ fileId: String) {
        guard let inflight = incoming[fileId], inflight.meta.chunks >= 0 else { return }
        let total = inflight.meta.chunks
        guard inflight.chunks.count >= total else { return }
        var assembled = Data()
        for i in 0..<total {
            guard let part = inflight.chunks[i] else { return } // missing chunk, wait
            assembled.append(part)
        }
        incoming[fileId] = nil
        guard assembled.count <= maxMediaBytes, let blobId = mediaStore.store(assembled) else { return }
        let meta = inflight.meta
        let ref = MediaRef(id: blobId,
                           kind: MediaKind(rawValue: meta.kind) ?? .file,
                           filename: meta.filename, mime: meta.mime,
                           size: assembled.count, width: meta.width,
                           height: meta.height, durationMs: meta.durationMs)
        let m = StoredMessage(text: "", outgoing: false,
                              timestamp: Date().timeIntervalSince1970, media: ref)
        append(m, to: inflight.convId)
    }

    // MARK: - Persistence helpers

    private func append(_ message: StoredMessage, to convId: String) {
        container.mutateState { st in
            guard let idx = st.conversations.firstIndex(where: { $0.id == convId }) else { return }
            st.conversations[idx].messages.append(message)
        }
        container.save()
        publishConversations()
    }

    private func publishConversations() {
        conversations.send(container.state.conversations)
    }

    /// Delete relay messages (and their media blobs) older than the configured
    /// window. No-op when auto-delete is off or for telegram-hidden chats.
    private func runAutoDeleteSweep() {
        let days = container.state.autoDeleteDays
        guard days > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
        var blobsToDelete: [String] = []
        container.mutateState { st in
            for i in st.conversations.indices where st.conversations[i].kind.usesRelay {
                let kept = st.conversations[i].messages.filter { msg in
                    if msg.timestamp < cutoff {
                        if let id = msg.media?.id { blobsToDelete.append(id) }
                        return false
                    }
                    return true
                }
                st.conversations[i].messages = kept
            }
        }
        mediaStore.delete(ids: blobsToDelete)
        container.save()
    }
}
