# Attribution refactor — proposal

Status: **implemented, 2026-08-13** — all ten items (R1–R10) landed on
`claude/all-ears-speaker-id-arch-3rvnee` (PR #83).
Prepared 2026-08-13 on top of `wip/roster-reconciliation-and-notes` (HEAD `8441937`).

The journal check requested below was performed before R3 landed: the journal
DB exists locally (it is gitignored, hence unreadable from a fresh worktree);
entry #171 refutes the decoder-pool hypothesis and concludes per-source
attribution is structurally sound, and #174's manual repair procedure is the
procedure R3/R5 automate. No entry in 142–175 refutes the late-naming design.
Deliberately deferred at implementation time: the first-binding-wins refusal
rule stays in the identity engine (relaxing it needs a designed threshold; a
rebind is now only a metadata hint), and the live ground-truth re-runs remain
operator-owned.

## Evidence base, and one honest gap

This proposal is grounded in: the code on this branch (file:line citations
throughout were checked against the working tree); `docs/architecture.md`,
`docs/data-formats.md`, `docs/engineering-practices.md`, the browser specs
(`docs/specs/browser/extension.md`, `transport.md`); the full git history
(149 commits, 2026-07-21 → 2026-08-13 — the repo's whole life); and
`test/ground-truth/` including `FINDINGS.md`.

**The engineering journal (`docs/journal/journal.db`) is gitignored
(`docs/**/journal.db`) and does not exist in this clone or anywhere in git
history.** It could not be read. Journal entry numbers cited below (#31, #73,
#93, #105, #142, #158, #171, #172, …) are quoted *as cited in code comments and
specs*, which turn out to carry a lot of the journal's conclusions verbatim.
Two consequences:

- Where a code comment says "journal #X established Y", I treated the comment
  as the record. Where code and comment disagree, the disagreement is flagged.
- **Entries #170/#171 (per-source vs per-turn attribution) could not be read
  directly.** The only #171 content visible in the repo is the comment at
  `browser/lib/audio-tap.ts:318-324` (inert-but-unmuted webaudio tracks).
  Section "Per-source vs per-turn" below is therefore reasoned from code and
  marked as inference where it goes beyond that comment. If the journal
  refutes any approach proposed here, that refutation wins — please check
  items R3 and the per-source/per-turn section against entries 142–175 before
  approving.

---

## Diagnosis: where the attribution decision lives today

The end-to-end path, as it actually exists:

1. **Track appears** — `rtc-hook.ts` wraps `RTCPeerConnection` and dispatches
   audio tracks (`dispatchTrack`, `rtc-hook.ts:97-109`), records provenance
   (`installProvenanceWraps`, `rtc-hook.ts:1060-1153`), and registers WebAudio
   tracks Meet mints (`registerWebAudioTrack`, `rtc-hook.ts:894-903`).
2. **Admission** — pure policy in `capture-seams.ts` (`admitReceiverTrack`,
   `seamTracksToAdopt/Retire`, `SeamArbiter`), driven imperatively from
   `audio-tap.ts` (`sink`, `adoptSeamTracks`, `escalateSeam`, the 3 s
   `reconcile()` sweep).
3. **Identity minted** — `identityFor` (`audio-tap.ts:614-624`): the platform
   adapter's `identify()` (Zoom MSID parse; Meet tile-DOM, usually null;
   Teams always null) or a synthetic fallback (`speaker-<n>`,
   `webaudio-track-<n>`).
4. **Identity upgraded** — Meet only: three `SpeakingCorrelator` instances plus
   binding maps inside `MeetAdapter` (`meet.ts:408-458`) pair device-id
   speaking evidence (collections datachannel edges, DOM speaking-ring bursts)
   with decoded-audio onsets; a confirmed match **restarts the pipeline** under
   the device id (`handleIdentityUpgrade`, `audio-tap.ts:258-283`) or, for
   dead/non-restartable tracks, sends `participant-renamed`
   (`audio-tap.ts:292-298`).
5. **To the daemon** — the participant id is baked into the earsd source label
   `browser:<platform>:<participant>` at `ingest.open` (`transport.ts:274-287`);
   names ride separately as `session.attendee` upserts
   (`session-tracker.ts:290-378`).
6. **On disk** — `session.toml` keeps the observed roster (`[[attendee]]`)
   and, since this branch, the derived map (`[[speaker]]`), reconciled at
   `session.end` by the pure `RosterReconciler`
   (`daemon/Sources/EarsCore/Session/RosterReconciler.swift`).
7. **Transcript** — `TranscribePipeline.swift:463-490` flattens the reconciled
   map to `[source-id: name]`; `TranscriptAssembly.swift:33-45` resolves labels
   and merges turns by resolved name.

So it is **one pipeline in intent but three overlapping deciders in
practice**: the browser decides live (admission + binding, in `audio-tap.ts`
orchestration + `MeetAdapter` state), the daemon re-decides at session end
(`RosterReconciler`), and transcribe re-decides once more only if the stored
map is empty (`TranscribePipeline.swift:478`). The browser's live decision is
authoritative in the worst way: it names the *source id* the audio is recorded
under, which the daemon can override in `[[speaker]]` but never un-record.

### What is actually wrong (five findings)

**F1 — The browser's decision layer is the one untested layer, and it is where
every recurring bug lived.** The leaf logic is pure and well tested
(`capture-seams.ts` policy, `SpeakingCorrelator`, `SpeakingBurstDetector`,
`meet-collections` parser, all the DOM extractors via `ElementLike` fakes).
But the layer that composes them — `audio-tap.ts`'s module-level imperative
core (`initCapture`, `sink`, `startPipeline`, `identityFor`,
`handleIdentityUpgrade`, `adoptSeamTracks`, `escalateSeam`, `reconcile`) and
`MeetAdapter`'s binding state (`upgradedTracks`, `deviceOwners`,
`localDeviceId`, three correlators) — has **no tests at all** for the
orchestration, and `MeetAdapter` reads `Date.now()` internally in three of its
four event entry points (`meet.ts:523,573,582`), which blocks replaying the
exact interleavings the #158-class bugs came from. Every fix-after-fix cluster
in the history (Meet naming drift Jul 23–24; graph probing Jul 28–30;
local-user double-capture Aug 5–6; correlator rebinding Aug 11–12) landed in
exactly this layer.

**F2 — Identity is entangled with the source id, so a binding mistake is a
recording mistake.** Because the participant id is baked into
`browser:<platform>:<participant>` at open time, a binding change mid-call
must restart the capture pipeline (losing frames,
`audio-tap.ts:248-251`), splits one human's audio across several source
directories, mints roster noise (`left` stamps for people who never left,
`audio-tap.ts:556-563`), and forced the first-binding-wins permanence rule
(`meet.ts:604-614`) — a wrong name that survives the guards is wrong for the
rest of the call *by design*, because rebinding was worse (the 86-rebind call,
`meet-correlator.ts:20-27`). The roster/speaker-map split on this branch
already concedes the point: `docs/data-formats.md:260-273` says the derived
binding is a guess and `session.speakers` — not the source id — is what
transcription labels turns from (`Session.swift:32-39`). The source id still
carrying an identity guess is the unfinished half of that thought.

**F3 — Failures are only observable live.** The evidence the correlators
consume (collections edges, DOM bursts, audio onsets, track mute/unmute
timings, provenance) is consumed transiently and mostly discarded. What
survives a call today: debug-gated `__earsAudioLog` (in-page, lost on
navigation unless exported), the IndexedDB perf ring (histograms and graph
topology, not identity evidence), console-tap logs (prose), and the final
`session.toml` (conclusions, not evidence). None of it can be fed back into
the code to reproduce a decision. Diagnosing #158 took a live call with real
people; so will the next one, unless the evidence is recorded.

**F4 — The daemon trusts, then over-corrects blindly.** `session.attendee`
upserts are applied with no provenance: a synthetic `speaker-<n>` row is
indistinguishable from a platform-observed roster row once on disk. That is
precisely why phantom rows poison `RosterReconciler`'s counting invariant
(a junk named row raises `remoteNames.count` above 1 and blocks the
one-remote inference, `RosterReconciler.swift:167-176`), why the `self` latch
is irreversible (`SessionRegistry.swift:463-466`), and why two attendees
bound to one source silently last-write-win in transcribe's dictionary
(`TranscribePipeline.swift:487-490`). And a wrong-but-non-empty stored
`[[speaker]]` map is never re-derived (`TranscribePipeline.swift:478`), so a
reconciler bug fix does not repair past sessions.

**F5 — The two languages disagree about names for the same concepts.**
Documented drift found: browser "participant" = daemon "attendee";
`ParticipantId` is an untyped union of a Meet device path, a Zoom node id,
and three synthetic shapes; Meet code calls that same value `deviceId`
(`meet-correlator.ts:105`) while `capture-seams.ts:227-231` documents
`MediaStreamTrack.getSettings().deviceId` as a different, useless thing;
"source" has four meanings in the browser (earsd label, `FrameSource`,
`MediaStreamAudioSourceNode`, attendee `source` field); `participant-renamed`
renames nothing (it joins a source to an attendee, `protocol.ts:75-82`);
"epoch" means both capture ownership and Unix time; "local" means provenance
origin, the local person, and loopback. Full table in the appendix.

---

## Target model

One narrative, three stages, each with one owner and a recorded artefact:

```
candidate track ──(admission: capture-seams policy, browser)──► admitted source
admitted source ──(evidence: observations recorded, browser)──► evidence log
evidence log ──(binding: pure reconciler, daemon, re-runnable)──► identified participant
```

- **Admission** stays in the browser (it must — it gates what is captured) but
  every admission decision is *recorded with its reason*.
- **The browser stops being the binding authority.** It still computes a live
  provisional binding (for UI, logging, and the attendee `source` hint), but
  the binding that labels the transcript is derived by the daemon's pure
  reconciler from recorded evidence — at session end, and re-runnable forever.
- **Source ids stop carrying identity guesses** (R3): a source is a stable
  handle on a captured track, and "whose voice is this" lives exclusively in
  `[[speaker]]`.

This is the same shape the Swift side already has (pure `EarsCore`, effectful
shims); the refactor is essentially "give the browser the EarsCore split, and
finish the roster/speaker-map separation through the wire and the source id".

---

## The plan

Ordered by leverage over the attribution problem. Sizes are focused
working days, honest ±50%. **[MIN]** marks the minimum path that makes the
outstanding bugs cheap to fix; the rest is compounding cleanup.
Every item is executable under the repo's rules: tier-0 test-first for pure
logic, one behaviour per commit, no `_v2` parallels — each item states its
staging so every commit is green.

### R1 — Attribution flight recorder [MIN]

**What changes.** Every input the attribution decision consumes, and every
decision taken, is recorded as a typed, timestamped event stream: per-call in
the browser, exported on demand, and (when a daemon session exists) shipped
over the existing message path and written by the daemon as
`sessions/<id>/attribution.jsonl` beside `events.jsonl`.

Event vocabulary (one discriminated union, versioned with a `schema` field):
track lifecycle (`track-appeared` with track id, seam, `muted` at dispatch,
provenance origin/rootId; `track-unmuted`/`-muted`/`-ended` with timestamps),
admission decisions (`admitted`/`deferred`/`adopted`/`retired`/`escalated`
with the reason string the policy already produces), identity evidence
(`collections-edge` with parsed fields *and* raw payload bytes base64,
`dom-burst` with device id and onset, `audio-onset` per track — the existing
`__earsAudioLog` shape at `audio-tap.ts:682-690`), roster observations
(`roster-delta` entries with the `(You)`-marker evidence for `isLocal`), and
binding events (`provisional-binding` with cause: which correlator, which
counts).

**Files/types.** New `browser/lib/attribution-log.ts` (pure: event types,
encoder, bounded ring); emit calls from `audio-tap.ts`, `capture-seams.ts`
call sites, `meet.ts`, `rtc-hook.ts` (collections tracer); relay/background
pass-through (one new `PortMessage` kind in `protocol.ts`); daemon:
`IngestRequest` or control-plane extension carrying batched events, a writer
in `EarsDaemonKit` (append-only JSONL, same discipline as `events.jsonl`),
spec updates in `docs/specs/browser/transport.md` and
`docs/data-formats.md`.

**Why it makes the bugs cheaper.** This is the single highest-leverage item:
it converts "diagnosing requires a live call with real people" into "export
the log". Every future real-call failure becomes a committed regression
fixture (the logs contain device-id paths and display names — commit only
sanitized/synthetic ones; real ones stay local, per the privacy rule). It is
also the substrate R2's replay tests and R3's daemon-side binding run on.

**Testing.** Tier-0: event encode/decode golden tests, ring bounds
(`attribution-log.test.ts`). Tier-1 daemon side: integration test that a
batched event message lands in `attribution.jsonl` under the right session.
Test-first throughout — the event vocabulary is pure data.

**Size.** 3–4 days (2–3 browser, 1 daemon). **Depends on:** nothing.

### R2 — Pure Meet identity engine; adapters become sensors [MIN]

**What changes.** `MeetAdapter` (`meet.ts:408-818`) is split into (a) a
**sensor half** that stays entangled: MutationObserver wiring, collections
listener registration, DOM polling — everything that *produces* observations;
and (b) a **pure decision half** — a new `meet-identity-engine.ts` holding
`names`, `upgradedTracks`, `deviceOwners`, `localDeviceId`, `emittedNames`,
and the three `SpeakingCorrelator` instances — consuming exactly the R1 event
vocabulary, with **every entry point taking a caller timestamp** (fixing the
three internal `Date.now()` reads at `meet.ts:523,573,582`; `onDeviceSpeaking`
at `meet.ts:533` already has the right shape). The engine's outputs are typed
decisions (`bind`, `refuse-rebind`, `roster-emit`, `local-resolved`), which
the adapter shell translates into today's `onIdentify`/`onRename`/`onRoster`
callbacks — the `PlatformAdapter` interface does not change in this item.
Also in scope: wire up `adapter.dispose()` from epoch teardown
(`meet.ts:666-674` documents that nothing calls it) so engine lifetime is
explicit rather than page-lifetime.

**Why cheaper.** The whole #158/#164/#172 class becomes unit-testable: a
replay test feeds a recorded event log into the engine and asserts final
bindings. The next Meet drift gets diagnosed by replaying the captured log
against the engine, not by re-running calls; the fix gets a failing-then-
passing test from the same log, satisfying the regression-test rule for a
category of bug that today cannot satisfy it.

**Testing.** Tier-0 test-first: engine tests are today's `meet.test.ts`
adapter tests rewritten without fake timers/global stubs (they already
exercise the right behaviours: rebind refusal at `meet.test.ts:414`, competing
claims, local exclusion at `:557-604`), plus a replay test over an R1 log
fixture. Staging: (1) timestamp injection, adapter behaviour unchanged, tests
green; (2) extract engine state move-by-move, one commit per moved
responsibility; (3) replay test.

**Size.** 4–5 days. **Depends on:** R1's event types (can start with the type
definitions only).

