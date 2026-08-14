# Ground-truth speech scripts

Four speakers, each locked to a distinct semantic domain so their content words barely
overlap. That is what makes the text-level score (bag-of-words Jaccard against the known
passage) actually discriminate — after stopword removal, the vocabularies are effectively
disjoint.

Constraints these passages already satisfy, keep them if you edit:

- No proper nouns, no digits or number words — ASR normalises both inconsistently.
- No cross-domain content words.
- 20–22 words each, ≈7–8 s at a normal TTS rate, comfortably inside a 12 s slot.
- Natural spoken register, not lists — a voice reading a list produces flat prosody and
  unnatural pauses at the commas.

## Speaker identity

| Speaker | Display name at join | Domain | Head tone | Voice |
|---------|---------------------|--------|-----------|-------|
| Host | (host account's own name) | soil / garden | 383 Hz | George — male, British |
| Alpha | `GT-Alpha` | sailing / harbour | 521 Hz | Sarah — female, American |
| Bravo | `GT-Bravo` | baking / bread | 673 Hz | Sarah — **same voice as Alpha** |
| Charlie | `GT-Charlie` | astronomy / telescopes | 947 Hz | Roger — male, American |

**Alpha and Bravo share a voice on purpose.** Separation has to come from the
per-participant source, not from the audio sounding different; two participants who are
acoustically indistinguishable are the case that finds a pipeline leaning on timbre. Host
and Charlie stay distinct — and distinct from each other in gender and accent — so a run
that fails only on the shared pair localises the fault immediately.

Tone frequencies are primes with no small-integer ratios between them, so no tone can be
mistaken for another's harmonic. Generate them with ffmpeg, not TTS.

## How to render

`generate.py` alongside this file does it, through the ElevenLabs Python SDK:

```sh
uv run generate.py --env-file /path/to/.env voices     # list the account's voices
uv run generate.py --env-file /path/to/.env render     # 20 passages → raw/
```

The key is read from `--env-file`, else `.env` beside the script, else the nearest `.env`
above the working directory. Do not copy the `.env` into this directory if it lives under
`/tmp` — that is world-readable.

`voices.json` is already filled in with the assignment above. The script refuses to run if
Alpha and Bravo do not share a voice, if there are not exactly three distinct ids, or if a
script file does not hold exactly five passages.

**One file per passage** — `raw/host-p1.mp3` … `raw/charlie-ov.mp3`, twenty in all. Slot
timing belongs to the harness, and per-passage files remove any dependence on the TTS
honouring paragraph breaks.

Renders are cached on a fingerprint of the text, voice, model, output format, seed, and
voice settings, so re-running is free until one of those changes. `--force` overrides.
`raw/manifest.json` records all of it plus a SHA-256 per file — that is what makes an old
corpus identifiable later. A re-render with a different voice is a different corpus, and the
manifest is what makes that visible.

Pinned for reproducibility: `eleven_multilingual_v2` (v3's dramatic delivery adds prosody
variance a fixture does not want), `mp3_44100_128`, a fixed seed, and stability 0.5 /
similarity 0.75 / style 0. ffmpeg converts to 16-bit PCM WAV during assembly.

---

## Host — soil and garden

**p1.** The clay under the back border stays wet all winter, so I forked in leaf mould and
coarse grit last autumn.

**p2.** Slugs shredded the young hostas again, but the copper ring around the raised bed
seems to be holding them off.

**p3.** I moved the compost heap nearer the shed and turned it twice, and the middle is
already warm enough to steam.

**p4.** Pruning the espaliered pear too late cost me most of the fruiting spurs, so this year
I cut back in midsummer.

**ov.** The greenhouse vents jam whenever the humidity climbs, so I prop them open with a
length of bamboo cane.

## Alpha — sailing and harbour

**p1.** We reefed early because the forecast promised gusts through the afternoon, and the
swell was already stacking up outside the harbour.

**p2.** The tide turned against us near the headland, so we ferry glided across and let the
current do the work.

**p3.** Halyards slap all night in the marina, which is why I lash them away from the mast
before turning in.

**p4.** Anchoring in that bay is fine on sand, but the weed patches nearer the shore refuse
to hold a hook.

**ov.** Our chartplotter lost its fix twice on the crossing, so we fell back on the compass
and a paper chart.

## Bravo — baking and bread

**p1.** My starter doubles overnight now, which means the kitchen has finally warmed up
enough for a decent rise.

**p2.** Scoring the loaf deeper gave a much better ear, though the crumb is still tighter
than I would like.

**p3.** I switched to a wetter dough and stretched it in the bowl instead of kneading it on
the counter.

**p4.** Steam matters more than heat at the start, so I throw a tray of boiling water onto
the oven floor.

**ov.** Rye behaves nothing like wheat, it goes sticky under the hands and needs a far
shorter proof.

## Charlie — astronomy and telescopes

**p1.** Collimation drifts every time I carry the scope down the stairs, so I check the
secondary mirror before anything else.

**p2.** Seeing was poor last night, the planet boiled at high magnification and only settled
during a few brief gaps.

**p3.** Light pollution washes out the fainter galaxies, but the narrowband filter still
pulls the nebula out of the glow.

**p4.** Tracking held well until the counterweight slipped, and after that every long
exposure trailed right across the frame.

**ov.** Dew on the corrector plate ends the session faster than cloud, so the heater strip
goes on early.

---

## Slot grid

Slot length 12 s: 0.5 s head tone, ~0.3 s gap, the passage, then silence to the boundary.
With N speakers, speaker *k* takes slots *k, k+N, k+2N*, silent elsewhere — three rounds, so
each speaker uses p1–p3 in order. p4 is spare: use it when a scenario needs a fourth round
(`s4-staggered` does, because a late joiner must still get three turns after admission).

**Overlap block** runs after the last round: two speakers deliver their `ov` passage
simultaneously, starting together. In `s1-solo` there is nobody to overlap with, so the block
is omitted; in `s2` it is host + Alpha; in `s3` and `s4`, **Bravo + Charlie**, with the host
and Alpha silent so the block isolates a clean two-way collision.

Bravo + Charlie rather than Alpha + Bravo deliberately: the overlap pair must not also be the
shared-voice pair, or a failure in that block could be either cause and the run tells you
nothing. Shared voices are tested in the clean disjoint rounds; simultaneous speech is tested
with distinct voices. One variable each.

Each speaker's WAV is their passages placed at their own slot offsets with silence
everywhere else — so every file is the full call length, and all files start together at
`t=0` of that speaker's join. `%noloop` keeps it that way.
