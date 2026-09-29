# Upstreaming the menu bar app — design

**Date:** 2026-09-29
**Status:** Approved design, pre-plan

## Goal

Put `saadiq/all-ears` in a position to submit the menu bar app (`ears-menubar`)
to `tomelliot/all-ears` as a series of PRs that upstream can take without
much debate. Every daemon change stands on its own merits, and the app ends up
a thin client of the daemon and the on-disk store.

Success means:

- each PR builds on `upstream/main` plus the PRs before it, and passes
  `swift format lint --strict`, `swift build` and `swift test` on its own;
- `make install`, `ears session start` and every existing wire exchange behave
  exactly as they do upstream today unless a client opts in;
- the fork keeps every feature it has now (detection, calendar enrichment),
  layered on top of the upstreamed shape instead of beside it.

## Context

As of 2026-09-29 the fork is level with `upstream/main` and 154 commits ahead:
141 files, +12,960/−573. About 5k of those lines are fork-only process
docs (`CLAUDE.md`, `docs/superpowers/*`). The rest is three separate efforts:

1. the menu bar app, plus the daemon changes it needs;
2. native meeting detection and calendar enrichment;
3. about a dozen capture/transcribe fixes that don't depend on either.

Upstream consolidated its session model in #42/#49. That work deleted
app-signal triggers and listed the deletion under "decisions already made (do
not relitigate)", with the rule "sessions are started deliberately." Detection
only starts a session after the user accepts a prompt, so it arguably respects
that rule. It is still a new daemon subsystem, though, so it is **not** part of
this series.

## Decisions

| Question | Decision |
| --- | --- |
| Scope | The menu bar app, stage 1, **without** detection or calendar. |
| How to build it | Fresh branches off `upstream/main` as a linear stack. Cherry-pick where the design is unchanged; rewrite where it changes. |
| Who knows the manual-session defaults | The daemon, reported in `status`. The app never parses daemon config. |
| Reading sessions back from disk | One scanner, shared by `ears` and the app. |
| `make install` | Unchanged. The app is opt-in via `make menubar`. |
| Fork `main` | Rebuilt as the stack plus a fork layer; the old `main` is tagged first. Needs explicit approval, because it means a force-push. |
| Anything outward-facing | No push, issue or PR upstream without the user's go-ahead. |

## The series

### Phase 0 — independent fixes (a parallel track that blocks nothing)

Each one is its own small PR off `upstream/main`, ported from the fork with any
detection-only callers removed:

- **Capture — a silent app tap is not a TCC denial** (`faef4a4`).
- **Capture failure made visible** (`59d437a`, `014f122`): `earsd` records
  `capture_failed` when a source fails to start, and `transcribe` warns in the
  transcript.
- **App PIDs resolved through the HAL when NSWorkspace can't** (`1d36be3`,
  `215f5b3`). `HALObjects` is ported with its non-detection user
  (`AudioInputDeviceSelection`) only; the `AppAudioActivityProbe` half stays
  in the fork layer.
- **Transcript speaker labels fall back to the source's `meta.toml` label**
  (`a7c0efd`, `a68a710`, `1acd3f1`, `a26ebbf`).

### W1 — job events for the on-end LLM stages

Today only `transcribe` reports itself over `job.publish`, so "summary ready"
can't be known by any subscriber.

- `OnClosePipelineRunner` publishes `job.publish` for `cleanup` and
  `summarize` (`started` / `done` / `failed`). `transcribe`'s own reporting is
  left alone.
- `JobPublishParams` gains optional `outputs: [String]` (absolute paths),
  which the runner fills on `done` from the stages' `--json` results. It's
  additive, and omitted when empty, so existing frames stay byte-identical.
- The same PR folds in the fork's two runner fixes: a failed job is published
  when `transcribe` dies before it can report itself (`c7894c8`) or exits 0
  with an unusable result (`73acc85`).
- Docs: the `job.publish` row in `control-protocol.md`, and the golden
  fixtures in `shared/protocol-fixtures/`.

### W2 — each session declares its own on-end chain

- `session.start` takes an optional `on_end_stages`, which has three states:
  - **omitted:** the per-trigger default, which is unchanged
    (`browser-extension` inherits `[earsd.sessions] on_end_stages`; every other
    trigger runs nothing);
  - **`[]`:** run nothing;
  - **a list:** run exactly those stages.
- The declaration is persisted in `session.toml` and honoured if the start is
  repeated. A declared chain runs exactly as given or the call is refused:
  any unknown name, or an LLM stage without `transcribe`, fails
  `session.start` with `invalid_request`. (A config default is still resolved
  leniently: dropped entries are logged at boot.)
- `OnEndChainPolicy` (pure, `EarsCore`) is the single decision point, and the
  read side uses it too.
