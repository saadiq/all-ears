# Plan: menu bar app (`ears-menubar`)

Status: **stage 1 implemented** (dropdown menu + notifications; the stage-2 dashboard
window remains future work).

Builds the menu-bar frontend that [`docs/specs/control-protocol.md`](../specs/control-protocol.md)
has anticipated since v2 ("the `ears` CLI, the browser extension, the menu-bar app
(`ears-menubar`)").
One glanceable surface for visibility into and control of the daemon, so day-to-day use
never needs a terminal.

## One job

A macOS menu bar app that (a) shows daemon and session state at a glance from the icon
alone, (b) offers the session verbs one click away — including starting a manual
session — and (c) proactively notifies when a summary is ready or a pipeline stage fails.
Full control surface, but with hierarchy: the common path stays small; depth is opt-in.

## Decisions already made

- **In this repo, not a separate one.** The v2 protocol explicitly assumes every client
  lives here and moves in lockstep with the wire; an out-of-repo frontend would recreate
  the versioning problem v2 rejected.
- **New SwiftPM targets in `daemon/Package.swift`, no Xcode project.** The Makefile
  assembles and signs the `.app` bundle, keeping one build system and putting the app
  inside the existing gates (swift-format, swift-testing, CI, golden wire fixtures).
- **Dropdown menu now, dashboard window later.** The clicked surface is a native menu
  (verbs, snapshot status). A richer dashboard window (live pipeline, health, logs) is
  **stage 2, out of scope here**, and gets its own spec when the need is proven.
- Menu content is a snapshot taken when the menu opens — no live-ticking rows. The
  *icon* is the always-on live indicator.

## Architecture

Two targets, mirroring the repo's "logic in a library, executables are shims" rule:

### `EarsMenuKit` (library — pure, no I/O, tier 0, TDD)

- **State reducer.** Applies a `subscribe` snapshot, then rev-tagged `session`/`source`
  events (spec rule: apply iff `rev == last_rev + 1`, else resubscribe) and `job`
  telemetry, producing one immutable `MenuState`: active session, sources, running/failed
  jobs, connection status.
- **Menu model.** Pure function `MenuState → menu content`: items, enabled/disabled
  verbs, status lines, icon variant.
- **Notification policy.** Pure function over state transitions → notification
  decisions. Quiet cases are part of the contract (see UX below).
- Elapsed-time rendering takes an injected clock; no wall-clock in tests.

### `ears-menubar` (executable — thin SwiftUI shell)

- SwiftUI `MenuBarExtra` scene rendering the menu model's output; the label view is the
  live icon.
- A connection actor wrapping `EarsIPC`'s socket client: **Unix socket** (full
  capability tier) → `hello` (`client: "menubar/<version>"`) → `subscribe(events:
  ["job"])` → frames feed the reducer. Reconnects with backoff; every reconnect
  resubscribes and rebuilds from the fresh snapshot, discarding in-flight job
  telemetry — which subsumes the spec's `boot_id` comparison, so the client never
  tracks the boot id itself. A rev gap drops the state back to `connecting` before
  bouncing the socket: the mirror is stale and the socket is gone, so the menu must
  stop offering verbs it can no longer deliver.
- Every control call's error is surfaced — in the menu, where the user who clicked is
  looking, and in unified logging. A verb that silently does nothing is the worst
  outcome available: the user believes the recording stopped.
- `UNUserNotificationCenter` adapter executing the policy's decisions (requires the
  `.app` bundle; a bare binary cannot post notifications).
- **Read-only** disk reader (`EarsDataStore.SessionStore`) for ended-session history and
  artifact paths — ended history is deliberately not served over the socket, and `earsd`
  stays the only writer.
- `launchctl` invoker (`Process`) for daemon restart.

Data flows one way: socket + disk → reducer → `MenuState` → render/notify. Verbs flow
back as protocol calls. `@MainActor` is permitted in the shell (it is UI); never in
`EarsMenuKit`.

## UX

**Icon** (template SF Symbol, one glyph per variant — a menu bar template renders
monochrome against arbitrary wallpaper, so paused is its own symbol, not a dimmed
recording one): idle · recording · paused · pipeline-busy · attention (stage failed,
a source of a live session died, or the daemon is unreachable).

**Menu**, top to bottom, content varying by state:

- Header: `● Recording · Weekly sync · 12:43` / `Idle` / `⚠ Daemon not running`, plus
  `· ⚠ system stopped` when a source the live session named is in `error` — the daemon
  isolates a source failure so the rest keeps recording, which is what makes half a
  meeting go missing unremarked.
