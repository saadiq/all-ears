import Testing

@testable import EarsCore

@Suite("CleanupChunker")
struct CleanupChunkerTests {
  /// A turn of `seconds` spoken duration and `characters` of text.
  private static func turn(seconds: Double, characters: Int = 10) -> TranscriptSegment {
    TranscriptSegment(
      source: "mic", speaker: "You",
      segment: Segment(start: 0, end: seconds, text: String(repeating: "a", count: characters)))
  }

  @Test("an empty transcript produces no chunks")
  func emptyProducesNoChunks() {
    #expect(CleanupChunker().chunks(of: []).isEmpty)
  }

  @Test("turns are batched up to the spoken-seconds bound")
  func batchesUpToTheSecondsBound() {
    let turns = Array(repeating: Self.turn(seconds: 30), count: 24)  // 720s of talking
    let chunks = CleanupChunker(maxSpokenSeconds: 300).chunks(of: turns)

    // 10 turns fill 300s exactly; an 11th would exceed it.
    #expect(chunks.map(\.count) == [10, 10, 4])
  }

  @Test("the partition covers every turn exactly once, in order")
  func partitionIsExactAndOrdered() {
    let turns = (1...50).map { Self.turn(seconds: Double($0 % 7) + 1) }
    let chunks = CleanupChunker(maxSpokenSeconds: 20).chunks(of: turns)

    #expect(chunks.first?.lowerBound == 0)
    #expect(chunks.last?.upperBound == turns.count)
    #expect(chunks.allSatisfy { !$0.isEmpty })
    for (previous, next) in zip(chunks, chunks.dropFirst()) {
      #expect(previous.upperBound == next.lowerBound)
    }
    #expect(chunks.reduce(0) { $0 + $1.count } == turns.count)
  }

  @Test("a single turn longer than the bound becomes its own chunk rather than being split")
  func oversizedTurnStandsAlone() {
    let turns = [
      Self.turn(seconds: 10),
      Self.turn(seconds: 9_000),  // far past the bound on its own
      Self.turn(seconds: 10),
    ]
    let chunks = CleanupChunker(maxSpokenSeconds: 300).chunks(of: turns)

    #expect(chunks.map(\.count) == [1, 1, 1])
  }

  @Test("the character bound closes a chunk even when it holds little speech")
  func characterBoundAlsoCloses() {
    // Fast talkers: 1s each but 1,000 characters, so the character cap binds
    // long before the 300s one does.
    let turns = Array(repeating: Self.turn(seconds: 1, characters: 1_000), count: 10)
    let chunks = CleanupChunker(maxSpokenSeconds: 300, maxCharacters: 2_500).chunks(of: turns)

    #expect(chunks.map(\.count) == [2, 2, 2, 2, 2])
  }

  @Test("wall-clock gaps between turns don't count toward the bound -- only spoken time does")
  func silenceBetweenTurnsIsNotCounted() {
    // Five 60s turns spread over an hour of wall clock: still one 300s chunk,
    // because only `end - start` is summed.
    let turns = (0..<5).map { index in
      TranscriptSegment(
        source: "mic", speaker: "You",
        segment: Segment(
          start: Double(index) * 600, end: Double(index) * 600 + 60, text: "some words"))
    }
    let chunks = CleanupChunker(maxSpokenSeconds: 300).chunks(of: turns)

    #expect(chunks.map(\.count) == [5])
  }
}