- CLI: `ears session start --on-end-stage <stage>` (repeatable) and
  `--no-on-end`.
- `ears sessions` and `ears session show` judge outcomes against the chain the
  session declared, so a stage that was never requested isn't shown as missing.
- Ported from `ef46923`, `bf28327`, `8fb5f73`, `0cb002a`, `88e0d0f`,
  `115cdbb`, `6c3a8c4` and their tests and docs, minus every
  `app-detected` reference.

### W3 — `status` reports what the daemon is configured with

`StatusData` gains `configured`:

```json
"configured": {
  "sources": ["mic", "system"],
  "on_end_stages": ["transcribe", "cleanup", "summarize"]
}
```

- `sources`: the ids of the capturable config-declared sources, in
  declaration order. This is the list `DaemonConfigResolution` already
  produces, kept in order on the daemon.
- `on_end_stages`: the resolved `[earsd.sessions] on_end_stages` chain.
- It's additive, and decoded with `decodeIfPresent`, so older payloads still
  decode. The docs and golden fixtures are updated.

This is what lets the app state its defaults without reading daemon config.
The daemon is the authority, so a config that was edited but not yet loaded
can't make the app ask for sources the running daemon will silently skip. The
fork's `CaptureSourceEntry` / `ManualSessionSources` / `ManualSessionStages`
are not ported.

### R1 — one session scanner

`ears`'s `SessionArtifactScanner` and `ScanEnvironment` move out of the `ears`
executable into `EarsDataStore`, so `ears` and the app share one
implementation of "what happened to session X".

- **Move with no behaviour change first:** `ears` output stays byte-identical
  and its tests move with the code.
- **Then two additive changes:**
  - `SessionArtifacts` gains `summaryPaths: [String]`. `summaryCount` stays,
    so `--json` views don't change.
  - A lighter scan skips source-directory sizing and attribution parsing for
    list views. Both `ears sessions` and the app's Recent Sessions use it.
- The app's sibling-summary match is stricter: a longer stem that shares the
  prefix doesn't count. It's adopted as its own `fix(ears)` commit, with a
  regression test.

### App — `ears-menubar` stage 1

**Targets** (unchanged from the fork): `EarsMenuKit` (pure library) and
`ears-menubar` (SwiftUI shell). Both are SwiftPM, with no Xcode project.

**`EarsMenuKit`** is pure, no I/O, and TDD:

- `MenuState` and `MenuStateReducer`:
  - applies the subscribe snapshot, then events numbered by `rev` (a gap
    triggers a resubscribe), then job telemetry;
  - drops non-failed jobs on every resubscribe.
- `MenuRenderer`: `MenuState` → `MenuContent`, i.e. the icon variant, the
  header (with any failed sources), the verbs and the pipeline rows.
- `NotificationPolicy`: turns state transitions into notification decisions.
  It covers summary ready, stage failed, and a recording at risk (announced
  once per session). The cases that stay quiet are part of the contract.
- Small helpers: `NotificationAvailability`, `DaemonUptime`,
  `ElapsedFormatter`, `ReconnectBackoff`, `RecentsRefreshPolicy`,
  `RecentSessions.select`.
- Not ported:
  - config readers: `PublishingSettings`, `SessionArtifactLocator`,
    `ConfiguredOnEndChain`, `ConfiguredEmptiness`, `ManualSession*`;
  - everything about detection and calendar.

**`ears-menubar`** is thin, and `@MainActor` only where it's UI:

- `MenuBarApp`: the `MenuBarExtra` scene. It keeps the
  `NSMenu.didBeginTracking` observation as the per-open refresh hook.
- `AppModel`: observable state only (menu state, rendered content, recents,
  the last action error, notification availability). It composes the types
  below and doesn't extend itself across files.
- `DaemonConnection`: the fork's actor as it is, with the generation counter,
  closing sockets that were dialled but never adopted, and a silent bounce.
- `SessionControls`: the verbs. Start Recording calls `status` and then
  `session.start(sources: configured.sources, on_end_stages:
  configured.on_end_stages)`, with no title (the daemon names it). The other
  verbs are Pause, Resume, Rename… and End. Every failure is surfaced in the
  menu and logged.
- `RecentsStore`: the last 7 ended sessions, using the shared scanner's
  lighter mode. It refreshes when the menu opens and on relevant events.
- `Notifier`: the `UNUserNotificationCenter` adapter.
  - "Summary ready" opens `outputs.first` from the event, falling back to the
    scanner.
  - "Stage failed" reveals the session folder.
  - It re-checks the grant each time the menu opens.
  - Style: the system default (banner). The "stay until dismissed" alert
    style belongs to the detection prompt, so it stays in the fork layer.
- `SystemActions`: restart via `launchctl kickstart`, open logs and folders,
  and open the Settings panes.
