# hawk

A menu bar toolkit for an Apple Silicon Mac: system monitor, fan control,
energy, network and processes, storage cleanup. Swift 6 + SwiftUI, with AppKit
where SwiftUI is too slow or cannot do it. macOS 26+. Built with SwiftPM and a
Makefile (no Xcode project).

## Build, run, check

```sh
make                         # release build + build/Hawk.app (ad-hoc signed, icon included)
make run                     # build and open the app
make check                   # warnings as errors + unit tests; run before every commit
make install                 # ~/Applications/Hawk.app + ~/.local/bin/hawk
make && sudo make install-helper   # root helper (fan control, system process figures)
make log-live                # stream logs, debug timings included
make problems                # warnings and errors kept in ~/Library/Logs/Hawk/hawk.log
make icon                    # redraw Support/AppIcon.iconset from tools/make-icon.swift
```

- Run `make check` once at the end of a change, not after each edit. Pipe
  output through `grep -E 'error|warning'` or `tail`.
- **Zero warnings.** `make check` builds with warnings as errors.
- Signing is ad hoc with a fixed designated requirement (identifier only), so a
  Full Disk Access grant survives rebuilds. Do not add a team or certificate.

## Testing

**No UI tests.** Unit tests (Swift Testing, `Tests/HawkKitTests/`) cover what
runs without the screen: fan curve and control policy, helper protocol, storage
deletion rules, alerts, energy accounting, parsers, formatting. One file per
subject. Anything with rules goes in HawkKit so it can be tested.

To check the interface, build and open the app for the user (`make run`) and
say what to look at. Screenshots are not available here. Never claim an
interface behaviour is verified when it has only been reasoned about.

## Layout

| Target | What it is |
|---|---|
| `HawkKit` | Everything that measures or decides, no UI: SMC, HID sensors, sampler, processes, energy, network, alerts, fan curve, helper protocol, storage (`Storage/`), logging |
| `HawkApp` | The app. `Model/` (Monitor, Engine, StorageModel, History), `Views/`, `Support/` |
| `hawkd` | Root helper run by launchd: the only process that writes fan speeds; also reads system processes' counters |
| `hawk` | Command-line monitor (`hawk watch`, `log`, `dump`, `set`, `auto`) |

`Support/` holds Info.plist, the launchd plist and the icon set; `tools/` the
icon generator.

## Performance budget (measured, not guessed)

Hawk must cost **under 5% of one core** in normal use, window visible, and
stay under ~100 MB. Measure with `sample <pid> 10` and count busy samples per
thread; the header shows Hawk's own CPU and memory live. What we learned:

- **Sampling never runs on the main actor.** `Engine` (an actor) samples and
  decides; the UI receives one finished `Tick` per interval.
- **Nothing animates every update.** Per-second animations re-laid out the
  whole window. Meters scale instead of resizing; the fan icon spins in Core
  Animation.
- **No `.help()` on views that change every second.** SwiftUI then hit-tests
  the whole window after each update.
- **Live lists use `DataTable` (AppKit)**, not SwiftUI `Table`, which rebuilt
  row views every update (5-35% CPU). DataTable rewrites the visible cells in
  place and pauses while scrolling.
- **Charts are `Canvas`**, not Swift Charts, capped at 120 points.
- **Measure only what is shown**: processes and network only while their tab is
  open (processes every 15 s in the background, for energy totals); temperature
  sensors every 3 s; battery every 2 s; disk capacity every 30 s.
- **A hidden window updates nothing**; samples are caught up when it shows.
- Expensive one-off work (SMC key discovery, battery health) is cached in
  UserDefaults and refreshed after the window is up.
- Caches hold small things: app icons as 16 pt bitmaps (full icons cost
  hundreds of MB).

## Code quality rules

- **No dead code.** Remove what stops being called in the same change.
  Comments explain *why*, never history.
- **Swift 6 concurrency.** `HawkApp` defaults to `MainActor`; data crossing to
  `Engine` is `nonisolated` and `Sendable`. HawkKit types are `Sendable` value
  types or classes owned by one actor.
- **State**: `@State` is private; `@Observable` models come through
  `.environment`; bindings only where the child writes; `ForEach` over stable
  ids. Each `View` is an invalidation boundary: extract subviews.
- **Logging**, not `print` (except the CLI's output): `Log.app/.engine/.helper`
  with `.debug/.info/.warning/.error`; warnings and errors also go to
  `~/Library/Logs/Hawk/hawk.log`. Time anything that can be slow with
  `Log.x.timed("what", warnAbove: ms) { }`. Every swallowed failure logs.
- Colours, fonts and sizes come from `Views/Theme.swift`.

## Safety rules

- **The helper is the only writer of fan speeds.** It accepts one admin-group
  client, clamps every speed, and hands the fans back to macOS when the client
  disconnects or goes quiet for 5 s, at 90 °C, on SIGTERM, and at startup.
- **Storage deletes only through `StorageRules`**, re-checked at the moment of
  deleting, and logged to the storage folder's `actions.md` with free space
  before and after. Protected paths are hard-coded and tested.
- **WhatsApp data is never deleted**, not even with confirmation. It is measured
  read-only (`SQLITE_OPEN_READONLY`).
- Without Full Disk Access, macOS silently hides other apps' data; Hawk then
  never starts storage scans on its own (they would record errors).
- Nothing leaves the Mac.

## Interface conventions

- Always dark: near-black body, white text, one cool blue accent. No emojis.
- Plain `-` as a separator, never an em dash or a middle dot.
- Columns over prose: long text goes behind a disclosure or popover.
- Accessibility: icon buttons carry labels; motion respects Reduce Motion.

## Privacy

Never put real personal data (chat names, phone numbers, project or client
names, file paths from this Mac) in code, tests, docs or commit messages; use
made-up examples.

## Git

- Commit messages: a short imperative subject, a blank line, then what changed
  and why. **No `Co-Authored-By` or other attribution trailers.**
- Remote: `git@github.com:marcosfons/hawk.git` (public, SSH). `main` is pushed;
  never rewrite pushed history.
- No CI, on purpose: run `make check` before every commit.
- Never commit `.build/`, `build/` or `.DS_Store` (`.gitignore` covers them).
- Releases: add the version to `CHANGELOG.md`, bump `CFBundleShortVersionString`
  in `Support/Info.plist`, `make check`, commit, tag `vX.Y.Z`, push the tag, then
  `gh release create vX.Y.Z --title "hawk X.Y.Z" --notes-file <that section>`.
