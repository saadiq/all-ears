# Plan: menu bar app (`ears-menubar`)

Status: **stage 1 implemented** (dropdown menu + notifications; the stage-2 dashboard
window remains future work).

The menu-bar frontend that [`docs/specs/control-protocol.md`](../specs/control-protocol.md)
names alongside the `ears` CLI and the browser extension: one glanceable surface for
visibility into and control of the daemon, so day-to-day use never needs a terminal.

## One job

A macOS menu bar app that (a) shows daemon and session state at a glance from the icon
alone, (b) offers the session verbs one click away — including starting a manual
session — and (c) notifies when a summary is ready or a pipeline stage fails. Full
control surface, but with hierarchy: the common path stays small; depth is opt-in.

## Decisions

- **In this repo, not a separate one.** The v2 protocol assumes every client lives here
  and moves in lockstep with the wire; an out-of-repo frontend would recreate the
  versioning problem v2 rejected.
- **SwiftPM targets in `daemon/Package.swift`, no Xcode project.** The Makefile
  assembles and signs the `.app`, keeping one build system and putting the app inside
  the existing gates (swift-format, swift-testing, CI, golden wire fixtures).
- **The daemon is the authority on what to record.** The app never parses daemon
  config: Start Recording declares exactly the sources and on-end chain the running
  daemon reports in `status.configured`. The only config the app reads is where the
  socket and the data root are, through the same loader `ears` uses.
- **One reader of sessions on disk.** Recent Sessions and notification clicks read
  sessions back through `EarsDataStore`'s `SessionArtifactScanner`, the scanner
  `ears sessions` and `ears session show` use, so the surfaces never disagree about
  where a transcript or summary is.
- **Dropdown menu now, dashboard window later.** Menu content is a snapshot taken when
  the menu opens; the icon is the always-on live indicator.

## Architecture

Two targets, mirroring the repo's "logic in a library, executables are shims" rule.

### `EarsMenuKit` (library — pure, no I/O, tier 0, TDD)

- **State reducer.** Applies a `subscribe` snapshot, then rev-tagged `session`/`source`
  events (apply iff `rev == last_rev + 1`, else resubscribe) and `job` telemetry,
  producing one immutable `MenuState`. Every resubscribe drops in-flight job lines —
  their `done` may have been missed — which subsumes the spec's `boot_id` comparison.
  Failed lines persist until dismissed.
- **Renderer.** `MenuState → MenuContent`: icon variant, header (naming any failed
  source of the live session), the verbs on offer, one row per pipeline job.
- **Policies.** `NotificationPolicy` (state transitions → notification decisions, quiet
  cases included), `StartRecording` (`status` → `session.start` params, or a refusal),
  `SummaryTarget`, `RecentSessions`, `RecentsRefreshPolicy`, `DaemonUptime`,
  `NotificationAvailability`. Elapsed time takes an injected clock.

### `ears-menubar` (executable — thin SwiftUI shell)

- A `MenuBarExtra` scene; the label view is the live icon. `@MainActor` is confined to
  this target.
- `DaemonConnection`, an actor over `EarsIPC`'s socket client: Unix socket → `hello`
  (`client: "menubar/<bundle version>"`) → `subscribe(events: ["job"])` → frames feed
  the reducer. It reconnects with backoff; a generation counter retires stale loops. A
  rev gap drops the state back to `connecting` before bouncing the socket, so the menu
  stops offering verbs it can no longer deliver.
- `SessionControls`: the verbs as control calls. Every failure is surfaced in the menu,
  where the user who clicked is looking, and in unified logging — a verb that silently
  does nothing leaves the user believing a recording stopped.
- `RecentsStore`: the last seven ended sessions, scanned off the main actor with the
  scanner's lighter outcome depth; refreshed when the menu opens and on events that
  change the list.
- `Notifier`: the `UNUserNotificationCenter` adapter (requires the `.app` bundle; a bare
  binary cannot post notifications).
- `SystemActions`: `launchctl kickstart` for restart, opening logs, folders and the
  Settings panes.

