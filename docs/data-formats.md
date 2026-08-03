# Data formats

This document defines the on-disk contract. Because the storage layout *is* the read API, these formats are stable interfaces: tools depend on them, so they are versioned and changed deliberately.

## Directory layout

```
<data-root>/                         # default: ~/Library/Application Support/ears
  sessions/
    <uuid>/                          # one directory per session — audio is session-scoped
      session.toml                   # session record (schema 3: identity, state, intervals,
                                     #   roster, sources); kept forever, never evicted
      events.jsonl                   # append-only session timeline; kept forever
      sources/                       # AUDIO — deleted as one unit by retention
        <source-id>/                 # e.g. mic, system, browser_meet_jane
          meta.toml                  # source descriptor (class, device, sample rate, codec)
          chunks/                    # native-rate listenable copy (default 48kHz mono)
            2026-07-17T10-30-00Z.<ext>   # time-stamped compressed audio chunk
            2026-07-17T10-30-30Z.<ext>
          asr/                       # derived 16kHz mono feed the transcriber consumes
            2026-07-17T10-30-00Z.<ext>
          chunks.jsonl               # structural index: chunk/gap events
          vad/                       # segmented VAD stream (speech/silence spans)
            2026-07-17T10-30-00Z.jsonl   # one size/time-rotated segment, named by first event
  sources/                           # legacy global ring — read-only fallback, never
    <source-id>/                     #   written by live capture any more
  vocab/
    global.txt                       # global known-word list
    <session-id>.txt                 # optional per-session vocabulary (session UUID)
  runtime/
    earsd.sock                       # control socket (path configurable)
    earsd.pid

<output-root>/                       # default: ~/Documents/Transcripts
  2026-07-17/
    10-30-00_standup.transcript.md   # transcript (from `transcribe`)
    10-30-00_standup.clean.md        # cleaned transcript (from `cleanup`)
    10-30-00_standup.summary.md      # summary (from `summarize`)
    10-30-00_standup.transcript.json # optional canonical sidecar (word timings, confidence)
```

`<source-id>` is the source's stable id with characters unsafe for paths replaced by `_` (e.g. `app:us.zoom.xos` → `app_us.zoom.xos`). The id itself, as used on the socket and in metadata, keeps its natural form.

Audio is **session-scoped**: a source records only while a session names it, and everything it writes lands under that session's own `sources/` tree. Two consequences:

- **Transcripts** (under `<output-root>`) are never evicted — they are the durable artifact.
- **Retention is a per-session delete.** Once an ended session's transcript has been complete for `evict_after_transcript_seconds` (default 2 h) — or, if no transcript ever completed, once the session has been over for `max_audio_age_seconds` (default 7 days) — the daemon deletes the whole `sessions/<uuid>/sources/` directory. `session.toml` and `events.jsonl` survive as the session's record. See `[earsd.retention]` in [configuration](./configuration.md).

The daemon enforces a **single-active-session invariant**: a `session.start` for a new identity (or a manual start) supersedes any session still live, running the old one through its full end pipeline first. At most one active session means exactly one legal directory for any capture actor at any moment, so a source's audio can never land in the wrong session's directory.

**Legacy directories are ignored, not migrated.** Pre-2026 layouts left two dead formats on disk: `sessions/<timestamp-slug>/` directories holding a schema-1 `session.toml`, and a `meetings/<uuid>/` tree holding schema-2 `meeting.toml` records. Nothing reads either — the session scan skips any descriptor whose `schema` isn't 3, and the `meetings/` tree is never consulted. They can be deleted by hand at any time.

## Audio chunks

- Fixed-duration chunks (default 30 s), named by their UTC start instant, ISO-8601 with `:` replaced by `-`.
- Compressed: AAC in an M4A container, or Opus. Codec and bitrate are per-source config, recorded in `meta.toml`.
- Chunk boundaries are a storage detail, independent of speech. Speech spans live in the index and may cross chunk boundaries.
- Chunks are never deleted individually. A session's audio grows for the session's duration and is deleted as one directory by transcript-driven retention (see above).
- Written atomically (temp + rename); on flush, `fsync` both the file and its directory.

### Dual-rate storage

Each source stores **two feeds**, because 16 kHz mono is what the ASR model wants but is unpleasant to re-listen to:

- **`chunks/`** — a native-rate (default 48 kHz) mono, listenable copy. This is the durable retained audio.
- **`asr/`** — the derived 16 kHz mono feed the transcriber consumes.