### R3 — Bind at reconcile: identity leaves the source id [MIN, and the one contract change]

**What changes.** A browser source id becomes a stable per-track handle —
`browser:<platform>:<track-slug>` where the slug is minted once per admitted
track (seam + counter, e.g. `t3`) and **never changes for the track's life**.
Consequences, all deletions of machinery that exists only because ids carry
identity guesses:

- The identity-upgrade **pipeline restart disappears** (`handleIdentityUpgrade`
  restart path, `audio-tap.ts:258-283`) — no more frames lost across upgrades
  (`audio-tap.ts:248-251`), no more one-human-many-sources, no more spurious
  `participant-left` roster stamps (`audio-tap.ts:556-563`).
- `participant-renamed` (the source-to-attendee join hack for dead tracks,
  `protocol.ts:75-82`, `audio-tap.ts:292-298`, `session-tracker.ts:318-328`)
  disappears — a confirmed identity is just an attendee upsert linking
  `source: browser:meet:t3`, whenever it arrives, even after the track died.
- The first-binding-wins permanence rule (`meet.ts:604-614`) relaxes: the
  browser's live binding is now advisory (an attendee `source` hint plus R1
  `provisional-binding` events), so revising it is a metadata update, not an
  audio-splitting event. The engine (R2) can adopt calmer rules — e.g. emit a
  revised hint after sustained contrary evidence — without any risk of the
  86-restart storm, which was a *pipeline* pathology, not a correlator one.
