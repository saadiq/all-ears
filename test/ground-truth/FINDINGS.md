# Findings

What the harness's first runs established, on 2026-08-06 (macOS 15.5 arm64,
Chromium 150.0.7871.46, Brave 151.1.93.129, extension 0.1.7, `earsd` at
`daemon/` HEAD).

Several of these are **negative findings about this harness's own design**. They
are recorded because a negative finding written down beats a harness that quietly
works around it — and because three of them fail *silently*, which is the failure
mode a ground-truth corpus exists to eliminate.

## Status

| Piece | State |
|-------|-------|
| Corpus assembly + verification | **done** — four scenarios, 16 WAVs, all assertions green |
| File-backed `CaptureEngineProvider` | **done** — 6 unit tests, wired, compile-time gate verified |
| `s1-solo` daemon-only run | **done** — `mic` proven to carry `host.wav` |
| Phase-1 runner | **built**; drives a call end to end, blocked below on live joins |
| Scorer | **built**; exercised against the daemon-only run, not yet against a full call |
| Tone-viability probe | **built, not yet answered** — blocked below |
| Scenarios `s1`–`s4` over a live call | **not run** — blocked below |
| Phase-2 containerised guests | **not started** |

## What is blocking the live runs

**Meet appears to throttle repeated anonymous joins.** Across roughly 18
anonymous joins to one meeting from one IP inside an hour, early attempts
succeeded reliably and later ones were refused with increasing frequency, in two
shapes: a redirect to `workspace.google.com/products/meet/`, and "You can't join
this video call". The refusals are not explained by the call being dormant, by
the browser, or by the extension — all three were controlled for:

- the signed-in convener was verified still present in the call at the moment of
  a refusal;
- a plain guest and an extension-carrying guest, launched back to back, both
  reached the pre-join screen in the same minute a run had just been refused;
- the last observed refusal reached the pre-join screen ("What's your name?") and
  was redirected away only at the join click, i.e. it is a server-side verdict,
  not a client failure.

This is a rate-limit shape rather than a configuration one. The mitigations worth
trying, in order: a fresh meeting code per run; spacing runs out; and, if
neither holds, the brief's own stated fallback of persistent `--user-data-dir`s
signed in manually once — which costs the "no credential anywhere" property but
nothing else.

Everything below was established before the throttling set in, or needs no call
at all.

## Confirmed: anonymous guests get real device identities

The brief flagged this as the unverified assumption to check first —
`spaces/<space>/devices/<n>` ids were *believed* to be assigned per joined device
regardless of sign-in state.

**They are.** An anonymous guest that typed `GT-JoinTest` appeared in the host
page's tile roster as `spaces/eJyoB7ZojqsB/devices/269`, and a later one as
`.../devices/571`. So anonymous guests exercise the identity path normally, and
the fallback of manually-signed-in profiles is not needed *for identity*. The
display name typed at join is the ground-truth label, exactly as designed.

## A signed-in participant must stay in the call

