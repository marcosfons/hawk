# Plan C - Logcat, crashes and ANRs

After A. Requirements: sections 4 (4.1-4.6) and 5 (5, 5.1).

## Goal

A logcat that is a pleasure to use (several apps, buttons and a filter bar that
are one filter, colours, recognised crashes and Flutter errors) and that only
runs when asked; and every ANR caught and alerted in Hawk without logcat.

## Owns

- `Sources/HawkKit/Android/Logcat/`: line parser, `LogClassifier`, filter query
  parser and matcher, ring buffer, tail store
- `Sources/HawkKit/Android/Crashes/`: DropBox listing and entry parsers,
  exit-info parser, ANR watcher policy
- `Sources/HawkApp/Features/Android/Sections/Logcat/`, `Crashes/`
- Tests for those subjects

Shared touch points (additive only): HawkKit alerts, to add an alert kind for
ANRs beside the fan alerts (the current type is `FanAlert`; add a kind, do not
rename it in this plan); `Theme` (log level and app colours); A's background
job registration for the 60 s ANR check.

## Work

1. **Parser**: `logcat -v threadtime -v uid` lines into entries (time, level,
   UID, PID, TID, tag, message); continuation lines; resilient to garbage.
   Decide `-B` binary only if `sample` shows text parsing is too costly.
2. **Ring buffer** (~50k entries per device) and incremental filtering on
   batches; UI updates at most ~4 per second via `DataTable`.
3. **Filter engine**: the query language from 4.2 (`package:`, `package:mine`,
   `tag:`, `-tag:`, `tag=:`, `tag~:`, `level:`, `pid:`, `process:`,
   `message~:`, `is:`, `age:`, free text, AND by space, `|` for OR). Parser
   produces a filter value; chips and the bar both read and write that value.
   Invalid tokens are reported, not fatal.
4. **Follow apps across restarts**: PID to package from `PackageIndex` and
   ActivityManager process start lines.
5. **`LogClassifier`**: recognised kinds and effective level (4.3 table): Java
   crashes, stack traces, ANR lines, native crashes, Flutter error blocks,
   unhandled Dart exceptions, Dart stacks, Flutter print output, Dart VM service
   URL, JSON messages. App frames vs framework frames.
6. **Interface**: chips row (levels, apps with icons and colours, quick filters,
   saved filters), filter bar with autocomplete and token highlighting, history,
   Find (Cmd-F), detail pane, right-click actions, scrollbar markers, colours
   from `Theme`.
7. **When it runs** (4.4): only while the page is open; Keep running toggle
   with a visible chip and menu bar marker; first read takes the existing buffer.
   Stop on page close, window close, device gone.
8. **Tail and recording** (4.5): compressed rolling tail in `DeviceStore`;
   recording to a user file; export filtered lines.
9. **ANR watcher** (5.1): on every connection list DropBox entries since the last
   known (date substring filter, tag filter), import new ones; every 60 s while
   connected (registered with A as background work); for a new ANR, one
   `logcat -d` read around its time stored with the record.
10. **Crashes section** (5): list per device, ANR page (reason, stack, CPU,
    logcat lines before), crash pages, per-app counts, Hawk alert for every ANR
    (Hawk only, nothing on the phone), crash alerts for watched apps, bugreport
    extraction for full traces without root.

## Tests (made-up fixtures, one file per subject)

- Line parser: every level, continuation lines, odd spacing, binary garbage.
- Query parser: each token, combinations, OR, invalid tokens, round trip
  chips -> text -> chips.
- Classifier: one test per kind, including a Flutter error block logged at
  Info that must become an error, and app vs framework frames.
- DropBox listing and full entry parsers (format checked on Android 17 in the
  requirement doc), date filter planning, dedup across reconnects.
- ANR watcher policy: connection import, 60 s check, no duplicate alerts.

## Measure

A deliberately noisy device (or a test app logging in a loop at ~2,000 lines/s)
with the page open: Hawk within budget, UI responsive while scrolling. With the
page closed: no logcat process exists (`ps`).

## Device checklist

- [ ] Open Logcat: earlier buffer shown, then live; close it: `adb` logcat
      process gone.
- [ ] Two apps picked: both shown, coloured; one restarted: still followed.
- [ ] Typing `level:warn -tag:chatty` lights the W chip; clicking E updates the
      bar.
- [ ] A Flutter debug app throwing an exception: shown as an error group.
- [ ] A test app forced into an ANR on a test device (busy main thread): Hawk
      alert within about a minute with the logcat lines before it, logcat page
      never opened.

## Budgets and profiling

Scenarios C adds to `make perf`: `logcat-100` and `logcat-2000` (a test app or
`adb shell` loop logging at that rate), `logcat-closed` (must show no logcat
process on the phone and no parsing thread on the Mac), `anr-watch` (tab
closed: the 60 s check only). Memory must plateau at the ring buffer cap.
Use the Time Profiler trace when parsing or filtering shows up in `sample`.
Limits in STANDARDS 1; numbers recorded in `docs/perf-baseline.md`.

## Done when

Merged into `main` and pushed (STANDARDS 5), `make perf` scenarios within
budget. The checklist passes and logcat never runs unless its page is open or Keep
running is on.