Both share the same chunk naming and index. Set `store_native = false` per source to keep only the ASR feed when disk matters more than playback.

### `meta.toml` (source descriptor)

```toml
schema = 1
id = "app:us.zoom.xos"
class = "app"            # mic | system | app | browser | device
label = "Zoom"
device_uid = ""          # for device/mic sources
native_sample_rate = 48000
asr_sample_rate = 16000
store_native = true
channels = 1
codec = "aac"
bitrate = 64000
created = "2026-07-17T10-30-00Z"
```

## The index (`chunks.jsonl` + `vad/`)

The index is split across two logs, both append-only JSON Lines (one event per line, ordered by time), because `vad` events outnumber the rest by roughly 50-to-1 yet are consulted only when reconstructing a specific range:

- **`chunks.jsonl` — the structural log.** `chunk`/`gap` events. Small, and read whole to recover the chunk set. Nothing else is needed to answer "which audio exists".
- **`vad/<timestamp>.jsonl` — the segmented VAD stream.** `vad` speech/silence spans, written to segments that roll over on a byte cap (~8 MB) or a wall-clock span (~1 h), each named by its first event's start. A range read opens only the segments overlapping the range.

It maps wall-clock time to audio and records speech activity so transcription can skip silence. Event types:

```jsonc
// a written chunk
{"t":"chunk","start":"2026-07-17T10:30:00Z","end":"2026-07-17T10:30:30Z","file":"chunks/2026-07-17T10-30-00Z.m4a","frames":480000}

// a VAD span (speech or silence), possibly spanning chunk boundaries
{"t":"vad","state":"speech","start":"2026-07-17T10:30:02.140Z","end":"2026-07-17T10:30:09.880Z"}
{"t":"vad","state":"silence","start":"2026-07-17T10:30:09.880Z","end":"2026-07-17T10:30:14.020Z"}

// a capture gap (daemon down, device lost, pause, stalled push delivery)
{"t":"gap","start":"2026-07-17T10:31:00Z","end":"2026-07-17T10:31:12Z","reason":"daemon_restart"}
{"t":"gap","start":"2026-07-17T10:32:00Z","end":"2026-07-17T10:32:41.5Z","reason":"delivery-stall"}
```

A reader reconstructs available audio for any range from `chunk` events, uses `vad` spans to skip silence, and honours `gap` events as known-missing. Both logs are append-only, so `tail -f chunks.jsonl` and `tail -f vad/*.jsonl` show live capture.

## Sessions (`sessions/<uuid>/`)

