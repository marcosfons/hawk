# Plan B - Apps, on-device helper, usage per app, storage

After A. Requirements: sections 3 (3.1-3.4) and 6 (not 6.1, which is F).

## Goal

The Apps, Usage and Storage sections: every app with icon and label, the
actions on apps, battery / Wi-Fi / mobile / memory per app with history, and
storage by class, all cheap on the phone.

## Owns

- `android-helper/` (new, repo root): Java sources of the on-device helper,
  `build.sh` (javac + d8 against the SDK's `android.jar`), the checked-in
  `hawk-helper.dex`
- `Sources/HawkKit/Android/Helper/`, `Apps/`, `Usage/`, `DeviceStorage/`
- `Sources/HawkApp/Features/Android/Sections/Apps/`, `Usage/`, `Storage/`
  (replacing A's placeholders)
- Tests for those subjects

Shared touch points (additive only): the `Makefile` line that copies the dex
into `Hawk.app/Contents/Resources`; `PackageIndex` (add label and icon fields);
`AndroidRules` (app action rules).

## Starting point

The prototype from requirements 3.2 (tested on Android 17, Samsung): it already
solves the Samsung `ActivityThread` setup, the shell-bound
`NetworkStatsManager`, and raw icon resources instead of live icons. Its source
is kept as a reference in `docs/android-plans/helper-prototype/Agent.java`
(throwaway code with measurement output); rewrite it cleanly in
`android-helper/`. It was built with:

```sh
J=~/Library/Android/sdk/platforms/android-36/android.jar
javac -source 11 -target 11 -cp $J -d cls Agent.java
~/Library/Android/sdk/build-tools/37.0.0/d8 --min-api 31 --lib $J --output dex cls/hawk/*.class
adb push dex/classes.dex /data/local/tmp/hawk-agent.dex
adb shell CLASSPATH=/data/local/tmp/hawk-agent.dex app_process / hawk.Agent net-depth
```

## Work

1. **Helper runtime** (`HelperRunner`): push once per dex hash
   (`/data/local/tmp/hawk-helper-<hash>.dex`, remove old ones), run with
   `nice -n 10 app_process`, one run per batch of commands, line-based output
   parsed in the background, timeout and kill, fallback when it fails.
   Commands: `icons <px> <packages...>`, `labels`, `net <from> <to>`
   (per UID, transport, fg/bg), later `usage <from> <to>` (screen time,
   `UsageStatsManager`, to try).
2. **Icons and labels**: cache per package + version code in `DeviceStore`;
   fetch only new or updated; first pass in batches of 100, GC every 25, user
   apps first.
3. **App list** (3.1): `DataTable` with icon, label, package, version,
   installer, user/system, enabled, sizes (from `dumpsys diskstats` per-app
   arrays, one call), install and update dates, target SDK. Filters and search.
4. **Actions** (3.3) through `AndroidRules` + `ActionLog`: install (drag APK,
   split bundles), uninstall (user 0 for system apps), disable/enable, pull APK
   (all splits), clear data (confirmation), clear cache (`pm clear --cache-only`
   when `pm help` lists it; root fallback), force stop, open, permissions.
5. **Usage per app** (3.4): one table with period selector. Data from the helper
   (about 100 days); battery from `batterystats --checkin`; memory from
   `dumpsys meminfo`; screen time from usagestats. Daily totals saved to the
   store. Heavy reads only when the page opens and every few minutes while
   shown.
6. **Storage** (6): volumes (`sm list-volumes`, `df`), classes from
   `dumpsys diskstats`, biggest apps, UFS vs eMMC from `/sys/block` names.

## Tests (made-up fixtures)

- Helper output parser (icons, labels, net lines), including truncated output.
- `diskstats` parser including the per-app arrays; `batterystats --checkin`
  records used; `meminfo` summary; `pm help` cache-only detection.
- Usage aggregation: daily totals, merging helper history with stored days,
  shared and removed UIDs.
- `AndroidRules`: protected packages refuse uninstall/disable/clear; rechecked
  at action time.

## Measure

On the phone, with the process's `/proc/self/smaps_rollup` and CPU time: a
normal connection (few or no new icons) costs one helper run under 0.3 s CPU and
~45 MB private memory that is freed at exit. In Hawk: `sample` with Usage open.

## Device checklist

- [ ] First connection: icons fill in batches, user apps first; second
      connection fetches none.
- [ ] Update an app (or install one on a test device): only that icon fetched.
- [ ] Usage shows about three months on first open; numbers match Android's
      Settings for one app within rounding.
- [ ] Clear cache on a test device's test app: logged in `actions.md`.

## Budgets and profiling

Scenarios B adds to `make perf`: `apps` (list open with icons), `usage`
(page open through two refreshes), `helper-first-pass` (phone side: first full
icon pass). Icons are held as 16/32 pt bitmaps only; the app list and usage
tables use `DataTable`. The helper's phone-side numbers (above) go into
`docs/perf-baseline.md` too.
Limits in STANDARDS 1; numbers recorded in `docs/perf-baseline.md`.

## Done when

Merged into `main` and pushed (STANDARDS 5), `make perf` scenarios within
budget. Apps, Usage and Storage sections work on the test device, the helper never
leaves a process running, and the measurements above are met.
