# Native meeting detection — design

**Date:** 2026-08-17
**Status:** Approved design, pre-implementation

## Problem

The browser extension makes Google Meet effortless: it starts the session,
names it, feeds the roster, and ends it. Meetings in the **native** Zoom and
Teams apps get none of that. The capture substrate already handles them —
`app:<bundle-id>` process-tap sources work today — but the user must notice
the meeting, start a session by hand, and remember to end it, and the
transcript labels remote speech with the raw source id (`app:us.zoom.xos`).

## Decisions taken

| Question | Decision |
| --- | --- |
| Trigger model | **Prompt on detection** — never record without an explicit yes; calendar only enriches. |
| Meeting-end behavior | **Auto-end after a grace period**, mirroring browser `ingest-idle`. |
| Calendar source | **EventKit** (macOS Calendar), in the same effort. No Google API. |
| Where detection lives | **Daemon detects, menu bar decides.** Detection and auto-end in `earsd`; prompt UX and calendar enrichment in `ears-menubar`. |

## Goals

- A Zoom/Teams native meeting produces one notification click → a fully
  configured session (title, attendees, mic + app source, on-end pipeline).
- The session ends itself when the meeting does.
- Remote speech is labelled with the source's human label ("Zoom"), not its id.
- Detection is config-driven: any capturable `[[earsd.source]]` of class
  `app:*` is watched — nothing is hardcoded to Zoom or Teams.

## Non-goals

- Within-stream diarization, or mapping calendar attendees to voices. All
  remote participants share one mixed app stream; calendar attendees enrich
  the roster and summaries only.
- Auto-start without a prompt.
- Google Calendar API / OAuth.
- Zoom or Teams SDK integration; window scraping of native apps.

## Daemon

### Detection: `EarsCaptureKit` probe + `EarsDaemonKit` orchestration

As built, this splits across the package boundary the same way every other
hardware seam does — only `EarsCaptureKit` may touch Core Audio, so the
polling/orchestration actor cannot live where it touches the HAL directly:

- **`EarsCaptureKit`** — `AppAudioActivityProbing` is the protocol seam
  (mirroring the existing hardware seams); `CoreAudioAppActivityProbe` is its
  one production conformance. It listens to the CoreAudio HAL **process
  objects'** input-running property — "this app is currently using the
  microphone" — by enumerating `kAudioHardwarePropertyProcessObjectList` and
  reading each object's bundle id and `kAudioProcessPropertyIsRunningInput`
  directly, no PID resolution needed. This is the same HAL layer
  `ProcessTapEngine` already uses; reading it needs no new TCC grant.
  `MeetingEpisodeTracker`, also here, is the pure, clock-injected debounce
  state machine that turns raw per-poll samples into **activity episodes**
  with stable daemon-generated ids: `began(source, episode)` / `ended(source)`.
- **`EarsDaemonKit`** — `MeetingActivityMonitor` is the polling orchestration
  actor, shaped like the existing `EvictionSweeper` pattern (own poll loop,
  injected clock/sleep): on each ~1s tick it calls the probe for every
  watched bundle id, feeds the samples through the tracker, and publishes
  confirmed edges. It never touches Core Audio itself.

The episode/debounce state machine is pure, clock-injected, tier-0 TDD.
Only the HAL property listener is a shim.

Watched set: every capturable config source of class `app:*`
(`EarsCore/Config/CaptureSourceEntry.swift`). The monitor reports truth
unconditionally; prompting policy is entirely client-side.

### Control plane

- New subscribable event **`meeting.activity`**: `source`, `bundle_id`,
  `label`, `active`, `episode`. Added to the subscribe event kinds; carried
  under the `observe` capability on both transports.
- The `status` response gains a snapshot of current activity, so a freshly
  launched client catches up without waiting for an edge.

### Trigger kind `app-detected`

Third `TriggerKind` case (`EarsCore/Models/TriggerKind.swift`) alongside
`manual` and `browser-extension`. Two policies key off it:

- **On-end chain** (`EarsDaemonKit/OnEndChainPolicy.swift`): `app-detected`
  inherits the configured chain, like `browser-extension`. The menu bar app
  stops declaring stages for these sessions.
- **Auto-end** (`EarsDaemonKit/SessionRegistry.swift`): when *all* of an
  `app-detected` session's `app:*` sources have been inactive continuously
  for `idle_grace_s`, the registry ends the session with a new
  `EndReason.appIdle` (`app-idle` on disk) and the on-end chain runs. Brief
  drops and rejoins inside the grace window keep the session alive.
  `manual` sessions remain never-auto-ended; browser behavior is unchanged.

### Config (`[earsd.detection]`, schema'd)

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch for the monitor and event. |
| `debounce_s` | `2` | Raw flap suppression before an episode edge is reported. |
| `idle_grace_s` | `90` | Continuous inactivity before an `app-detected` session auto-ends. |

## Menu bar app

### Prompt

