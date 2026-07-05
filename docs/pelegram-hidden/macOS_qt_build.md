# macOS build of the existing Qt client (secondary / near-free path)

The desktop `hidden/` module is plain C++/Qt/OpenSSL and is already
cross-platform. Building `TBuild/tdesktop` for macOS yields a Mac **desktop** app
with full hidden-area parity and **no code changes** to the hidden module.

This does NOT produce an iPhone/iPad app — for that see the Telegram-iOS path.

## Why it's essentially free

Everything the hidden area uses exists on macOS:

- `QSslSocket`, `QWidget`, `QTextEdit`, rpl, `crl::on_main` — Qt, all platforms.
- OpenSSL `EVP_*`, `RAND_bytes`, `PKCS5_PBKDF2_HMAC` — bundled in the Telegram
  macOS `Libraries`.
- The zeroing shim already has the non-Windows branch:
  `container_stub.cpp` uses `explicit_bzero` on non-`Q_OS_WIN`. `explicit_bzero`
  exists on macOS 10.12+. ✔️ (If an older SDK complains, swap to `memset_s`.)

Verify no `Q_OS_WIN`-only paths remain in the module before building:

```bash
rg -n "Q_OS_WIN|Windows.h|SecureZeroMemory" TBuild/tdesktop/Telegram/SourceFiles/hidden
```

Only `container_stub.cpp`'s `HIDDEN_ZERO` macro is guarded, and it already has a
correct `#else` branch — so the module is macOS-ready as-is.

## Build steps (on a Mac)

Follow the upstream macOS build (see repo `AGENTS.md` → "macOS", and
`docs/building-*` in tdesktop). In outline:

1. Install Xcode + command line tools.
2. Prepare the `Libraries` tree next to the repo as the official macOS build
   instructions describe (Qt 6.8, OpenSSL, etc.).
3. `export QT=6.8`
4. Configure and build the `Telegram` target (Debug is enough for testing;
   Release is heavy — the repo guidance says don't build Release for testing).

The hidden module is listed in `Telegram/CMakeLists.txt` (lines ~820–829) and
will be compiled into the app automatically.

## Distribution

- **Local/dev:** ad-hoc signing or a free personal team is enough to run it.
- **Outside the App Store:** sign with a Developer ID + notarize
  (`codesign` + `notarytool`). Needs a paid Apple Developer account.
- **Mac App Store:** possible but heavier (sandbox entitlements); not required.

## Interop with iOS / desktop

A macOS-Qt hidden client, an iOS `HiddenCore` client, and a Windows/Linux desktop
client all speak the **same relay protocol and E2E blob format**, so any two of
them mapped to the same relay room can message each other.
