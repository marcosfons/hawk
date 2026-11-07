# Plan F - Later: security, performance, request capture, storage saver

Starts after B and E are merged. STANDARDS.md applies to every part: each adds
its `make perf` scenarios (F2's sampling only while a capture runs; F3's proxy
must not add latency or CPU when idle; F4's encoding at low priority), commits
per milestone, pushes its branch and merges into `main` the same way. Requirements: 6.1, the request capture in 7.4,
8, 9, 14.3-14.5. Each part can go to a separate agent; they share nothing but
A, B and E's APIs.

## F1 - Security and bloat scans (8)

- Owns `HawkKit/Android/Security/`, `Sections/Security/`.
- Local risk flags from `PackageIndex` + `dumpsys package` (installer,
  accessibility services, device admin, notification listeners, overlay, SMS,
  hidden launcher icon, Play Protect off), certificate signals from E.
- Bloat list (source is an open question) with safety levels; disable or
  uninstall for user 0 only, always reversible, "restore all" from
  `actions.md`; "never" packages are `AndroidRules`' protected list.
- Tests: every flag rule; the restore list built from a made-up `actions.md`.

## F2 - Performance timeline (9)

- Owns `HawkKit/Android/Performance/`, `Sections/Performance/`.
- On demand: `gfxinfo` frame stats, CPU frequency per core, thermal status,
  `meminfo`, PSI pressure, on one time axis in `Canvas` (capped points). Perfetto
  trace capture to a file.
- Tests: parsers and the timeline's alignment and downsampling.

## F3 - Request capture (7.4, level 2)

- Owns `HawkKit/Android/Capture/`, `Sections/Network/Capture*` (coordinate with
  E's Network section: a separate sub-page).
- Proxy on the Mac, `adb reverse`, phone proxy set and **always restored**:
  saved original value (`:0` means none), restore on stop, quit, unplug,
  and on next connect after a crash; banner while set. The restore rule is the
  first thing built, with tests, before any proxying.
- Hosts and bytes first; HTTPS decryption for the user's debug apps only if
  the open question says so. Flutter apps documented as needing an app-side
  proxy.

## F4 - Storage saver (6.1)

- Owns `HawkKit/Android/StorageSaver/`, `Sections/Storage/Saver*` (coordinate
  with B's Storage section: a sub-page).
- Media store query, estimate, re-encode with VideoToolbox / archive / both,
  verify before replacing, WhatsApp media excluded, every step in
  `actions.md` with free space before and after. Rules in `AndroidRules` with
  tests first.

## F5 - Several devices, reports, Play Console (14.3-14.5)

- Run one action on several devices; compare two devices; one-click report zip;
  alerts for connect/disconnect/battery/storage; optional off-by-default
  `gplay` integration (open question: it calls Google's API).
