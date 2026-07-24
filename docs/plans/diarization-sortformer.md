# Plan: diarization (Sortformer via FluidAudio)

Status: proposed. Implements the diarization stage that `docs/specs/model-interface.md`
has specified-but-unimplemented since the protocol seam landed. First backend:
NVIDIA **Sortformer** streaming diarizer, via FluidAudio (same dependency and
Core ML/ANE path already used for Parakeet ASR).

This plan follows the codebase's existing shape exactly: **capability-by-protocol
seams in `EarsCore`, a thin tier-2 backend shim in its own target, config-selected
composition in the pipeline, pure assembly logic unit-tested in isolation.** The
diarizer mirrors the `Transcriber`/`ParakeetTranscriber` pattern one-for-one.

## Where this fits

Diarization is a *refinement*, not a re-attribution (`model-interface.md` §Diarization,
`data-formats.md` §Speaker attribution):

- **Source-of-origin stays the primary label.** Mic → `You`; each far-end source
  (`system`, `app:*`, `browser:*`) keeps its source/roster identity. This already
  works and must not regress.
- **The diarizer only splits a *multi-speaker* source into `Speaker N`.** The
  target case is a far end where several people share one stream (system/app audio
  from a call app that isn't per-participant separated). A mic, or an already
  per-participant `browser:meet:*` source, is single-speaker and is never diarized.
- **Anti-pattern to avoid:** concatenating per-source transcripts and asking an LLM
  to guess speakers. Not in scope, ever.

## Architecture (mirror the ASR backend)

| ASR (existing)                         | Diarization (this plan)                    |
|----------------------------------------|--------------------------------------------|
| `Transcriber` protocol (`EarsCore`)    | `Diarizer` protocol (`EarsCore`, exists)   |
| `StreamingTranscriber` capability      | `StreamingDiarizer` capability (**new**)   |
| `ModelInfo`                            | `DiarizerInfo` (exists)                    |
| `EarsTranscribeKit` target             | `EarsDiarizeKit` target (**new**)          |
| `ParakeetTranscriber` shim             | `SortformerDiarizer` shim (**new**)        |
| `[transcribe]` config table            | `[diarize]` config table (**new**)         |
| `ANEInferenceGate` (shared)            | reuse the **same** `ANEInferenceGate`      |

Reusing the *same* `ANEInferenceGate` instance across the ASR and diarizer shims is
load-bearing: the macOS 14 SIGBUS this guards against is process-wide ANE
contention, not per-model (see `ParakeetTranscriber` init doc). The pipeline must
construct one gate and pass it to both factories.

## Protocol changes (`EarsCore`)

### 1. Give `Diarizer` a `load` step, symmetric with `Transcriber`

The current `Diarizer` has only `info` + `diarize`. FluidAudio needs a
download/compile/load step (weights fetched from Hugging Face, compiled to Core ML).
Add it so the shim isn't forced to lazy-load inside `diarize`:

```swift
public protocol Diarizer: Sendable {
  var info: DiarizerInfo { get }
  func load(_ options: LoadOptions) throws          // NEW — reuse ASR's LoadOptions
  func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]   // offline/batch pass
}
```

`LoadOptions` (`modelIdentifier`, `compute`) already exists and is backend-agnostic —
reuse it rather than inventing a diarizer-specific one.

### 2. Add the `StreamingDiarizer` capability protocol (new file)

Mirrors `StreamingTranscriber` exactly — caller owns continuity via an opaque
`inout` state box, so one diarizer serves many sources without holding per-source
state. Gated by `DiarizerInfo.supportsStreaming` (already on `DiarizerInfo`).

```swift
/// Optional capability: incremental (streaming) diarization for the live pass,
/// gated by `DiarizerInfo.supportsStreaming`.
public protocol StreamingDiarizer: Diarizer {
  func step(_ frames: AudioBuffer, state: inout DiarizerState) throws -> [SpeakerSpan]
}
```

Add `DiarizerState` + `BackendDiarizerState` mirroring `DecoderState` /
`BackendDecoderState` (opaque box the backend owns; the Sortformer state rides in
`.backend`). This keeps the two-pass design (`model-interface.md`) open without
committing the offline-only first cut to it.

### 3. Update `NullDiarizer` (`EarsCoreTestSupport`)

Add the new `load(_:)` no-op so it still conforms. It stays the mockable-seam proof.

## New target: `EarsDiarizeKit`

Add to `Package.swift`, mirroring `EarsTranscribeKit`:

```swift
.target(
  name: "EarsDiarizeKit",
  dependencies: [
    "EarsCore",
    .product(name: "FluidAudio", package: "FluidAudio"),
  ]
),
```

Wire it into the `transcribe` executable's deps (alongside `EarsTranscribeKit`).
Add a `EarsDiarizeKitTests` target for anything unit-testable without the ANE
(model-version/label mapping, span conversion given a fake result).

### `SortformerDiarizer` shim

The tier-2 boundary: **only this file touches FluidAudio's diarizer API.** Reuse
the *exact* sync↔async bridging `ParakeetTranscriber` already proved
(`blockingBridge` + a `LoadedModelState` actor + the shared `ANEInferenceGate`).

```swift
public final class SortformerDiarizer: Diarizer, StreamingDiarizer, @unchecked Sendable {
  public private(set) var info: DiarizerInfo      // name "sortformer-fluidaudio",
                                                   // supportsStreaming: true
  private let gate: ANEInferenceGate
  private let modelDirectory: URL?
  private let state = LoadedModelState()           // actor holding the FluidAudio manager

  public func load(_ options: LoadOptions) throws { /* download+compile via gate+bridge */ }
  public func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan] { /* offline pass */ }
  public func step(_ frames: AudioBuffer, state: inout DiarizerState) throws -> [SpeakerSpan] { /* live pass */ }
}
```

**FluidAudio API to bind against (confirm exact names in the checked-out
`FluidAudio` 0.15.5 source before coding — these are from the published docs):**

- Models: `DiarizerModels.downloadIfNeeded()` (or `SortformerModels.loadFromHuggingFace(config:)`).
- Backend type conforming to FluidAudio's own `Diarizer` protocol: `SortformerDiarizer`
  (offline via `OfflineDiarizerManager`, streaming via `addAudio(_:sourceSampleRate:)`
  + `process()`).
- Offline entry: `processComplete(_:sourceSampleRate:)` → a timeline whose
  `finalizedSegments` are `TimedSpeakerSegment { speakerId, startTimeSeconds, endTimeSeconds }`.
- Streaming entry: `addAudio(chunk, sourceSampleRate:)` then `process()` →
  `DiarizerTimelineUpdate { finalizedSegments, tentativeSegments }`.

**Input contract:** 16 kHz mono Float32 (identical to the ASR path — the slices the
pipeline already hands `Transcriber` are the right shape). Sortformer has **4 fixed
speaker slots**; surface that as `DiarizerInfo` metadata and clamp labels to it.

**Mapping to `SpeakerSpan`:** `TimedSpeakerSegment` → `SpeakerSpan(start:end:speaker:)`
with `speaker = "Speaker \(speakerId + 1)"`, times kept relative to the diarized
buffer's start (same convention `Transcriber` uses — the pipeline shifts onto the
shared timeline).

