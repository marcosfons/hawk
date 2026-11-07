# Android devices - requirements

Status: draft for discussion. Nothing here is built yet beyond the current
`AndroidFeature` (device list + a few properties, polled every 2 s).

Hawk's rules still apply: under 5% of a core and ~100 MB with the window
visible, nothing measured that is not shown, nothing leaves the Mac, every
destructive action goes through rules that are tested and logged.

Everything is done with the user's own `adb` (platform-tools) over USB or
Wi-Fi. **Rooted and unrooted devices are both supported**: everything works
without root, and root unlocks more where Android allows it only with root
(1.8). Where something needs root or a newer Android version, it says so.

## 1. Devices

### 1.1 Several devices at once

- Every device adb sees, USB, Wi-Fi and emulators, side by side.
- Each has a stable identity, `ro.serialno`, so the same phone over USB and over
  Wi-Fi is one device with two transports. Wireless serials already carry it
  (`adb-<serialno>-<id>._adb-tls-connect._tcp`); for `ip:port` ones Hawk reads
  `ro.serialno` once on connect.
- A user-given nickname per device (saved).
- Watch with one long-lived `adb track-devices -l` connection instead of running
  `adb devices` every 2 s: it costs nothing until something changes.

### 1.2 Devices never disappear

- Every device Hawk has seen stays in the list. When it goes away it is marked
  **Disconnected - last seen 12 min ago** and its pages show the last snapshot
  with a banner; actions that need the device are disabled.
- Opening a known device shows its cached snapshot instantly, then refreshes
  in the background when it is connected.
- Forget a device by hand (context menu); nothing is pruned automatically.
- States shown as they are: `unauthorized` (accept the RSA prompt on the phone),
  `offline`, `recovery`, `sideload`, `bootloader` (via `fastboot devices`, if
  installed).

### 1.3 What is stored

One folder per device under `~/Library/Application Support/Hawk/Android/`,
**capped at 50 MB per device** (a setting). Expected use is far below that. The
device's menu shows how much it uses, with a "Forget" button. When the cap is
reached the oldest saved logcat goes first, then the oldest history; the snapshot,
app list and icons are never evicted.

| Kept | Expected size | Notes |
|---|---|---|
| Snapshot: system, storage by class, battery health, MDM, network config | a few KB | JSON, rewritten on change, not appended |
| App list: package, label, version, installer, flags, sizes | ~50-100 KB | |
| App icons | ~2 KB each, ~600 KB for 300 apps | 32 px PNG, keyed by package + version code, so only new or updated apps are fetched |
| Crash/ANR records | ~1-3 MB, last 500 | Full trace, plus the logcat lines just before it (read once from the phone's buffer, 5.1) |
| Usage per app history | ~1-2 MB a year | Daily battery, Wi-Fi, mobile data, foreground time per app (3.4) |
| Logcat tail | up to ~20 MB | Only what was captured while logcat ran; rolling, compressed (4.5) |
| Connection events | small, last 500 | connected, disconnected, transport changed |
| Device history | small | Battery health and free storage, one point per day |

Captures (screenshots, recordings, pulled APKs) are files the user owns in a
folder they pick; they do not count against the cap.

### 1.4 How a device is connected, and reconnections

- Each device shows its transports as chips: **USB**, **Wi-Fi**, both. When both
  are up, Hawk uses USB (faster) and keeps Wi-Fi as a fallback.
- Events in a short per-device timeline: "Unplugged from USB 14:02", "Reconnected
  over Wi-Fi 14:02", "Back on USB 14:30". A transport change is not a disconnect:
  a running logcat and the live views carry on through the other transport.
- Auto-reconnect: when USB goes away and the device was paired for wireless
  debugging, Hawk looks for it on mDNS and connects.
- Seen but not usable is shown too: on USB without debugging (1.5), or advertising
  wireless debugging on the network but not yet paired.
- If logcat was running when the device dropped, it resumes on reconnect with
  `-T <last line's time>`, so the gap is filled from the phone's own buffer when
  it still holds those lines; the log marks the gap and whether it was filled.

### 1.5 Connection doctor

For "I plugged it in and nothing shows". Hawk can see the USB side from the Mac
(IOKit) even when adb sees nothing, so it can tell these apart:

| What the Mac sees | Diagnosis shown |
|---|---|
| No USB device at all | Cable is charge-only or the port is bad; try another cable |
| Android USB device, no adb interface | USB debugging is off, or Developer options are off, with the steps to enable them for that vendor |
| USB device in MTP/PTP/charging mode, no adb | Switch USB mode, or debugging is off |
| adb interface, state `unauthorized` | Accept the prompt on the phone; "Revoke USB debugging authorizations" if it never appears |
| adb interface, state `offline` | Restart the adb server (button) |
| Two adb binaries/servers fighting (Android Studio + Homebrew) | Which ones, which version each, which is running |

Also: USB link speed of the port (USB 2 480 Mb/s vs USB 3 5/10 Gb/s) from IOKit,
and a button to restart the adb server.

Note: if adb works at all, USB debugging is on by definition. "Developer mode
disabled" can only be diagnosed from the Mac side, as above.

### 1.6 Wi-Fi debugging

- Pair Android 11+ devices by **QR code** shown in Hawk (Wireless debugging - Pair
  with QR code), or by pairing code; found via `adb mdns services`.
- Older devices: `adb tcpip 5555` while on USB, then connect by IP.
- Reconnect known Wi-Fi devices automatically when they appear on mDNS.
- Show the Wi-Fi link: SSID, band, RSSI, link speed (`dumpsys wifi`).

### 1.7 Connection speed

- USB: negotiated link speed (IOKit).
- Wi-Fi: link speed and signal from the phone.
- Real adb throughput: an on-demand test that pushes and pulls a temporary file
  and reports MB/s, then deletes it.

### 1.8 Rooted and unrooted

- Root is detected per device (`su` present and answering: Magisk, KernelSU,
  or `adb root` on userdebug builds and emulators) and shown as a chip.
- Hawk never requires root and never asks for it on its own: the first root
  action asks the user in Hawk, then the phone's root manager prompts too.
- What root adds, each marked "root" in the interface and disabled without it:
  - Full ANR traces (`/data/anr`) and tombstones (5).
  - Saved Wi-Fi passwords from the phone (7.2).
  - User-installed CA certificates (7.6).
  - Full packet capture with `tcpdump` when present (7.4).
  - Per-app cache clear on Android versions before 14 (3.3).
  - Reading any app's data folder (sizes, databases) and backing it up.
- Root commands go through the same `AndroidRules` as everything else, so a
  protected package or path stays protected with root.

## 2. Device overview (the first page of a device)

### 2.1 Right now

- Foreground app and activity (`dumpsys activity activities` - resumed activity),
  with one click to its logcat, its app page, or force stop.
- Battery: level, charging state and source, temperature, health, current.
- Screen on/off, locked, Do Not Disturb.

### 2.2 Management (MDM)

From `dumpsys device_policy` and `pm list users`:

- Device owner and profile owner packages, the managing organisation's name
  when set. Vendor containers are labelled as such, not as MDM: on Samsung,
  Secure Folder (Knox) appears as a profile owner of its own user (checked).
- Work profile present, users on the device.
- Active policies that explain odd behaviour: camera disabled, USB file transfer
  blocked, debugging restrictions, app install restrictions, password policy.
- Device admins enabled (`dumpsys device_policy` admin list).

### 2.3 System, in full

- Model, manufacturer, SoC (`ro.soc.model`), Android version, SDK, build,
  security patch, kernel, bootloader locked or not, verified boot state,
  SELinux mode, encryption, root indicators.
- RAM, swap and zram ("virtual RAM" such as RAM Plus is swap: `/proc/swaps`),
  display, ABI list.
- Full `getprop` behind a disclosure, searchable.

### 2.4 Live (while shown)

- CPU per core with frequency, RAM and swap use, processes (`top`), network
  rates (`/proc/net/dev`), thermal status (`dumpsys thermalservice`).
- Rate: every 2-3 s, one `adb shell` call per tick with everything batched in
  one script, never one process per value.

## 3. Apps

### 3.1 List

- All packages: name, label, version, installer (Play, sideloaded, preloaded),
  user/system, enabled/disabled, size (app, data, cache), first install and last
  update, target SDK.
- Filter: user / system / disabled / sideloaded; search by package or label.
- App labels and icons (3.2).

### 3.2 On-device helper (icons, labels, long history)

Some answers have no shell command: an app's icon and label, and per-app data
usage older than 24 hours. Pulling every APK (often 50-200 MB each) for icons
is far too slow, and adaptive icons are XML layers, not files.

So Hawk has a small **helper run on the phone like a script**, exactly how
scrcpy runs its own server. It is **not an app**: a ~10 KB `.dex` file pushed to
`/data/local/tmp` and run with `app_process` as the shell user. It never shows
in the launcher or the app list, nothing is installed, no permission prompt,
and it exits when its work is done.

**Prototype tested** on the Samsung test device (Android 17, not rooted), see
the measurements below. What it took:

- The same setup scrcpy's server does, or Samsung's framework crashes: a fake
  bound application and a configuration controller on the process's
  `ActivityThread`, then a context that reports the shell package.
- `NetworkStatsManager` built for the shell package by hand (the system's own
  instance belongs to the `android` package and is refused).
- Icons from the raw icon resource, not `loadIcon`: Samsung's "live" icons (the
  calendar draws the date) need fonts this bare process never loads, and
  crashed it.

