# Architecture

## Overview

```
   audio sources                   earsd (daemon)              on-disk audio store
 ┌───────────────┐   Core Audio   ┌──────────────────┐  writes   ┌──────────────────────┐
 │ microphone    │──────────────▶ │  per-source      │─────────▶ │ <root>/sessions/<id>/│
 │ system audio  │──────────────▶ │  capture engines │           │   session.toml       │
 │ per-app audio │──────────────▶ │  + VAD           │           │   events.jsonl       │
 │ browser ext.  │──push (WS)───▶ │  (session-scoped)│           │   sources/<sid>/     │
 └───────────────┘                └────────┬─────────┘           │     chunks/ asr/     │
                                           │ control socket      └─────────┬────────────┘
                                           │ (status, sessions,            │ reads (files)
                                           │  live feed)                   ▼
                              ┌────────────┴───────┐         ┌──────────────────────────┐
                              │ ears / browser ext.│         │ transcribe → cleanup →   │
                              │ (session lifecycle)│────────▶│ summarize                │
                              └────────────────────┘  invoke └─────────────┬────────────┘
                                                                           │ writes
                                                                           ▼
                                                             ┌──────────────────────────┐
                                                             │ <output>/YYYY-MM-DD/*.md │
                                                             └──────────────────────────┘
```

Four cooperating parts:

1. **`earsd`** — the always-running capture daemon. Boots idle and records only while a session is active: a session names its sources, capture starts, and everything recorded lands under that session's own directory. Owns the session lifecycle, the VAD index, retention, and the control plane. It is the only writer to the audio store and is never in the read path.
2. **The audio store on disk** — the storage contract, one directory per session. Its documented layout *is* the read API. See [data formats](./data-formats.md).
3. **The frontends** — the `ears` CLI, the browser extension, and the menu bar app (`ears-menubar`), control clients that start and end sessions over the control plane. The daemon owns the state machine; frontends only signal.
4. **The pipeline tools** — `transcribe`, `cleanup`, `summarize`. Independent binaries that read files (and, for streaming, tail the live index) and write Markdown outputs. The daemon spawns a chain of them when a session ends — the chain that session's starter declared, or, for a session that declared none, the per-trigger default (`on_end_stages`, applied to browser sessions).

## The disk-as-API contract

The store's on-disk layout is a stable, documented interface. Any tool — and any future front-end — reads audio, the VAD index, and session metadata directly from files. Deliberate consequences:

- The daemon is not a bottleneck or single point of failure for reads. If `earsd` crashes, everything already captured stays readable and transcribable.
- Tools are developed and tested against a fixture audio store with no daemon running.
- `ls`, `cat`, `jq`, and `tail -f` are first-class debugging tools.

The daemon owns **writes** to the audio store. No other tool writes there. Pipeline tools write only to the configured output location.

## The control plane

`earsd` serves the same command set on two transports (see the [capture-daemon spec](./specs/capture-daemon.md) for the wire protocol):

- A **Unix domain socket** (default under the runtime dir) — the privileged plane the `ears` CLI and pipeline tools use. Newline-delimited JSON request/response with correlated ids, plus a subscribe mode: a snapshot of live state, then revision-tagged events (session and source changes) and telemetry (VAD transitions, transcript segments, job progress).
- A **loopback control WebSocket** (`[earsd.control_ws]`, off by default) — the browser extension's route to the same commands, gated by a fail-closed `Origin` allowlist and limited to observation plus the session verbs.

Audio ingestion is separate: the extension pushes binary PCM over a dedicated **loopback ingest WebSocket** (`[earsd.ingest_ws]`) that accepts nothing but `ingest.open`/`ingest.close` and audio frames. Results always land on disk; the sockets carry control and notifications only.

The full contract — correlated requests, snapshot-on-subscribe, the daemon-owned session lifecycle — is specified in [control protocol v2](./specs/control-protocol.md).

## Sources

A **source** is an independently-captured audio stream with a stable id. Sources are kept fully separate end to end: separate audio directories, separate VAD indices, separate transcripts. Classes:

- `mic` — the default (or a named) input device.
- `system` — aggregate system output audio, via a Core Audio process tap.
- `app:<bundle-id>` — system audio scoped to one application (e.g. `app:us.zoom.xos`), via per-process tap inclusion lists.
- `browser:<platform>:<participant>` — per-participant call audio pushed in by the browser extension, created lazily on first ingest.
- `device:<uid>` — a specific external input device.

Keeping mic and system/app audio separate is what yields you-vs-them attribution for free; per-participant browser sources extend it to named speakers.

## Data flow

