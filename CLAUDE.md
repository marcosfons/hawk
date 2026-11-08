# hawk

A menu bar toolkit for an Apple Silicon Mac: system monitor, fan control,
energy, network and processes, storage cleanup, Android devices, security
checks. Swift 6 + SwiftUI, with AppKit
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
make perf SCENARIO=baseline  # CPU, memory, energy, busy threads of a release build (tools/perf.sh list)
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
| `HawkKit` | Everything that measures or decides, no UI: SMC, HID sensors, sampler, processes, energy, network, alerts, fan curve, helper protocol, `Storage/`, `Android/`, `Security/`, logging |
| `HawkApp` | The app, below |
| `hawkd` | Root helper run by launchd: the only process that writes fan speeds; also reads system processes' counters |
| `hawk` | Command-line monitor (`hawk watch`, `log`, `dump`, `set`, `auto`) |

`HawkApp` folders:

| Folder | What lives there |
|---|---|
| `App/` | `HawkApp` (scenes: window + menu bar), `RootView` (window shell, header), `MenuBar` (icon, label, panel), `AlertsPanel` |
| `Core/` | `Feature` (the protocol), `AppModel` (feature list, selection, visibility), `Refresher` (scheduled work), `Diagnostics` |
| `System/` | `Monitor` (shared system data on the main actor), `Engine` (sampling actor), `History` |
| `UI/` | Building blocks every feature uses: `Theme`, `Components` (Card, meters, gauges), `HistoryChart`, `DataTable` |
| `Features/<Name>/` | One folder per tab: the feature class, its model and views |

`Support/` holds Info.plist, the launchd plist and the icon set; `tools/` the
icon generator.

## Adding a feature (a tab)

1. Logic that measures or decides goes in `HawkKit/<Area>/`, with tests.
2. In `HawkApp/Features/<Name>/<Name>Feature.swift`, a class conforming to
   `Feature`: `id` (stable, saved), `title`, `symbol`, `makeView()`.
3. Pick the kind of work it does (a feature can have several):
   - **Shared system data** (processes, network, energy): declare `needs`; read
     it from `Monitor`. The Monitor samples it only while a visible feature
     needs it.
   - **Its own periodic work**: an actor for the slow part, and a
     `Refresher(foreground:background:)` started from `setVisible`. Give it a
     `background` interval only if it must run with the tab closed (Security's
     startup-item watch), and keep that cheap.
   - **Heavy, on demand** (a deep scan): only from a button that says it is
     heavier, with progress (`SecurityFeature.deepScan`).
   - **Must run with no window at all, every second** (fan control, alerts,
     energy totals): that is the Engine's job, not a feature's.
4. Raise alerts with `monitor.post(_:)`, so they share the list and notifications.
5. Live lists use `DataTable` (`Column`s + optional `menu` and `onSelect`);
   cards use `Card`; colours and fonts come from `Theme`.
6. Add the feature to `AppModel.init`'s list. That is the only wiring.

`AndroidFeature` (own periodic work, foreground only) and `SecurityFeature`
(needs + own work with a background watch + an on-demand heavy scan) are the
reference examples.

## Docs

| File | What it is |
|---|---|
| `docs/engineering-guidelines.md` | How code is written here: performance and energy, SwiftUI, macOS design, accessibility, security, testing |
| `docs/android-requirements.md` | What the Android toolkit must do, with findings checked on a real device |
| `docs/android-plans/` | Execution plans for the Android work (foundation first, then parallel plans) and their binding `STANDARDS.md` |

## Window and menu bar

- Hawk runs from launch to Quit. Closing the window frees its views and hides
  the Dock icon; Hawk carries on in the menu bar. The Monitor keeps sampling
  (fan control, alerts, energy) but publishes nothing while neither the window
  nor the menu panel shows it, except `headline` for the menu bar label.
- `AppModel.updateVisibility()` is the single place that decides what is on
  screen and tells features and the Monitor.

## Performance and energy budget (measured, not guessed)

Low CPU, memory and energy use is a requirement, not a nice-to-have. Every
change is measured against these limits before it is committed:

| State | CPU (one core, avg over 60 s) | Memory |
|---|---|---|
| Window visible, normal use (lists, tables, search, charts) | **under 5%** | under ~100 MB |
| Window visible, something deliberately heavy the user started (scrcpy mirror, a deep scan) | may exceed 5% while it runs; back under 5% when it stops | under ~100 MB |
| **Full background** (window closed, menu bar only) | **under 2%, target under 1%** | under ~100 MB |

- Background limits hold **without dropping features**: fan control, alerts,
  energy totals and the Android ANR check keep running. Do less, less often,
  more cheaply; never switch a feature off to meet the number.
- **Energy**: no timer fires and nothing polls while nothing needs it; prefer
  event sources (IOKit notifications, sockets, file events) over polling;
  coalesce work into one wakeup per interval; give timers tolerance; run
  background work at `.utility` or `.background` QoS so macOS can schedule it on
  efficiency cores and keep App Nap possible.
- **Lists, tables and search stay fast at any size**: `DataTable` for anything
  live or long, cells rewritten in place, no SwiftUI `Table`/`List` for live
  data; search and filters debounced (~150 ms) and computed off the main actor,
  incrementally where data streams; never sort or filter in `body`.
- **Measure**: `top -l 60 -s 1 -pid <pid> -stats cpu,mem,power` (CPU, memory,
  energy impact), `footprint <pid>`, `sample <pid> 10` (count busy samples per
  thread), `leaks <pid>` for long runs, and Instruments from the command line
  (`xcrun xctrace record --template 'Time Profiler' --attach Hawk --time-limit
  30s --output build/perf/time.trace`; also the `SwiftUI` and `Allocations`
  templates). Measure both states: window open and window closed. The header
  shows Hawk's own CPU and memory live.

What we learned:

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
- **Measure only what is shown**: processes and network only while a visible
  feature needs them (processes every 15 s in the background, for energy
  totals); temperature sensors every 3 s; battery every 2 s; disk capacity
  every 30 s.
- **A hidden window updates nothing**, a closed one does not exist; samples are
  caught up when something shows again.
- Expensive one-off work (SMC key discovery, battery health) is cached in
  UserDefaults and refreshed after the window is up.
- Caches hold small things: app icons as 16 pt bitmaps (full icons cost
  hundreds of MB).

## Code quality rules

Full guidelines (SwiftUI correctness and performance, macOS design,
accessibility, security, testing): `docs/engineering-guidelines.md`. Every
change follows them; the points below are the ones most often missed.

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
