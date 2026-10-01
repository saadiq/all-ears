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
  the reducer. (This fork subscribes to `["job", "meeting.activity"]` — see
  [Fork layer](#fork-layer-saadiqall-ears-only).) It reconnects with backoff; a generation counter retires stale loops. A
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

## Fork layer (saadiq/all-ears only)

This fork adds native-meeting detection and calendar enrichment on top of stage 1. The
daemon does the detecting ([`[earsd.detection]`](../superpowers/specs/2026-08-17-native-meeting-detection-design.md),
`meeting.activity` telemetry, auto-end); the app offers, prompts, starts and enriches.
It lives in its own types beside the stack's, so `MenuState`, the reducer, the renderer,
`Verb`, `NotificationPolicy` and `StartRecording` are untouched.

**Menu offer row.** While connected with no active or paused session, one row per active
meeting, in `meeting_activity` order, above the plain verbs: `Start Recording ‘<label>’
Meeting` (`<label>` is the source's descriptor label, else its id). Plain `Start
Recording` still follows.

**Prompt notification.** On the daemon's confirmed active edge (`debounce_s` plus the
monitor's 1s poll): title `<label> meeting detected`, body `Start recording?`, sound, in
category `meeting-detected` with buttons `start-recording` ("Start Recording") and
`not-now` ("Not Now"), neither `.foreground`. Its id is `meeting-detected:<source>` —
per source, so a newer episode for the same app replaces the alert instead of stacking.
Only a body click or Start accepts; Not Now, a system dismiss and anything unknown are
ignored. Each episode is prompted at most once. A live session withdraws every standing
prompt and drops (marks prompted) every active episode; an episode merely going inactive
withdraws nothing, because Zoom releases and retakes the mic ~17s after joining and
withdrawing on that edge cancelled prompts before anyone could answer. Prompts are
re-evaluated on each `meeting.activity` frame, whenever a session goes live or stops being
live (so accepting one offer withdraws the rest once that session's frame arrives), and
after the connect catch-up.

**Alert style.** `NSUserNotificationAlertStyle = alert`, so a prompt waits to be
answered. It is app-wide (summary and at-risk notices wait too) and macOS reads it only
at first registration.

**Prompt history.** UserDefaults `promptedMeetingEpisodes` (≤50, oldest evicted) and
`promptedMeetingEpisodesBootID`. Episode ids restart with each daemon boot, so the
history is reset whenever `hello`'s `boot_id` changes — before any catch-up can prompt.

**Catch-up.** A connect clears activity; the one `status` call that anchors uptime
refills `meeting_activity` unless a live edge or reconnect landed while it was in
flight (an edit-mark compare).

**Accept** (row or prompt): withdraw that source's prompt and mark the episode; if a
session is live, stop silently. Otherwise `status`, then `session.start` with `trigger:
app-detected`, `platform` from `KnownMeetingApp` (`zoom-app`, `teams-app`, `slack-app`,
`facetime-app`, else the bundle id), `external_id` = the episode, `sources` = `mic` if
`status.configured` lists it, then the app source; no `title`, no `on_end_stages` (the
daemon's `OnEndChainPolicy` runs the configured chain). Refused if the daemon is too old
or no longer captures the app source. Failures land on the menu's `⚠` line.

**Calendar enrichment**, only after a successful start, so the first-run permission
dialog never delays capture: `requestFullAccessToEvents` lazily, events from now − 4h to
now + 2h. `CalendarMatching.best` drops all-day rows, takes events overlapping now (600s
early-join slack), prefers one carrying the platform's link marker, then the nearest
start, then title. Then `session.rename` to its title (if any) and one `session.attendee`
per attendee: id `calendar-<i>`, origin `calendar`, `self` only for the current user, no
source binding. The first failure is reported and stops the rest. Denied access or no
match leaves the session unenriched, silently. `Info.plist` carries
`NSCalendarsFullAccessUsageDescription`; without it macOS terminates the app on the
access request.

**Code.** `EarsMenuKit` (tier 0, tested): `MeetingActivityReducer`, `MeetingOffers`,
`MeetingPromptPolicy`, `MeetingPromptResponse`, `DetectedSessionStart`,
`CalendarEnrichment`, `PromptedEpisodes`, plus `KnownMeetingApp`, `CalendarMatching` and
`PromptedEpisodePolicy`. `ears-menubar` shims: `DetectedMeetings` (the observable slice
`AppModel` hooks into), `DetectedMeetingControls`, `CalendarProvider` (all EventKit),
`PromptedEpisodeStore`. `Notifier` has generic hooks — category registration with a
response handler, stable ids, withdrawal — shared with `SessionNotifications`.

**Tier 2** (manual): join a call → alert and menu row; Not Now → no re-prompt; leave and
rejoin → the prompt replaces, not stacks; Start → mic + app source, `app-detected`,
calendar title and attendees applied; auto-end after the call, then the summary notice;
relaunch the app mid-call → no re-prompt; restart the daemon → a new prompt; deny
calendar access → unenriched, no error.
