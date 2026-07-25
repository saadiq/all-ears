import CoreML
import EarsCore
import Testing

@testable import EarsDiarizeKit

@Suite("SortformerDiarizer")
struct SortformerDiarizerTests {
  @Test("info reports the Sortformer backend as offline-only for this first cut")
  func infoIsOfflineOnly() {
    let info = SortformerDiarizerBackend().info
    #expect(info.name == "sortformer-fluidaudio")
    // Streaming (the live `--follow` pass) is deferred to a follow-up, so the
    // shim must not advertise a capability it does not yet conform to.
    #expect(info.supportsStreaming == false)
  }

  @Test("ComputePreference maps to the matching Core ML compute units")
  func computePreferenceMapping() {
    #expect(resolveComputeUnits(for: .automatic) == .all)
    #expect(resolveComputeUnits(for: .neuralEngine) == .cpuAndNeuralEngine)
    #expect(resolveComputeUnits(for: .gpu) == .cpuAndGPU)
    #expect(resolveComputeUnits(for: .cpu) == .cpuOnly)
  }
}
