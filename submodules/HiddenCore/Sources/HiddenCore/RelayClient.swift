//
//  RelayClient.swift
//  HiddenCore
//
//  WebSocket relay client. Mirrors Telegram/SourceFiles/hidden/relay_client.cpp
//  but uses URLSessionWebSocketTask, which gives TLS (with full peer
//  verification, like the desktop's VerifyPeer) and RFC6455 framing for free —
//  so the hand-rolled masking / frame parser from the desktop is unnecessary.
//
//  The relay is blind: blobs are E2E-encrypted by the caller (see E2ECrypto).
//  All Combine subjects are delivered on the main queue to match the desktop
//  "main thread only" contract for the manager layer.
//

import Foundation
import Combine

public struct RelayMessage: Equatable {
    public let id: String
    public let blob: Data   // still encrypted
}

public final class RelayClient: NSObject {

    public static let defaultHost = "krendollbot.duckdns.org"
    public static let defaultPath = "/ws"

    /// Event streams mirroring the desktop rpl::event_stream members.
    public let authOk = PassthroughSubject<Void, Never>()
    public let authErr = PassthroughSubject<Void, Never>()
    public let delivered = PassthroughSubject<RelayMessage, Never>()
    public let relayDisconnected = PassthroughSubject<Void, Never>()

    public private(set) var isConnected = false

    private let url: URL
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    private var token: String?
    private var reconnectDelayMs = 2000
    private let maxReconnectDelayMs = 30_000
    private var reconnectWorkItem: DispatchWorkItem?
    private var intentionalClose = false

    public init(host: String = defaultHost, path: String = defaultPath) {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        self.url = components.url!
        super.init()
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config,
                                  delegate: self,
                                  delegateQueue: nil)
    }

    // MARK: - Public API (mirrors desktop)

    public func connect(token: String) {
        self.token = token
        intentionalClose = false
        openSocket()
    }

    public func disconnect() {
        intentionalClose = true
        cancelReconnect()
        token = nil
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Enqueue an already-encrypted blob. Returns the msg_id, or nil if not
    /// authenticated. Mirrors RelayClient::sendBlob.
    @discardableResult
    public func sendBlob(_ encryptedBlob: Data) -> String? {
        guard isConnected, let task = task else { return nil }
        let msgId = UUID().uuidString.lowercased()
        let frame = RelayOutbound.send(msgId: msgId,
                                       blobBase64: encryptedBlob.base64EncodedString())
        task.send(.string(String(decoding: frame.jsonData(), as: UTF8.self))) { [weak self] error in
            if error != nil { self?.handleSocketBroken() }
        }
        return msgId
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        cancelReconnect()
        isConnected = false
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        // Auth is sent from didOpen (URLSessionWebSocketDelegate).
        receiveLoop()
    }

    private func sendAuth() {
        guard let token = token, let task = task else { return }
        task.send(.string(String(decoding: RelayOutbound.auth(token: token).jsonData(), as: UTF8.self))) { [weak self] error in
            if error != nil { self?.handleSocketBroken() }
        }
    }

    private func sendAck(_ msgId: String) {
        guard isConnected, let task = task else { return }
        task.send(.string(String(decoding: RelayOutbound.ack(msgId: msgId).jsonData(), as: UTF8.self)), completionHandler: { _ in })
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(message):
                self.handleIncoming(message)
                self.receiveLoop()
            case .failure:
                self.handleSocketBroken()
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .data(d):
            data = d
        case let .string(s):
            data = Data(s.utf8)
        @unknown default:
            return
        }
        guard let inbound = RelayInbound(jsonData: data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dispatch(inbound)
        }
    }

    private func dispatch(_ inbound: RelayInbound) {
        switch inbound {
        case .authOk:
            isConnected = true
            reconnectDelayMs = 2000
            authOk.send(())
        case .authErr:
            isConnected = false
            authErr.send(())
            task?.cancel(with: .normalClosure, reason: nil)
        case let .deliver(msgId, blobBase64):
            guard let blob = Data(base64Encoded: blobBase64) else { return }
            delivered.send(RelayMessage(id: msgId, blob: blob))
            sendAck(msgId)
        case .queued:
            break
        case .unknown:
            break
        }
    }

    private func handleSocketBroken() {
        let wasConnected = isConnected
        isConnected = false
        task = nil
        if wasConnected {
            DispatchQueue.main.async { [weak self] in self?.relayDisconnected.send(()) }
        }
        guard !intentionalClose, token != nil else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        cancelReconnect()
        let delay = reconnectDelayMs
        reconnectDelayMs = min(reconnectDelayMs * 2, maxReconnectDelayMs)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.token != nil, !self.intentionalClose else { return }
            self.openSocket()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }
}

extension RelayClient: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession,
                           webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        sendAuth()
    }

    public func urlSession(_ session: URLSession,
                           webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        handleSocketBroken()
    }
}
