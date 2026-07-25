@preconcurrency import CoreML
import Dispatch
import EarsCore

/// Pure mapping from the backend-agnostic `ComputePreference`
/// (`docs/specs/model-interface.md`) to Core ML's `MLComputeUnits`, the exact
/// sibling of `EarsTranscribeKit`'s `resolveComputeUnits(for:)`. Duplicated
/// rather than shared so the two tier-2 FluidAudio shims stay independent (per
/// `docs/engineering-practices.md`: only these targets touch Core ML) — the
/// mapping is three lines and stable.
func resolveComputeUnits(for preference: ComputePreference) -> MLComputeUnits {
  switch preference {
  case .automatic: return .all
  case .neuralEngine: return .cpuAndNeuralEngine
  case .gpu: return .cpuAndGPU
  case .cpu: return .cpuOnly
  }
}

/// Bridges a synchronous, throwing call to an `async throws` operation by
/// blocking the calling thread on a semaphore while the work runs on a detached
/// task. A verbatim copy of `EarsTranscribeKit`'s `blockingBridge` — the same
/// sync-protocol / async-SDK mismatch applies here: FluidAudio's model download
/// (`SortformerModels.loadFromHuggingFace`) is `async`, but `Diarizer.load`/
/// `diarize` are synchronous `throws` (fixed by `docs/specs/model-interface.md`).
///
/// Only safe when called from an ordinary OS thread outside Swift's cooperative
/// executor pool (a synchronous CLI entry point before any `Task` is running).
/// `transcribe` is exactly that: a single-shot batch process. See
/// `ParakeetTranscriber`'s doc comment for the full rationale.
func blockingBridge<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T
{
  let semaphore = DispatchSemaphore(value: 0)
  let box = BridgeResultBox<T>()

  Task.detached(priority: .userInitiated) {
    do {
      box.result = .success(try await operation())
    } catch {
      box.result = .failure(error)
    }
    semaphore.signal()
  }

  semaphore.wait()
  switch box.result {
  case .success(let value):
    return value
  case .failure(let error):
    throw error
  case .none:
    fatalError("blockingBridge: semaphore released without a recorded result")
  }
}

/// Plain box carrying the detached task's result back across the semaphore.
/// `@unchecked Sendable` is sound because the semaphore establishes a
/// happens-before edge: `result` is written before `signal()`, read only after
/// `wait()` returns.
private final class BridgeResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
