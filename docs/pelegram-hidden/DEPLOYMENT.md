# pelegram-iOS — concrete deployment values

Filled in from decisions on 2026-07-01.

## Relay tokens (already provisioned on the VPS)

`/opt/relay/tokens.json` on krendollbot.duckdns.org (91.107.239.1) is already set
up — no change needed. The relay is a strict **2-client** design, so `room1`
holds exactly the two peers:

```json
{
  "3f3da505e5c5e429ec3e412b63e80b8dfc768c5a0cbd5507a09020fcff39e43e": "room1",
  "c39336d956cb353ff0c5db14eeb1c703dfa7a6a9767547eacfc8dfdfabd6598c": "room1"
}
```

- First token = the **desktop** client (`kRelayToken`).
- Second token = this **iPhone** (peer-B slot), baked into
  `HiddenConfig.defaultToken`. Do **not** add a third token to `room1` — with the
  broadcast-to-all-peers relay that would leak messages to a third connection.

## Signing (free Apple ID, Hetzner re-signer)

- Apple ID: **antonashko.volodymr@gmail.com** (use an app-specific password on the
  Hetzner box; enable 2FA). See `hetzner_headless_signer.md`.
- 7-day cert → cron re-sign every ~6 days.
- Main app only (extensions stripped) to fit the free 3-app limit.

## Target device

- iPhone on **iOS 26.5** → deployment target set to iOS 15 (covers 26.5); no
  special constraints. netmuxd / On-Demand VPN behave normally on 26.x.

## E2E

- Staying on the shared **dev PSK** for now (user: "плевать"). Desktop and iPhone
  use the same PSK in `E2ECrypto.devPSK`, so they interoperate. Revisit X25519
  later (must change both clients together).
