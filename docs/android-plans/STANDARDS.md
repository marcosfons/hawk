# Standards for every Android plan

Every agent reads this, `CLAUDE.md`, `docs/engineering-guidelines.md` and its
own plan before writing code. A milestone is not done until it meets all of
them. This page adds what is specific to the Android work.

## 1. Resource budgets (hard limits)

Hawk is a monitor: it must cost almost nothing, on the Mac and on the phone.
Measured on a release build (`make`), window open unless stated, one device on
USB. A milestone that goes over a limit is fixed before it is committed, or the
commit says which limit, by how much, and why, and the user agrees.

**Mac (Hawk process):**

| Scenario | CPU (avg over 60 s) | Memory (phys footprint) |
|---|---|---|
| Hawk without the Android tab (baseline) | no regression over `docs/perf-baseline.md` (+0.3% max) | +5 MB max |
| Android tab closed, device connected | +0.1% max; no thread busy in `sample` between checks | +5 MB max |
| **Full background** (window closed, devices connected) | Hawk total **under 2%, target under 1%** (`CLAUDE.md`); Android's share +0.1% max, ANR check included | +5 MB max |
| Android tab, device list + Overview | +1.5% max | +15 MB max |
| Logcat, 100 lines/s | 3% max | +40 MB max with 50k lines |
| Logcat, 2,000 lines/s flood | 8% max, UI stays responsive | same cap, never grows past it |
| Usage / Apps pages open | 2% max (spikes allowed on refresh) | +20 MB max with icons |
| scrcpy mirroring (scrcpy is its own process) | Hawk +0.5% max | +5 MB max |
| Whole app, normal use | under 5% of one core | under 100 MB |
| 30 min soak, Android tab open | no upward trend | drift under 5 MB, `leaks` reports 0 |

**Phone:**

| Scenario | Limit |
|---|---|
| Overview or Live open (one `shellBatch` per 2-3 s) | adbd + shell under 2% of one core on average |
| Tab closed | nothing but the 60 s ANR check, under 50 ms CPU each |
| Helper run (typical) | under 0.3 s CPU, ~45 MB private memory, freed at exit |
| Afterwards | no Hawk process left, no wakelock held, nothing in `/data/local/tmp` but the current helper |

**Energy**: `top`'s POWER column for Hawk with the Android tab open stays in
the same range as the baseline scenario; no timer fires while nothing is shown.

## 2. Profiling: how to measure

Plan A adds `tools/perf.sh` and `make perf SCENARIO=<name>`; every plan adds
its scenarios to it. The script, for a running release Hawk:

1. Finds Hawk's PID and the scenario's setup (which tab, which section).
2. CPU, memory and energy: `top -l 61 -s 1 -pid <pid> -stats cpu,mem,power`,
   averaged, plus `footprint <pid>` at the start and the end.
3. Where time goes: `sample <pid> 10`, summarised as busy samples per thread
   (main thread must be idle between updates).
4. Leaks (soak scenario): `leaks <pid>`.
5. Phone side: `adb shell top -b -n 3 -d 5 -o PID,%CPU,RES,ARGS`, filtered to
   `adbd`, `sh`, `app_process`, `logcat`; and a check that nothing of Hawk's is
   left running.
6. Writes `build/perf/<date>-<scenario>.md` (ignored by git).

Deeper, when a number is off: Instruments from the command line, attached to
the running app (Xcode 27 is installed):

```sh
xcrun xctrace record --template 'Time Profiler' --attach Hawk --time-limit 30s --output build/perf/time.trace
xcrun xctrace record --template 'SwiftUI'       --attach Hawk --time-limit 30s --output build/perf/swiftui.trace
xcrun xctrace record --template 'Allocations'   --attach Hawk --time-limit 60s --output build/perf/alloc.trace
```

Then `open build/perf/<file>.trace`, or `xcrun xctrace export --input ...
--toc` to read it from the terminal. Do not use the staged SwiftUI skill's
Python trace scripts (not reviewed).

`docs/perf-baseline.md` (created by Plan A, committed) holds one row per
scenario: date, commit, CPU, memory, POWER, phone CPU. Each plan adds its rows
when its milestones land, so regressions show in review.

## 3. Swift, SwiftUI and code practices

`docs/engineering-guidelines.md` sections 1-7 apply in full (performance and
energy, SwiftUI correctness and performance, AppKit, macOS design,
accessibility, code). Android-specific additions:

- **All device work through `DeviceSession`** (Plan A): never spawn `adb`
  directly, so timeouts, concurrency limits, errors and reconnection are the same
  everywhere, and logic can be tested against the fake session.
- **Streams are coalesced**: logcat reaches the UI at most ~4 times a second;
  periodic pages publish one value per tick from one `shellBatch`.
- **Typed errors from adb** (`AdbError`); a failure on one device never affects
  another device or the rest of Hawk.
- **Phone-side cost counts too**: no shell call per value, no helper run per
  item, nothing left running on the phone.

## 4. Security

- **Device output is untrusted input.** Parsers never crash on garbage, cap
  sizes (lines, fields, files), and are tested with truncated and random input.
- **Shell injection**: values interpolated into an `adb shell` script go through
  one quoting function (tested), and are validated first: package names
  (`^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$`), serials, remote paths. File
  names from the device are sanitised before becoming local paths (no `..`, no
  absolute paths): pulls never write outside the chosen folder.
- **Destructive actions** only through `AndroidRules` (rechecked at the moment
  of acting), after confirmation, logged in `actions.md`. Protected packages and
  paths are hard-coded and tested. WhatsApp data is never deleted.
- **Secrets**: Wi-Fi passwords read from the keychain stay in memory for the one
  command, are never logged, stored or shown in `actions.md`. `hawk.log` never
  contains logcat content, phone numbers, SSIDs, serials or account names.
- **Local only**: nothing leaves the Mac. Proxies and tunnels bind to
  `127.0.0.1`. Device folders are named by a hash of the serial and created with
  `0700` permissions.
- **Root** only through the single gated wrapper, after asking the user.
- **Helper integrity**: Hawk checks the pushed dex's SHA-256 on the phone before
  running it, and runs only the file it pushed.
- **Privacy in the repo** (it is public): no real serials, SSIDs, package lists,
  phone numbers, names or paths from this Mac in code, tests, docs or commit
  messages. Review the diff for them before every push.

## 5. Git: commit and push

Before any plan starts, `main` must be clean and pushed.

- Each plan works in its own worktree and branch:
  `git worktree add ../hawk-<plan> -b android/<plan> main`
- **Commit every milestone** once `make check` is green and, for milestones that
  run anything periodically or stream, its `make perf` scenarios are within
  budget. Message: short imperative subject, blank line, what changed and why,
  and the perf numbers when relevant. **No `Co-Authored-By` or any attribution
  trailer** (`CLAUDE.md`).
- **Push the branch after every commit**: `git push -u origin android/<plan>`.
- **Integrate into `main`** when the plan's milestones are done (or at a stable
  point the plan names):
  1. `git fetch origin`, then `git merge origin/main` into the branch (never
     rebase or force-push pushed commits);
  2. `make check` and the plan's `make perf` scenarios again;
  3. `git switch main && git pull --ff-only`, `git merge --no-ff android/<plan>`,
     `make check`, `git push origin main`. If the push is rejected, pull and
     repeat the checks; never force.
- Never commit `build/`, `.build/`, traces, perf reports, `.DS_Store`, or anything
  pulled from a device.
- Releases are the user's call (`CLAUDE.md` release steps), not an agent's.
