import EarsDataStore
import Testing

@testable import transcribe

/// Pure coverage of ``SessionAudioResolution`` — the store-selection and
/// empty-diagnosis rules for `transcribe --session` (all-ears issue #20),
/// exercised without any data root on disk.
@Suite("SessionAudioResolution")
struct SessionAudioResolutionTests {
  private func probe(exists: Bool, chunks: Int, speech: Int = 0) -> SegmentedAudioReader.RangeProbe
  {
    SegmentedAudioReader.RangeProbe(
      sourceExists: exists, chunksInRange: chunks, speechIntervals: speech)
  }

  @Test("prefers the per-session store when it holds chunks")
  func prefersSessionWhenItHasChunks() {
    let chosen = SessionAudioResolution.chooseStore(
      session: probe(exists: true, chunks: 2), ring: probe(exists: true, chunks: 5))
    #expect(chosen == .session)
  }

  @Test("falls back to the ring store when the per-session store has no chunks")
  func fallsBackToRingWhenSessionEmpty() {
    // The exact issue #20 shape: a per-session dir exists but is empty for the
    // window, while the ring holds the audio.
    let chosen = SessionAudioResolution.chooseStore(
      session: probe(exists: true, chunks: 0), ring: probe(exists: true, chunks: 3))
    #expect(chosen == .ring)
  }

  @Test("falls back to the ring store when there is no per-session dir at all (e.g. mic)")
  func fallsBackToRingWhenNoSessionDir() {
    let chosen = SessionAudioResolution.chooseStore(
      session: probe(exists: false, chunks: 0), ring: probe(exists: true, chunks: 3))
    #expect(chosen == .ring)
  }

  @Test("keeps the per-session store when neither has chunks but the per-session dir exists")
  func keepsSessionWhenBothEmptyButSessionExists() {
    let chosen = SessionAudioResolution.chooseStore(
      session: probe(exists: true, chunks: 0), ring: probe(exists: true, chunks: 0))
    #expect(chosen == .session)
  }

  @Test("returns nil when neither store holds the source")
  func nilWhenNeitherStoreExists() {
    let chosen = SessionAudioResolution.chooseStore(
      session: probe(exists: false, chunks: 0), ring: probe(exists: false, chunks: 0))
    #expect(chosen == nil)
  }

  @Test("empty reason: store missing when no store was chosen")
  func emptyReasonStoreMissing() {
    #expect(
      SessionAudioResolution.emptyReason(
        storeExists: false, chunksInRange: 0, speechIntervals: 0, sliceCount: 0) == "store missing")
  }

  @Test("empty reason: no chunks in range")
  func emptyReasonNoChunks() {
    #expect(
      SessionAudioResolution.emptyReason(
        storeExists: true, chunksInRange: 0, speechIntervals: 0, sliceCount: 0)
        == "no chunks in range")
  }

  @Test("empty reason: chunks but no speech intervals")
  func emptyReasonNoSpeech() {
    #expect(
      SessionAudioResolution.emptyReason(
        storeExists: true, chunksInRange: 4, speechIntervals: 0, sliceCount: 0)
        == "chunks but no speech intervals")
  }

  @Test("empty reason is nil when the source produced slices")
  func emptyReasonNilWhenSlicesProduced() {
    #expect(
      SessionAudioResolution.emptyReason(
        storeExists: true, chunksInRange: 4, speechIntervals: 2, sliceCount: 1) == nil)
  }
}
