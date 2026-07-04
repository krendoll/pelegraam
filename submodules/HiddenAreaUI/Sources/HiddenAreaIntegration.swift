//
//  HiddenAreaIntegration.swift
//  ChatListUI  (pelegram)
//
//  Glue between the search-bar PIN gate and the HiddenCore session. Kept in one
//  file so the edit to ChatListSearchContainerNode is a single call. Mirrors the
//  desktop hidden_layer_manager.cpp wiring.
//
//  UNVERIFIED BY BUILD (authored on Windows). The first CI run will surface any
//  toolchain fixes; symbols used here were checked against the fork's sources:
//    - Api.functions.account.updateStatus(offline:) — Api42.swift
//    - Api.Bool.boolTrue — Api1.swift
//

import Foundation
import UIKit
import SwiftUI
import Combine
import HiddenCore
import AccountContext
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit
import Display

// MARK: - Presence (stealth) — desktop parity: account.updateStatus(true) / 25 s

final class TelegramPresenceController: PresenceController {
    private let context: AccountContext
    init(context: AccountContext) { self.context = context }
    func pushOffline() {
        let _ = context.account.network
            .request(Api.functions.account.updateStatus(offline: .boolTrue))
            .startStandalone()
    }
}

// MARK: - Engine ops for "hidden normal chats" (verified against the fork)

enum HiddenChatsEngine {

    /// Resolve `@username`, archive it (desktop parity: folders_EditPeerFolders
    /// folderId=1), and report its int64 id back for persistence in the vault.
    static func hideByUsername(
        _ username: String,
        context: AccountContext,
        onResolved: @escaping (_ peerId: Int64, _ title: String) -> Void
    ) {
        let name = username.hasPrefix("@") ? username : "@" + username
        let _ = (context.engine.peers.resolvePeerByName(name: name, referrer: nil)
            |> deliverOnMainQueue).startStandalone(next: { result in
                guard case let .result(maybePeer) = result, let peer = maybePeer else { return }
                let _ = context.engine.peers.updatePeersGroupIdInteractively(
                    peerIds: [peer.id], groupId: .archive).startStandalone()
                onResolved(peer.id.toInt64(), name)
            })
    }

    /// Un-archive back to the main list (groupId .root).
    static func unhide(peerId: Int64, context: AccountContext) {
        let _ = context.engine.peers.updatePeersGroupIdInteractively(
            peerIds: [EnginePeer.Id(peerId)], groupId: .root).startStandalone()
    }

    /// Resolve the peer from its id and open its real chat.
    static func open(peerId: Int64, context: AccountContext, navigationController: NavigationController?) {
        guard let nc = navigationController else { return }
        let _ = (context.engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: EnginePeer.Id(peerId)))
            |> deliverOnMainQueue).startStandalone(next: { maybePeer in
                guard let peer = maybePeer else { return }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                    navigationController: nc, context: context, chatLocation: .peer(peer)))
            })
    }
}

// MARK: - Entry point used by the search bar

public enum HiddenArea {

    /// Synchronous check — mirrors the desktop tryIntercept guard.
    public static func isPin(_ text: String) -> Bool {
        return PinGate.isPinCandidate(text)
    }

    /// Derive the key off-main (PBKDF2 100k) and, on success, present the overlay.
    /// `present` should modally present the given controller full-screen.
    /// Takes the raw field text so the call site (ChatListUI) needs no HiddenCore
    /// import; the SecurePIN is built and owned here.
    public static func enter(
        pinText: String,
        context: AccountContext,
        navigationController: NavigationController?,
        present: @escaping (UIViewController) -> Void
    ) {
        let pin = SecurePIN(pinText)
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let session = HiddenSession(container: Container(vaultDirectory: dir))

        DispatchQueue.global(qos: .userInitiated).async {
            let opened = session.open(pin: pin, token: HiddenConfig.defaultToken)
            DispatchQueue.main.async {
                guard opened else { return } // wrong PIN: silently nothing
                // The SwiftUI overlay needs iOS 15 APIs; the fork's min OS is 13.
                // Target device is iOS 26.5, so this branch always runs there.
                if #available(iOS 15.0, *) {
                    let vc = HiddenAreaOverlayController(
                        session: session,
                        context: context,
                        navigationController: navigationController)
                    vc.modalPresentationStyle = .fullScreen
                    present(vc)
                } else {
                    session.dismiss()
                }
            }
        }
    }
}

// MARK: - Overlay host controller (owns lifecycle + deactivation triggers)

@available(iOS 15.0, *)
final class HiddenAreaOverlayController: UIViewController {

    private let session: HiddenSession
    private let stealth: StealthKeeper
    private let model: HiddenOverlayModel
    private weak var hostNavigationController: NavigationController?
    private var observers: [NSObjectProtocol] = []

    init(session: HiddenSession, context: AccountContext, navigationController: NavigationController?) {
        self.session = session
        self.stealth = StealthKeeper(presence: TelegramPresenceController(context: context))
        self.model = HiddenOverlayModel(session: session, stealth: stealth, context: context)
        self.hostNavigationController = navigationController
        super.init(nibName: nil, bundle: nil)

        // Open a hidden chat: dismiss the overlay first (desktop parity), then
        // navigate on the underlying chat-list navigation controller.
        self.model.onOpenChat = { [weak self] peerId in
            guard let self = self else { return }
            let nav = self.hostNavigationController
            self.tearDownAndDismiss()
            HiddenChatsEngine.open(peerId: peerId, context: context, navigationController: nav)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let host = UIHostingController(rootView: HiddenOverlayView(
            model: model,
            onClose: { [weak self] in self?.tearDownAndDismiss() }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        // Deactivation triggers (mirror subscribeToDeactivationTriggers):
        // background / resign-active wipe the key and drop the overlay.
        let nc = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.tearDownAndDismiss()
            })
        }
    }