The daemon-owned [Session](./specs/control-protocol.md#session) entity — the one lifecycle record. `session.toml` (**schema 3**) carries the fields of the wire's session object — identity, title, state, transcription intervals, roster, sources, trigger, transcript-completion marker — written atomically on every mutation and reloaded at daemon start. Optional scalar fields use an empty string for "absent"; `rev` is deliberately not persisted (revisions are scoped to a daemon boot).

```toml
schema = 3
id = "0d5e7f6a-…"                      # daemon-assigned UUID
platform = "meet"                       # platform identity; "" for manual sessions
external_id = "abc-defg-hij"            # the platform's own meeting id; "" for manual
title = "Weekly sync"                   # renameable; defaults from identity or id
state = "ended"                         # active | paused | ended
started = "2026-07-19T10:00:00Z"
ended = "2026-07-19T10:31:00Z"          # "" while active/paused
transcript_completed = "2026-07-19T10:31:12Z"  # "" until a transcript run succeeds;
                                        #   the marker retention keys off
trigger = "browser-extension"           # manual | browser-extension
sources = ["mic", "browser:meet:jane-a1b2"]

[[interval]]                            # transcription marks over the recording;
start = "2026-07-19T10:00:00Z"          #   pause closes one, resume opens the next
end = "2026-07-19T10:12:30Z"
[[interval]]
start = "2026-07-19T10:20:05Z"
end = ""                                # "" = currently marked

[[attendee]]                            # roster, upserted by whoever knows it
id = "spaces/x/devices/y"               #   (the extension's DOM layer today)
display_name = "Jane Doe"
joined = "2026-07-19T10:00:12Z"
left = ""
source = "browser:meet:jane-a1b2"       # optional link to a per-participant source
```

`events.jsonl` is the append-only per-session timeline — one line per domain event: `started`, `interval_opened`/`interval_closed`, `attendee_joined`/`attendee_left`, `renamed`, and `ended` with `reason = "client"` (explicit `session.end`), `"ingest-idle"` (the orphan grace timer), `"superseded"` (a new `session.start` displaced it), or `"orphaned"` (swept at daemon boot). Written for disk consumers (`summarize`, humans, `jq`), never used for protocol sync.

Tools reject a `schema` other than 3 rather than guessing — which is exactly how the legacy schema-1 and schema-2 descriptors (above) stay inert on disk.

## Transcript format

Human-first Markdown with YAML frontmatter. This is the canonical human artifact; an optional `.transcript.json` sidecar carries full word-level timings/confidence for tooling.

```markdown
---
schema: 1
kind: transcript
session: 0d5e7f6a-…         # the session UUID this transcript unions the
                            # intervals of (`transcribe --session`)
# range_run: 2026-07-17T10-30-00Z_mic
                            # instead of `session:` on a raw range run
                            # (`--last`/`--from`/`--to`) — a synthesized
                            # <start-timestamp>_<slug> identifier
sources: [mic, "app:us.zoom.xos"]
range: { start: 2026-07-17T10:30:00Z, end: 2026-07-17T11:02:00Z }
model: { name: parakeet, backend: fluidaudio, version: "0.x" }
diarization: { enabled: false }
generated: 2026-07-17T11:02:14Z
duration_seconds: 1920
speech_seconds: 1440
word_count: 3120
vocab: [global, standup]
# audio_stores: ["mic=ring", "app:us.zoom.xos=session"]
#                           # present on `transcribe --session` output only —
                            # which store each source was read from (`session` =
                            # per-session copy, `ring` = legacy global buffer),
                            # so a wrong-store read is visible
---

## [10:30:04] You
Morning — let's keep this quick. Any blockers?

## [10:30:11] app:us.zoom.xos
Nothing from me, the deploy went out last night.
```

Rules:

- Segments are grouped by speaker turn, each headed by a timestamp and a speaker label.
- **Speaker labels** derive from the source: `mic` → `You`, every other source → its source id (a per-participant browser source is therefore already a per-person label). Within-stream diarization — stable `Speaker N` labels inside a multi-speaker source — is designed but not yet implemented.
- `cleanup` and `summarize` outputs use the same frontmatter convention with `kind: clean` / `kind: summary` and a `derived_from` field naming the source transcript. A summary also carries a `preset` field naming the `[[summarize.preset]]` it was generated from.

### Canonical JSON sidecar (optional)

```jsonc
{
  "schema": 1,
  "diarization": { "enabled": false },        // { enabled, backend? } — mirrors the frontmatter
  "segments": [
    {
      "start": 604.14, "end": 611.88,          // seconds from range start
      "source": "app:us.zoom.xos",
      "speaker": "app:us.zoom.xos",
      "text": "Nothing from me, the deploy went out last night.",
      "words": [ {"w":"Nothing","start":604.14,"end":604.51,"conf":0.98} ]
    }
  ]
}
```

The Markdown is rendered from the same data the sidecar holds, so the two never disagree for a given run.

## Speaker attribution

Two independent layers:

1. **Source-level (implemented):** every segment carries its originating source. `mic` maps to you; each `app:`/`system` source maps to the other side; each `browser:<platform>:<participant>` source maps to one named participant. Keeping sources separate through capture and transcription is what makes this attribution free and reliable.
2. **Diarization (offline pass implemented):** an opt-in diarization stage (`[diarize].backend = "sortformer"`) assigns stable `Speaker N` labels within a multi-speaker source, rendered as `<source> · Speaker N` so source attribution stays primary. An optional per-session name map (`Speaker 2` → `Priya`) applied at or after `cleanup`, never mutating timings, remains future work; the live (streaming) pass is a follow-up to the offline pass that ships today.

## Vocabulary / known-word lists

Plain text, one term or phrase per line; `#` comments allowed. A global list plus optional per-session lists (merged, session wins on conflict). The merged list is passed to the `cleanup` LLM prompt as a correction backstop and recorded in transcript frontmatter. Feeding it to the ASR decoder as biasing hints is designed (see the [model interface](./specs/model-interface.md)) but not wired up yet.

```
# global.txt
Parakeet
FluidAudio
Anthropic
kubectl
```

## Schema versioning

Every structured file carries a `schema` integer. Tools reject a `schema` they don't understand with a clear error rather than guessing.
