# Engineering guidelines

How code is written in Hawk. `CLAUDE.md` has the short version and the rules
learned by measuring this app; this page is the full code of conduct every
change follows, by a person or an agent.

The SwiftUI and design parts are a summary, rewritten for Hawk, of two
MIT-licensed guides reviewed on 2026-11-07: AvdLee/SwiftUI-Agent-Skill and
raintree-technology/apple-hig-skills. Where they disagree with Hawk's own
conventions (always dark, one accent), Hawk's conventions win.

## 1. Performance and energy

The budget is in `CLAUDE.md`: under 5% of one core with the window open in
normal use, **under 2% (target under 1%) in full background**, under ~100 MB,
without dropping features. How to stay inside it:

- **Do nothing for what nobody sees.** A hidden window updates nothing; a
  closed page stops its streams and timers; background work is limited to what
  must run with no window (fan control, alerts, energy totals, ANR checks).
- **One wakeup, many reads.** Batch reads into one call per interval (one SMC
  pass, one `adb shell` script), instead of many small timers.
- **Events over polling** when the system offers them (IOKit notifications,
  sockets, file system events, `NSWorkspace` notifications).
- **Background QoS.** Background work runs at `.utility` or `.background` so it
  can use efficiency cores; timers get tolerance so macOS can coalesce them.
- **Slow work off the main actor**, always: process launches, parsing, disk,
  sorting, filtering, image work. The main actor receives finished values.
- **Bounded memory**: every buffer, cache and history has a cap and an eviction
  rule, with a test. Images are cached at the size shown (16-32 pt), never full.
- **Measure before and after** any change that runs periodically, streams, or
  touches a list: CPU, memory and energy with the window open and closed (tools
  in `CLAUDE.md`). Numbers go in the commit message when they matter.

## 2. SwiftUI: correctness (always bugs when broken)

- `@State` and `@FocusState` are `private`.
- `@Binding` only where the child writes the value.
- A value owned by the parent is not copied into `@State` (except an explicit,
  documented one-time seed).
- `@Observable` models with `@State` when the view owns them, `.environment` or
  plain properties when injected, `@Bindable` when an injected model needs
  bindings.
- `ForEach` over stable identity: never `.indices` or offsets, never an id built
  from mutable content. Each element produces a constant number of views.
- `.animation(_:value:)` always names its value.
- No closures stored in environment values; environment defaults are stable
  (no `Model()`, `Date()` or `UUID()` as a default).
- Display scale comes from `@Environment(\.displayScale)`, not global screen
  state.
- Version-specific APIs behind `#available` with a sensible fallback (Hawk is
  macOS 26+, so this only matters for newer APIs).
- Replace hard-deprecated APIs; leave soft-deprecated ones unless the change is
  about them.

## 3. SwiftUI: performance

- **Each `View` type is an invalidation boundary.** Give a view only the data it
  reads; keep frequently changing values in the smallest subtree that shows
  them; extract subviews instead of growing one big `body`.
- **Only assign state when it changed.** Compare before setting, especially in
  anything called every tick.
- **Derived values are computed, not stored**, and computed in the model when
  expensive, not in `body`.
- **`body` stays cheap and pure**: no object creation, formatting of large data,
  sorting, regex, image decoding or side effects.
- **Granular observation**: many rows reading one big observable array all
  re-render when one element changes; give rows plain values or per-row
  observable holders.
- **Frequently changing values do not go in the environment.**
- **Lazy containers** (`LazyVStack`, `LazyVGrid`) for long static content; for
  live or long data, Hawk's `DataTable`.
- **No per-update animations**, no `.help()` on views that change every second
  (both measured in Hawk to re-layout or hit-test the whole window).
- **Cancel with the view**: `.task` for view-scoped async work; features stop
  their work in `setVisible(false)`.
- Closures SwiftUI may run off the main thread (`Shape.path(in:)`, `Layout`,
  `visualEffect`, `onGeometryChange`) capture the values they need instead of
  reading main-actor state.
- Investigating unexpected updates: `let _ = Self._logChanges()` inside
  `#if DEBUG`, removed before committing; then the Instruments SwiftUI template.