- Daemon side: `RosterReconciler` already produces the authoritative map and
  transcribe already labels from it; this item extends the reconciler to
  consume the R1 evidence (or at minimum the provisional-binding hints with
  their confidence causes) instead of only the roster's single `source` link
  per attendee. `sanitizeLabel`/`sourceLabel` (`protocol.ts:223-230`) change;
  `docs/specs/browser/transport.md:60` ("Source labeling") and
  `docs/data-formats.md` update; the ground-truth harness's assumption that
  source ids embed the participant (its `score.py` docstring, the manifests'
  `expected_source_id`, and `sessions.py`'s `browser:` source filter —
  `score_roster` itself checks source *presence* per attendee and
  provisional-id shapes, not the full label shape) updates to score via
  `[[speaker]]` instead — which is truer to what it should measure anyway.

**Why cheaper.** This is the item that makes the recurring bug class
*structurally* cheaper rather than better-instrumented: name↔track binding
becomes a pure daemon-side derivation over recorded evidence, re-runnable
(R5) when the algorithm improves, testable from fixtures, and indifferent to
when in the call the name arrived. Late identity, rejoin, and upgrade all
collapse into "another evidence row".

**Testing.** Tier-0: reconciler extension tests
(`RosterReconcilerTests.swift`) and browser label tests. Tier-1: a fixture
session with track-scoped sources + evidence produces correctly-named
transcript (`TranscribeTests`). Ground-truth: re-run s1/s2 scenarios once
live after landing (see R9). Staging: (1) track-slug minting behind the
existing label call site, Meet only, with the old path deleted in the same
commit per no-parallels; (2) delete restart/rename machinery; (3) reconciler
extension; (4) scorer update.

