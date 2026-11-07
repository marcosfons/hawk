# Plan A - Foundation: adb, server, devices, reconnection

Done first, by one agent. Everything else builds on its API. Requirements:
sections 1, 2.1, 2.3 and 12 of `docs/android-requirements.md`.

## Goal

Hawk talks to adb in one place that never hangs the app, never hot-loops, and
recovers from anything adb does: server killed or restarted by someone else,
server hung, version fights, devices dropping, switching between USB and Wi-Fi.

## Environment findings (2026-11-07)

- **There is only one adb on this Mac.** `which -a adb` lists two paths, but
  `/usr/local/bin/adb` is a symlink (created March 2025, owned by root) to the
  SDK's `~/Library/Android/sdk/platform-tools/adb`. `~/.zshrc` puts
  `platform-tools` first in `PATH`, so both names run the same binary.
- Version: **platform-tools 37.0.1** (`adb version`: 1.0.41, 37.0.1-15733141),
  installed August 2026. Homebrew's local metadata knows 37.0.2, so it is one
  patch behind, not outdated. Update through Android Studio's SDK Manager, or
  `sdkmanager "platform-tools"`.
- No Homebrew `android-platform-tools` cask is installed; Android Studio uses the
  same SDK folder, so it shares this adb. scrcpy also calls the `adb` in `PATH`.