`ears-menubar` subscribes to `meeting.activity`. When an episode begins and
no session is live, it posts a macOS notification via the existing
`SessionNotifications` infrastructure — *"Zoom meeting detected — Start
recording?"* with a Start action — and shows the same offer as a menu row.

Prompt policy is pure logic in `EarsMenuKit` (tier-0 tested), keyed on the
daemon's episode id:

- Episodes that begin while any session is active are dropped, not deferred —
  no prompt fires later for them. (Manual start from the menu remains
  available as always.)
- Never re-prompt for an episode already prompted, accepted, or dismissed
  (episode ids survive menu bar restarts).
- Clear the offer when the episode ends.

### Calendar enrichment (EventKit)

- EventKit fetch is a thin shim in the `ears-menubar` target; **event
  matching is pure logic in `EarsMenuKit`**: given fetched events and "now",
  pick an event overlapping now (with slack for early joins and late
  starts), preferring one whose location/notes/URL carries a platform marker
  (`zoom.us`, `teams.microsoft` — matched as a substring, so it also catches
  `teams.microsoft.com`), else the nearest ongoing event, else none.
- Calendar access is requested **lazily on first prompt accept**.
  `NSCalendarsFullAccessUsageDescription` is added to
  `packaging/ears-menubar.Info.plist`. Denied access or no matching event
  degrades gracefully: the session starts unenriched. Calendar is a garnish,
  never a gate.

### Session start on accept

`session.start` with:

- `trigger: app-detected`
- `platform`: well-known slug for recognized bundles (`us.zoom.xos` →
  `zoom-app`, Teams → `teams-app`), else the bundle id.
- `external_id`: the episode id — makes the start **idempotent**; a menu bar
  restart or double-click cannot create a duplicate session.
- `sources`: `mic` + the detected `app:*` source, declared explicitly.

No `title` at start time: the calendar fetch that would produce one runs
*after* `session.start` succeeds, so a first-run calendar-access permission
dialog can never delay the capture the user just asked for. When a matching
event has a non-empty title, it is applied via a `session.rename` sent
immediately after start — the daemon's title precedence
(`docs/specs/capture-daemon.md`) treats a rename exactly like a start-time
title, so this changes the title away from the default the same way passing
it at start would have. Then `session.attendee` upserts follow for each
calendar attendee:

- `display_name` from the event; new **`origin: calendar`**.
- The user (EventKit marks the current user's attendee): `self: true`, with
  **no source binding** — binding `mic` would rename the transcript's "You"
  turns to the user's own name via the reconciled speaker map.
- All other attendees: **no source binding** — their voices share the mixed
  app stream. They enrich the roster and downstream summaries only.

## Transcript labels (independent fix)

`transcribe`'s `TranscriptAssembly.speakerLabel` currently renders raw
source ids for anything but `mic`. Fix: `transcribe` reads each source
descriptor's `meta.toml` `label` and passes it as a fallback map. Precedence
becomes: reconciled `[[speaker]]` name → `mic` → "You" → descriptor label
("Zoom") → raw id. Pure, test-first, and improves today's manual app
sessions immediately.

## Documentation updates (contracts move with the code)

- `docs/data-formats.md`: trigger value `app-detected`, end reason
  `app-idle`, attendee origin `calendar`.
- `docs/configuration.md`: `[earsd.detection]`.
- `docs/architecture.md`: the activity monitor component and event.
- `docs/specs/capture-daemon.md`: auto-end semantics for `app-detected`.
- `docs/overview.md`: adjust the "not built yet" list.

## Testing

- **Tier 0 (TDD, clock-injected):** episode debounce/grace state machine;
  registry auto-end decision; prompt policy; calendar event matching;
  speaker-label fallback.
- **Tier 1 (tool vs fixtures / sockets):** `meeting.activity` and status
  snapshot over a real socket with a synthetic backend; `app-detected`
  descriptor round-trip through `SessionDescriptorTOML`; auto-end
  end-to-end via the registry with a fake monitor.
- **Tier 2 (shims, relaxed):** HAL property listener; EventKit fetch. A
  live opt-in test (env-gated like `EARS_LIVE_SYSTEM_AUDIO_TEST`) verifies
  real mic-use detection against a running app.

## Build order (each milestone independently shippable)

1. **Speaker-label fallback** in `transcribe`.
2. **Daemon detection**: monitor, `meeting.activity` + status snapshot,
   `app-detected` trigger, auto-end, `[earsd.detection]`.
3. **Menu bar prompt**: subscription, notification + menu offer, prompt
   policy, session start with episode identity.
4. **Calendar enrichment**: EventKit shim, matching logic, title +
   attendee upserts, lazy permission.

## Risks

- The HAL input-running property is the load-bearing signal; if a platform
  app reports it oddly (e.g. holds the mic open while idle in a waiting
  room), debounce/grace tuning is the lever. The live opt-in test exists to
  validate the signal per app.
- One-active-session invariant: the prompt is suppressed while a session is
  live, so detection never supersedes a hand-started session.