**Offline pass detail:** `diarize` runs over one source's audio for the whole range.
Because the pipeline reads audio as VAD-gated slices (not one contiguous buffer), the
diarizer needs continuous audio to hold speaker identity across a pause. Stitch the
range's slices into one buffer (silence-filling the gaps, or concatenating and
carrying each slice's offset) and diarize once per source, so `Speaker N` stays
stable across the whole transcript rather than resetting per slice.

## Config: `[diarize]` table

Off by default — it downloads a model and costs ANE time, so it must be opt-in
(matches "no silent fallback" and the zero-config default).

```toml
[diarize]
backend = "none"        # "none" (default) | "sortformer"
model = ""              # optional FluidAudio model identifier override
compute = "automatic"   # "ane" | "gpu" | "cpu" | "automatic"  (same mapping as [transcribe])
max_speakers = 4        # Sortformer is fixed at 4; reserved for future backends
```

Schema changes:
- `Phase0ConfigSchema.passthroughKeys`: add `"diarize"`.
- `EarsdConfigSchema` / the `transcribe`-scoped schema: add a real `[diarize]` field
  slice (mirror the existing `[transcribe]` `backend`/`model`/`compute` slice) so
  unknown keys under it are rejected with a precise message.
- `docs/configuration.md`: document the table (and correct the stale "no `[transcribe]`
  table yet" line, which the code already contradicts).

## Pipeline wiring (`transcribe`)

### `TranscribeRuntime`
Resolve `[diarize].backend` / `model` / `compute` next to the existing `[transcribe]`
reads; pass a `diarizeBackendName` and diarizer `LoadOptions` into the pipeline
`Dependencies`.

### `TranscribePipeline.Dependencies`
Add an optional factory (nil ⇒ no diarization), constructed in `.production` from
config, sharing the ASR gate:

```swift
var diarizerFactory: (@Sendable () -> Diarizer)? = nil
// .production: backend == "sortformer" ? { SortformerDiarizer(gate: sharedGate) } : nil
```

### `runResolved`
After a source's slices are read and transcribed, and *only for a multi-speaker
far-end source* (`sourceClass != .mic` and not an already-single-speaker
`browser:*` participant), if a diarizer is configured:
1. `load` it once per run (like the transcriber).
2. Stitch the source's slices → one range-relative buffer; `diarize` → `[SpeakerSpan]`.
3. Collect `[SourceID: [SpeakerSpan]]` to hand to assembly.

`load`/`diarize` are synchronous `throws` and run on the same single-shot CLI task as
`transcribe` — the `blockingBridge` safety argument in `ParakeetTranscriber`'s doc
applies unchanged (don't parallelize slices/sources without moving off the blocking
bridge).

Failure is non-fatal and degrades gracefully: if `diarize` throws, log it, drop the
source's spans, and fall back to source-only labels — a diarizer problem must never
fail the transcript.

## Assembly: refine labels (`TranscriptAssembly`)

Currently `speakerLabel(for:speakers:)` maps a source to one label. Extend assembly
to be span-aware:

- `assemble(...)` gains `diarization: [SourceID: [SpeakerSpan]]` (default `[:]`) and
  sets `TranscriptDiarizationInfo(enabled: !diarization.isEmpty, backend: <name>)`
  in the frontmatter (replacing the hardcoded `enabled: false`).
- For a source **with** spans: each ASR segment is labelled by the span covering its
  midpoint (max-overlap wins on ties). The label refines, it does not replace:
  `"<source-label> · Speaker N"` (e.g. `Priya's call · Speaker 2`) — source
  attribution stays primary, diarizer adds the within-source split. Exact label
  format is a one-line decision to confirm; the rule is *source stays visible*.
- For a source **without** spans (mic, browser participants, diarization off):
  unchanged — existing `speakerLabel` behavior, byte-identical output.
- `[speakers]` name-map remaps still apply on top (`Speaker 2` → `Priya` post-cleanup),
  never mutating timings.

The existing word-granularity `interleave` merge is untouched — it groups by resolved
label, so finer diarized labels flow through it for free.

## Two passes

`model-interface.md` calls for a fast live pass + a stabilized offline pass, with the
**durable transcript reflecting the offline pass**. Scope this in phases:

- **Phase 1 (this plan's core): offline pass only.** `transcribe` (batch) runs
  `Diarizer.diarize` and writes stabilized `Speaker N` labels. This is the durable
  artifact and the correct first target.
- **Phase 2 (follow-up): live pass.** `TranscribeFollowPipeline` (`--follow`) uses
  `StreamingDiarizer.step`, threading `DiarizerState` per source exactly as it threads
  `DecoderState` for streaming ASR. Live labels are provisional and get overwritten by
  the offline pass on finalization. Deferred so Phase 1 ships a verifiable, durable
  result first.

## Implementation order

1. `EarsCore`: `Diarizer.load`, new `StreamingDiarizer` + `DiarizerState` files;
   update `NullDiarizer`. (Pure — unit-testable, builds without FluidAudio API.)
2. Config: `[diarize]` schema slice + passthrough + `docs/configuration.md`.
3. `EarsDiarizeKit` + `SortformerDiarizer` shim against FluidAudio 0.15.5.
4. Pipeline wiring in `TranscribeRuntime` / `TranscribePipeline` (factory + per-source
   offline diarize + graceful fallback).
5. `TranscriptAssembly` span-aware labelling + frontmatter `diarization` info.
6. Docs: flip the "not yet implemented" notes in `model-interface.md`,
   `data-formats.md`, `transcribe.md`.

## Testing

- **Pure, runs anywhere:** `TranscriptAssembly` label refinement (span→label, overlap
  tie-break, mic untouched, frontmatter `enabled/backend`, `[speakers]` remap on top);
  `SpeakerSpan` mapping given a fake FluidAudio result; config schema accept/reject.
- **macOS-only (ANE):** `SortformerDiarizer` load + diarize against a short fixture,
  gated like the existing FluidAudio-touching tests. **Note:** this repo targets
  macOS 15 + Apple Silicon ANE; the shim and its live tests can only be built and run
  on that platform, so steps 3–4 must be validated on a Mac, not in a Linux CI shell.

## Open questions to settle before/while coding

1. Exact FluidAudio 0.15.5 diarizer type/method names (confirm in the checked-out
   source — docs describe `main`, the pin is 0.15.5).
2. Label format: `"Source · Speaker N"` vs a separate structured field on
   `TranscriptSegment`. Keeping it in the label string is simplest and needs no data
   change; a structured `speakerSubLabel` is cleaner but touches the transcript schema.
3. Slice-stitching strategy for the offline pass (silence-fill gaps vs concatenate +
   offset map) — affects cross-pause speaker stability.
4. Which sources count as "multi-speaker" — start with the simple rule (`system`/`app`
   yes, `mic`/`browser:*` no); revisit if a per-participant source ever blends people.
