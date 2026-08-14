# Ground-truth harness for speaker attribution

A repeatable, scorable corpus for the all-ears capture pipeline, where the right
answer is known **by construction** rather than judged by staring at a live call.
Any algorithm change can be scored against it — including a change made six weeks
from now, against a run recorded today.

- [`CORPUS.md`](./CORPUS.md) — the passages, the voice assignment and the slot
  grid, and the reasoning behind each, so you can tell a safe edit from an unsafe
  one.
- [`FINDINGS.md`](./FINDINGS.md) — what the first real runs answered, including
  where this harness's own design assumptions turned out to be wrong.

## How it works

Three shortcuts make it cheap.

**No audio hardware.** Chrome synthesises a microphone from a WAV
(`--use-file-for-fake-audio-capture`), so every participant is a deterministic,
byte-identical audio source, replayable across runs. It also removes the
confound journal #115 flagged: with synthetic devices there is no acoustic
coupling between participants, because there are no acoustics.

**Guests are anonymous.** A guest types a display name and joins — no account, no
login automation, no credential anywhere in the harness. The elegant part: **the
name typed at join is the ground-truth label.** `GT-Alpha` plays `alpha.wav`. The
roster join is declared, not inferred.

**Only the instrumented browser carries the extension.** Guests are dumb audio
sources: no `earsd`, no extension, no instrumentation.

### Three browser roles

| Role | What it is | What it does |
|------|-----------|--------------|
| **Convener** | The user's own Brave, on their own profile, driven through the Claude in Chrome extension | Creates the meeting, sets access to **Open**, then **stays in the call in Companion mode**. No all-ears extension, no `earsd` traffic, no flags, no profile changes. |
| **Instrumented participant** | Chromium the runner launches, throwaway `--user-data-dir`, carrying the built extension and `host.wav`, joining anonymously as `GT-Host` | The browser under test. |
| **Guests** | Chromium the runner launches, one per participant, each with its own WAV and `--user-data-dir` | Emit known audio. Nothing else. |