- Verbs: `Start Recording` (a manual `session.start` naming the enabled
  `[[earsd.source]]` ids, resolved from the same config layers `earsd` reads — the
  daemon records exactly what a manual session names, and at idle it has no live
  sources to ask about; shown **only when no
  session is live** — superseding a live session from a menu click is a footgun), or
  `Pause`/`Resume`, `Rename Session…` (small text dialog), `End Session` when one is
  active. Extension-started sessions appear automatically and get the same verbs.
- Pipeline status, only while jobs exist: one line per job from `job` events; a failed
  stage stays visible with `⚠ failed` until cleared via a `Dismiss` item.
- `Recent Sessions ▸`: last ~7 ended sessions from disk, each with `Open Summary`,
  `Open Transcript`, `Show in Finder` (disabled until the artifact exists).
- `Daemon ▸`: version + uptime, `Restart Daemon`, `Open Logs`, `Open Data Folder`.
- `Launch at Login` toggle (`SMAppService`), `Quit`.

**Notifications** — results and failures only:

- Summarize job reaches `done`: *“Summary ready — Weekly sync”*; click opens the summary.
- Any stage reaches `failed`: *“Transcription failed — Weekly sync”*; click reveals the
  session folder.
- Unexpected daemon disconnect **while a session is active** notifies (a recording is at
  risk); daemon-down while idle is icon-only. Once per at-risk session, not once per
  drop — a crash-looping daemon reconnects between crashes, and each reconnect would
  otherwise re-arm the warning about the same recording.
- Explicitly quiet: session start/end/pause/resume — the user did those themselves.

## Daemon-side change: job events for every on-end stage

Today only `transcribe` publishes `job.publish` (it reports itself); the on-end chain
runs `cleanup`/`summarize` silently, so “summary ready” is unknowable to subscribers.
`OnClosePipelineRunner` will publish `job.publish` for the two stages that don't report
themselves (`kind: "cleanup" | "summarize"`, states `started`/`done`/`failed`), leaving
`transcribe`'s self-reporting untouched. The wire type
already carries `kind` as a string; the method table in
[`control-protocol.md`](../specs/control-protocol.md) and the golden fixtures in
`shared/protocol-fixtures/` are updated to match. This is additive, useful to any
subscriber, and lands as its own PR ahead of the app.

A second daemon-side change landed during implementation: `session.start` gained an
optional `on_end_stages`, so the chain a session runs is **declared by whoever starts
it** rather than inferred from its trigger. The menu bar app declares the operator's
configured chain (it promises "Stop → summary", so it asks for it); `ears session
start` declares nothing and stays inert unless given `--on-end-stage`, and any client
can pass `[]` to run its own post-processing without the daemon racing it.

This deliberately replaces an earlier, blunter version of the same feature that
removed the browser-only guard outright. That version changed what `ears session end`
did for every existing CLI user — a Parakeet load and one LLM call per summarize
preset, against a metered backend, where previously nothing ran. The declared-chain
form gives the menu bar app exactly what it needs while leaving upstream behavior
byte-identical for anyone who doesn't opt in, which is the difference between a PR
that has to be weighed and one that can just be taken.

## Packaging

`make menubar`: `swift build -c release --product ears-menubar`, assemble
`All Ears.app` (`Info.plist` with `LSUIElement = true`, bundle id under
`net.tomelliot.ears`; SF-Symbol menu icon, app icon later from `docs/brand`), codesign
with `SIGN_IDENTITY`, install to `~/Applications`, relaunch. `make install` /
`make uninstall` learn about the app. Signed-and-notarized distribution remains a
suite-wide non-goal for now (see “Not built yet”).

## Testing

- **Tier 0** (`EarsMenuKitTests`, swift-testing): reducer over snapshot/event sequences,
  including rev-gap → resubscribe and the reconnect state reset; menu model per state;
  notification policy transitions with the quiet cases asserted too. Frames decode via
  the same `EarsCore` codec the golden fixtures round-trip.
- **Tier 1**: extend the on-end chain smoke test (`CLISmokeTests`) to assert
  cleanup/summarize job events arrive on a subscribed socket.
- **Tier 2** (thin, manual): the SwiftUI shell and notification delivery.

## Upstream

`saadiq/all-ears` is a fork of `tomelliot/all-ears`. Before the first PR: a short
upstream issue describing this plan. Then two PRs: (1) on-end job events +
spec/fixture updates, (2) the app itself.
