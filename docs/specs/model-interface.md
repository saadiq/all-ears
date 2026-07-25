# Spec: model interface (ASR & diarization)

`transcribe` depends on interfaces, not on any specific model. Parakeet via FluidAudio is the shipping ASR backend.

## ASR backend protocols

Capability-by-protocol, not a god-object `switch` on engine type: a small base protocol plus optional capability protocols a backend opts into. The pipeline checks capability flags / casts to the capability protocol — it never switches on a model name.

```swift
// Base: every backend does this much.
protocol Transcriber {
    var info: ModelInfo { get }              // name, version, capability flags
    func load(_ options: LoadOptions) throws // load weights, pick ANE/GPU/CPU

    // Batch decode a mono PCM buffer into timed segments.
    func transcribe(_ audio: AudioBuffer, context: TranscribeContext) throws -> [Segment]
}

// Optional capabilities — a backend opts in by conforming.
protocol StreamingTranscriber: Transcriber {          // info.supportsStreaming
    // Caller owns continuity: decoder state is explicit and passed inout,
    // so the manager itself stays stateless across sources.
    func step(_ frames: AudioBuffer, state: inout DecoderState) throws -> [Segment]
}
protocol BiasingTranscriber: Transcriber {            // info.supportsBiasing
    func setBias(_ terms: [String]) throws            // decoder-level keyword boosting
}
```

- `TranscribeContext` carries vocabulary/biasing terms, language hint, and prior text for continuity. `Segment` carries `start`, `end`, `text`, optional `words[]` with per-word timing/confidence.
- **Stateless manager, caller owns continuity:** decoder state is passed `inout`, so one manager serves many sources without holding per-source state, and streaming + batch use can share one loaded model.
- `supportsBiasing` decides whether the known-word list is injected at decode or left entirely to `cleanup`.

### The Parakeet/FluidAudio backend

Runs NVIDIA Parakeet through FluidAudio on the Apple Neural Engine via Core ML. Conforms to `Transcriber` and `StreamingTranscriber` (TDT decoder state threaded per step); it does **not** yet conform to `BiasingTranscriber`, so vocabulary currently applies only at `cleanup`.

Integration specifics that are load-bearing (each maps to a real crash or quality bug):

- **Serialize ANE inference** (single-flight gate): concurrent Core ML inference on the ANE can SIGBUS on macOS 14.
- **Reconstruct word timings** by merging `▁`-prefixed SentencePiece tokens into words.
- **Pad trailing silence on short clips** before batch TDT decode, or the decoder drops the final word.
- **Run the VAD on CPU** to avoid ANE contention with the ASR model during live work.
- **Auto-recover** a corrupt compiled Core ML model by re-downloading; resume interrupted downloads; keep the model cache inside the sandbox (`XDG_CACHE_HOME`).

### Subprocess adapter (not yet implemented)

A planned second backend wraps any external model speaking an audio-in / JSON-out contract (Python NeMo, `whisper.cpp`), so new models can be trialled without touching Swift. The known discipline for it, when built: stdout = JSON results and stderr = logs, strictly separated; drain both pipes before waiting on exit (64 KB pipe-buffer deadlock); supervise long-lived children with health checks, backoff restart, and a parent-PID watchdog; pin weights to exact upstream commits.

## Diarization protocol

Diarization is a separate, optional stage, with the same capability-by-protocol shape as the ASR side: a small base protocol (the offline/batch pass) plus an optional streaming capability.

```swift
// Base: the offline (batch) pass every diarizer provides.
protocol Diarizer {
    var info: DiarizerInfo { get }
    func load(_ options: LoadOptions) throws                     // reuse the ASR LoadOptions
    func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]   // {start, end, speaker}
}

// Optional capability — a backend opts in for the fast live pass.
protocol StreamingDiarizer: Diarizer {                          // info.supportsStreaming
    func step(_ frames: AudioBuffer, state: inout DiarizerState) throws -> [SpeakerSpan]
}
```

**Shipping backend: Sortformer via FluidAudio** (`EarsDiarizeKit.SortformerDiarizer`, the sibling of `EarsTranscribeKit.ParakeetTranscriber`). NVIDIA Sortformer through FluidAudio's Core ML/ANE pipeline, selected by `[diarize].backend = "sortformer"` (off by default). This first cut is **offline-only** — it conforms to `Diarizer` (`info.supportsStreaming = false`); the live streaming pass is the tracked follow-up. Every ANE call shares the *same* `ANEInferenceGate` as the ASR backend (the macOS 14 SIGBUS is process-wide).

Design constraints, all honoured by the implementation:

- **Channel-of-origin is the primary label; the diarizer only refines.** Source separation already gives you-vs-them; the diarizer splits a multi-speaker source (typically the far end) into `Speaker N` and never overrides source attribution — `transcribe` refines only `system`/`app:*`/`device:*` sources, never the `mic` or per-participant `browser:*` streams, and renders `<source> · Speaker N`.
- **Two-pass:** a fast streaming pass for live attribution, an offline batch pass to stabilise speaker IDs; the durable transcript reflects the stabilised pass. Phase 1 ships the offline pass; `StreamingDiarizer` is the seam for the live pass (`--follow`).
- Labels are stable within a transcript and remappable to names (see [speaker attribution](../data-formats.md#speaker-attribution)).
- **Anti-pattern:** faking diarization by concatenating per-source transcripts and asking an LLM to guess speakers — that is not attribution.

See `docs/plans/diarization-sortformer.md` for the implementation plan and open questions.