**What it can do** (tested):

| Command | Result |
|---|---|
| Per-app data history | **About 100 days**, per UID, Wi-Fi and mobile, foreground/background (`NetworkStatsManager.querySummary` as the shell user, which holds `PACKAGE_USAGE_STATS`). Versus 24 hours from `dumpsys` |
| Labels and icons | All 645 packages; 427 have an icon. 32 px PNG, ~1.5 KB each |

**What it costs** (measured with the process's own `/proc/self/smaps_rollup`
and CPU time):

| Run | Phone CPU | Time | Memory |
|---|---|---|---|
| Start only (the Java runtime, nothing else) | 0.19 s | ~1 s with adb | 30 MB private |
| Start + app context, no work | 0.22 s | 1.1 s | 38 MB private |
| 30 days of per-app data (418 rows) | +7 ms | 1.1 s | same |
| 100-day history, 24 queries | +0.3 s | 1.5 s | same |
| Icons for 5 apps (the usual case: new or updated) | +31 ms of work | 1.1 s | 42 MB private |
| All 427 icons, first time, naive | 4.1 s | 7.5 s | 136 MB private, 0.5 GB peak |
| All 427 icons, GC every 25 | 2.0 s | 2.6 s | 43 MB private, 257 MB peak (mostly shared APK pages) |

Starting the runtime is most of the cost of any small job, and the first full
icon pass is the only heavy one.

**Performance rules for the helper:**

1. **Shell first.** Anything a shell command answers (getprop, dumpsys, `/proc`)
   stays a shell command, batched into one script per tick: ~10 ms on the phone.
   The helper is only for what the shell cannot do.
2. **Short-lived and batched.** One run does all pending helper work (new
   icons + data history) and exits. No resident process. If a page ever needs
   helper calls every few seconds, a session mode (requests on stdin, exit after
   30 s idle) can be added, but nothing needs it so far.
3. **Only what changed.** Icons and labels are cached per package + version
   code (1.3); a normal connection fetches none or a few. Data history is
   fetched once in full, then only the days since the last fetch.
4. **First icon pass in batches** of 100, GC every 25, user apps first so the
   list fills quickly, at low priority (`nice`).
5. **Pushed once** per helper version (`hawk-helper-<hash>.dex`), not each run;
   Hawk removes old versions.
6. **Compact output** on stdout, one line per item; Hawk parses it in the
   background actor. A timeout on every run; Hawk kills it if exceeded.
