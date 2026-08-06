# Build a ground-truth test harness for all-ears speaker attribution

You are building a repeatable, scorable test harness for the all-ears capture pipeline
(`/Users/tom/projects/fun/all-ears`). Today, speaker-attribution correctness is judged by
staring at a live call and guessing. The harness replaces that with a corpus where the
answer is known **by construction**, so any algorithm change can be scored against it —
including changes made six weeks from now against a run recorded today.

Read `docs/architecture.md`, `docs/data-formats.md`, `docs/specs/browser/extension.md`, and
`browser/lib/capture-seams.ts` before designing anything. The journal
(`sqlite3 docs/journal/journal.db`) is the source of truth for what has already been
observed; entries #105, #106, #110–#120 are the relevant run-up.

## The core idea

Three shortcuts make this cheap. Do not design around them being unavailable until you have
verified they fail.

**1. No audio hardware.** Chrome synthesises a microphone from a file:

```
--use-fake-device-for-media-stream
--use-file-for-fake-audio-capture=/gt/alpha.wav%noloop
--use-fake-ui-for-media-stream            # auto-grants mic permission
--autoplay-policy=no-user-gesture-required
```

The WAV must be 16-bit PCM. Every participant becomes a deterministic, byte-identical audio
source, replayable across runs. It also removes the confound journal #115 flagged: with
synthetic devices there is no acoustic coupling between participants, because there are no
acoustics.

`%noloop` matters — without it the file repeats and the slot schedule drifts out of
alignment with the recording.

**2. Guests are anonymous.** Meet allows anonymous guest join: the guest types a display
name and knocks, the host admits (or enables Quick access so nobody has to knock). No
account creation, no login automation, no bot-detection fight.

The elegant part: **the display name the guest types is the ground-truth label.** Name each
guest after its audio file — `GT-Alpha` plays `alpha.wav`, `GT-Bravo` plays `bravo.wav`.
The roster join is then known by construction; you are declaring truth, not inferring it.

Unverified assumption to check on the first run: `spaces/<space>/devices/<n>` ids are
believed to be assigned per joined device regardless of sign-in state, so anonymous guests
should exercise the identity path normally. If signed-in participants turn out to behave
differently, the fallback is persistent `--user-data-dir`s logged in **manually once** — the
profile persists, so it is a one-time cost, and it stays clear of automating Google sign-in.
Report which case you hit.

**3. Only the host browser needs the extension.** Guests are dumb audio sources: no `earsd`,
no extension, no instrumentation. They just need to be in the call emitting known audio.
That halves the surface that has to work in a container.

## Two browser roles, deliberately split

The signed-in account and the instrumented browser are **different participants**. Keeping
them separate is what removes the audio driver, the second Google account, and any change to
the machine the user works on.

**Convener** — Brave, already running, on Tom's own `Personal` profile
(`~/Library/Application Support/BraveSoftware/Brave-Browser/Default`, account `/u/0`),
driven through the Claude in Chrome extension. Its only jobs are to create the meeting,
enable Quick access (or admit guests), and leave. **No all-ears extension is loaded into it
and no `earsd` traffic comes from it.**

- Attached to, never launched. It is a daily driver with the user's tabs open: do not
  restart it, do not pass it command-line flags, do not clear its profile, do not install
  anything into it.
- Pin the account when navigating: `?authuser=0`, so a profile with several signed-in
  accounts cannot silently join as the wrong one.

**Instrumented participant** — a Chrome (or Brave) instance the runner launches, on a
throwaway `--user-data-dir`, carrying the built extension and `--use-file-for-fake-audio-capture=host.wav`,
joining the meeting **anonymously** as `GT-Host`. This is the browser under test.

- Because it joins anonymously, no credential exists anywhere in the harness. Guests are
  anonymous too.
- Because it is launched, it takes the fake-device flags — which is what makes the host's
  outgoing audio deterministic without a virtual audio driver. See below.
- If it runs Brave rather than Chrome: Brave loads the `chrome-mv3` build, and the extension
  already accounts for Brave in one place (the `ws://127.0.0.1/*` host permission exists
  because Brave handles localhost more strictly than Chrome), so it is a known target. But
  **Brave Shields is a live variable** — its fingerprinting and WebRTC protections can
  perturb exactly the audio path the seam arbitration observes. Prefer Chrome here; if you
  use Brave, turn Shields off for `meet.google.com` and record that you did. When a result
  contradicts an earlier Chrome observation, suspect Shields before suspecting the pipeline.

