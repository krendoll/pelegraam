# Integrating HiddenCore into the Telegram-iOS fork

Hook points below were **verified against upstream Telegram-iOS master** (cloned
2026-07-01). Line numbers drift between commits — grep the symbol, don't trust
the number. Telegram-iOS is a monorepo; `submodules/*` are plain folders.

Target = iOS only (your decision). This mirrors the now-complete desktop
implementation feature-for-feature.

## 0. Add HiddenCore to the fork

Copy `HiddenCore/Sources/HiddenCore/` into
`submodules/HiddenCore/Sources/HiddenCore/`, add a `BUILD` file modeled on a leaf
module (e.g. `submodules/Postbox/BUILD`), deps = only system frameworks
(`Foundation`, `CryptoKit`, `CommonCrypto`, `Combine`, `Security`). Add
`"//submodules/HiddenCore"` to the `deps` of `submodules/ChatListUI/BUILD` and the
app target `Telegram/BUILD`.

## 1. PIN gate — VERIFIED hook

`submodules/ChatListUI/Sources/ChatListSearchContainerNode.swift`, method:

```swift
override public func searchTextUpdated(text: String) {   // ~line 708
    let searchQuery: String? = !text.isEmpty ? text : nil
    ...
    self.searchQuery.set(.single(searchQuery))
    ...
}
```

Insert the intercept at the very top, before `searchQuery.set` — the exact
analogue of the desktop `dialogs_widget.cpp::submit()` guard:

```swift
import HiddenCore

override public func searchTextUpdated(text: String) {
    if PinGate.isPinCandidate(text) {
        self.hiddenAreaRequested?(SecurePIN(text)) // host closure -> step 2
        self.clearSearch()                          // clear field synchronously
        return                                      // never reaches search
    }
    let searchQuery: String? = !text.isEmpty ? text : nil
    ...
}
```

Note: `searchTextUpdated` fires on every keystroke, so the 4-digit gate naturally
triggers on the 4th digit. Expose `hiddenAreaRequested` up to `ChatListController`
(which owns navigation) to present the overlay.

## 2. Present the overlay  (mirrors LayerManager::mount + OverlayWidget)

`ChatListController` owns one `HiddenSession`. A ready SwiftUI overlay is in
`Integration/ExampleUI/HiddenOverlayView.swift` (wrap in `UIHostingController`).

```swift
let config = HiddenConfig(relayToken: /* this iPhone's token */)
let session = HiddenSession(container: Container(vaultDirectory: vaultDir()))

func presentHiddenArea(pin: SecurePIN) {
    DispatchQueue.global(qos: .userInitiated).async {   // PBKDF2 100k is slow
        let ok = session.open(pin: pin, token: config.relayToken)
        DispatchQueue.main.async {
            guard ok else { return }                    // wrong PIN: do nothing
            let vc = UIHostingController(rootView: HiddenOverlayView(
                model: HiddenOverlayModel(session: session),
                onClose: { [weak self] in self?.dismiss(animated: true) }))
            vc.modalPresentationStyle = .fullScreen
            self.present(vc, animated: true)
        }
    }
}

func vaultDir() -> URL {
    // App's OWN container — do NOT use an app group (free provisioning can't).
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
}
```

## 3. Deactivation triggers  (mirrors subscribeToDeactivationTriggers)

`session.dismiss()` synchronously wipes the key + disconnects. Call it on all of:

| Desktop trigger | iOS |
|---|---|
| app not active | `UIApplication.willResignActiveNotification` |
| minimized | `didEnterBackgroundNotification` |
| passcode lock | Telegram-iOS lock signal (`rg -n "presentationPasscode\|LockController" submodules/TelegramUI/Sources`) |
| Esc / close | overlay Close button |

Also dismiss when the search itself is deactivated (`deactivateSearch(animated:)`
in `ChatListController.swift`).

## 4. Feature parity — VERIFIED engine APIs

The desktop is now fully implemented; match it:

| Feature | Desktop | iOS engine call |
|---|---|---|
| Hide a normal chat from the list | `MTPfolders_EditPeerFolders(folderId=1)` (archive) | `context.engine.peers.updatePeersGroupIdInteractively(peerIds: [peerId], groupId: .archive)` — **verified** in `ChatListUI/Sources/ChatContextMenus.swift:380` & `ChatListController.swift:1590` |
| Un-hide | folderId=0 | same call with `groupId: .root` |
| Stealth / appear offline | `MTPaccount_UpdateStatus(true)` every 25 s | host implements `PresenceController.pushOffline()` → `account.network.request(Api.functions.account.updateStatus(offline: .boolTrue))`; cadence driven by `StealthKeeper` (25 s). Verify `Api.functions.account.updateStatus` in `submodules/TelegramApi`. |
| Open a hidden chat from the overlay | double-click → navigate, overlay dismisses first | `session.dismiss()` then push `ChatControllerImpl(context:subject:.peer(peerId))` |
| Relay chat via token | `+` → token dialog | `HiddenConfig.relayToken` / add a token entry (see FEATURES.md) |

Persist the hidden `peerId` set + stealth flag in the vault (`VaultState`), so they
sit behind the PIN — the iOS equivalent of desktop's `tdata/.hidden_ids` /
`.hidden_prefs`, but encrypted.
