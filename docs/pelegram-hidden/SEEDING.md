# Seeding this repo with Telegram-iOS

`krendoll/pelegraam` started empty. This `hidden-area` branch carries **only the
pelegram additions** (the `submodules/HiddenCore` package, CI, and docs) at the
exact paths they occupy in a Telegram-iOS tree. To get a buildable app you must
combine it with the upstream Telegram-iOS source.

## Recommended: fork on GitHub, then overlay

1. On GitHub, fork `TelegramMessenger/Telegram-iOS` — or, since `pelegraam`
   already exists, add upstream and pull its history:

   ```bash
   git clone https://github.com/krendoll/pelegraam.git
   cd pelegraam
   git remote add upstream https://github.com/TelegramMessenger/Telegram-iOS.git
   git fetch upstream --depth 1
   git checkout -b master upstream/master     # seed master with Telegram-iOS
   git push -u origin master
   ```

2. Overlay the pelegram additions from this branch (they live at
   `submodules/HiddenCore/`, `.github/workflows/ios-build.yml`, `docs/…`, all new
   paths — no conflicts with upstream):

   ```bash
   git checkout master
   git checkout hidden-area -- submodules/HiddenCore .github/workflows/ios-build.yml docs
   git commit -m "Add pelegram HiddenCore + CI"
   ```

3. Then do the small in-tree edits that can't be pure adds (they touch upstream
   files): follow `docs/pelegram-hidden/TelegramIOS_integration.md`:
   - add `"//submodules/HiddenCore"` to `submodules/ChatListUI/BUILD` and
     `Telegram/BUILD` deps,
   - insert the PIN intercept in
     `submodules/ChatListUI/Sources/ChatListSearchContainerNode.swift`
     (`searchTextUpdated`),
   - present the overlay from `ChatListController`,
   - wire archive-hide / stealth / open-hidden-chat.

## Build & install

- CI: `.github/workflows/ios-build.yml` builds an unsigned IPA on a macOS runner.
- Install: `docs/pelegram-hidden/hetzner_headless_signer.md` (free-signing
  re-signer over WireGuard).

## Develop HiddenCore standalone (no Telegram-iOS needed)

`submodules/HiddenCore` is also a valid Swift Package. On any Mac:

```bash
cd submodules/HiddenCore
swift test
```

That exercises all the security-critical logic (crypto, vault, protocol, PIN
gate) without the giant app build.