You do not need an ElevenLabs key — the corpus is already rendered and committed. Do not add
an API-key code path "for later".

### Why the instrumented browser is not containerised

Putting the instrumented browser in a container alongside the guests, and pointing the
extension at `earsd` on the macOS host, was considered and rejected. Two reasons.

**The container would run Chromium, not Chrome.** Both runtimes here are arm64 Linux
(`docker` reports `arm64 linux`; `container` is Apple's, same shape) and Google ships no
arm64 Linux Chrome. Seam arbitration is the thing under test and Meet's audio path has
already migrated four times in twelve days per-call — a result from Chromium-on-arm64-Linux
does not transfer to the Chrome/Brave the extension ships on. Running amd64 Chrome under
emulation is worse: a timing harness must not measure timing through a translation layer.

**It requires bypassing a deliberate invariant twice.** `lib/transport.ts:113` and
`lib/control-transport.ts:95` both refuse any non-`127.0.0.1` URL — the spec calls a remote
URL "a bug, not a configuration" — and `earsd` binds `127.0.0.1` only. Reaching one from the
other needs a forwarder inside the container *and* one on the Mac, plus the unpacked
extension's `chrome-extension://<id>` origin added to `[earsd.ingest_ws].allowed_origins`.
Two loopback bypasses in the test rig is a poor trade for a browser that is the wrong
browser anyway.

Guests are the opposite case and containerise cleanly: they are dumb audio sources with no
extension, no daemon connection, and no dependence on being Chrome specifically.

## The host's own audio: two file readers, no audio driver

This is the part most likely to be got wrong. **The browser flag and the daemon are separate
consumers and each needs feeding.** `earsd` captures the `mic` source through **CoreAudio**,
not through the browser: `AudioInputDeviceSelection` binds the input device and
`InputDeviceSelection.choose` follows the system default unless a `device_uid` is set. So
`--use-file-for-fake-audio-capture` alone would make Meet *transmit* `host.wav` while the
`mic` source went on recording the real MacBook microphone — room noise. Half the ground
truth silently wrong.

The answer is not a virtual audio driver. Both consumers read the same file independently:

1. **Meet** ← the instrumented browser's `--use-file-for-fake-audio-capture=host.wav%noloop`.
2. **`earsd`** ← a new file-backed capture provider, described next.

They start on different clocks. That is fine and must not be engineered away: the scorer's
zero-lag cross-correlation recovers a fixed offset by construction. Record the two start
instants; do not try to synchronise them.

### Work item: a file-backed `CaptureEngineProvider`, compile-time gated

The seam already exists and is documented for exactly this. `CaptureEngineProvider` "keeps
the tap/ring/generation-counter/frame-count pipeline **identical** whether the upstream node
is the real microphone (`AVAudioEngine().inputNode`, production) or an injected
`AVAudioSourceNode`". `RealMicSourceProvider` is the production side;
`SyntheticSourceNodeProvider` in `daemon/Tests/EarsCaptureKitTests/` is the existing test
side, driving a real `AVAudioEngine` from a source node in **offline** mode.

Add a sibling that renders a WAV through an `AVAudioSourceNode` in **realtime** mode — the
capture path must run at wall-clock speed, because the whole point is that its timing is
scored against a live call. Wire it in `realCaptureBackendFactory()`
(`daemon/Sources/earsd/RealCaptureBackendFactory.swift`) alongside the existing
`syntheticCaptureBackendEnvironmentKey` switch, taking a per-source file path.

**Gate it at compile time (`#if DEBUG` or an explicit SwiftPM trait), not on an environment
variable.** The existing synthetic switch is env-gated and ships in the release binary, but
it emits constant tones — obviously not a recording. A file-backed mic can put arbitrary
speech into a stored transcript that is indistinguishable from a real one, so it must not
exist in a shipping build at all. Do not follow the env-var precedent here; the release
binary must have no code path that reads a file as a microphone.

Two things this earns beyond the harness: the daemon half of the corpus becomes hermetic and
CI-able with no audio hardware, no driver, and no TCC prompt; and `docs/specs/capture-daemon.md`
records that `device_uid` binding "needs the real-hardware verification pass before it is
trusted in a release" — the provider work sits next to that binding, so verify it while you
are there and report the result.

## Scenarios

Build four, each fully described by a machine-readable manifest:

| id | shape |
|----|-------|
| `s1-solo` | 1 local participant (host only) |
| `s2-one-guest` | 1 local participant + 1 guest |
| `s3-three-guests` | 1 local participant + 3 guests, all joined before speech starts |
| `s4-staggered` | 1 local participant + 3 guests, joining and leaving at staggered times |

`s4` is the important one: guests admitted late change the track timeline, and late-joining
is exactly what produced the anomalous track-5 in the 2026-08-06 call. Record the actual
join and leave wall-clock times, not just the intended ones.

## Why the audio is shaped the way it is

The passages and slot grid in `README.md` are fixed; this section is the reasoning
behind them, so you can tell a safe edit from an unsafe one.

- **Disjoint speaking slots.** Participant *k* speaks only in slots *k, k+N, k+2N…*, silent
  elsewhere. Attribution becomes scorable from energy and timing alone, no ASR involved.
- **Distinct passages within those slots.** Now it is *also* scorable at the text level via
  bag-of-words Jaccard against the known script.
- **A short identifying tone at the head of each turn** (a distinct fixed frequency per
  participant) — a third, ASR-free channel. Generate with ffmpeg, not TTS.
- **An overlap block near the end** where two participants speak simultaneously. Every
  correlator so far has died there, and a corpus that omits it will certify a fragile
  solution as good. Include it deliberately.

Two independent scoring paths matter because they fail differently. If timing says track-5
is Bravo and text says Alpha, that disagreement is itself a finding — surface it, do not
average it away.

Passage text is lexically distinctive per participant (each speaker owns one semantic
domain, so content words barely overlap after stopword removal) — that is what makes Jaccard
discriminate. Names, digits, and number words are absent deliberately: ASR normalises them
inconsistently. Keep all of that true if you touch the passages.

**Alpha and Bravo share one TTS voice.** Separation must come from the per-participant
source, not from the audio sounding different, and two acoustically indistinguishable
participants are the case that catches a pipeline leaning on timbre. Host and Charlie are
distinct voices, and distinct from each other in gender and accent, so a run that fails only
on the shared pair localises the fault. The overlap pair is deliberately *not* the
shared-voice pair — see `README.md` — so those two variables are never tested together.

## Corpus generation

**The speech itself is rendered manually — you do not call the ElevenLabs API.** Tom
generates it and drops the files in. Your job is assembly, verification, and everything
downstream.

- The passages, the slot grid, and the renderer are already written: see `README.md`,
  `scripts/*.txt`, and `generate.py` alongside this brief. Four speakers on lexically
  disjoint domains, four numbered passages plus one overlap passage each, rendered
  one file per passage to `raw/<speaker>-<label>.mp3` — twenty files. Treat `README.md`
  as the specification; copy it into the harness directory as the corpus's own README.
- `raw/manifest.json`, written by `generate.py`, already carries the model, output format,
  seed, voice settings, per-speaker voice ids, and per-passage text and SHA-256. Fold it
  into the scenario manifests rather than re-deriving any of it.
- Build the assembler to consume `raw/` and fail loudly with the file name if a passage is
  missing or its SHA-256 does not match the manifest. It must never silently produce a
  short or misaligned WAV.
- ffmpeg does the assembly: head tones (generated, not spoken), silence padding to slot
  boundaries, concatenation, conversion to 16-bit PCM WAV at a fixed sample rate (48 kHz
  mono unless you find Chrome objects), and construction of the overlap block.
- **Cache by content hash** of the `raw/` inputs plus the slot grid. Reassembly must be free
  when nothing changed, and must never silently produce different audio when something did.
  Commit the passages, the slot schedule, the manifest, and the hashes; the assembled WAVs
  are build output, but the `raw/` renders are *not* reproducible without a manual step —
  weigh that when deciding what to commit, and say what you decided and why.
- Record the ElevenLabs voice id and model id per speaker in the manifest, from whatever
  Tom used. A re-render with a different voice is a different corpus and must be visible as
  one.
- Verify what you assembled: assert each WAV's duration, format, and per-slot energy
  envelope match the schedule before any browser is launched. A corpus that silently drifted
  is worse than no corpus.

### What not to reuse

The repo has no speech corpus — only ~60 words of illustrative dialogue (the "standup"
exchange in `docs/data-formats.md`, the disfluency lines in the cleanup tests). Do not build
the corpus from those. Two reasons: they are far too short, and
`TranscriptRenderingTests.swift` asserts byte-for-byte equality against the doc, so anything
that touches them breaks a test for an unrelated reason.

### Why speech and not just tones

Tones are cheaper and score beautifully — a unique frequency per speaker is identifiable by
FFT with near-perfect confidence, and in the overlap block you could measure *both*
speakers' presence in a mixed track, which speech cannot do. The reason the corpus is
nonetheless speech is that Meet's audio path is speech-tuned end to end, and four things
between the fake mic and the transcript may treat a sine tone as non-speech:

- WebRTC noise suppression, which is built to attenuate exactly that kind of steady signal
- Opus in voice mode, plus DTX, which may transmit nothing during a "silent" stretch
- Meet's local speaking analyzer — the one driving the speaking-ring DOM that journal #111
  and #118 feed into `SpeakingCorrelator`. If the ring never lights, the correlator, which
  is among the most important things under test, cannot be exercised at all.
- the daemon's own per-source VAD, which would emit no speech spans

Tones-only would exercise the capture and seam layer while silently skipping the identity
correlator and everything downstream of it. That is most of the value.

**This is a testable assumption, not a settled one, and the head tones already in the design
carry the same risk.** So the first thing the harness does — before any scenario runs — is a
tone-viability probe: one guest, a WAV of pure tones at the four head frequencies, and three
checks. Does the audio reach the host at all, does Meet's speaking ring light for that
guest, does the daemon's VAD emit spans. Report all three.

If all three pass, say so prominently: a tones-only corpus then becomes a legitimate cheap
mode for capture-layer regression runs, and the harness should be structured so that mode is
a corpus swap rather than a rewrite. If the ring stays dark, that is decisive for speech and
also means the head tones need rethinking.

## The manifest (ground truth)

One JSON file per scenario, versioned, that a scorer six weeks from now can read without
this conversation. At minimum:

- scenario id and schema version
- participants: label, display name typed at join, WAV path + hash, ElevenLabs voice/model
- the slot schedule: per slot, participant, start/end offsets relative to that
  participant's audio start, and the exact passage text
- head-tone frequency per participant
- the overlap block's slots
- intended join/leave offsets, and (filled in at run time) actual ones
- run metadata: timestamp, Meet code, resulting session id, extension version, Chrome
  version, host machine

**Keep the WAVs, the slot schedule, and the resulting session id together.** The corpus is
only valuable if an old run can be re-scored against a new algorithm.

## Runner

Two phases. Do not skip to phase 2.

**Phase 1 — local, no container.** Separate `--user-data-dir`s let multiple Chrome instances
coexist on macOS:

```sh
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --user-data-dir=/tmp/gt-alpha \
  --use-fake-device-for-media-stream \
  --use-file-for-fake-audio-capture=/gt/alpha.wav%noloop \
  --use-fake-ui-for-media-stream \
  --autoplay-policy=no-user-gesture-required \
  --remote-debugging-port=9223 \
  "https://meet.google.com/<code>"
```

No container, no Xvfb, no audio routing. This should produce real data on day one.

The instrumented participant launches the same way, with `host.wav` and its own
`--user-data-dir`, plus the built extension loaded — it differs from a guest only in
carrying the extension and in `earsd` running behind it.

**Phase 2 — containerise the guests only.** `container` and `docker` are both available at
the CLI. Xvfb + headful Chrome is safer than `--headless=new`, which Meet has historically
been unhappy with. The instrumented browser stays on macOS; only the dumb audio sources move
into containers. The container is an optimisation of something that should already be
working — treat it that way.

### Browser control

Use `rodney` (see the `rodney` skill) for guest automation. Rodney launches its own Chrome
by default, which will not carry the fake-device flags, so use **`rodney connect
<host:port>`** against a Chrome you launched yourself with the flags above. Give each guest
its own `RODNEY_HOME` so concurrent sessions do not collide, and never touch the user's
global `~/.rodney` session. If `rodney connect` turns out not to work against a
self-launched Chrome, say so and fall back to CDP directly rather than quietly dropping the
fake-audio flags.

Per guest, the automation is small: open the meet URL, type the display name, click join,
wait to be admitted, stay, and (for `s4`) leave at the scheduled offset.

### Host side

The convener (running Brave) is driven with the Claude in Chrome tools, and only to create
the meeting and open access — rodney is for the launched browsers. The instrumented
participant runs the built extension (`cd browser && npm run build`, load
`browser/.output/chrome-mv3` unpacked) with a `#if DEBUG` `earsd` behind it, reading
`host.wav` through the file-backed capture provider. Capture, per run:

- the session id and full `sessions/<uuid>/` tree
- `events.jsonl` (attendee_joined / attendee_left are directly scorable against the manifest)
- `session.toml` roster and the per-participant source ids
- extension console logs, filtered to the capture-seam and identity paths

## Scoring

A standalone scorer that takes `(manifest, session dir)` and emits a structured report plus
a non-zero exit on regression. Three independent scores, reported separately:

1. **Roster** — declared display names vs `session.toml` attendees and
   `browser:<platform>:<participant>` source ids; join/leave times vs `events.jsonl`.
2. **Timing/energy** — per-source energy envelope vs the slot schedule; zero-lag
   cross-correlation between each captured source and each reference WAV. This is the path
   that caught the mic duplication; it needs no ASR.
3. **Text** — bag-of-words Jaccard between each source's transcript segments and each
   participant's known passages.

Report the confusion matrix (which reference each captured source actually matched), not
just a pass/fail. Explicitly flag disagreement between paths 2 and 3. Also report
duplication: two captured sources matching the same reference is the mic-duplication
signature and must not score as a pass.

## Questions the first real run should answer

The harness earns its keep by answering these; make sure the instrumentation captures what
each needs, and write up the answers.

- Whether the neteq fan-out is a fixed pool of 3 or scales with participants — join guests
  one at a time and count `MediaStreamAudioDestinationNode`s off the neteq worklet at 1, 2,
  3 and 4 remotes.
- Whether a **real** remote participant's decoded track reports `groupId` — the gap the solo
  test left open, and the only direction that can lose audio (see journal #119).
- Whether journal #106's one-to-one finding survives de-confounding at 2 and 4 participants.
- Whether `seamTracksToRetire` and the `local via=device-settings` skip line actually fire —
  they need a remote unmute escalating to the webaudio seam, which a solo call structurally
  cannot produce.
- Whether the webaudio-seam self-audio exclusion (journal #117) holds when the local mic is
  carrying *known, loud, identifiable* speech. This is the case the two-file-reader design
  exists to make testable: `host.wav` goes out over Meet through the fake device, so a seam
  that wrongly taps self-audio now taps something recognisable instead of silence. A feed of
  silence would have passed this test for the wrong reason.

## Known gotchas

- Meet's noise suppression and AGC will process the fake input. Turn them off in Meet's
  audio settings for bit-exact expectations; for identity scoring it does not matter, but
  record which way you ran it.
- Camera absence is fine — "Camera not found" still joins normally.
- Late-admitted guests change the track timeline. Stagger joins deliberately and record the
  actual times.
- Anything that writes into a live Meet beyond joining, naming, and leaving is out of scope.
  Do not enumerate or log real participant names from any call that is not this synthetic
  corpus.

## Deliverables

Live under a single directory in the repo (`test/ground-truth/` unless you find a better
fit) and follow `docs/engineering-practices.md`:

- the passage scripts and slot grid (`README.md`, copied in as the corpus README)
- the assembler (`raw/` renders → per-scenario per-speaker WAVs, cached, verified)
- the four scenario manifests
- **the file-backed `CaptureEngineProvider`, compile-time gated**, with unit tests — this one
  lands in `daemon/`, not here, and is the only change to shipping code the harness requires
- the runner (phase 1 local; phase 2 containerised guests)
- the scorer + report format
- a README covering: how to run one scenario end to end, what each score means, how to add a
  scenario, and how to re-score an archived run against a new algorithm
- the write-up of the first real run's answers to the questions above

## How to work

- Build and verify in order: tone-viability probe → file-backed capture provider (with its
  unit tests, and a `s1-solo` daemon-only run proving `mic` carries `host.wav`) → assembler →
  verification of the assembled corpus → phase-1 runner on `s1-solo` → scorer on that one
  session → the remaining scenarios → containerisation. Do not build all four scenarios
  against an unverified runner.
- The probe comes first because its result can change the corpus design, and it needs
  nothing but one guest and a generated WAV.
- The capture provider comes second because it is the only shipping-code change, it is
  testable with no browser at all, and everything downstream trusts the `mic` source.
- Nothing in this harness requires installing an audio driver or touching the user's
  daily-driver Brave profile beyond creating a meeting in it. If you find yourself about to
  do either, stop and ask — it means a design assumption has broken.
- Report what you actually observed, including where an assumption in this brief turned out
  wrong. A negative finding written down beats a harness that quietly works around it.