The brief's convener design — create the meeting, enable Quick access, leave —
does not work. Anonymous guests are refused when the call has no signed-in
participant, even with meeting access set to **Open** ("This call is open to
anyone"), and even when other anonymous participants are already in it.

Evidence, in order:

| Call state | Anonymous join |
|---|---|
| Convener left, call empty | refused (redirect to marketing) |
| Convener present | admitted, ~5 s |
| Convener killed, but an anonymous guest still in the call | admitted (observed by the user) |
| Call empty again | refused |

The middle two look contradictory until you separate "the call is live" from "a
signed-in user is present": a live call keeps accepting joins that were already
in flight, but reviving a dormant call needs a signed-in user, and an anonymous
user cannot do it.

**Consequence for the harness:** the convener stays for the whole run and is a
real participant. It is therefore *declared* — `run.py` records it under
`run.observers`, and `score.py` treats a recorded observer as
expected-but-not-scored while still failing on an attendee that is neither
declared nor recorded.

**Join in Companion mode** ("Other ways to join" → "Use Companion mode"). Meet
then reports "your speakers and mic are unavailable to avoid echo": the convener
holds the call open while contributing no audio at all, which is exactly what the
corpus needs from it. A plain muted join also works but leaves a live mic one
click away from the ground truth. Companion mode was verified to satisfy the
signed-in-presence requirement (two guests joined against a Companion-mode
convener).

## Three ways the fake-audio rig fails silently

All three were found by instrumenting rather than by reasoning, and all three
produce "the corpus is silently wrong" rather than an error.

### 1. The audio-service sandbox blocks the file, and reports success

Without `--disable-features=AudioServiceSandbox`, `--use-file-for-fake-audio-capture`
on macOS produces a fake device that appears normally, reports
`label: "Fake Default Audio Input"`, delivers frames at the right rate — and
every single sample is digital zero.

```
Chromium 150, no flag       38 windows, peak RMS 0.000000
Chromium 150, sandbox off   1110 Hz at RMS 0.0884  (file is 1111 Hz at RMS 0.0884)
```

`--disable-features=AudioServiceOutOfProcess` also works. The sandbox variant is
preferred: it keeps the audio service out of process, closer to production.

`browsers.py preflight` asserts against this before every run, using its own
generated tone at a frequency that is *not* one of the four head tones — so a
stale corpus WAV cannot pass the check.

Also measured: the fake device is **level-transparent**. The file's RMS and the
RMS observed in the page were identical to four decimal places. Chrome does
resample and re-channel it (`getSettings()` reports 44100 Hz, 2 channels from a
48 kHz mono file), which does not matter downstream since Opus is 48 kHz anyway.

### 2. `%noloop` does nothing

The brief states `%noloop` matters because without it the file repeats and the
slot schedule drifts out of alignment. The flag has **no effect** on either
browser here:

| Setup | At t=16 s of a 5 s file |
|---|---|
| `file.wav%noloop` | still full level — looped |
| `file.wav` | still full level — looped |
| `file.wav%bogus` | no capture at all |

The `%bogus` result proves the suffix *is* parsed; `noloop` simply is not
honoured. The design no longer depends on it: every participant WAV carries
`LOOP_GUARD_SECONDS` (120 s) of trailing silence so the file cannot reach its end
inside a run, and the runner stops the call well before the loop point. The flag
is still passed — harmless, and correct if a future build honours it.

The daemon-side reader has no such problem: `FileAudioSourceProvider` emits
silence past the end and never loops, with a test asserting exactly that.

### 3. `getUserMedia` needs a secure context

A preflight page served from `file://` fails with `NotAllowedError` and reads
*identically* to the sandbox problem above. The preflight server binds
`127.0.0.1`, which is potentially-trustworthy.

## Two ways the join automation failed

**A browser navigated to the meeting after `about:blank` is refused.** The same
browser, same flags, same call, started with the meeting URL as its startup
argument reaches the anonymous pre-join screen every time. `launch()` therefore
takes the URL.

**A click on a disabled button reports success.** Meet enables "Join now" a beat
after rendering it, and `HTMLElement.click()` on a disabled button is a silent
no-op. The first implementation clicked once, believed itself, and then waited out
its whole admission timeout on the pre-join screen — which is indistinguishable
from a refusal, and cost two runs before it was caught by reading the live page
and finding the name field populated with `GT-Host` next to an enabled, unclicked
button. `join_meet` is now one loop that re-asserts the name and re-clicks an
*enabled* button until the call UI appears.

## Browser choice: the brief's preference order inverts

Google Chrome is not installed on this machine. Of what is:

| Browser | Anonymous Meet join |
|---|---|
| Chromium 150, own UA | refused — redirected to marketing |
| Chromium 150, stock Chrome UA | **works** |
| Brave 151, own UA | refused — "You can't join this video call" + "This browser version is no longer supported" |
| Brave 151, stock Chrome UA | refused |

**Meet gates anonymous join on the user agent.** Overriding `--user-agent` fixes
Chromium; it does *not* fix Brave, because the flag does not touch
`navigator.userAgentData`, which still reports Brave. So Brave cannot be a
participant at all, and the brief's preferred order (Chrome → Brave → Chromium)
inverts to Chrome → Chromium → Brave.

Brave Shields, which the brief flags as the live variable in a Brave run, never
came into it. The `BRAVE_PREFS` shields-down profile is retained in `browsers.py`
for the day a Brave run becomes possible, and is currently unused.

The UA override is presentation-layer only — the engine, media stack and
extension are untouched, nothing in the capture path reads `navigator.userAgent`,
and it arguably yields a *more* faithful result by getting the same Meet build a
stock Chrome user is served.

## The daemon half is proven end to end

`s1-solo`, daemon only, no browser: a debug `earsd` on its own data root with
`ALLEARS_CAPTURE_FILE_MIC=build/s1-solo/host.wav`, one manual session, 81.5 s
recorded.

```
captured 81.5s  rms=0.0480  chunks=8  vad_speech=177 spans
cross-correlation vs host.wav:  corr=0.9463  lag=+0.00s
  slot 0 p1: tone_snr= 36770  passage_rms=0.0549
  slot 1 p2: tone_snr=483020  passage_rms=0.0631
  slot 2 p3: tone_snr=497907  passage_rms=0.0731
control  vs alpha.wav   corr=0.2664
control  vs bravo.wav   corr=0.4162
control  vs charlie.wav corr=0.4674
```

So the `mic` source carries the corpus and not the room, the head tones survive
the AAC round-trip with enormous margin, and the daemon's own VAD segments the
corpus speech. This half of the harness is hermetic: no audio hardware, no
driver, no TCC prompt.

**It also calibrated the scorer.** The wrong references correlate at 0.27–0.47 —
comfortably clear of a 0.30 floor — because every participant's file shares the
same slot grid, so their envelopes are structurally similar whatever the speech
is. A floor alone does not discriminate. `score.py` now also requires the winner
to lead the runner-up by `MATCH_MARGIN` (0.15) and reports "ambiguous" rather
than silently assigning. Here the margin was 0.48.

### `device_uid` binding

Not verified. `docs/specs/capture-daemon.md` records that `device_uid` binding
"needs the real-hardware verification pass before it is trusted in a release",
and the brief asked for that pass while the provider work was next door. The
file-backed provider deliberately reports `boundInputDevice == false` (it induces
no configuration change, so claiming one would suppress a genuine route change),
which means it exercises none of the binding path. Verifying the bind needs a
real second input device and a route change, which is a manual runbook item, not
something this harness can assert. It remains open.

## Questions the first full run must still answer

None of these can be answered without a multi-participant live call, so all
remain open:

- whether the neteq fan-out is a fixed pool of 3 or scales with participants;
- whether a **real** remote participant's decoded track reports `groupId` — the
  gap the solo test left open, and the only direction that can lose audio
  (journal #119);
- whether journal #106's one-to-one finding survives de-confounding at 2 and 4
  participants;
- whether `seamTracksToRetire` and the `local via=device-settings` skip line
  actually fire (journal #120 notes these are unobservable in a solo call);
- whether the webaudio-seam self-audio exclusion (journal #117) holds when the
  local mic carries known, loud, identifiable speech — the case the two-file-reader
  design exists to make testable.

One thing already measured that bears on the last: the fake mic **does** report a
`groupId` (`getSettings()` above), so `looksLikeCaptureDevice` classifies the
harness's own local track as a capture device exactly as it would a real mic.
The harness does not perturb the provenance classifier it is meant to test.