**Size.** 7–10 days across both languages; the largest item. **Depends on:**
R1 (evidence exists), R2 (engine emits typed decisions), R4 recommended
first. **Risk / decision needed:** this changes the on-disk source-id shape
and the ingest label contract — a per-item approval from you is warranted,
and the journal (which I could not read) should be checked for a prior
refutation of "late naming" designs. `docs/data-formats.md:50` treats source
ids as stable interface; the change is additive-compatible for readers that
treat the id as opaque, which `TranscriptAssembly` does.

### R4 — Typed participant references and attendee provenance [MIN]

**What changes.** Browser: `ParticipantId` (`protocol.ts:18`) becomes a
discriminated `ParticipantRef` — `{kind: "platform", id: string}` (Meet
device path, Zoom node) vs `{kind: "synthetic", id: string}` (`speaker-<n>`,
`webaudio-track-<n>`, `graphtap-<n>`) — flattened to strings only at the wire
edges. `session.attendee` gains an `origin` field (`"platform" | "synthetic"`),
carried through `AttendeeUpsert` (`protocol.ts:307-317`), `ControlCall.swift`'s
`SessionAttendeeParams`, `SessionAttendee` (`Session.swift:163-201`), and
`[[attendee]]` TOML (absent = unknown, for old files). `RosterReconciler`
counts **only platform-origin rows** as named remotes for invariant 2 and for
title derivation.

