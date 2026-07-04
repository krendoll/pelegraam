//
//  HiddenAreaIntegration.swift
//  HiddenAreaUI  (pelegram)
//
//  Glue between the search-bar PIN gate and the HiddenCore session, plus the
//  host UIViewController that owns the hidden-area lifecycle. The Telegram-styled
//  SwiftUI screens live in the sibling Hidden*.swift files in this module.
//
//  UNVERIFIED BY BUILD (authored on Windows). Telegram symbols used here were
//  checked against the fork's sources:
//    - Api.functions.account.updateStatus(offline:) — Api*.swift
//    - context.engine.peers.updatePeersGroupIdInteractively(peerIds:groupId:)
//    - context.engine.peers.resolvePeerByName(name:referrer:)
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

// MARK: - Engine ops for "hidden normal chats"
//
// NOTE: this is a PURELY UI hide (spec point 2 invariant): the Telegram data is
// never deleted. Baseline hide = archive (folderId 1) so the chat leaves the
// main list; deeper "no trace" filtering (Archive / global search / shared media
// / notifications) is the open item flagged for review.

enum HiddenChatsEngine {

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

    static func unhide(peerId: Int64, context: AccountContext) {
        let _ = context.engine.peers.updatePeersGroupIdInteractively(
            peerIds: [EnginePeer.Id(peerId)], groupId: .root).startStandalone()
    }

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

    /// Derive the key off-main (PBKDF2 100k) and, on success, present the hidden
    /// area full-screen.
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
            let opened = session.open(pin: pin)
            DispatchQueue.main.async {
                guard opened else { return } // wrong PIN: silently nothing
                if #available(iOS 15.0, *) {
                    let vc = HiddenAreaHostController(
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

// MARK: - Host controller (owns lifecycle + deactivation triggers)

@available(iOS 15.0, *)
final class HiddenAreaHostController: UIViewController {

    private let session: HiddenSession
    private let stealth: StealthKeeper
    private let model: HiddenViewModel
    private weak var hostNavigationController: NavigationController?
    private var observers: [NSObjectProtocol] = []

    init(session: HiddenSession, context: AccountContext, navigationController: NavigationController?) {
        self.session = session
        self.stealth = StealthKeeper(presence: TelegramPresenceController(context: context))
        self.model = HiddenViewModel(session: session, stealth: stealth, context: context)
        self.hostNavigationController = navigationController
        super.init(nibName: nil, bundle: nil)

        // Open a hidden Telegram chat: tear the overlay down first (desktop
        // parity), then navigate on the underlying chat-list nav controller.
        self.model.onOpenTelegramChat = { [weak self] peerId in
            guard let self = self else { return }
            let nav = self.hostNavigationController
            self.tearDownAndDismiss()
            HiddenChatsEngine.open(peerId: peerId, context: context, navigationController: nav)
        }
        self.model.onHideTelegramChat = { [weak self] username, completion in
            guard let self = self else { return }
            HiddenChatsEngine.hideByUsername(username, context: context) { peerId, title in
                completion(peerId, title)
            }
        }
        self.model.onUnhideTelegramChat = { peerId in
            HiddenChatsEngine.unhide(peerId: peerId, context: context)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let host = UIHostingController(rootView: HiddenRootView(
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