7. Fallback when it fails on a device: package names without icons, 24 h data
   from `dumpsys`; the failure is logged.

Built from a few Java files with `javac` and the SDK's `d8` against
`android.jar`; the `.dex` is checked in and bundled, so `make` does not need the
Android SDK. Next to try with it: screen time per app (`UsageStatsManager`).

### 3.3 Actions

| Action | How | Notes |
|---|---|---|
| Install | `adb install -r` / `install-multiple` | Drag an `.apk` onto the window; split bundles (`.apks`, `.xapk`) too |
| Uninstall | `pm uninstall` | System apps: `pm uninstall --user 0` (reversible with `cmd package install-existing`) |
| Disable / enable | `pm disable-user` / `pm enable` | Reversible, preferred over uninstall for system apps |
| Pull APK | `pm path` then pull every split | Saved to a folder the user picks |
| Clear data | `pm clear` | Confirmation, names what will be lost |
| Clear cache | `pm clear --cache-only` | Present on the test device (Android 17); Hawk detects it from `pm help` rather than by version. Without it: root, or trim all apps' caches (`pm trim-caches`) |
| Force stop | `am force-stop` | |
| Open | `monkey -p pkg 1` / `am start` | |
| Permissions | `dumpsys package` | Granted runtime permissions, with revoke |

All destructive actions go through an `AndroidRules` module (like
`StorageRules`): protected packages hard-coded and tested (the launcher,
settings, system UI, phone, package installer, the device owner app), and every
action logged to an `actions.md` with device, package and result.

### 3.4 Usage per app

One table per device, every column sortable, a period selector (today, 7 days,
30 days, since last full charge, this billing cycle, custom), and a click opens
the app's page with charts:

| Column | Source | Notes |
|---|---|---|
| Battery % and mAh | `dumpsys batterystats` (the `--checkin` format, more stable to parse) | Foreground vs background, screen on vs off |
| Wi-Fi data | `dumpsys netstats detail`, per UID and transport | Received / sent, foreground vs background |
| Mobile data | same | Per SIM when there are two; roaming |
| Hotspot, VPN | same | Tethering shown as its own row |
| Memory | `dumpsys meminfo` (one call lists every process) | PSS and swap now; low-memory kills from exit-info |
| CPU time | `batterystats`; live from `top` | |
| Screen time, launches | `dumpsys usagestats` | |
| GPS time, wakelocks, mobile radio time | `batterystats` | What keeps a phone awake: key for location apps |

- How far back (checked):
  - Data per app: **about 100 days** through the helper (3.2), per UID, Wi-Fi
    and mobile, foreground/background. Without the helper, `dumpsys netstats
    --checkin --full --uid` gives only the last 24 hours.
  - Battery per app: since the last full charge (`batterystats --checkin`:
    `pwi` power per UID, `wl` wakelocks, `cpu`, `nt` network, `fg`, `st`).
- Hawk saves daily per-app totals while connected (1.3), so battery history
  grows beyond "since charge" and data history beyond the phone's 100 days.
- These dumps are heavy (batterystats can be several MB): read when the page
  opens and every few minutes while it is shown, never every few seconds.
- Uninstalled apps and shared system UIDs are grouped and labelled, not hidden.

## 4. Logcat

This is the part that has to be really good.

### 4.1 Core

- Streams `adb logcat -v threadtime -v uid` (or `-B` binary format if parsing
  cost demands it) per device, parsed off the main actor.
- Columns: time, level, app (icon + label, resolved from UID/PID), tag, PID,
  TID, message. Columns can be hidden and reordered; the app column is what
  makes several apps readable at once.
- Buffers selectable: main, system, crash, events, radio.
- Pause/resume, follow tail (stops following when the user scrolls up, resumes at
  the bottom), clear, jump to time.
- A detail pane for the selected entry: the full message, JSON pretty-printed,
  stack traces with the app's own frames highlighted.
- Right-click on a line: only this app, only this tag, hide this tag, only this
  PID, show lines around this one (clears filters, keeps the line in view),
  copy, copy as a filter.

### 4.2 Filters: buttons and a filter bar, one filter

Two ways to filter that are **the same filter**: clicking a button writes into
the filter bar, typing in the bar lights up the buttons. Easy for quick
clicks, precise when typing.

**Buttons (chips) above the list:**

- Level: V D I W E F, minimum level by default, each toggleable.
- Apps: a picker with icons, running apps first, several at once; each picked
  app becomes a chip with its colour. "My apps" = apps marked as mine plus any
  debuggable app.
- Quick ones: Crashes, ANRs, Flutter, Errors only, This session only.
- Saved filters appear as buttons too.

**Filter bar**, the syntax people know from Android Studio, with autocomplete
for keys, installed and running package names, and tags seen so far:

| Typed | Means |
|---|---|
| `package:com.example.app` | That app (follows it across restarts) |
| `package:mine` | My apps |
| `tag:Location` / `-tag:chatty` | Tag contains / exclude |
| `tag=:flutter` | Exact tag |
| `tag~:^TS.*` | Tag by regex |
| `level:warn` | Warning and above |
| `pid:1234`, `process:com.example.app:remote` | Process |
| `message~:timeout\|refused` | Message by regex |
| `is:crash`, `is:anr`, `is:stacktrace`, `is:flutter-error` | Recognised kinds (4.3) |
| `age:5m` | Last five minutes |
| free text | Anywhere in tag or message |

- Terms separated by spaces must all match; `|` between terms means either.
- Tokens are highlighted as typed; an invalid one turns red and is ignored
  instead of emptying the list.
- History of recent filters (arrow up), and **saved filters** with a name, per
  app or global. Export/import as a small text file.
- **Find** (Cmd-F) is separate from filtering: it highlights matches and
  jumps between them without hiding lines.
- Ready-made saved filters, for example:
  - Background geolocation (transistorsoft):
    `tag=:TSLocationManager | tag=:flutter`
  - Flutter app: `package:<app> | tag=:flutter`
  - Crashes only: `is:crash | is:anr`