**Why cheaper.** Kills the phantom-attendee class at the reconciler
(`RosterReconciler.swift:167-176` currently counts junk rows and blocks the
one-remote inference — the report's finding, not yet an observed incident) and
gives both languages one enforced vocabulary at the boundary, which is where
the naming drift (F5) has caused real bugs. Also the natural place to fix the
`participant`/`attendee` naming: the wire object is an attendee; the browser
type should say so.

**Testing.** Tier-0 both sides: `protocol.test.ts` golden frames with
`origin`; `RosterReconcilerTests` for counting-with-origin;
`ControlProtocolV2FixtureTests` for the wire shape. Test-first throughout.

**Size.** 2–3 days. **Depends on:** nothing (lands before or with R3).

### R5 — Reconciliation is versioned and re-runnable [MIN]

**What changes.** `session.toml` gains `reconciler_version` (an integer
alongside the `[[speaker]]` block). `TranscribePipeline.swift:478` re-derives
not only when the map is empty but when the stored version is older than the
current one, and a `transcribe --rereconcile` flag forces it. New reconciler
invariants (all pure, all warned): one source ↔ at most one name (two
attendees claiming a source currently produce two `SessionSpeaker` rows and
transcribe's dict keeps the last, `TranscribePipeline.swift:487-490`); the
`isLocal` latch (`SessionRegistry.swift:463-466`) becomes revisable by
reconciler inference with the evidence recorded in `warnings`.

**Why cheaper.** Every past session becomes repairable by re-running
transcription after a reconciler fix — which is precisely the promise the
roster/speaker-map split made (`docs/data-formats.md:275`) and currently keeps
only for the empty-map case. A reconciler bug stops being permanent damage.

**Testing.** Tier-0 test-first: `RosterReconcilerTests` for the new
invariants; `TranscribeTests` for version-triggered re-derivation over a
fixture store with a stale wrong map.

**Size.** 2–3 days. **Depends on:** nothing; synergises with R3/R4.

### R6 — Deletions and doc-truth sweep

**What gets deleted** (each with the evidence it is dead):

- `browser/entrypoints/pcm-worklet.ts` and the `dataset.earsWorklet`
  publication (`content.ts:53`) — no consumer exists (grep-verified); the spec
  itself calls it "an unwired legacy fallback" (`extension.md:115`).
- `installMeetTransformProbe` (`rtc-hook.ts:558-617`) — self-described
  "Temporary diagnostic (journal #73)… Remove once the fix lands"; the fix
  (webaudio seam) landed Jul 30.
- `MeetAdapter.deviceState` (`meet.ts:427-429`) — written, never read,
  self-described "for future use".
- The `transceiver` parameter on `PlatformAdapter.identify` (`adapter.ts:9-13`)
  — no adapter uses it.
- `data-initial-participant-id` (`meet.ts:148-149`) and `ZoomAdapter`'s
  `track.id` MSID fallback (`zoom.ts:57`) — confirmed-gone attribute;
  practically-unreachable branch. Note: the meet.ts comment records a
  deliberate *keep* ("costs nothing"), so deleting it overrides a recorded
  decision — flagged rather than assumed.
- Stale cross-references: three comments cite "rtc-hook.ts:654" for the
  ids-never-match finding (`capture-seams.ts:15,96`, `audio-tap.ts:608`) — the
  text has moved; cite the function name, not a line.
- Spec drift: `extension.md:83` still describes the collections flag as
  per-turn speaking (re-interpreted 2026-07-24 as a mute edge,
  `meet-collections.ts:23-33`); `extension.md`'s `PlatformAdapter` copy is
  missing `onTrackUnmute`/`onDeviceSpeaking`/`onRename`/`onRoster`/
  `pollIdentities`. Also `audio-tap.ts:146-151`'s claim that
  `anyAudioDecodedThisCall` survives epoch handoff is wrong for genuine
  re-injections (fresh module instance per `rtc-hook.ts:17-19`) — fix the
  comment or the mechanism.

**Deliberately kept**, recorded here so the decision is visible: the
`meet-encoded-tee` seam (dead since #73 but retained as a documented hedge,
`capture-seams.ts:36-39`); the dormant collections `correlator` and the
opportunistic tile-media `identify()` path (`meet.ts:39-46,159-164`); the
debug-gated `graph-bridge` and `audioprocessor` tee (investigation tools).
These are defensible under "delete, don't park" only because each carries its
rationale in a comment; this sweep should make sure each still does.

**Testing.** Deletions ship with the test run proving nothing consumed them;
the spec fixes are docs commits. **Size.** 1–2 days. **Depends on:** nothing.

### R7 — Split `audio-tap.ts` and `rtc-hook.ts` along their existing internal seams

**What changes.** `audio-tap.ts` (~1600 lines) becomes four modules with the
boundaries the code already draws: the frame pipeline (`TrackCapture`,
`LinearResampler`, `RingBuffer`, `TrackProcessorSource` — pure-ish, already
tested), `MeetDecodeSource` + RED unwrap (already injection-seamed via
`MeetDecodeDeps`), the admission/orchestration layer (`initCapture`, `sink`,
`startPipeline`, adoption/escalation/reconcile — restructured from
module-level `let`s into a class with injected deps: adapter, arbiter, poster,
clock), and debug surfaces. `rtc-hook.ts` (~1450) likewise: constructor hook +
provenance registry; encoded tee; graph probe/bridge (debug-only module).
No behaviour change; the orchestration class is the point — it makes the last
untested attribution layer (F1) constructible in a test with fakes.

**Testing.** Existing tests move with their code (mechanical commits); then
new tier-0 tests for the orchestration class: admission flows, escalation,
adoption/retire race, `identityFor` — the scenarios currently only exercised
by real calls. Test-first for every newly-written test.

**Size.** 4–5 days. **Depends on:** best after R2/R3 so the orchestration it
freezes is the simplified one — doing it first would test machinery R3
deletes.

### R8 — Relay/background become testable; browser tests enter CI

**What changes.** `content.ts`'s relay switch (`relay()`, `content.ts:244-393`,
including the respawn-replay logic that guards the stranded-session bug) and
`background.ts`'s handler wiring are extracted into pure reducers over
`RelayState`/session state, with the chrome plumbing as thin shells. And:
`.github/workflows/ci.yml` currently runs **only** the Swift suite — the
browser's ~5,800 vitest lines run on no commit gate at all, and the top-level
`Makefile` has no test target. Add a browser CI job (`bun install && bun run
test`) and a `make test` running both.

**Why cheaper.** The respawn-replay path guards a documented bug class
(`extension.md:129`) with zero tests; and untested-in-CI is how attribution
regressions ship silently today.

**Testing.** Tier-0 reducer tests; CI change is its own commit.
**Size.** 2–3 days. **Depends on:** nothing; the CI half (half a day) should
land **first**, this week, independent of everything.

### R9 — Ground-truth harness: replay tier and a revived live tier

**What changes.** The harness (`test/ground-truth/`) is the only end-to-end
attribution proof and, per `FINDINGS.md` (2026-08-06), the multi-guest
scenarios have never completed a live run (Meet rate-limits anonymous joins;
`bb501d2` moved toward signed-in profiles). Two additions: (a) a **replay
tier**: `score.py` learns to score from an archived run's store plus the R1
`attribution.jsonl`, so every archived and every future recorded call is
re-scorable against new binding logic offline — this becomes the standing
regression harness for R3's reconciler; (b) the live tier gets the
signed-in-profile flow documented and s2/s3 executed once, so the corpus's
core promise ("re-score a run recorded today against a new algorithm next
month") is finally demonstrated on a multi-party call. Live runs remain
manual and operator-driven (they require a real Meet call — out of scope for
this environment).

**Testing.** The harness *is* the test; its own pure pieces (scorers) have
Python-side checks worth extending with the new replay path.
**Size.** 3–4 days plus operator time for live runs. **Depends on:** R1 (for
`attribution.jsonl` scoring); partially R3.

### R10 — Ingest transport: correlation ids

**What changes.** `transport.ts` matches `ingest.open`/`close` responses
FIFO (`transport.ts:16-17,325-364`); one unsolicited or reordered daemon
response desynchronises every subsequent open. Add an optional `id` echoed by
the daemon (`IngestRequest.swift` / `IngestWebSocketServer.swift` accept and
echo; extension sends and matches), keeping FIFO as fallback for old daemons.
**Testing.** `transport.test.ts` + `EarsIPC` tests, golden frames.
**Size.** 1–2 days. **Depends on:** nothing. Lowest priority: no observed
incident, but it converts a protocol assumption into a checked contract.

---

## Minimum path vs full path

**Minimum path to "the outstanding bugs are cheap to fix":**
CI half of R8 (half a day) → R1 → R2 → R4 → R5 → R3.
After R5 the daemon-side bug class (phantom rows, irreversible latches,
unrepairable maps) is fixed-or-fixable with pure tests; after R2 the Meet
binding class is replay-testable; R3 then removes the structural coupling
that made binding bugs expensive. Roughly 4–5 working weeks.

**Full path** adds R6, R7, rest of R8, R9, R10 — roughly 2–3 further weeks.

---

## Per-source vs per-turn attribution

What the code forces today: attribution is strictly **per-source** — a turn's
label is a function of its source id (`TranscriptAssembly.swift:40-45`), and
per-turn evidence (DOM bursts, collections edges) is used only transiently to
bind sources, then discarded. The one in-repo trace of #171
(`audio-tap.ts:318-324`) shows the cost: inert-but-unmuted webaudio tracks
become phantom sources, and silence alone must not retire a source — the
admission layer cannot answer "is this track a person" from track metadata
alone.

**Inference (journal unread):** the architecture does force a premature
choice today, because per-turn evidence is not persisted. The cheap hedge is
already in this plan: R1 records the per-turn evidence (speaking intervals
per device id, per track) as a session artefact, and R3 moves binding to a
pure daemon-side derivation over that artefact. If a future finding flips the
answer toward per-turn attribution — e.g. labelling individual turns inside a
mixed or ambiguous source by DOM-burst overlap — the change is then confined
to `RosterReconciler`/`TranscriptAssembly` (consuming evidence that is
already on disk) plus rendering, with no browser changes and full offline
testability against archived calls. Without R1/R3, flipping would require new
live capture code and could not be validated retroactively. Teams (one mixed
track, dominant-speaker design unimplemented, `teams.ts:3-6`) is the concrete
customer for per-turn: under this plan it becomes "record dominant-speaker
evidence, attribute turns at transcribe time" rather than new live machinery.

---

## Replayability: what exists, what is missing

Exists today: real collections wire-byte fixtures
(`meet-collections.test.ts:137`); `__earsAudioLog` (debug-gated, in-page,
unbounded — `audio-tap.ts:686-690`); the IndexedDB perf ring (graph topology,
stage timings — survives the post-call redirect); `captureDebugState()`/
`hookDebugState()` snapshots; `decodeBinaryFrame` + `dev/harness-server.ts` /
`stub-server.ts` (PCM replay without a daemon); the dev console probe
(`dev/probes/meet-identity-probe.js`); ground-truth archived runs
(re-scorable stores). Missing, and supplied by R1: timestamped identity
evidence (bursts, edges, onsets, roster snapshots with the `(You)` evidence),
admission decisions with reasons, track lifecycle with mute states, and a
clock discipline (R2) that lets any of it drive the decision code
deterministically.

---

## Outstanding bugs found and not fixed

Evidence-backed, in the code on this branch. None are addressed by this
proposal directly; items note which refactor makes each cheap.

| # | Bug | Evidence | Made cheap by |
|---|-----|----------|---------------|
| B1 | Inert-but-unmuted webaudio tracks still become phantom sources/attendees (open #171) | `audio-tap.ts:318-324`, `capture-seams.ts:179-183` | R1 (energy evidence recorded) + R4 (synthetic rows discounted) |
| B2 | Local-user detection keys on English "(You)"; non-English locales fail open → #158-class misbinding | `meet.ts:230-236, 557-560, 762-770` | R1/R2 (replayable), R5 (daemon inference revisable) |
| B3 | First-binding-wins: a wrong surviving name is permanent for the call | `meet.ts:441-443, 604-614` | R3 |
| B4 | Wrong-but-non-empty stored speaker map never re-derived | `TranscribePipeline.swift:478` | R5 |
| B5 | Two attendees bound to one source → silent last-write-wins | `TranscribePipeline.swift:487-490`; no reconciler invariant | R5 |
| B6 | `isLocal` latch irreversible; a wrong `self=true` makes invariant 1 drop *correct* bindings | `SessionRegistry.swift:463-466` | R5 |
| B7 | Phantom/junk roster rows defeat the one-remote counting inference | `RosterReconciler.swift:167-176` | R4 |
| B8 | `capture-failed` never reaches the daemon (aim of issue #22 unmet) — gaps look like silence | `background.ts:251-261` | R1 (record), small fix after |
| B9 | Zoom has no display-name channel at all; ids-only attendees | `zoom.ts` (no `displayName`/`onRoster`) | independent feature |
| B10 | `adapter.dispose()` never called; adapter state persists across epochs, stale-comment claims otherwise | `meet.ts:460-463, 666-674` vs `hook.content.ts:76` | R2 |
| B11 | Identity-upgrade restart drops frames and stamps `left` for people who never left | `audio-tap.ts:248-251, 556-563` | R3 (deletes the mechanism) |
| B12 | Meet confirmation is single-point-of-failure on the DOM speaking ring (thresholds make collections-only confirmation unreachable) | `meet.ts:53-60, 388-391`; `meet-collections-drift.md` finding 1 | R1/R2 (drift visible in replays) |
| B13 | `ingestStreamClosed` grace not identity-scoped (open side was fixed for #24; close side relies on single-active-session) | `SessionRegistry.swift:582-587` vs `:547-553` | small daemon fix |
| B14 | FIFO response matching on the ingest socket desyncs on any reorder | `transport.ts:16-17, 327` | R10 |
| B15 | Graph-bridge sources bypass pipeline lifecycle; daemon-side streams never closed | `audio-tap.ts:1595-1604`, wired at `hook.content.ts:72` | R6/R7 (debug isolation) |
| B16 | Session identity TOML with one of platform/external_id silently decodes to nil identity | `SessionDescriptorTOML.swift:110-117` | small fix + test |
| B17 | Default-title detection by string equality; manual sessions all "unnamed" | `Session.swift:110-112` | small fix |
| B18 | Unparseable `session.toml` at boot strands audio outside retention | `SessionRegistry.swift:187-189` | small fix |
| B19 | PowerObserver misses dynamic browser sources (documented gap) | `EarsDaemon.swift:684-688` | small fix + test |
| B20 | `__earsAudioLog` unbounded under its debug flag | `audio-tap.ts:686-690` | subsumed by R1's bounded ring |
| B21 | Teams attribution unimplemented — always `speaker-<n>`, spec's dominant-speaker design absent | `teams.ts:3-14` | R1+R3 make the per-turn design cheap |
| B22 | Firefox Meet broken (no `createEncodedStreams`; `TrackProcessorSource` fatals without `MediaStreamTrackProcessor`) | `docs/browser-extension.md:48`, `audio-tap.ts:1110-1115` | independent |

Also recorded (process, not code): browser tests are not in CI and the
Makefile has no test target (R8); HEAD `8441937` is a self-described
unsplittable WIP commit, in tension with the small-green-commits rule.

---

## Appendix: cross-language vocabulary table

| Concept | Browser (TS) | Daemon (Swift) | Wire / disk | Drift |
|---|---|---|---|---|
| Human in the call | `participant`, `RosterEntry.participantId` | `SessionAttendee` ("attendee") | `session.attendee`, `[[attendee]]` | Two words, one concept (R4 fixes at boundary) |
| Platform's stable id for them | `ParticipantId`, called `deviceId` in correlator code | `SessionAttendee.id` | `id` | `deviceId` collides with `getSettings().deviceId`, documented-useless (`capture-seams.ts:227-231`) |
| Synthetic stand-in | `speaker-<n>`, `webaudio-track-<n>`, `graphtap-<n>` | indistinguishable from real ids | same field | No provenance marker (R4) |
| Captured stream | "source" = earsd label; also `FrameSource`, `MediaStreamAudioSourceNode` | `SourceID`, `SourceDescriptor` | `browser:<platform>:<participant>`, `sources = [...]` | Four meanings of "source" browser-side |
| Voice↔name conclusion | live binding in `upgradedTracks` | `SessionSpeaker` via `RosterReconciler` | `[[speaker]]` | Browser's version is a guess persisted into the *source id* (R3) |
| Local user | provenance `local`; roster `isLocal` | `isLocal` | `self` | Three senses of "local" |
| Rename | `participant-renamed` (joins source→attendee) vs `meeting-renamed` (real rename) | — | `session.attendee` / `session.rename` | Misnomer (`protocol.ts:75-82`) |
| Capture segment counter | `generation` | — (session `rev` is unrelated) | `generation` on PCM | OK, but near-collides with `rev` |
| Ownership counter vs time | `epoch` (capture ownership) / `sentAt` "epoch ms" | — | — | Same word, unrelated |
