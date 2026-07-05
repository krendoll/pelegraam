# Hidden-area feature parity — iOS mapping

The four hidden-area features from the brief, how they exist on desktop today,
and how to build them on iOS with `HiddenCore` + Telegram-iOS.

Legend: ✅ in `HiddenCore` now · 🟡 core hook exists, host work needed · 🔜 planned.

## 1. Multiple hidden chats  🟡

- **Desktop today:** the overlay is single-conversation; the vault (`StateView`)
  already stores a `chats` vector (title + lastMessage) but the UI wires one
  relay/token.
- **Core now:** `Container` persists `[ChatEntry]`; `HiddenSession` drives one
  active relay room via `open(pin:token:)`.
- **To finish:** extend `ChatEntry` with a per-chat `token` (relay room) and
  optional per-chat key, and let `HiddenSession` switch the active room (or hold
  one `RelayClient` per open chat). This is a local-only vault change, so it does
  **not** affect desktop interop of the relay/E2E wire formats. Suggested:
  add fields to `ChatEntry` and bump a vault format version byte in the magic.

## 2. Connect to another hidden owner by token  🟡

- The relay "room" is identified purely by the device token → `room_id` mapping
  on the server (`serverside`: `tokens.json`). Two clients that authenticate with
  tokens mapped to the **same room** are peers.
- **Flow:** user pastes/scans a token → add a `ChatEntry` with that token → open
  a `RelayClient` with it. Both peers must share an E2E key.
- **Key sharing:** today both sides use the dev **PSK** (`E2ECrypto.devPSK`), so
  they already interoperate for testing. For production, replace with X25519
  ECDH (exchange public keys out-of-band, e.g. in the same QR that carries the
  token) and feed the derived key as `HiddenSession(e2eKey:)`. The wire blob
  layout `[iv12][tag16][ct]` stays the same, so desktop stays compatible once it
  gets the same key exchange.
- **Server:** issuing tokens/rooms is the relay's job (see serverside README
  §"Регистрация по invite"). The client just needs the token string.

## 3. Add normal Telegram chats, hidden from the main list  🟡 (host-side)

The desktop is already done here and uses the **archive** trick
(`MTPfolders_EditPeerFolders(folderId=1)`), persisting hidden ids to
`tdata/.hidden_ids`. Match it on iOS:

- **Hide:** `context.engine.peers.updatePeersGroupIdInteractively(peerIds: [peerId], groupId: .archive)`
  — **verified** in `ChatListUI/Sources/ChatContextMenus.swift:380` and
  `ChatListController.swift:1590`. Un-hide = same call with `groupId: .root`.
- **Storage:** keep the hidden `peerId` set in the vault (extend `VaultState`) so
  the list is encrypted behind the PIN — the iOS analogue of `.hidden_ids`.
- **Access inside hidden area:** list those peers in the overlay; opening one
  dismisses the overlay first, then pushes `ChatControllerImpl(context:subject:)`
  for the peer (desktop: double-click navigates after dismiss).
- Hides from the local list only; the account still knows the chats
  server-side — matches "не светятся в общем списке".

## 4. Disable online status toggle  ✅ (core) / 🟡 host apply

Desktop parity: stealth calls `MTPaccount_UpdateStatus(true)` **every 25 s**.

- `HiddenCore` ships `StealthKeeper` (owns the 25 s cadence) + a
  `PresenceController` protocol the host implements. Enable/disable via
  `stealthKeeper.setEnabled(_:)`.
- Host `PresenceController.pushOffline()` issues
  `account.network.request(Api.functions.account.updateStatus(offline: .boolTrue))`
  (TL: `account.updateStatus#6628562c offline:Bool`). Verify the symbol in
  `submodules/TelegramApi`.
- The **relay itself is presence-less by design**, so nothing leaks inside the
  hidden area; this toggle only concerns the normal account.
- Persist the flag in `VaultState` (add `hideOnline: Bool`) — behind the PIN,
  the analogue of desktop's `tdata/.hidden_prefs`.