- Views: `MenuContentView`, `RenamePrompt`, `LaunchAtLoginToggle` (which says
  when approval is needed or registration failed).
- Config: only enough to find the socket and build the scan environment,
  through the same loader `ears` uses.

**Features:** the same as fork stage 1 without detection:

- icon variants: idle, recording, paused, busy, attention;
- the header;
- verbs, shown by state;
- pipeline rows with Dismiss;
- Recent Sessions (outcome glyph, warnings, Open Summary, Open Transcript,
  Show in Finder);
- the Daemon submenu (version and uptime, Restart, Open Logs, Open Data
  Folder);
- the notifications-denied warning;
- Launch at Login;
- Quit.

**Code style:**

- Match upstream's comment density.
- Comments explain *why*; history ("an earlier version…", "that was tried")
  goes in commit messages.
- Honour the 300-line file / 100-line function limits by splitting on real
  responsibilities, never by making members less private.
- The `hello` client string takes the bundle's version, not a literal.

### Packaging and docs

- **`make menubar`:** assemble `All Ears.app`, then:
  - `Info.plist`: `LSUIElement`, bundle id `net.tomelliot.ears.menubar`, no
    calendar key, no alert style;
  - an icon rendered from `docs/brand/exports`;
  - codesign through the shared `RESOLVE_IDENTITY` macro;
  - install to `~/Applications`, then relaunch without ever failing the
    target.
- `make install` stays unchanged; `make uninstall` also removes the app if
  it's present.
- **Docs updated in the PR that changes the behaviour:**
  - W1–W3: `control-protocol.md`;
  - W2: `data-formats.md`, `capture-daemon.md`, `configuration.md`;
  - the app: `architecture.md`, `overview.md`, `distribution.md`, `README.md`,
    and `docs/plans/menubar-app.md`, rewritten to this design.
- `CLAUDE.md` and `docs/superpowers/*` are never part of an upstream PR.

## Fork convergence

After the stack is built and green:

1. Tag the current `main` `fork-main-pre-upstreaming`.
2. Build the new fork `main` as the stack plus a **fork layer**. The layer
   holds everything upstream won't get from this series:
   - **detection (daemon side):** `MeetingActivityMonitor`, the probe and its
     HAL fixes, `meeting.activity`, the `app-detected` trigger, auto-end,
     `[earsd.detection]`;
   - **detection and calendar in the app**, hooked into `AppModel` /
     `SessionControls` / `Notifier` as their own types;
   - **fork-only UI and reconciler bits:** the alert style, the known
     meeting-apps table (Slack, FaceTime), the calendar attendee origin and
     the reconciler warning fix that goes with it, and the status dashboard's
     meeting labels;
   - **fork-only docs:** `CLAUDE.md` and `docs/superpowers/*`.
3. The fork layer uses W3 as well, so detection's watched set comes from the
   daemon's own resolution.
4. Replacing `main` needs the user's explicit approval (a force-push to
   `origin`). The fallback is a merge that resolves conflicts toward the stack.

Until then, fork `main` stays as it is and daily use isn't affected.

## Testing

- **Unit tests, TDD, clock injected:** reducer sequences (including a rev gap
  → resubscribe, and the reset on reconnect), the renderer for each state, the
  notification rules (quiet cases asserted), `OnEndChainPolicy`, `StatusData`
  and `JobPublishParams` coding, and the scanner's lighter mode and
  `summaryPaths`.
- **Tool vs. fixtures and real sockets:**
  - W1: cleanup/summarize events, with `outputs`, reach a subscribed socket.
  - W2: a declared chain runs; `[]` and omitted behave as specified; the
    declaration survives a repeated start.
  - W3: `status.configured` over a real socket with a synthetic backend.
  - The golden fixtures round-trip.
  - `ears` output is unchanged across the R1 move.
- **The shell (manual checklist in the app PR):**
  - start / pause / rename / end;
  - a summary notification that opens its file;
  - a failure notification;
  - restart the daemon while recording (the at-risk notice fires once);
  - Launch at Login, both signed and ad-hoc;
  - the notifications-denied warning.

## Out of scope

- Native meeting detection and calendar enrichment. They are the fork layer
  now and may become a later, separate upstream proposal.
- A stage-2 dashboard window.
- Signed or notarized distribution, and registering the daemon with
  `SMAppService`.
- Browser extension changes.

## Risks

- **Upstream moves during the series.** Keep the stack rebased on
  `upstream/main`, and re-run the full suite after each rebase.
- **W3's field name or shape is the maintainer's call.** It's small and
  additive, so it's easy to rename in review. The app depends on it in only
  one call.
- **The R1 move touches `ears` output.** The move commit must leave every
  `ears` output unchanged; the smoke tests guard that.