The convener staying is a **correction to the original design** — see
[`FINDINGS.md`](./FINDINGS.md#a-signed-in-participant-must-stay-in-the-call). It
holds the call open and is declared in the run record as a non-scored observer.

### The host's own audio: two file readers, no audio driver

`earsd` captures `mic` through Core Audio, not through the browser. So
`--use-file-for-fake-audio-capture` alone would make Meet *transmit* `host.wav`
while the `mic` source went on recording the real room — half the ground truth
silently wrong. The answer is not a virtual audio driver; both consumers read the
same file independently:

1. **Meet** ← the instrumented browser's fake-device flag.
2. **`earsd`** ← `FileAudioSourceProvider` in `daemon/Sources/EarsCaptureKit/`,
   a realtime `AVAudioSourceNode` rendering the same WAV through the *production*
   tap/ring/generation pipeline. Compile-time gated behind `#if DEBUG`.

They start on different clocks. That is fine and deliberate: the scorer's
zero-lag cross-correlation recovers a fixed offset by construction. Both start
instants are recorded; nothing tries to synchronise them.

## Running one scenario end to end

Prerequisites: `ffmpeg`, `uv`, `rodney`, a `earsd` you built yourself in **debug**
(`swift build`), and the extension built (`cd browser && npm run build`).

```sh
cd test/ground-truth

# 1. Assemble and verify the corpus. Cached on a content hash — free when nothing changed.
uv run assemble.py build
uv run verify.py check

# 2. Prove the fake-device path works at all, before burning a call on it.
uv run browsers.py preflight

# 3. Have the convener create a meeting (Claude in Chrome, or by hand):
#    meet.google.com → New meeting → Start an instant meeting
#    Host controls → Meeting access type → Open
#    Other ways to join → Use Companion mode, and STAY in the call.

# 4. Point earsd's mic source at the same WAV the browser will transmit, and run.
ALLEARS_CAPTURE_FILE_MIC=$PWD/build/s1-solo/host.wav ~/.local/bin/earsd &
uv run run.py scenario s1-solo \
  --meet-url https://meet.google.com/xxx-yyyy-zzz \
  --convener "<the convener's display name>"

# 5. Score it.
uv run score.py runs/<timestamp>-s1-solo
```

`run.py` writes `runs/<timestamp>-<scenario>/run.json`: the scenario manifest
with a `run` block carrying the actual join and leave instants, the resolved
session id, the extension version and every browser's argv. **The manifest and
the session id travel together on purpose** — that is what makes an archived run
re-scorable.

### Signed-in profiles (when anonymous join is refused)

Meet stopped admitting this harness's anonymous guests (see
[`FINDINGS.md`](./FINDINGS.md#what-is-blocking-the-live-runs)), so participants
can instead run from **persistent, manually-signed-in Chrome profiles** under
`.profiles/` — the brief's stated fallback. Once per profile, a human signs in
by hand, in a browser launched with no debugging port and no automation flags:

```sh
mkdir -p .profiles
open -na Chromium --args --user-data-dir="$PWD/.profiles/host"
# …sign in to the participant's Google account, then quit the browser.
```

Then hand each participant its profile by label:

```sh
uv run run.py scenario s2-one-guest \
  --meet-url https://meet.google.com/xxx-yyyy-zzz \
  --profile host=host --profile alpha=alpha     # LABEL=dir under .profiles/
```

What this changes, and what it costs:

- `launch` never wipes a profile named here, and nothing in the harness ever
  writes to one. `.profiles/` is gitignored — the directories hold **live
  Google session cookies**; never commit them.
- An anonymous guest types its display name, so the roster label is ground
  truth by construction. A signed-in guest shows its **Google account name**,
  which the harness neither controls nor rewrites — so the ground truth moves
  from "the name typed at join" to "**which profile played which WAV**". Still
  by construction (the runner owns that mapping), but the name must now be
  *observed*: the runner reads the host's own tile while it is alone in the
  call, and attributes each later-appearing tile name to the guest it had just
  launched. The observed names land in `run.json` (gitignored) as
  `observed_display_name`, and the scorer matches the roster on them.
- The convener role disappears: a signed-in participant revives a dormant call
  by itself, so `--convener` is only needed for legacy anonymous runs.

### The tone-viability probe

Run once before trusting the corpus design, and again whenever Meet's audio path
moves:

```sh
uv run probe.py wav
uv run run.py probe --meet-url https://meet.google.com/xxx-yyyy-zzz --convener "<name>"
uv run probe_report.py runs/<timestamp>-probe
```

One guest plays a WAV of tones at the four head frequencies **plus a speech
control**, and three things are checked per window: does the audio reach the
host, does Meet's speaking ring light, does the daemon's VAD emit spans. The
speech control is what makes the result interpretable — a tones-only probe
cannot tell "Meet discarded the tone" from "the rig is broken", because both look
like silence at the far end.

## What each score means

`score.py` reports three scores **separately**, because they fail differently.

**1. Roster.** The display names typed at join versus `session.toml`'s attendees,
their `spaces/<space>/devices/<n>` ids, whether each guest's voice was
attributed to a source via the reconciled `[[speaker]]` map, and join/leave
instants versus `events.jsonl`. Source ids are opaque track handles
(`browser:<platform>:<track-slug>`) that embed no participant — attribution is
judged on the map, never parsed out of a label. Fails on a declared guest that
never appeared, or an attendee that is neither declared nor a recorded
observer.

**2. Timing/energy.** Each captured source's RMS envelope cross-correlated
against every reference WAV, zero-lag. Envelopes rather than raw samples: the
captured copy has been through Opus and a jitter buffer, so it is nowhere near
sample-identical, but *when it is loud* survives that untouched. Needs no ASR.
This is the path that caught the mic duplication.

**3. Text.** Bag-of-words Jaccard between each source's transcript segments and
each participant's known passages. The four speakers own disjoint semantic
domains, so after stopword removal this discriminates cleanly. Reported as
`unscored` rather than failed when the session has no transcript yet.

Beyond pass/fail, the report always carries:

- **the confusion matrix** — which reference each captured source actually
  matched, not just whether it was right;
- **disagreement between paths 2 and 3**, flagged and never averaged away. If
  timing says a source is Bravo and text says Alpha, that disagreement is itself
  the finding;
- **duplication** — two captured sources matching one reference is the
  mic-duplication signature (journal #117: one call transcribed the user four
  times) and must never score as a pass.

`score.py` exits non-zero on a failing score, so it can gate a change.

## Adding a scenario

Scenarios are declared in `gtlib.py`'s `SCENARIOS` and nothing else needs
touching:

```python
"s5-rejoin": gt.Scenario(
    id="s5-rejoin",
    shape="1 local participant + 1 guest that leaves and comes back",
    speakers=["host", "alpha"],
    rounds=3,
    overlap_pair=("host", "alpha"),
    schedule={"alpha": (-gt.PREROLL_SECONDS, 60.0)},  # (join, leave) in grid seconds
    skip_rounds={},                                    # rounds a late joiner misses
),
```

Then `uv run assemble.py build && uv run verify.py check`. The scenario's WAVs
and its manifest are generated together, and the corpus fingerprint moves so
nothing stale can survive.

Slot assignment is derived, not written by hand: speaker *k* of *N* takes grid
slots *k, k+N, k+2N…*, and passages are assigned in order of that speaker's own
turns (so a late joiner's first turn is still `p1`).

## Re-scoring an archived run against a new algorithm: the replay tier

This is the whole point of the corpus, and it needs no daemon, no call, and no
cooperation from the capture side — `docs/architecture.md` makes the on-disk
layout the read API. One command replays a run recorded today against whatever
the reconciler says next month:

```sh
uv run replay.py runs/20260806T174500Z-s3-three-guests
```

`replay.py` copies the run's archived session store into a scratch data root
(the archive stays byte-identical), runs the **real `transcribe` binary** from
this checkout over the copy — `--session <id> --rereconcile --json`, the same
Swift reconciler the daemon runs, consuming the same evidence: the roster in
`session.toml` plus the binding hints in `attribution.jsonl` — then scores the
re-derived speaker map (read back from the replayed transcript's JSON sidecar)
with the same three scorers as a live run. The replay's record lands in a new
`runs/<stamp>-replay-<name>/replay.json`; the archived run is never written to.

What makes this work months later:

- `runs/<...>/run.json` holds the slot schedule, the per-participant WAV
  SHA-256s, the corpus fingerprint **and** the session id together.
- `raw/` is committed. The renders are not reproducible — the same script, voice
  id, model and seed can return different audio as ElevenLabs updates its models
  — so the bytes are kept next to the hashes that describe them. See
  `docs/engineering-practices.md`.
- **Archive the session tree beside the run**: copy `sessions/<uuid>/` into
  `runs/<...>/session/` once the call ends. `replay.py` looks there first, so
  the run stays replayable after the live store is cleaned up or on another
  machine. Without the copy it falls back to the live store by session id.

Degraded archives degrade the scores honestly rather than silently:

- **Audio evicted** (retention default: 2 h after the transcript completes) —
  the timing score reports `unscored`, not failed; roster/attribution still
  score fully. Archive `sessions/<uuid>/sources/` beside the run to keep
  timing re-scorable.
- **Text** is `unscored` under the default null ASR backend (fast, hermetic,
  no model). `--asr` runs the real model over archived audio and re-scores it.
- **No `attribution.jsonl`** — the session predates the R1 flight recorder, so
  there is no recorded binding evidence to replay: refused with that message.
  `--roster-only` replays it from the roster alone (still the real
  reconciler, just hint-less).
- **Pre-R3 store** (`session.toml` schema ≠ 3) — refused with a clear
  message: the current reconciler has nothing it can honestly derive from a
  pre-schema-3 record. (A schema-3 store whose source ids still carry the old
  participant-labelled shape replays fine — the reconciler reads those labels
  compatibly.)

The replay path itself is pinned by a committed synthetic archive —
`fixtures/replay-demo/`, sanitized ids and fixture names only — whose stored
`[[speaker]]` map is deliberately stale, so a correct replay **must**
re-derive. `uv run check_replay.py` drives it end to end (needs a built
daemon: `swift build` in `daemon/`) and asserts the re-derivation, the
refusals, and that the fixture archive survives byte-identical.

`score.py --session <uuid-or-path>` remains the manual route: score a run
directory against any session store, which is how you compare two pipeline
versions over the same corpus by hand.

## Layout

| Path | What it is |
|------|-----------|
| `CORPUS.md` | passages, voices, slot grid, and why they are shaped that way |
| `FINDINGS.md` | what the first real runs answered |
| `scripts/*.txt`, `voices.json`, `generate.py` | the TTS renderer (run by hand; you do not need an API key to use the harness) |
| `raw/*.mp3`, `raw/manifest.json` | the committed renders, pinned by SHA-256 |
| `gtlib.py` | slot grid, scenarios, audio I/O, alignment — the shared model |
| `assemble.py` | `raw/` → per-scenario per-speaker WAVs + scenario manifests, cached |
| `verify.py` | asserts the assembled corpus matches its manifests |
| `probe.py`, `probe_report.py` | the tone-viability probe and its analysis |
| `browsers.py` | launching and driving participant browsers; `preflight` |
| `sessions.py` | reads `earsd`'s audio store straight off disk |
| `run.py` | the phase-1 runner |
| `score.py` | the scorer |
| `replay.py` | the replay tier: re-run an archived run through the real reconciler, re-score |
| `check_replay.py` | hermetic end-to-end check of the replay path over the committed fixture |
| `fixtures/replay-demo/` | committed synthetic archive (sanitized ids, fixture names) the check replays |
| `build/`, `runs/`, `.work/`, `.profiles/` | build output, run records, signed-in profiles (all gitignored) |

## Gotchas worth knowing before you debug something else

- **The fake audio file is silently not read unless the audio-service sandbox is
  off.** `--disable-features=AudioServiceSandbox` is mandatory on macOS.
  `preflight` asserts it.
- **`%noloop` does nothing.** The file is instead made longer than any run can
  be, and the runner stops the call well before the loop point.
- **Launch straight at the meeting URL.** A browser started on `about:blank` and
  then navigated to the meeting is redirected away.
- **Meet gates anonymous join on the user agent.** Every launched browser passes
  a stock Chrome UA.
- The guard band between a slot's speech and its boundary is ~3.7 s, so total
  audio-start drift between browsers must stay under ~1.8 s or scheduled slots
  collide. `run.py` measures the drift and flags a run that ate it.
- Meet's noise suppression and AGC process the fake input. Record which way you
  ran; it does not matter for identity scoring.
- A run record contains the convener's display name, because the scorer needs to
  tell a declared observer from an unexpected joiner. Nothing else about any real
  participant is logged, and nothing here should ever be pointed at a call that
  is not this synthetic corpus.
