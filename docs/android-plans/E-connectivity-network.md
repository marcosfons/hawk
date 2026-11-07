# Plan E - Connectivity, network, system details

After A. Requirements: 1.5 (connection doctor), 1.6 (Wi-Fi debugging), 1.7
(connection speed), 1.8 (root detection), 2.2 (MDM), 2.4 (live), 7 except the
request capture proxy in 7.4 (that is F).

## Goal

Make "why can't I connect" and "why does this phone's network behave like this"
answerable from one place, and add the system and network pages.

## Owns

- `Sources/HawkKit/Android/Connectivity/`: USB device inspection (IOKit),
  doctor rules, mDNS / pairing, QR payload, throughput test, root detection
- `Sources/HawkKit/Android/Network/`: connectivity, VPN, DNS, proxy, routes,
  sockets (`/proc/net/*`), netstats device totals, tunnels, certificates,
  Wi-Fi sharing
- `Sources/HawkKit/Android/System/`: MDM (`device_policy`), live stats readers
- `Sources/HawkApp/Features/Android/Sections/Doctor/`, `Network/`, `Live/`
  and the Overview MDM card (A's Overview gets one additive card slot)
- Tests for those subjects

## Work

1. **Connection doctor** (1.5): list USB devices from IOKit (vendor, product,
   interfaces, link speed); match against adb's view; diagnosis table from the
   requirements (charge-only cable, no adb interface, MTP without debugging,
   unauthorized, offline, two adb versions from A's locator). Pure rules,
   tested.
2. **Wi-Fi debugging** (1.6): pairing by QR (`WIFI:T:ADB;S:<name>;P:<code>;;`,
   then `adb pair` to the mDNS service that appears) and by code; `adb tcpip`
   path for older Android; known devices reconnect via A's registry.
3. **Connection speed** (1.7): USB link speed from IOKit; Wi-Fi link from
   `dumpsys wifi`; on-demand push/pull throughput test with a temporary file,
   always deleted.
4. **Root** (1.8): detection (`su -c id`, `adb root` builds); chip; a single
   `RootSession` wrapper that asks the user first and still goes through
   `AndroidRules`.
5. **MDM** (2.2): device owner, profile owners, users, policies, admins;
   Samsung Secure Folder labelled as such (seen on the test device).
6. **Live** (2.4): CPU per core and frequency, RAM, swap/zram, processes,
   network rates, thermal, in one `shellBatch` every 2-3 s while shown.
7. **Network** (7.1-7.3, 7.5, 7.6): data usage device totals and hotspot state,
   configuration page (VPN, Private DNS, proxy with `:0` meaning none,
   interfaces, routes, mobile), open connections from `/proc/net/tcp*` with app
   names from `PackageIndex`, adb tunnels (forward / reverse list, saved,
   recreated on reconnect), certificates (system store parsed on the Mac, a
   host's chain checked against it, app signers; user CAs only with root).
8. **Wi-Fi sharing** (7.2): Mac to phone via keychain (macOS prompts) and
   `cmd wifi add-network`; phone SSIDs via `cmd wifi list-networks`; passwords
   from the phone only with root. Hotspot rename: open the settings screen
   without root; root path to try on a rooted device.

## Tests

- IOKit snapshot to diagnosis (made-up USB descriptions).
- QR payload builder; `adb mdns services` parser.
- Parsers: `dumpsys wifi` link section, `device_policy`, `/proc/net/tcp` and
  `tcp6` (hex addresses, states, UIDs), `ip route`, `settings` values including
  `:0`, `dumpsys connectivity` VPN section, netstats device totals,
  `forward --list` / `reverse --list`, certificate parsing.
- Tunnel restore on reconnect (registry events in, commands out).

## Device checklist

- [ ] Charge-only cable or USB in file-transfer mode with debugging off: the
      doctor names the cause.
- [ ] Pair a phone over Wi-Fi by QR, unplug USB: still live.
- [ ] Add an `adb reverse` tunnel, unplug and replug: recreated.
- [ ] Open connections list shows app names; matches what an app is doing.
- [ ] Throughput test leaves nothing on the phone.

## Budgets and profiling

Scenarios E adds to `make perf`: `live` (Live page, one `shellBatch` per 2-3 s,
phone side under 2% of a core), `network` (configuration and connections
open), `doctor` (IOKit reads only while the doctor is shown; USB change events
instead of polling where IOKit offers them).
Limits in STANDARDS 1; numbers recorded in `docs/perf-baseline.md`.

## Done when

Merged into `main` and pushed (STANDARDS 5), `make perf` scenarios within
budget. The checklist passes and every page reads only while shown.