- What would be a problem: a **second real copy** (installing the Homebrew cask,
  or a tool bundling its own adb). Two different versions kill each other's
  server on every call ("adb server version (X) doesn't match this client (Y);
  killing..."), dropping scrcpy, Android Studio and Hawk sessions. Hawk detects
  and explains that (below). The symlink is harmless while the SDK stays put;
  if the SDK moves, the symlink dangles and Hawk reports it.

## Owns

- `Sources/HawkKit/Android/Adb/` (new; the current `Adb.swift` is replaced and
  removed)
- `Sources/HawkKit/Android/Store/`
- `Sources/HawkKit/Android/Rules/` (`AndroidRules`, `ActionLog`: skeleton and
  protected list; later plans add rules)
- `Sources/HawkApp/Features/Android/` (feature, hub glue, device list, section
  host, Overview, placeholders for every other section)
- `Tests/HawkKitTests/Android*Tests.swift` for its subjects

## Design

### Locating adb (`AdbLocator`)

- Order: `ADB` environment variable if set, `$ANDROID_HOME/platform-tools`,
  `~/Library/Android/sdk/platform-tools`, every `adb` in `PATH`,
  `/opt/homebrew/bin`, `/usr/local/bin`.
- Resolve symlinks; group by real path; read each one's `adb version` once
  (cached by path + modification date).
- Report: the chosen adb, its version, and **other distinct copies** with their
  versions. Two distinct versions = a warning in the connection doctor and the
  Android header ("Two adb versions installed: they will keep restarting each
  other's server").
- Dangling symlink, missing adb, not executable: a clear state, not a crash.
- Hawk always uses the chosen path, never whatever `PATH` gives a child process.

### Running commands (`AdbProcess`)

The current `runCommand` blocks a thread until the process ends. Replace for
adb with an async runner:

- `run(args, timeout, input?) async throws -> AdbOutput` (stdout, stderr,
  status, duration). stdout and stderr read separately and concurrently (a full
  pipe must not deadlock).
- `stream(args) -> AsyncThrowingStream<Data>` for long-lived commands
  (`logcat`, `track-devices` fallback, `screenrecord`), cancelled by the
  consumer.
- Timeout and cancellation: SIGTERM, then SIGKILL after 2 s if still alive.
  Every child is tracked and killed when Hawk quits.
- Every run logged at debug with duration; `Log.x.timed` warnings for slow ones.

### Classifying failures (`AdbError`)

One enum from stderr and status, tested against made-up stderr lines:

| Case | Recognised by (examples) | What Hawk does |
|---|---|---|
| `notInstalled` | locator found nothing | Doctor explains how to install |
| `serverStarting` | `daemon not running; starting now` | Not an error; wait |
| `serverUnreachable` | `cannot connect to daemon`, connection refused | Supervisor restarts with backoff |
| `versionMismatch` | `server version (..) doesn't match this client` | Warning naming both binaries; no automatic restart loop |
| `portInUse` | `could not install *smartsocket* listener`, address in use | Says what owns port 5037 (`lsof -iTCP:5037`) |
| `deviceNotFound` | `device '...' not found`, `no devices/emulators found` | Device marked gone; registry resyncs |
| `deviceOffline` | `device offline` | State `offline` |
| `unauthorized` | `device unauthorized` | State `unauthorized`, doctor hint |
| `closed` | `error: closed`, `protocol fault` | Retry once, then gone |
| `timeout` | runner timeout | Counted toward server health |
| `commandFailed(status, stderr)` | anything else | Shown to the user as is |

### Talking to the server directly (`AdbSocket`)

For the device watch, Hawk speaks adb's host protocol on `127.0.0.1:5037`
instead of spawning processes: send a 4-hex-digit length + `host:track-devices-l`,
read `OKAY`, then length-prefixed device lists for every change.

- No process per update, and it never auto-starts a server (an `adb` client
  call would): Hawk decides when a server starts.
- Also `host:version` for a cheap health check (one round trip).
- Everything else (shell, push, pull, install, logcat) uses `AdbProcess`.
- Framing parser is pure and tested.

### Server supervisor (`AdbServer`, an actor)

States: `stopped(byUser)`, `starting`, `running(version)`, `unhealthy(reason)`,
`backingOff(until, attempt)`, `failing(reason, since)`.

- **Start**: `adb start-server` with a 10 s timeout, then wait for
  `host:version` to answer.
- **Health**: the track-devices socket is the heartbeat; if it closes, or
  `host:version` fails or takes over 3 s, the server is unhealthy.
- **Restart (user action, "Restart adb")**: confirm first, since it drops scrcpy,
  Android Studio and terminal sessions. Then: pause the registry and cancel
  streams, `adb kill-server` (5 s timeout), if the server is still alive kill its
  PID (from `lsof -tiTCP:5037 -sTCP:LISTEN`, only if that PID is an adb) with
  SIGTERM then SIGKILL, wait for the port to free (5 s), start, resubscribe.
- **Stop (user action, "Stop adb")**: same as the kill half; state
  `stopped(byUser)`. **Hawk never starts the server again on its own** until the
  user presses Start or opens a device action that needs it (with a prompt).
- **Killed or restarted by someone else** (terminal `adb kill-server`, Android
  Studio): the socket closes; Hawk reconnects with backoff. If another client
  already started a server, Hawk just reattaches.
- **Backoff**: 1, 2, 5, 10, 30 s, capped at 30 s, with jitter. After 5 failures
  in a row: `failing`, shown in the header with the last error, the adb path and
  version, and Retry / Restart adb buttons. Background retries continue at 60 s
  only while the Android tab is open; none while it is closed.
- **Never a hot loop**: every automatic action passes through the backoff
  policy, a pure value type with an injected clock, fully unit tested
  (`ServerPolicy`).
- **Version mismatch**: no automatic restarts at all (they would fight the
  other client); show the warning and the two binaries.
- **Hung server** (accepts the connection, never answers): timeouts mark it
  unhealthy; restart kills by PID because `kill-server` would hang too.

### Devices (`DeviceRegistry`, inside the hub actor)

- Input: track-devices updates (serial, state, product, model, transport id,
  usb path), plus a full `devices -l` resync after every server (re)start and
  every `deviceNotFound`.
- **Identity**: `ro.serialno`, read once per new transport (one shell call).
  Wireless mDNS serials (`adb-<serialno>-<id>._adb-tls-connect._tcp`) carry it
  already. One `Device` has several `Transport`s (USB, Wi-Fi, emulator).
- **States** per transport: `device`, `offline`, `unauthorized`, `authorizing`,
  `connecting`, `recovery`, `sideload`, `bootloader`, `no permissions`. A
  device's state is its best transport's.
- **Preferred transport**: USB over Wi-Fi when both are up. When the preferred
  one drops and another is up, sessions move to it without a disconnect event.
- **Events** (persisted, capped at 500): connected, disconnected, transport
  added/removed, state changed, server restarted.
- **Wi-Fi reconnect**: when a device's USB goes and it was paired for wireless
  debugging, try `adb mdns services` then `adb connect` with backoff (every 5 s
  for a minute, then every 60 s while the tab is open). `adb connect` always has
  a 5 s timeout (it hangs on unreachable addresses).
- **Disconnected devices never disappear** (requirements 1.2); "Forget" removes
  one and its folder.

### Device session API (`DeviceSession`), what every plan uses

```swift
// Sketch, not final names.
protocol DeviceSession: Sendable {
    var id: DeviceID { get }                       // ro.serialno
    func shell(_ script: String, timeout: Duration) async throws -> ShellResult
    func shellBatch(_ parts: [String: String], timeout: Duration) async throws -> [String: String]
    func stream(_ args: [String]) -> AsyncThrowingStream<Data, Error>  // logcat, screenrecord
    func push(_ local: URL, to remote: String) async throws
    func pull(_ remote: String, to local: URL) async throws
    func exec(_ args: [String], timeout: Duration) async throws -> AdbOutput  // install, forward...
}
```

- Always addressed by the current preferred transport's serial (`-s`), resolved
  at call time, so a USB-to-Wi-Fi switch is invisible to callers.
- `shellBatch` runs several labelled commands in one `adb shell` call with
  markers between outputs (one process, one round trip), the way every periodic
  read must be done.
- Concurrency: at most 3 adb processes per device and 8 in total; long-lived
  streams don't count toward the per-call limit but are capped (4 per device).
- Calls fail fast with `deviceNotFound` while a device is disconnected; streams
  end with a reason the caller can show and resume from.
- A fake `DeviceSession` with scripted answers lives in the test target, so other
  plans test their logic without a device.

### Package index (`PackageIndex`)

A small shared map every plan needs (logcat's app column, usage, crashes):
package name, UID, user/system, version code, from `pm list packages -U
--show-versioncode -s/-3` (one call), refreshed on connect and when a package
change is noticed. Plan B extends it with labels and icons; others only read it.

### Storage (`DeviceStore`)

- `~/Library/Application Support/Hawk/Android/<id-hash>/`, folder named by a
  hash of `ro.serialno` (no serials in paths or logs).
- API: `snapshot` (JSON, replaced atomically), `append(log:)` (capped files),
  `blob(name:)` for icons and similar, `usage()`, `evict(toFit:)`.
- Cap 50 MB per device (setting). Eviction order: logcat tail, then oldest
  history; snapshot, app list and icons never evicted.
- Writes off the main actor, coalesced (at most once every few seconds).

### Rules and action log

- `AndroidRules`: protected packages (launcher, Settings, System UI, phone,
  package installer, the device owner and profile owner apps), checked again at
  the moment of acting. Later plans add their rules here with tests.
- `ActionLog`: every action that changes a device appends to the device folder's
  `actions.md`: time, device nickname, action, target, result.

### Interface

- Android tab: left column with devices (live / disconnected with "last seen",
  transport chips, root chip, nickname), then the section list; section host on
  the right.
- Header strip: adb state (running / restarting / failing / stopped), adb
  version, warnings (two versions, dangling symlink), buttons Start / Stop /
  Restart adb.
- Overview section: identity, system (2.3) and "right now" (2.1: foreground app,
  battery, screen) from one `shellBatch` every 3 s while shown.
- Placeholder sections for B to F ("Not built yet"), one file each.

### Background work

With the Android tab closed: only the track-devices socket (idle until a change)
and the cheap jobs other plans register explicitly (C's ANR check). Nothing
else.

## Milestones (one commit each, `make check` green, branch pushed)

0. **Perf tooling first**: `tools/perf.sh` and `make perf SCENARIO=...`
   (STANDARDS 2), scenarios `baseline` (window open), `background` (window
   closed, menu bar only) and `soak`; run them on the current
   `main` and commit `docs/perf-baseline.md` with those numbers, so every later
   change is compared against the app as it was before Android work.
1. `AdbLocator` + `AdbError` + tests (fixtures: made-up `adb version` and stderr
   lines). Remove nothing yet.
2. `AdbProcess` (run, stream, timeouts, kill on quit) + tests with `/bin/sh`
   scripts standing in for adb (slow, hanging, flooding stderr).
3. `AdbSocket` framing + `ServerPolicy` (backoff, failing, user-stopped,
   mismatch) + tests with an injected clock.
4. `AdbServer` actor wired to both; header strip with Start / Stop / Restart.
5. `DeviceRegistry`: identity, transports, states, events, resync, Wi-Fi
   reconnect + tests (scripted track-devices sequences: plug, unplug, USB to
   Wi-Fi, unauthorized then authorized, server restart in the middle).
6. `DeviceSession` + fake + `shellBatch` marker parser tests.
7. `DeviceStore` + eviction tests; `AndroidRules` + `ActionLog` skeleton tests.
8. Android tab shell: device list, section host, Overview, placeholders. Old
   `Adb.swift` and the old view removed. Update `CLAUDE.md`'s Layout table if
   names changed.

## Device checklist (with the user's phone, read-only)

Run each with Hawk open on the Android tab, and note the result in the PR:

- [ ] Plug in, unplug, plug in: one device, events recorded, never duplicated.
- [ ] `adb kill-server` from a terminal: Hawk shows restarting, reattaches,
      device back, no error dialog.
- [ ] Restart adb from Hawk while scrcpy runs: confirmation shown first.
- [ ] Stop adb from Hawk: stays stopped; a terminal `adb devices` starting it
      again is picked up as "started by someone else".
- [ ] Hung server: `kill -STOP <adb server pid>` for 20 s: Hawk times out, shows
      unhealthy, does not freeze; Restart kills it by PID. Then `kill -CONT` if
      still alive.
- [ ] Revoke USB debugging authorisations on the phone: unauthorized shown with
      the hint; accept: back to live.
- [ ] Wireless debugging on, then unplug USB: "Reconnected over Wi-Fi", Overview
      keeps updating.
- [ ] `sample <pid> 10` with the tab open on Overview: within budget.

## Budgets and profiling

Scenarios A adds to `make perf`: `android-closed` (device connected, tab
closed), `android-overview` (tab open on Overview), `adb-restart` (CPU and
threads during a restart and the 30 s after), `adb-down` (server stopped and
failing: backoff must keep Hawk idle, not spinning). Limits in STANDARDS 1;
in particular the tab closed must cost nothing measurable, and a failing adb
must never raise CPU (no retry loops, no timers faster than the backoff).

Also measure on the phone: Overview's `shellBatch` every 3 s keeps adbd + shell
under 2% of a core.

## Done when

Every milestone merged into `main` and pushed; the checklist passes; the
`make perf` scenarios are within budget and recorded in `docs/perf-baseline.md`; another plan can call
`DeviceSession.shell` and receive either a result or a typed error within its
timeout, whatever adb is doing.
