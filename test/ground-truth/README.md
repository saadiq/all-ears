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
their `spaces/<space>/devices/<n>` ids, whether each carries a
`browser:<platform>:<participant>` source, and join/leave instants versus
`events.jsonl`. Fails on a declared guest that never appeared, or an attendee
that is neither declared nor a recorded observer.

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

## Re-scoring an archived run against a new algorithm

This is the whole point of the corpus, and it needs no daemon and no cooperation
from the capture side — `docs/architecture.md` makes the on-disk layout the read
API.

```sh
# Same run, new algorithm: re-run the pipeline over the archived session, then re-score.
transcribe --session <uuid>
uv run score.py runs/20260806T174500Z-s3-three-guests
```

Two things make this work months later:

- `runs/<...>/run.json` holds the slot schedule, the per-participant WAV
  SHA-256s, the corpus fingerprint **and** the session id together.
- `raw/` is committed. The renders are not reproducible — the same script, voice
  id, model and seed can return different audio as ElevenLabs updates its models
  — so the bytes are kept next to the hashes that describe them. See
  `docs/engineering-practices.md`.

If the session's audio has been evicted by retention (default 2 h after its
transcript completes), scores 1 and 3 still work; score 2 needs the audio, so
archive `sessions/<uuid>/sources/` alongside the run if you want to re-score
timing later.

`score.py --session <uuid>` scores a run directory against a different session,
which is how you compare two pipeline versions over the same corpus.

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
| `build/`, `runs/`, `.work/` | build output and run records (gitignored) |

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