Data flows one way: socket + disk → reducer → `MenuState` → render/notify. Verbs flow
back as protocol calls. `earsd` stays the only writer.

## UX

**Icon** (template SF Symbol, one glyph per variant — a template renders monochrome
against arbitrary wallpaper, so paused is its own symbol, not a dimmed recording one):
idle · recording · paused · pipeline-busy · attention (stage failed, a source of the
live session died, or the daemon is unreachable).

**Menu**, top to bottom, content varying by state:

- Header: `● Recording · Weekly sync · 12:43` / `Idle` / `⚠ Daemon not running`, plus
  `· ⚠ system stopped` when a source the live session named is in `error` — the daemon
  isolates a source failure so the rest keeps recording, which is what makes half a
  meeting go missing unremarked.
- Verbs: `Start Recording` only when no session is live (superseding a live session
  from a menu click is a footgun), else `Pause`/`Resume`, `Rename Session…`, `End
  Session`. Extension-started sessions get the same verbs.
- Pipeline rows while jobs exist, one per job; a failed stage stays as `⚠ … failed`
  until dismissed, and an in-flight row can be dismissed too, since a dropped terminal
  event would otherwise strand it.
- `Recent Sessions ▸`: each row carries `ears sessions`' outcome glyph and any
  attribution warnings, with `Open Summary`, `Open Transcript` and `Show in Finder`
  (disabled until the artifact exists).
- `Daemon ▸`: version and uptime, `Restart Daemon`, `Open Logs`, `Open Data Folder`.
- `Launch at Login` (`SMAppService`, saying when approval is needed or registration
  failed), `Quit`.

**Notifications** — results and failures only, in the system's default banner style:

- A summarize job reaches `done`: *"Summary ready — Weekly sync"*; a click opens the
  file the daemon reported writing (`job.outputs`), falling back to the scanner if it
  has moved.
- Any stage reaches `failed`: *"Transcription failed — Weekly sync"*; a click reveals
  the session folder.
- An unexpected daemon disconnect while a session is live warns once per at-risk
  session, not once per drop — a crash-looping daemon reconnects between crashes.
- Quiet: session start/end/pause/resume — the user did those themselves.
- A denied grant makes macOS accept and silently drop every post. The prompt is
  one-shot, so the app re-reads the grant each time the menu opens and carries a menu
  warning with a shortcut to the Notifications settings pane.

## Daemon support the app relies on

Each is additive and useful to any client:

- `job.publish` events for `cleanup` and `summarize`, carrying the paths written in
  `outputs`, so "summary ready" is knowable and openable.
- `session.start`'s optional `on_end_stages`: the starter declares the chain. The app
  declares the configured chain; `ears session start` declares nothing and stays inert.
- `status.configured`: the capturable configured sources and the resolved chain.
- The shared session scanner in `EarsDataStore`, with summary paths and a lighter
  depth for list views.

## Packaging

`make menubar`: build, assemble `All Ears.app` (`Info.plist` with `LSUIElement`, bundle
id `net.tomelliot.ears.menubar`, an icon rendered from `docs/brand/exports`), codesign
with the identity `make install` resolves, install to `~/Applications`, relaunch.
Upstream it is opt-in; this fork's `make install` also runs `make menubar`. `make
uninstall` removes it.
Signed-and-notarized distribution remains a suite-wide non-goal for now.

## Testing

- **Tier 0** (`EarsMenuKitTests`, swift-testing): reducer over snapshot/event
  sequences, including rev-gap → resubscribe and the reconnect reset; the renderer per
  state; notification policy with the quiet cases asserted; start-recording refusals.
- **Tier 1**: the on-end chain smoke tests assert job events (with `outputs`) arrive on
  a subscribed socket, a declared manual chain runs, and the shared scanner finds
  exactly what the chain wrote.
- **Tier 2** (manual): start / pause / rename / end; a summary notification that opens
  its file; a failure notification; restarting the daemon while recording (the at-risk
  notice fires once); Launch at Login, signed and ad-hoc; the notifications-denied
  warning.