- Hide noise: a user-maintained list of tags always muted (`-tag:` applied to
  every filter), shown as one "muted: 7" chip that expands.
- **Follows apps across restarts**: a package filter keeps matching when the
  app's PID changes (Hawk watches process start lines), and keeps lines from
  earlier PIDs of the same app.

### 4.3 Colours and recognised lines

- **By level**, from `Theme`, readable on the dark background: Verbose dim
  grey, Debug muted blue, Info normal white, Warning amber, Error red, Fatal red
  with a tinted row. The level letter is a coloured badge; the message is
  coloured only for warnings and above, so normal logs stay calm.
- Each app gets a stable colour (from a small palette in `Theme`) on its app
  column, matching its chip.
- **Recognised kinds**, grouped into one entry that expands, marked in the
  scrollbar so they can be found in a long log, and usable as `is:` filters:

| Kind | Recognised by | Shown as |
|---|---|---|
| Java/Kotlin crash | `FATAL EXCEPTION`, `AndroidRuntime` | Error group: exception line, then frames; the app's own frames bright, framework frames dim |
| Any stack trace | `at pkg.Class.method(File:line)` and `Caused by:` runs | Grouped under the line before it |
| ANR | `ANR in <process>` (ActivityManager) | Error group, link to the ANR's page (5) |
| Native crash | `*** *** ***` and `backtrace:` from `DEBUG` / `crash_dump` | Error group |
| **Flutter error** | `══╡ EXCEPTION CAUGHT BY ... ╞══` blocks; `[ERROR:flutter/...] Unhandled Exception:`; `E/flutter` | Error group even though Flutter logs it at Info: shown as an error and matched by `level:error` |
| Dart stack | `#0  main (package:app/main.dart:12:3)` frames | Grouped; frames from the app's own `package:` bright |
| Flutter output | `I/flutter` from `print` / `debugPrint` | Normal, marked as app output |
| Dart VM service | `The Dart VM service is listening on http://...` | A button: forward the port and open DevTools (14.2) |
| JSON in a message | a message that parses as JSON | Pretty-printed in the detail pane |

- The recognising rules live in HawkKit (`LogClassifier`) with tests on
  made-up log lines, one test per kind; adding a kind is one rule and one test.
- An entry's **effective level** (Flutter errors count as errors) is used for
  colour and for the level filter.

### 4.4 When it runs

**Logcat never runs on its own.** A stream wakes the phone's log reader and
keeps adb and Hawk parsing all the time: it costs battery on both sides.

- It streams only while the Logcat page of that device is open, and stops when
  the page closes, the window closes or the device goes away for good.
- **Keep running** is an explicit toggle per device (for "leave it capturing
  while I reproduce this"), shown as a red chip on the device and in the menu
  bar so it is never forgotten, and turned off when Hawk quits.
- Opening the page does not lose what happened before: the first read takes
  the phone's existing buffer (`logcat -d`, then follow), which usually holds
  the last minutes to hours.
- ANR and crash detection do **not** need logcat (5.1).

### 4.5 Keeping and exporting

- In memory: a ring of the last N lines per device (N sized to stay inside the
  memory budget, about 50k lines).
- **Tail on disk**: what was captured while logcat ran is kept as a rolling,
  compressed tail per device (up to ~20 MB, 1.3), so it is still there after a
  disconnect or a Hawk restart. Not a full history.
- **Record**: when the user starts a recording, the whole stream goes to a file
  they keep, outside the device cap.
- Export the visible (filtered) lines or the whole session as a `.txt`.
- A running stream survives a disconnect; a reconnect fills the gap (1.4).

### 4.6 Performance

Logcat can produce thousands of lines a second. Parse in a background actor,
batch into the UI at most ~4 times a second, use `DataTable`, filter on the
batch, never per line on the main actor. Measured with `sample` against a
deliberately noisy device before calling it done.

## 5. Crashes and ANRs

- One list per device, newest first, persisted: app, type (crash, native crash,
  ANR, system server watchdog), time, first line of the reason.
- Sources: `logcat -b crash` (live), `dumpsys dropbox` (`data_app_crash`,
  `data_app_anr`, `system_app_crash`, `SYSTEM_TOMBSTONE`...: history, survives
  without Hawk running), `dumpsys activity exit-info <pkg>` (Android 11+:
  why each process died, including low memory kills).
- Full stack trace on selection; copy, export.
- Per app: crash/ANR counts over time.
- **ANR alert, in Hawk only**: every ANR, of any app or the system, on any
  device raises a Hawk alert (`monitor.post`: the alert list and macOS
  notifications) naming the device and app. Clicking it opens the ANR's page.
  Nothing is shown on the phone. Crashes alert only for apps the user marks as
  watched.
- **ANR page**: reason ("Input dispatching timed out..."), app, process, time,
  foreground activity, CPU usage before the ANR, the main thread's stack (from
  the dropbox entry on recent Android, to verify per version), the logcat lines
  before it, and battery/memory state when it was detected.
- Full traces of every thread (`/data/anr`) and native tombstones: with root,
  read directly; without root, an on-demand `adb bugreport` (heavy, with
  progress) and Hawk extracts them.

### 5.1 Catching every ANR without logcat

Android records every ANR and crash in its **DropBox** (`dumpsys dropbox`),
whether or not anything was watching, and keeps them for days. So:

- **On every connection** (and reconnection), Hawk lists the DropBox entries
  since the last one it has for that device (`data_app_anr`, `system_app_anr`,
  `data_app_crash`, `system_app_crash`, `data_app_native_crash`,
  `SYSTEM_TOMBSTONE`, watchdog) and imports the new ones. ANRs that happened
  while the phone was unplugged show up when it comes back, marked with their
  real time.
- **While connected**, a cheap check every 60 s, only while Hawk runs (window
  open or not): it lists entry headers, and fetches the full entry only for new
  ones. One short shell call a minute, no stream.
- For a new ANR, Hawk reads once the logcat lines from the phone's buffer
  around its time (`logcat -d -t '<time - 30 s>'`, stopped after the ANR time)
  and stores them with the record. No logcat stream involved.