## 4. AppKit where SwiftUI is too slow

SwiftUI first. AppKit when measurement shows SwiftUI cannot do it within budget
or cannot do it at all: `DataTable` (`NSTableView`) for live lists, Core
Animation for continuous motion (the fan icon), window management. Bridged views
update in place and never rebuild on each tick.

## 5. macOS design

Hawk's conventions (`CLAUDE.md`: always dark, near-black body, white text, one
cool blue accent, plain `-` separator, columns over prose) apply first. From
Apple's guidelines, adapted:

- **Content over chrome**: subtle separators and system materials, not heavy
  borders and boxes.
- **Dense but comfortable**: use the large display to show more at fewer levels
  of nesting, with little modality; long text behind a disclosure or popover.
- **Windows behave like Mac windows**: resizable, remember their size and
  position, work in full screen.
- **Keyboard first-class**: shortcuts for frequent actions, Cmd-F for find,
  arrow keys in lists, everything reachable without a mouse.
- **Menus**: commands reachable from the menu bar and context menus, with
  consistent names.
- **SF Symbols** for icons, matched in weight to the text beside them; system
  fonts (SF Pro, SF Mono for numbers and logs that must align).
- **Clear feedback for every action**: progress for anything over a moment,
  confirmation before anything destructive, the result shown afterwards.
- **Motion with meaning only**; Reduce Motion replaces it with a fade or nothing.

## 6. Accessibility

- Every interactive element has an accessibility label; icon-only buttons
  always.
- Colour is never the only signal (log levels have a letter, states have text).
- Contrast holds on the dark background, including Increase Contrast.
- Text uses text styles so larger sizes do not break layouts.
- Reduce Motion respected everywhere.

## 7. Code

- **Swift 6 strict concurrency**, zero warnings. Actors own mutable state; data
  crossing actors is a `Sendable` value type. `@unchecked Sendable` or
  `nonisolated(unsafe)` only with a comment proving it safe.
- **Logic in HawkKit, tested**: parsers, rules, policies and state machines are
  pure functions or value types with Swift Testing tests on made-up data. Views
  display and forward.
- **Seams for testing**: protocols at the boundary to hardware and processes
  (SMC, helper, `DeviceSession`), fakes in tests, injected clocks for anything
  time-based.
- **Errors are typed and handled**; no `try!` or force unwrap on anything from
  hardware, a process, a file or a device. Every swallowed failure is logged.
- **Processes** launched with argument arrays, never a shell string; every child
  has a timeout, is tracked and is killed on cancel and on quit.
- **Small files, one subject each**; clear names; no dead code; comments say
  why.
- **No new third-party dependencies** without the user agreeing first.
- Separate business logic from views for testability; no particular
  architecture pattern is mandated.

## 8. Security and privacy

- **Input from outside is untrusted**: device output, files, process output.
  Parsers cap sizes and never crash on garbage; tests include truncated and
  random input.
- **No injection**: values put into shell scripts (for example `adb shell`) are
  validated and quoted by one tested function.
- **Paths**: names that come from outside are sanitised before becoming local
  paths; nothing is written outside the folder the user chose.
- **Destructive actions** go through tested rules (`StorageRules`,
  `AndroidRules`), are rechecked at the moment of acting, confirmed, and logged.
- **Secrets** (Wi-Fi passwords, tokens) live in memory for the one use: never
  logged, stored or shown.
- **Nothing leaves the Mac**; local servers bind to `127.0.0.1`.
- **Least privilege**: the root helper does only what it must; root on a phone
  only after asking; permissions (Full Disk Access, Accessibility) asked for at
  the moment their value is clear, with the reason.
- **Privacy in the repo** (public): no real personal data in code, tests, docs
  or commit messages.

## 9. Testing and verification

- Unit tests for everything with rules (Swift Testing, `Tests/HawkKitTests/`,
  one file per subject). No UI tests.
- Interface changes: `make run`, then say what to look at; never claim an
  interface behaviour works when it was only reasoned about.
- `make check` once at the end of a change and before every commit.
- Performance-sensitive changes: measured with the window open and closed, as in
  section 1.
