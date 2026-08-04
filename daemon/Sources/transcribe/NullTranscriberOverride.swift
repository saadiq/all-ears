import EarsCoreTestSupport
import Foundation

/// The env var a test harness sets on a **spawned child process** to divert
/// the batch pipeline's ASR backend to `EarsCoreTestSupport.NullTranscriber`
/// (and turn diarization off), so a smoke test can drive a real, built
/// `transcribe` binary through a *successful* run — output written, result
/// line emitted, exit 0 — without `ParakeetTranscriber.load`'s model download
/// or any ANE inference. `earsd` already has exactly this shape of seam
/// (`RealCaptureBackendFactory`'s `ALLEARS_CAPTURE_BACKEND=synthetic`); this
/// is the transcribe-side twin, used by
/// `Tests/CLISmokeTests/PlainModeContractSmokeTests.swift` to pin the
/// plain-mode stdout contract (issue #62) on the success path.
///
/// **Test-only escape hatch, never a real user-facing config option —
/// deliberately *not* `EARS_`-prefixed.** `configLayer(fromEnvironment:)`
/// sweeps every `EARS_`-prefixed env var into real layered config and rejects
/// unknown keys (see `RealCaptureBackendFactory`'s doc comment for the full
/// war story), so this uses the `ALLEARS_` package prefix the config loader
/// ignores entirely. It has no entry in `docs/configuration.md` and
/// `--print-config` never reflects it; only a test harness sets it, on its
/// own spawned child process's environment.
let nullTranscriberEnvironmentKey = "ALLEARS_TRANSCRIBE_BACKEND"

/// Applies the ``nullTranscriberEnvironmentKey`` escape hatch to an
/// already-built production `TranscribePipeline.Dependencies`: with
/// `ALLEARS_TRANSCRIBE_BACKEND=null` set, the transcriber factory yields a
/// `NullTranscriber` (loads instantly, returns no segments) and the diarizer
/// is disabled. Everything else — audio resolution, transcript assembly and
/// writing, the guarded `ResultChannel` stdout route — runs exactly as in
/// production, which is the point: the smoke harness exercises the real
/// binary's real output contract, faking only the model.
func applyNullTranscriberOverrideIfRequested(
  _ dependencies: inout TranscribePipeline.Dependencies
) {
  guard ProcessInfo.processInfo.environment[nullTranscriberEnvironmentKey] == "null" else {
    return
  }
  dependencies.transcriberFactory = { NullTranscriber() }
  dependencies.diarizerFactory = nil
}