- `dumpsys activity exit-info` (Android 11+) adds why each process died (ANR is
  one of the reasons). It is large on a busy phone (over 10,000 records on the
  test device), so it is read per package or for the newest records only.

Checked on the test device:

- Listing: `dumpsys dropbox` prints a header, then one line per entry,
  `2026-11-05 08:37:18 data_app_crash (text, 1599 bytes)`, plus a preview line.
- Filter by tag: `dumpsys dropbox data_app_anr`. Filter by date: a date
  argument matches as a substring (`dumpsys dropbox 2026-11-06`), so Hawk asks
  for today and yesterday and drops what it already has.
- Full entry: `dumpsys dropbox --print <tag>` gives headers (`Process`, `PID`,
  `UID`, `Package` with version, `Foreground`, `Timestamp` with milliseconds and
  zone, screen and lock state), then the trace. Readable by the shell user.
- **Retention is short on some phones**: DropBox keeps at most 1,000 entries,
  and on the Samsung test device a vendor app filled it so that only about two
  days were left. The check on connection catches only what is still there; the
  60 s check while connected is what makes "every ANR" true.
- Not checked yet: an ANR entry's content (none on the device at the time).

## 6. Storage

- Volumes: internal, SD card, USB OTG (`sm list-volumes`, `df`), each with
  total/used/free.
- **By class, without walking files**: `dumpsys diskstats` already has apps,
  app data, cache, photos, videos, audio, downloads, system, other. One call.
- Biggest apps by app+data+cache (same source).
- Storage type: UFS vs eMMC from the block device names in `/sys/block`
  (`sda`, `sdb`... is UFS; `mmcblk0` is eMMC), plus the SD card if present.
  Checked: on the Samsung test device `ro.boot.bootdevice` is empty and the
  device's vendor/model files are not readable, so the names are the signal.
- `dumpsys diskstats` also carries per-app arrays (`Package Names`,
  `App Sizes`, `App Data Sizes`, `Cache Sizes`), so the app list gets its sizes
  from the same single call (checked).

### 6.1 Storage saver (later)

High-resolution video is usually most of a phone's used space. A guided flow,
per device:

1. **Find**: list videos from the media store (`content query --uri
   content://media/external/video/media`): size, resolution, duration, bitrate,
   date, folder. No file walking. Sort by size, filter by resolution (4K, 1080p),
   age, folder.
2. **Estimate**: for the selection, the size after re-encoding (HEVC at a chosen
   resolution and quality) and the space it frees, before anything is done.
3. **Choose what happens to each original**:
   - Re-encode: pull, encode on the Mac with VideoToolbox (hardware HEVC on Apple
     Silicon, fast and cool), keep date, location and orientation metadata, push
     back, rescan the media store.
   - Archive: copy the original to a folder on the Mac, then free it on the phone.
   - Both: archive the original and put the smaller copy on the phone.
4. **Verify, then replace**: the new file's duration, resolution and playability
   are checked before the original is touched. The original is deleted only
   after that check and only when it is archived or the user confirmed losing it.

Rules, in `AndroidRules` with tests: never touch a file the check did not pass;
WhatsApp media is excluded, matching Hawk's WhatsApp rule; every action goes to
`actions.md` with free space before and after. Same approach could later cover
photos (HEIC) and duplicate media.

## 7. Network

### 7.1 Data usage and hotspot

- Data usage from `dumpsys netstats`: mobile vs Wi-Fi totals per day/month,
  per SIM when there are two, per app (top N), and tethering/hotspot usage.
- Hotspot: on/off, connected clients (`dumpsys tethering`).
- Hotspot name and password: **root only**. On the test device `cmd wifi`
  offers no softap command to the shell user (Android hides its root-only
  commands from the shell), and `cmd tethering` has no shell commands. Without
  root, Hawk opens the phone's Hotspot settings screen and shows the current
  state; with root, it uses `cmd wifi start-softap` (to try on a rooted device).

### 7.2 Sharing Wi-Fi networks between Mac and phone

- **Mac to phone**: list the Mac's known networks; the password is read from the
  keychain (macOS asks the user per network), then added on the phone with
  `cmd wifi add-network <ssid> open|owe|wpa2|wpa3|wep <pass>` (save) or
  `connect-network` (save and join). Both present for the shell user on the test
  device.
- **Phone to Mac**: without root Android does not give passwords over adb; Hawk
  can list the phone's saved SSIDs (`cmd wifi list-networks`) and the user types
  the password, or shows the phone's own "Share" QR. With root, Hawk reads
  them (1.8).
- Added on the Mac with `networksetup -addpreferredwirelessnetworkatindex`.

### 7.3 Configuration

One page that answers "why does this phone's network behave like this":

- Active network and its capabilities (`dumpsys connectivity`): Wi-Fi or mobile,
  metered, validated, captive portal.
- **VPN**: active VPN and its app, always-on VPN, "block connections without
  VPN" (lockdown), per-app VPN rules when set by MDM.
- Private DNS mode and host (`settings get global private_dns_mode` /
  `private_dns_specifier`), DNS servers in use.
- Proxy: global HTTP proxy, per-network proxy, PAC URL. Note: "no proxy" reads
  back as `:0`, not empty (checked), which the restore rule (7.4) must treat as
  unset.
- Interfaces, addresses and routes (`ip addr`, `ip route`, `ip rule`), so tunnels
  (`tun0`), hotspot and USB tethering interfaces show up.
- Mobile: carrier, SIMs, APN, network type (LTE/5G), signal.

### 7.4 Connections and requests

Two levels, very different in cost and reach:

1. **Open connections (no setup)**: every TCP/UDP socket with its app (from `/proc/net/tcp*`, `udp*`: readable by the shell user, with a UID
   column, checked on Android 17), remote address and port, state. Refreshed
   while shown. Host names come from the request capture below when it runs;
   reverse DNS from the Mac would send queries out, so it is off by default.