    private func tearDownAndDismiss() {
        stealth.setEnabled(false)
        session.dismiss()            // synchronous key wipe + relay disconnect
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        dismiss(animated: true)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - SwiftUI overlay

@available(iOS 15.0, *)
@MainActor
final class HiddenOverlayModel: ObservableObject {
    @Published var messages: [HiddenMessage] = []
    @Published var statusText = "Connecting…"
    @Published var draft = ""
    @Published var stealthOn = false
    @Published var hiddenChats: [ChatEntry] = []
    @Published var addChatText = ""

    /// Set by the host controller: open a hidden chat by peer id.
    var onOpenChat: ((Int64) -> Void)?

    private let session: HiddenSession
    private let stealth: StealthKeeper
    private let context: AccountContext
    private var cancellables = Set<AnyCancellable>()

    init(session: HiddenSession, stealth: StealthKeeper, context: AccountContext) {
        self.session = session
        self.stealth = stealth
        self.context = context

        // Restore persisted preferences + chat history from the vault (behind the PIN).
        self.stealthOn = session.hideOnline
        self.hiddenChats = session.hiddenChats
        self.messages = session.history
        stealth.setEnabled(session.hideOnline)

        session.messages
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.messages.append($0) }
            .store(in: &cancellables)
        session.status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.statusText = Self.label($0) }
            .store(in: &cancellables)
    }

    func send() {
        let text = draft
        draft = ""
        session.send(text)
    }

    func setStealth(_ on: Bool) {
        stealthOn = on
        stealth.setEnabled(on)
        session.setHideOnline(on)
    }

    /// Add a normal Telegram chat (by @username) to the hidden list: archive it
    /// so it leaves the main list, and persist its id behind the PIN.
    func addHiddenChat() {
        let name = addChatText.trimmingCharacters(in: .whitespacesAndNewlines)
        addChatText = ""
        guard !name.isEmpty else { return }
        HiddenChatsEngine.hideByUsername(name, context: context) { [weak self] peerId, title in
            guard let self = self else { return }
            self.session.addHiddenChat(peerId: peerId, title: title)
            self.hiddenChats = self.session.hiddenChats
        }
    }

    func unhide(_ chat: ChatEntry) {
        HiddenChatsEngine.unhide(peerId: chat.peerId, context: context)
        session.removeHiddenChat(peerId: chat.peerId)
        hiddenChats = session.hiddenChats
    }

    func open(_ chat: ChatEntry) {
        onOpenChat?(chat.peerId)
    }

    private static func label(_ s: HiddenSession.Status) -> String {
        switch s {
        case .idle: return "Offline"
        case .connecting: return "Connecting…"
        case .online: return "Online"
        case .reconnecting: return "Reconnecting…"
        case .authError: return "Auth error"
        }
    }
}

@available(iOS 15.0, *)
struct HiddenOverlayView: View {
    @ObservedObject var model: HiddenOverlayModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hidden").font(.headline)
                    Text(model.statusText).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Offline", isOn: Binding(
                    get: { model.stealthOn },
                    set: { model.setStealth($0) })).labelsHidden()
                Button("Close", action: onClose).padding(.leading, 8)
            }
            .padding(.horizontal, 16).frame(height: 54)
            Divider()
            hiddenChatsSection
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.messages.enumerated()), id: \.offset) { _, m in
                            bubble(m)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(8)
                }
                .onReceive(model.$messages) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message…", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.send)
                Button("Send", action: model.send)
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(8).frame(height: 52)
        }
        .background(Color(.systemBackground))
    }

    // Hidden normal Telegram chats: archived so they leave the main list, listed
    // here behind the PIN. Tap = open the real chat; swipe = un-hide.
    private var hiddenChatsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Hide chat by @username…", text: $model.addChatText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .onSubmit(model.addHiddenChat)
                Button("Hide", action: model.addHiddenChat)
                    .disabled(model.addChatText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if !model.hiddenChats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.hiddenChats, id: \.peerId) { chat in
                            Button(action: { model.open(chat) }) {
                                Text(chat.title)
                                    .font(.caption)
                                    .padding(.vertical, 4).padding(.horizontal, 10)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(Capsule())
                            }
                            .contextMenu {
                                Button(role: .destructive) { model.unhide(chat) } label: {
                                    Label("Un-hide", systemImage: "eye")
                                }
                            }
                        }
                    }.padding(.horizontal, 8)
                }
                .padding(.bottom, 6)
            }
            Divider()
        }
    }

    private func bubble(_ m: HiddenMessage) -> some View {
        HStack {
            if m.outgoing { Spacer(minLength: 40) }
            Text(m.text)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(m.outgoing ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(m.outgoing ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if !m.outgoing { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: m.outgoing ? .trailing : .leading)
    }
}

// All four hidden-area features are now wired here + in HiddenCore:
//  1. relay chat (E2E)          — HiddenSession
//  2. hide a normal chat        — HiddenChatsEngine.hideByUsername -> archive +
//                                 persisted peerId in VaultState (behind the PIN)
//  3. open a hidden chat        — HiddenChatsEngine.open (dismiss then navigate)
//  4. appear-offline toggle     — StealthKeeper + persisted VaultState.hideOnline
// Follow-up (nice-to-have): add-by-picker/context-menu instead of @username only;
// resolve stored titles live. See docs/pelegram-hidden/FEATURES.md.
