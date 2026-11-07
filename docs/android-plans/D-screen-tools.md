# Plan D - Screen (scrcpy), captures, shell, developer tools

After A. Requirements: sections 10 (10.1-10.3), 14.1 and 14.2.

## Goal

Open scrcpy with options picked from controls, change them by relaunching in the
same spot, take screenshots and recordings that land on the Mac ready to share,
and the developer and background-debugging tools.

## Owns

- `Sources/HawkKit/Android/Screen/`: scrcpy locator and option model, argument
  builder, relaunch geometry, scrcpy log parser, ffmpeg preset builder
- `Sources/HawkKit/Android/DevTools/`: toggles, intents, background & power
  readers and forcing commands with their undo
- `Sources/HawkApp/Features/Android/Sections/Screen/`, `Tools/`, `Power/`,
  `Shell/`
- Tests for those subjects

## Work

1. **scrcpy model**: options from 10.1 as a value type; hide options the
   installed version lacks (parse `scrcpy --version` and `--help`); presets per
   device and global; argument builder (pure, tested).
2. **Launch and relaunch in place** (10.1 recipe, tested 2026-11-07):
   - find the window with `CGWindowListCopyWindowInfo` by scrcpy's PID;
   - content rect = frame minus the title bar
     (`NSWindow.frameRect(forContentRect:styleMask:)`; zero when borderless);
   - height from the video aspect ratio in scrcpy's `Texture: WxH` log line, so
     the size does not drift;
   - `--no-power-on`; start right after the old one exits; retry once if it
     exits without a window; show its stderr on failure;
   - options that need a relaunch are locked while recording;
   - remember the last frame per device.
   - Cheat sheet of scrcpy's live shortcuts. Buttons that send them only if the
     user grants Accessibility (open question in the requirements).
3. **Captures** (10.2): screenshot with `exec-out screencap -p` to a file and
   the clipboard; recording via scrcpy (`--record`, `--no-window` for record
   only) or `screenrecord` segments joined; captures strip (drag out, reveal,
   delete); ffmpeg presets (Share, Smallest with `hevc_videotoolbox`, GIF/WebP,
   trim, remove audio) in the background with progress, original kept.
4. **Shell** (10.3): open the user's terminal with `adb -s <serial> shell` ready
   (embedded terminal is an open question); quick commands per device.
5. **Background & power** (14.1): per-app exemptions, standby bucket, app ops,
   location permission level, what the app holds (location requests,
   wakelocks, alarms, jobs, foreground services); forcing Doze / bucket /
   unplugged battery, each with undo, reset on disconnect, logged in
   `actions.md`.
6. **Developer tools** (14.2): toggles panel (each change logged and
   reversible), intents and deep links, Flutter DevTools (Dart VM service URL
   from C's classifier when available, else a one-off `logcat -d` search) and
   WebView DevTools forwarding through E's tunnels when E is merged (until then,
   a direct `adb forward`).

## Tests

- scrcpy argument builder from option values; version gating from made-up
  `--help` text.
- Relaunch geometry: frame to content rect, aspect-ratio height, borderless,
  multiple screens (negative coordinates).
- scrcpy log parser (`Texture:` line, errors).
- ffmpeg argument builder per preset.
- Power toolkit parsers (`dumpsys deviceidle whitelist`, standby bucket, appops)
  and the undo list for every forcing command.

## Device checklist

- [ ] Start mirroring with borderless + on top; move and resize the window;
      change bitrate: it reappears in the same spot within about a second.
- [ ] Ten relaunches in a row: no drift.
- [ ] Screenshot lands as a file and on the clipboard; recording of 30 s with
      audio; Share preset makes it smaller and keeps the original.
- [ ] On a test device: force Doze, then undo; disconnect while forced: reset on
      reconnect.

## Budgets and profiling

Scenarios D adds to `make perf`: `mirroring` (Hawk while scrcpy runs: Hawk
must stay idle, scrcpy's own cost is its own), `relaunch` (ten relaunches in a
row: no leaked processes or windows), `ffmpeg` (runs at low priority and never
blocks the UI). The window lookup polls only during a relaunch, never
continuously.
Limits in STANDARDS 1; numbers recorded in `docs/perf-baseline.md`.

## Done when

Merged into `main` and pushed (STANDARDS 5), `make perf` scenarios within
budget. The checklist passes; no scrcpy, ffmpeg or screenrecord process is left after
stopping.