2. **Requests (opt-in capture)**: Hawk runs a proxy on the Mac, makes it
   reachable from the phone with `adb reverse`, and sets the phone's HTTP proxy
   to it.
   - Without decrypting: method and URL for HTTP, host name and bytes for HTTPS.
     Already enough for "which servers does this app talk to and how often".
   - Decrypting HTTPS needs a Hawk CA installed on the phone, and apps only trust
     user CAs when they opt in (debug builds with a network security config).
     Useful for the user's own apps, not for others.
   - **Flutter apps ignore Android's proxy setting**: Dart's HTTP client has to
     be pointed at the proxy in the app's debug build. Documented, not hidden.
   - Safety: if the phone keeps a proxy setting after Hawk stops, it loses
     internet. Hawk saves the original value, restores it on stop, on quit, on
     unplug when it can, and on the next connection if Hawk died; a banner shows
     while the proxy is set. This is a rule in HawkKit with tests, like the fan
     helper's hand-back.

### 7.5 Tunnels

- **adb tunnels**: manage `adb forward` (Mac port to phone port, e.g. reach a
  debug server running on the phone) and `adb reverse` (phone port to Mac port,
  e.g. the phone app calls `localhost:8080` and reaches a dev server on the Mac).
  A list per device with add/remove, saved, and **recreated on reconnect** (adb
  drops them when the device goes away).
- Ready-made: Flutter/Dart VM service, Chrome/WebView DevTools sockets (14).
- **From the internet**: see open questions; it can mean three different things.

### 7.6 Certificates

- **Trusted CAs on the phone**: system store (`/system/etc/security/cacerts`, or
  the Conscrypt APEX on Android 14+), parsed on the Mac: subject, issuer,
  expiry. Both readable by the shell user (checked). User-installed CAs (often
  installed by MDM or by a debugging proxy) are a security signal, but their
  folder is not readable without root (checked: permission denied); without
  root Hawk says it cannot see them rather than "none".
- **A server's certificate**: enter a host, Hawk fetches the chain from the Mac
  and checks it against the phone's trust store: expiry, hostname, chain,
  whether this phone would trust it.
- **App signing certificates**: signer and SHA-256 per app (`dumpsys package`,
  or the pulled APK), flags debug-signed apps and apps whose signer changed
  between versions.

## 8. Security

### 8.1 Malware / risky app scan (local)

Without root and without sending anything off the Mac, a scan means flags
that are worth a look rather than "infected":

- Sideloaded apps (installer is not a store), especially recent ones.
- Apps holding powerful access: accessibility service, device admin,
  notification listener, draw over other apps, install unknown apps, SMS, call
  log, default SMS/dialer, VPN, usage access.
- Apps that hide their launcher icon.
- Play Protect / package verifier off (`settings get global
  package_verifier_enable`), unknown sources allowed.
- APK SHA-256 matched against a local list of known indicators (stalkerware
  and malware lists), if downloading such a list is allowed (open question).

### 8.2 Bloat scan

- Preinstalled packages grouped by vendor/carrier, with a short description
  and a safety level (safe / probably safe / risky / never).
- Actions: disable (preferred) or uninstall for user 0, always reversible, with
  "restore everything Hawk removed" per device from `actions.md`.
- "Never" packages are the `AndroidRules` protected list and cannot be acted on.

## 9. Performance bottlenecks

On demand, for one app or the whole device:

- Frame timing: `dumpsys gfxinfo <pkg>` (janky frames, 50/90/95/99th
  percentiles), reset and measure while the user exercises the app; histogram.
- CPU: per-core frequency over time, time spent near max, per-process CPU.
- Thermal throttling status over time.
- Memory: `dumpsys meminfo <pkg>` (PSS breakdown: Java, native, graphics),
  low-memory kills from exit-info, memory pressure (`/proc/pressure/*`).
- I/O pressure.
- One timeline that lays these on the same time axis, so "jank at 12:03 while
  CPU 7 throttled" is visible. Charts are `Canvas`, as elsewhere in Hawk.
- Heavy capture: a Perfetto trace saved to a file for deeper analysis (on
  demand, with progress).

## 10. Screen and shell

### 10.1 Mirror (scrcpy)

A Screen page per device that starts scrcpy with options picked from controls,
not typed flags. Requires scrcpy installed (Homebrew); options the installed
version lacks are hidden.

- **Start / Stop**, and presets saved per device and globally ("Demo",
  "Low bandwidth Wi-Fi", "Recording"), last used remembered.
- **Window**: borderless, always on top, fullscreen, position and size
  remembered per device, title with the device's nickname.
- **Video**: max size from the device's real resolution (native, 1920, 1280,
  1024, 800), max fps, bitrate, codec (H.264 / H.265 / AV1, from
  `--list-encoders`), which display (`--list-displays`), crop, orientation lock,
  camera as the source with its supported sizes (`--list-camera-sizes`), a
  virtual display to run one app in its own window (`--new-display`).
- **Audio**: on/off, device output or microphone (Android 11+).
- **Control**: view only, keyboard and mouse mode, show touches, stay awake,
  turn the phone's screen off while mirroring, power off on close.
- Several devices mirrored at once.

**Changing options while it is open.** Examined on scrcpy 5.0.1 (the installed
version: its `--help` and the `scrcpy-server` it ships):

- The scrcpy app has **no control channel**: no socket, no stdin commands, no
  config reload. Options are fixed at launch. The only live input is its
  keyboard shortcuts, in its own window.
- **Live through scrcpy's shortcuts**: fullscreen, rotate or flip the picture,
  pause, resize 1:1 or to remove black borders, phone screen off/on, rotate the
  device, FPS counter, reset the video stream, camera torch and zoom. Hawk shows
  these as a cheat sheet. Turning them into Hawk buttons means sending key
  events to scrcpy's window, which needs the Accessibility permission: optional.
- **Not changeable from outside**: always on top and borderless are properties
  of scrcpy's own window; macOS gives no public way for another app to change
  them. Moving and resizing it from Hawk also needs Accessibility.
