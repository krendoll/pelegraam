# pelegram-Apple — status

_Updated 2026-07-01. Author env: Windows, no Apple toolchain — all Apple code is
source to be built on a macOS CI runner._

## Locked decisions (from your answers)

- **Target: iOS only.** macOS-Qt dropped (you only need the phone). `Integration/
  macOS_qt_build.md` kept as a note, not active work.
- **No Mac** → build the IPA on **GitHub Actions macOS runners**
  (`ci/ios-build.yml`, goes into the fork).
- **No paid Apple account** → install via **free signing**, with a **Hetzner
  headless AltServer-Linux re-signer** over **WireGuard** (phone as On-Demand VPN
  peer), cron re-sign ~every 6 days after a one-time USB pairing
  (`Integration/hetzner_headless_signer.md`).
- **Free-provisioning 3-app limit** → build **main app only** (strip extensions in
  CI). No push, no app groups → vault in the app's own container; delivery while
  app runs (relay buffers offline, drains on reconnect).
- **You have a fork** of Telegram-iOS; tokens issued **manually**; hidden chats
  hidden **from local lists only**.
- The **desktop is now feature-complete** (stealth via `account.updateStatus(true)`
  /25 s, hide via archive `folders_EditPeerFolders(folderId=1)`, relay token
  dialog, `.hidden_ids`/`.hidden_prefs`). iOS mirrors it 1:1.

## Done

- Analyzed desktop hidden area + relay; cloned upstream Telegram-iOS and
  **verified the real hook points**:
  - PIN gate → `ChatListSearchContainerNode.searchTextUpdated(text:)` (~L708).
  - Hide chat → `context.engine.peers.updatePeersGroupIdInteractively(peerIds:groupId:.archive)`.
- `HiddenCore` Swift package, wire-compatible with desktop:
  Protocol, E2ECrypto (CryptoKit), RelayClient (URLSessionWebSocketTask + Combine),
  Container (CommonCrypto PBKDF2 + AES-GCM, byte-identical vault), SecurePIN,
  PinGate, HiddenSession, **HiddenConfig** (relay host/token/25 s), **StealthKeeper**
  + `PresenceController` (offline toggle cadence). XCTest suite.
- Integration docs with verified hooks + SwiftUI overlay reference.
- **CI workflow** for the fork (`ci/ios-build.yml`) producing an unsigned IPA.
- **Hetzner re-signer + WireGuard** runbook.

## Remaining

1. **In the fork (needs the fork URL + a Mac CI run):**
   - Drop in `submodules/HiddenCore` + `BUILD`; add deps to ChatListUI + app.
   - Insert the PIN intercept; expose `hiddenAreaRequested`; present overlay.
   - Wire deactivation triggers; wire archive-hide, stealth, open-hidden-chat.
   - Strip app extensions (main-app-only) for free signing.
2. **CI:** confirm the exact `build-system/Make.py` invocation for your fork; get
   a green unsigned-IPA build.
3. **Signer:** stand up the Hetzner box (usbmuxd/netmuxd, anisette, AltServer,
   WireGuard); one-time USB pairing; cron.
4. **Feature completion in `HiddenCore`:** per-chat token in `ChatEntry` +
   room switching; add `hiddenPeerIds` + `hideOnline` to `VaultState`.
5. **Production crypto:** replace dev PSK with X25519 (lockstep with desktop).
6. **On a Mac/CI:** `swift test` the package (not build-verified from Windows).

## Blocking items for you

See `QUESTIONS.md` — chiefly: the **fork URL / how I push to it**, and the
**iPhone's relay token/room** (manual `tokens.json` entry sharing the desktop's
room).
