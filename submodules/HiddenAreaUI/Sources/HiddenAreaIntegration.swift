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
import SwiftSignalKit

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
                    let vc = HiddenAreaOverlayController(session: session, context: context)
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
    private var observers: [NSObjectProtocol] = []

    init(session: HiddenSession, context: AccountContext) {
        self.session = session
        self.stealth = StealthKeeper(presence: TelegramPresenceController(context: context))
        self.model = HiddenOverlayModel(session: session, stealth: stealth)
        super.init(nibName: nil, bundle: nil)
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
    @Published var stealthOn = false {
        didSet { stealth.setEnabled(stealthOn) }
    }

    private let session: HiddenSession
    private let stealth: StealthKeeper
    private var cancellables = Set<AnyCancellable>()

    init(session: HiddenSession, stealth: StealthKeeper) {
        self.session = session
        self.stealth = stealth
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
                Toggle("Offline", isOn: $model.stealthOn).labelsHidden()
                Button("Close", action: onClose).padding(.leading, 8)
            }
            .padding(.horizontal, 16).frame(height: 54)
            Divider()
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

// TODO (needs peer picker + navigation, deferred to keep the first build green):
//  - Hide a normal chat from the list:
//      context.engine.peers.updatePeersGroupIdInteractively(peerIds: [peerId], groupId: .archive)
//    Persist the hidden peerId set in VaultState (behind the PIN).
//  - Open a hidden chat from the overlay: dismiss first, then push
//      ChatControllerImpl(context:subject:.peer(peerId)).
//  See docs/pelegram-hidden/FEATURES.md.