- **Need a new session**: max size, bitrate, fps, codec, display, crop, audio,
  camera, control mode, virtual display, recording. Even scrcpy's own protocol
  cannot change these live: the server's control messages are input, clipboard,
  screen power, start app, resize a virtual display, camera torch and HID. A new
  stream is required whatever the client.
- The scrcpy app and its server must be the exact same version ("The server
  version (5.0.1) does not match the client").

So, in order:

**Decision: Hawk uses scrcpy itself and relaunches it in place.** Hawk finds
the scrcpy window, stops it, and starts a new one with the new options in the
same spot. With `--no-power-on` the phone's screen is left as it was. A
relaunch during a recording would split the file, so options that need one are
locked while recording.

Tested with scrcpy 5.0.1 and the test device, from a small tool that reads
window frames:

| What | Result |
|---|---|
| Find the window | `CGWindowListCopyWindowInfo`, matched by scrcpy's PID: frame and layer are readable with no permission. The title is not (that needs Screen Recording), so match by PID, not by title |
| Time to a visible window | 1.2 s on the first launch, 0.5-0.6 s on the next ones; a stop followed at once by a start works |
| What `--window-x/-y/-width/-height` mean | The **content** area, not the frame. The frame the system reports is the content plus the title bar above it (about 30 pt) |
| Aspect ratio | scrcpy shrinks the requested size to the video's aspect ratio and centres it in the box, so passing the frame back as-is drifts a few points each relaunch |
| Borderless + always on top | Placed exactly where asked (no title bar); window layer 3 (floating) instead of 0 |
| Reliability | One launch in seven exited before showing a window; the same arguments worked when repeated. Cause not found |

So relaunching in place means:

1. Read the frame by PID; content = frame minus the title bar
   (`NSWindow.frameRect(forContentRect:styleMask:)` gives its height; zero when
   borderless).
2. Pass width and a height computed from the video's aspect ratio (from
   scrcpy's own log line `Texture: 1080x2340`), so nothing drifts.
3. Start the new scrcpy right after the old one exits; if it exits without a
   window within a few seconds, retry once, then show its error output.
4. Keep the last frame per device, so the next normal launch opens there too.

Not pursued, unless the half-second gap turns out to bother: a **native
viewer**. Hawk talks to
   `scrcpy-server` itself, decodes with VideoToolbox and draws in its own
   window. Window options (on top, borderless, size) become instant because
   Hawk owns the window; video options still restart the stream, but the window
   stays and only freezes briefly. Costs: the scrcpy protocol is internal and
   tied to the server version, so Hawk would ship its own pinned server and
   follow protocol changes on updates; plus input, clipboard, audio and HID to
   reimplement. Mirroring is an explicit heavy action, outside the 5% budget
   while it runs, and must cost nothing once stopped.

### 10.2 Screenshots and recordings

- **Screenshot**: `adb exec-out screencap -p` straight into a file (nothing left
  on the phone), also copied to the clipboard. Button and shortcut. Named
  `<device>-<date>-<time>.png`.
- **Record**: with scrcpy (`--record`, no time limit, audio on Android 11+,
  `--no-window` to record without mirroring); without scrcpy, `screenrecord`
  (no audio, 3 min per segment: Hawk chains segments, pulls and joins them).
  Timer and Stop; the file is on the Mac when it stops.
- **Captures**: a strip of recent screenshots and recordings: drag out into any
  app, copy, reveal in Finder, delete. Saved to a folder the user picks.
- **Optimize with ffmpeg** (when installed), in the background with progress,
  size before and after, original kept until the user deletes it:
  - Share: H.264 1080p, good quality, plays everywhere, small.
  - Smallest: HEVC with the hardware encoder (`hevc_videotoolbox`), 720p.
  - GIF / WebP for short clips (15 fps, 480 px wide).
  - Trim start/end, remove audio, speed up.

### 10.3 Shell

- A shell on the device (`adb -s <serial> shell`, or `su` when rooted and asked).
  See open questions: built into Hawk or in the user's terminal.
- Quick commands panel: saved one-liners per device or global.

## 11. Layout

The Android tab gets its own left column:

```
Devices
  Pixel (USB)          live
  Tablet (Wi-Fi)       live
  Old phone            disconnected 2 h
  + Pair over Wi-Fi
  Connection doctor
---
Overview          (2)
Apps              (3)
Usage per app     (3.4)
Screen            (10)
Logcat            (4)
Crashes & ANRs    (5)
Performance       (9)
Background & power (14.1)
Storage           (6)
Network           (7)
Security          (8)
Tools             (14)
Shell             (10.3)
```

Sections of a disconnected device show the last data with a banner; actions
that need the device are disabled.

## 12. How it fits Hawk

- `HawkKit/Android/`: adb runner, device registry, every parser (getprop,
  dumpsys diskstats/netstats/device_policy/gfxinfo/meminfo/dropbox, logcat
  lines), `AndroidRules`. One test file per parser, fixtures made up (no real
  device output with real names, numbers or accounts).
- An `AndroidHub` actor owns `track-devices`, per-device state and logcat
  streams; the feature only reads finished snapshots.
- Work only for what is shown: logcat streams only while its page is open or
  the user turned on Keep running (4.4); live stats only while Overview is
  open. With the tab or window closed, only two cheap things run: the device
  watch (`track-devices`, idle until something changes) and the ANR check
  every 60 s per connected device (5.1).
- Logs may contain personal data: stored only locally, never in logs Hawk
  writes to `hawk.log`.

## 13. Suggested order

1. Device registry, track-devices, small on-disk snapshots, transports and
   reconnection, overview, system info, connection doctor, Wi-Fi pairing.
2. Logcat (filters, presets, follow-app, recording) and crashes/ANRs.
3. Apps: list with icons, install, uninstall, pull, clear, with
   `AndroidRules`; usage per app (battery, Wi-Fi, mobile, memory).
4. Screen: scrcpy launcher with relaunch in place, screenshots, recordings,
   ffmpeg presets. Then background & power toolkit (14.1), adb tunnels, Flutter/WebView DevTools.
5. Storage, network configuration, data usage, open connections, certificates.
6. Performance timeline.
7. Security and bloat scans.
8. Request capture (proxy), Wi-Fi sharing and hotspot (after testing on real
   devices).
9. Storage saver.

## 14. More ideas

Ranked roughly by how useful they would be day to day.

### 14.1 Background & power toolkit

For exactly the background geolocation kind of debugging, "why did my app stop
getting locations in the background":

- Per app: battery optimisation exemption (`dumpsys deviceidle whitelist`),
  standby bucket (`am get-standby-bucket`), background restrictions and app ops
  (`cmd appops get <pkg>`), location permission level (while in use / always),
  precise vs approximate.
- What the app is holding right now: location requests (`dumpsys location`),
  wakelocks, alarms (`dumpsys alarm`), jobs (`dumpsys jobscheduler`), foreground
  services.
- Force states to test without waiting hours: Doze (`dumpsys deviceidle
  force-idle`, then `unforce`), standby bucket, app inactive, unplug battery
  (`dumpsys battery unplug`, then `reset`). Each with an "undo" and reset on
  disconnect.
- Vendor killers: detect Samsung/Xiaomi/Huawei battery managers and show where
  the user has to whitelist the app (links to the known settings screens).
- Location: providers on/off, last known locations per provider, mock location
  app set; on emulators, `geo fix` and a route playback.
- Battery drain per app since charge (`dumpsys batterystats`).

### 14.2 Developer tools

- **Flutter**: detect Flutter apps (`libflutter.so`), pick up the Dart VM service
  URL from logcat, forward it and open DevTools in one click.
- **WebView/Chrome**: find `devtools_remote` sockets, forward, open
  `chrome://inspect`-style list.
- **Intents and deep links**: launch a URL or intent (`am start -a VIEW -d ...`),
  send broadcasts, saved per app. Test App Links verification
  (`pm get-app-links`).
- **Developer toggles** in one panel: animation scales, show taps, pointer
  location, layout bounds, stay awake, dark mode, font scale, display size,
  locale, demo mode (clean status bar for screenshots), Wi-Fi / data / airplane.
- **Type from the Mac**: send text to the focused field (`input text`), paste the
  Mac clipboard into the phone.
- **Files**: browse shared storage, drag files in and out.
- **Emulators**: start/stop AVDs from the list (with `emu` when present).

### 14.3 Several devices

- Run an action on several devices at once: install an APK, run a shell
  command, apply a toggle.
- Compare two devices side by side (versions, settings, app versions).

### 14.4 Reports and alerts

- **One-click report**: zip with device info, recent logcat (filtered to an app),
  crashes, screenshot and installed version, ready to attach to a ticket.
  Optional full `bugreport`.
- Alerts through `monitor.post`: device connected/disconnected, watched app
  crashed or ANR, test device battery low, storage nearly full, proxy still set.

### 14.5 Play Console (optional)

With `gplay` on this Mac: for an app installed on a device, show the version
live on each track vs the installed one, and its crash/ANR rates. This calls
Google's API, so it breaks "nothing leaves the Mac" and would only be an
explicit, off-by-default integration.

## 15. Checked on a real device

Done on 2026-11-07 with a Samsung Galaxy on Android 17 (SDK 37), not rooted,
over USB, read-only commands only (nothing on the phone was changed). Findings
are written into the sections above; in short:

| Item | Result | Section |
|---|---|---|
| Socket list with app UIDs (`/proc/net/tcp*`) | Readable | 7.4 |
| System CA store | Readable (both locations) | 7.6 |
| User-installed CAs | Root only | 7.6 |
| `pm clear --cache-only` | Present | 3.3 |
| `cmd wifi add-network` / `connect-network` / `list-networks` | Present | 7.2 |
| Hotspot name/password | Root only | 7.1 |
| `dumpsys dropbox` format, tag and date filters | Confirmed; short retention on Samsung | 5.1 |
| Per-app data usage | 24 h from `dumpsys`; about 100 days through the helper | 3.4 |
| On-device helper (icons, labels, data history) | Works; costs measured | 3.2 |
| `batterystats --checkin` per-app records | Present | 3.4 |
| `dumpsys diskstats` classes and per-app sizes | Present, one call | 6 |
| UFS vs eMMC | From `/sys/block` names only | 6 |
| Secure Folder seen as profile owner | Yes | 2.2 |
| scrcpy relaunch in place | Works; details and recipe | 10.1 |

Still to check: an ANR entry's content, root-only paths on a rooted device,
mDNS wireless serials, an older Android version (Wi-Fi pairing and `cmd wifi`
need 11+).

## 16. Open questions

1. Which devices and Android versions must work? Several items need Android 11+
   (Wi-Fi pairing, `cmd wifi`, exit-info) or 14+ (per-app cache clear).
2. "Tunnel from the internet" means which?
   a. Reach a phone's adb from anywhere (remote adb over Tailscale/WireGuard).
   b. Give the phone the Mac's internet over USB (reverse tethering; needs a
      small app on the phone, like gnirehtet).
   c. Expose a phone or Mac port publicly (cloudflared/ngrok style); this sends
      traffic out and would be explicit only.
3. Request capture: is hosts-and-bytes enough, or do you want HTTPS decryption for
   your own debug apps (installing a Hawk CA on the phone)?
4. Malware indicators: may Hawk download a public indicator list (inbound only,
   no data sent)? Online hash lookups stay out unless you say otherwise.
5. Shell: embedded terminal in Hawk (needs a terminal emulator dependency such
   as SwiftTerm) or open the user's terminal with `adb shell` ready?
6. Bloat list: write our own, or base it on an existing community list (check
   its licence)?
7. Should some of this also be in the `hawk` CLI (`hawk adb logcat --preset`)?
8. Play Console integration (14.5): wanted, given it calls Google's API?
9. scrcpy buttons for its live toggles: worth asking for the Accessibility
    permission, or is a shortcut cheat sheet enough?