**Capture (session-scoped):** the daemon boots idle. When a session starts (`session.start` from the browser extension or the CLI), the daemon starts capture of the session's sources; each engine appends encoded, time-stamped chunks — and its VAD appends speech/silence spans — under `sessions/<id>/sources/<sid>/`. Pause and resume are marks over the recording, never capture control. When the session ends, capture stops and the actors are torn down; for browser-triggered sessions the daemon then runs the on-end pipeline — `transcribe --session <id>`, then `cleanup` and `summarize` over its output (`[earsd.sessions] on_end_stages`).

**Retention (transcript-driven):** after a session ends and its transcript completes, the session's audio is kept `evict_after_transcript_seconds` (default 2 h), then the whole `sources/` directory is deleted in one pass. A session whose transcript never completed keeps its audio until `max_audio_age_seconds` (default 7 days) after it ended, so a failed transcription can be retried, then it too is deleted. `session.toml`, `events.jsonl`, and transcripts are never deleted.

**Transcription and downstream:** `transcribe` resolves a session (or a raw source + range) to chunks via the index, skips silence using VAD spans, runs the ASR model, and writes a transcript. `cleanup` corrects it with an LLM and the vocabulary list. `summarize` renders summaries from configured prompts. Each step is separately invokable and communicates only through files.

**Streaming:** `transcribe --follow <source>` tails a live source's index, decodes incrementally, emits finalised segments to stdout, appends to the transcript file, and republishes segments onto the daemon's live feed (`segment.publish`) for other subscribers. Batch and streaming produce the same on-disk format.

## Concurrency & runtime model

The core is **headless and actor-based** — a hard constraint, not a style preference:

- **No `@MainActor` anywhere in the core.** Engines, managers, and protocols are `actor`/`Sendable` boundaries, enforced by Swift 6 strict concurrency. The one valid exception is a realtime type where an actor would add latency; there, a lock plus `@unchecked Sendable` is acceptable, deliberately and locally.
- **Actor decomposition inside `earsd`:** one `CaptureActor` per source (its capture backend, chunk writer, and VAD), built when a session names the source and torn down when the session ends; a `ControlServer` owning the control plane; and a `SessionRegistry` owning the session lifecycle. Per-source actors isolate failures — one source's teardown never stalls another.
- **Generation counters guard every teardown.** Every IO-proc/tap callback is gated by a generation counter so a stale hardware callback from a torn-down engine cannot corrupt a new one after a device hot-swap. Any `await` in a capture path re-checks ownership before acting on the result.

### Two stores, kept distinct

There are two buffers in the capture path, and conflating them is a known bug source:

1. **The in-RAM jitter buffer** — a per-source, fixed-size, lock-free single-producer/single-consumer circular buffer. The real-time IO-proc is allocation-free and only publishes samples into it; a separate worker drains it for encoding and disk I/O. Under sustained backpressure it drops loud: a dropped-sample counter is logged, and after N consecutive drops the stream fails rather than growing unbounded. Milliseconds-to-seconds deep.
2. **The on-disk audio store** — each session's recorded chunks, bounded by the session's duration and deleted wholesale by transcript-driven retention. Files, not RAM.

## Module structure

One Swift package (`daemon/`), split so almost all logic is unit-testable without hardware:

- **`EarsCore`** — pure library, no I/O: VAD-index reading and range reconstruction, segment merging, streaming-delta emission, frontmatter serialisation, socket message types, config layering. Deterministic and tested in isolation.
- **Protocol seams at every hardware/model boundary:** `CaptureBackend`, `Transcriber`, `StreamingTranscriber`, `Diarizer`, `VAD`, `PermissionProviding`. Each has a mockable default; the [model interface](./specs/model-interface.md) specifies the ASR/diarization ones.
- **Thin shims behind those protocols:** `EarsCaptureKit` (Core Audio, process taps), `EarsTranscribeKit` (FluidAudio/Parakeet), `EarsDataStore` (chunk I/O), `EarsIPC` (sockets, WebSocket servers), `EarsLLMKit` (LLM subprocess), plus `EarsConfig`, `EarsLogging`, `EarsCLISupport`, and `EarsDaemonKit` (daemon wiring).
- **Executables** (`earsd`, `ears`, `transcribe`, `cleanup`, `summarize`) are small — they wire libraries together and own no business logic.

## Failure and robustness

- **Daemon crash:** captured data remains readable; on restart a `gap` event covers the downtime.
- **Disk pressure:** audio accrues only while sessions are active, and transcript-driven retention deletes each session's audio shortly after its transcript lands (hard-capped at `max_audio_age_seconds` for failed runs); every deletion is logged.
- **Model/LLM failure:** pipeline stages fail loud with non-zero exits; outputs are written atomically (temp + rename) so a failed run never corrupts a good transcript.
- **Backpressure on ingestion:** if a socket producer outruns the daemon, buffering is bounded and drops are logged rather than growing without limit.
