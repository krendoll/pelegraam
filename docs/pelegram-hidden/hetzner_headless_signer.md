# Headless re-signer on Hetzner (free Apple ID) + WireGuard delivery

Your chosen distribution pipeline, written up as concrete steps. Goal: a Linux
box (Hetzner) that, with **no Mac and only a free Apple ID**, re-signs the
unsigned IPA from CI and (re)installs it onto your iPhone over WireGuard every
~6 days before the 7-day free cert expires.

```
GitHub Actions (macOS) --unsigned IPA--> Hetzner box
   Hetzner box: AltServer-Linux + anisette + usbmuxd(-over-network)
   iPhone: WireGuard peer, On-Demand VPN always-on
   cron (every 6 days): AltServer re-signs + reinstalls to phone's WG IP
```

> Constraints that shape this (free provisioning): 7-day cert, **max 3 sideloaded
> apps per device**, 10 App IDs/week, no push (`aps-environment`), no app groups.
> Therefore: build **main app only** (extensions stripped in CI), store the vault
> in the app's own container, and expect messages only while the app is running
> (the relay buffers offline with 7-day TTL and drains on reconnect — fine).

## Components

- **usbmuxd** — talks the lockdown protocol to the iPhone. Normally USB; we make
  it reachable over the network so the phone can be signed over WireGuard.
- **AltServer-Linux** — performs the Apple-ID sign + install (the AltStore server,
  headless build). https://github.com/NyaMisty/AltServer-Linux
- **anisette server** — provides Apple's "anisette" auth data AltServer needs to
  log in with your Apple ID. Self-host, e.g. `Provision`/`anisette-v3-server`.
- **WireGuard** — puts the phone and the box on one private network so usbmuxd can
  reach the phone by IP after the initial USB pairing.

## One-time setup

### 1. Box packages
```bash
apt update && apt install -y usbmuxd libimobiledevice-utils wireguard unzip
# AltServer-Linux + anisette are downloaded binaries / docker; see their repos.
```

### 2. Anisette
Run an anisette provider (docker is easiest):
```bash
docker run -d --restart=always --name anisette -p 6969:6969 \
  dadoum/anisette-v3-server
```
Point AltServer at `http://127.0.0.1:6969` via `ALTSERVER_ANISETTE_SERVER`.

### 3. Initial USB pairing (the ONE physical step)
You must pair the phone to the box once over USB (borrow any USB cable + the box's
USB, or do the pairing from your Windows PC with iTunes/`idevicepair` and copy the
pairing record). Copy the pairing record so usbmuxd trusts the device:
```bash
idevicepair pair                 # accept "Trust" on the phone
ls /var/lib/lockdown/*.plist     # the pairing record — back this up
```
After this, the phone can be reached over the network (WireGuard) without USB.

### 4. WireGuard
Box `wg0` (server) + phone (peer). Give the phone a static WG IP, e.g.
`10.7.0.2`. On the phone install the WireGuard profile and enable **On-Demand**
(always-on) so the tunnel is up whenever needed for re-signing.

Expose usbmuxd over the tunnel so AltServer can reach the phone by its WG IP.
`usbmuxd` is a unix socket locally; bridge it to the network with
`socat`/`inetd` on the box bound to `10.7.0.1`, and use
`usbmuxd`'s network device support (or `netmuxd`) so `10.7.0.2` shows as a
device. (netmuxd: https://github.com/jkcoxson/netmuxd — pairs with the record
from step 3 and registers the phone as a network device to usbmuxd.)

### 5. First sign + install
```bash
export ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969
AltServer -u <phone-udid> -a <apple-id> -p <app-specific-or-account-password> \
  /opt/pelegram/incoming/pelegram-unsigned.ipa
```
Approve on first run: Settings → General → VPN & Device Management → trust your
developer (Apple-ID) certificate.

## Recurring re-sign (cron, every 6 days)

Free certs die at 7 days; re-sign at 6 to stay ahead.

`/opt/pelegram/resign.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
export ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969
UDID=$(cat /opt/pelegram/udid)
IPA=/opt/pelegram/incoming/pelegram-unsigned.ipa
# WireGuard On-Demand should bring the tunnel up; ensure the device is visible:
idevice_id -l | grep -q "$UDID" || { echo "phone not reachable over WG"; exit 1; }
AltServer -u "$UDID" -a "$APPLE_ID" -p "$APPLE_PW" "$IPA"
```
```cron
# every 6 days at 04:00
0 4 */6 * *  APPLE_ID=you@icloud.com APPLE_PW=xxxx /opt/pelegram/resign.sh >> /var/log/pelegram-resign.log 2>&1
```

## Failure modes to watch

- **Cert expired before re-sign** → app won't launch; re-run `resign.sh`. Consider
  a 5-day cadence for safety margin.
- **Anisette / Apple-ID 2FA** → use an app-specific password; keep the anisette
  server healthy (it occasionally needs its provisioning refreshed).
- **Phone not reachable** → On-Demand VPN not up, or netmuxd lost the pairing;
  re-register the device / re-pair.
- **>3 apps** → free limit; keep only pelegram + at most 2 others sideloaded.
- **App IDs exhausted (10/week)** → re-signing the SAME bundle id does not consume
  new App IDs; avoid changing the bundle id.

## Security note

The re-signer holds your Apple-ID credentials and the phone's pairing record —
treat the Hetzner box as sensitive. It never sees the hidden-area content (that's
E2E behind the PIN and lives only on the phone), only the app binary.
