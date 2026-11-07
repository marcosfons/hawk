# Android plans

How to build `docs/android-requirements.md` with several agents without them
stepping on each other.

## Order

```
            A  Foundation (alone, first)
                         |
     +-----------+-------+-------+-----------+
     |           |               |           |
     B Apps,     C Logcat,       D Screen    E Connectivity,
     helper,     crashes,        and tools   network, system
     usage,      ANRs
     storage
     |           |               |           |
     +-----------+-------+-------+-----------+
                         |
            F  Later: security, performance, request capture, storage saver
```

- **A** must be merged before anything else starts. It owns adb itself: finding
  it, running it, the server, devices, reconnection, storage on disk, the
  Android tab's shell and the section placeholders.
- **B, C, D, E** run in parallel, each in its own worktree and branch, after A.
- **F** starts when B and E are merged (it reuses the app list, the helper and
  network pieces).

## Rules every plan follows

- **[STANDARDS.md](STANDARDS.md) is binding**: resource budgets (CPU and memory
  must stay low on the Mac and on the phone), how to profile, Swift and SwiftUI
  performance rules, code practices, security, and how to commit and push.
- Read `CLAUDE.md` and the requirement sections the plan lists before starting.
- Each plan **owns** a list of folders. It creates and edits files only there,
  plus the explicitly listed shared touch points. If it needs a change in A's
  code, it makes the smallest additive change and says so in the commit
  message; it never reshapes A's API on its own.
- Plan A creates a placeholder file for every section (`Sections/<Name>/
  <Name>Section.swift`, a "Not built yet" view). A later plan **replaces the
  contents of its own placeholders**; nobody edits the section list.
- All device work goes through A's `DeviceSession` (never spawn `adb` directly),
  so timeouts, concurrency limits, errors and reconnection behave the same
  everywhere.
- Logic that parses or decides goes in `HawkKit/Android/...` with Swift Testing
  tests on **made-up** fixtures (no real serials, SSIDs, package lists, phone
  numbers). One test file per subject.
- Each milestone is one commit that passes `make check` (zero warnings) and,
  when it runs anything periodic or streaming, its `make perf` scenarios; the
  branch is pushed after every commit (STANDARDS 5).
- Interface checks: `make run`, then say what to look at. Never claim UI
  behaviour is verified when it was only reasoned about.
- Device checks: read-only commands are fine on any connected device. Anything
  that changes the phone (install, uninstall, clear, settings, proxy, Doze)
  only on a device the user says is a test device, and always undone.
- Nothing runs that is not shown, except what A's plan lists as background
  (device watch, ANR check). Numbers in STANDARDS 1.

## Plans

| Plan | File | Requirement sections |
|---|---|---|
| A | [A-foundation.md](A-foundation.md) | 1, 2.1, 2.3, 12 |
| B | [B-apps-usage-storage.md](B-apps-usage-storage.md) | 3, 6 |
| C | [C-logcat-crashes.md](C-logcat-crashes.md) | 4, 5 |
| D | [D-screen-tools.md](D-screen-tools.md) | 10, 14.1, 14.2 |
| E | [E-connectivity-network.md](E-connectivity-network.md) | 1.5-1.7, 2.2, 2.4, 7 (except request capture) |
| F | [F-later.md](F-later.md) | 6.1, 7.4 capture, 8, 9, 14.3-14.5 |
