//
//  StealthKeeper.swift
//  HiddenCore
//
//  "Disable online status" toggle. Mirrors the desktop stealth checkbox, which
//  calls MTPaccount_UpdateStatus(true) every 25 s.
//
//  HiddenCore is host-agnostic: it cannot call Telegram's MTProto directly, so
//  the host provides a PresenceController that performs the actual
//  `account.updateStatus(offline: true)` request. StealthKeeper owns the 25 s
//  cadence so the parity-critical timing lives here, not scattered in the host.
//

import Foundation

/// Implemented by the Telegram-iOS host. Should issue
/// `Api.functions.account.updateStatus(offline: .boolTrue)` via
/// `account.network.request(...)`.
public protocol PresenceController: AnyObject {
    func pushOffline()
}

public final class StealthKeeper {

    public private(set) var isEnabled = false

    private weak var presence: PresenceController?
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?

    public init(presence: PresenceController?, interval: TimeInterval = 25) {
        self.presence = presence
        self.interval = interval
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        enabled ? start() : stop()
    }

    private func start() {
        presence?.pushOffline() // immediate, then every `interval`
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.presence?.pushOffline() }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }
}
