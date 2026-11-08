# Performance baseline

What Hawk costs, scenario by scenario, so every change can be compared with the
app as it was before. Measured with `make perf SCENARIO=<name>`
(`tools/perf.sh`): a release build, 20 s of warm-up, then `top` averaged over
the run, `footprint` at the start and the end, `sample` for 10 s. Budgets are in
`CLAUDE.md` and `docs/android-plans/STANDARDS.md` section 1.

Columns: CPU is percent of one core averaged over the run; Footprint is
`footprint` at the end of the run; POWER is `top`'s energy impact, averaged;
Main busy is the main thread's samples outside a kernel wait during 10 s of
`sample` (about 8,000 samples in total); Phone is adbd + sh + app_process +
logcat on the phone, percent of one core (`-` when no device).

Measured on an Apple M4 Pro, macOS 27.2, one phone on USB, the helper
installed.

## Before the Android work

`c41e948` (main before Plan A), plus only the two hooks `tools/perf.sh` needs:
the `-startInMenuBar` launch argument and the window visibility log line.

| Date | Commit | Scenario | CPU | Footprint | POWER | Main busy | Phone |
|---|---|---|---|---|---|---|---|
| 2026-11-07 | c41e948 | baseline (window open, Overview, 60 s) | 2.53% | 73 MB | 2.53 | 256 | 0.1% |
| 2026-11-07 | c41e948 | background (window closed, 60 s) | 3.63% | 37 MB | 3.64 | 416 | 0.0% |
| 2026-11-07 | c41e948 | soak (window open, 3 min tooling check) | 2.39% | 74 MB | 2.39 | 234 | 0.1% |

The soak drifted +1 MB in 3 minutes and `leaks` found 0. The full 30-minute soak
runs once with the Android tab open, at the end of Plan A.

Findings that predate the Android work:

- **Background is over budget** (3.6% against under 2%, target under 1%), and
  costs more than the window open on Overview. The main thread stays busy with
  the window closed. Android changes are judged by their own share (+0.1% max in
  background), not against this total; fixing it is separate work.
- Footprint varies between launches (37 to 133 MB seen in trial runs of the same
  build), so a memory comparison uses the same scenario run twice, not a single
  reading.

## How to add a row

Run the scenario when a milestone lands, add one row per scenario under a
heading for the plan, with the commit, and note anything over budget with the
reason. Runs where the window was covered are flagged invalid by the script
(`Valid: no`) and are not recorded.

## Plan A

`adb-down` and `adb-restart` run against `tools/fake-adb` on port 5099, so they
never touch the real server or a phone. A single 60 s run on a Mac doing other
work varies by about half a point (background read 2.1% to 3.6% across runs of
the same kind), so differences smaller than that are noise, not regressions.

| Date | Commit | Scenario | CPU | Footprint | POWER | Main busy | Phone |
|---|---|---|---|---|---|---|---|
| 2026-11-07 | M4 | android-closed (Overview, adb attached, phone on USB) | 2.24% | 57 MB | 2.25 | 193 | 0.0% |
| 2026-11-07 | M4 | background (window closed, adb watch open, phone on USB) | 2.13% | 35 MB | 2.14 | 170 | 0.0% |
| 2026-11-07 | M4 | adb-down (Android tab, backoff 2-5-10-30 s, then failing) | 2.44% | 39 MB | 2.44 | 222 | 0.1% |
| 2026-11-07 | M4 | adb-restart (window open, server killed, re-attached within 2 s) | 2.03% | 37 MB | 2.04 | 204 | 0.0% |
