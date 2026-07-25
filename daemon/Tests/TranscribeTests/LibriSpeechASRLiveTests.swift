import EarsCore
import Foundation
import Testing

@testable import transcribe

/// End-to-end ASR + word-timing check against a real, hand-transcribed
/// recording: LibriSpeech utterance `1089-134686-0000` ("He hoped there would
/// be stew for dinner…"), a ~10 s single-speaker read-speech clip.
///
/// LibriSpeech is CC BY 4.0 (Panayotov et al., 2015; derived from public-domain
/// LibriVox audiobooks). The clip is fetched on demand and pinned by SHA-256 —
/// see ``IntegrationFixture``. It guards the word-timing reconstruction added to
/// ``ParakeetTranscriber``: without it a whole-file decode carried no per-word
/// spans and diarization could not split a segment by speaker.
///
/// Opt-in (network + real ANE), off unless `EARS_LIVE_MODEL_TEST=1`.
@Suite(
  "LibriSpeech ASR + word timings live (opt-in, real FluidAudio)",
  .enabled(if: IntegrationFixture.liveEnabled)
)
struct LibriSpeechASRLiveTests {
  /// A mirror of LibriSpeech test-clean `1089-134686-0000.flac` (16 kHz mono).
  static let audioURL = URL(
    string: "https://huggingface.co/datasets/Narsil/asr_dummy/resolve/main/1.flac")!
  static let audioSHA256 = "30885601173f96b0d8ddd020dc959b055c6c1582b85a33e3fcab8c4b08ed94c2"

  /// The reference (hand-written) transcript's distinctive content words. ASR
  /// output varies in punctuation/casing across model revisions, so the test
  /// asserts these survive rather than demanding an exact string match.
  static let contentWords = [
    "stew", "dinner", "turnips", "carrots", "potatoes", "mutton", "sauce",
  ]

  /// The minimal slice of the JSON sidecar this test reads back.
  private struct Sidecar: Decodable {
    struct Word: Decodable {
      let w: String
      let start: Double
      let end: Double
    }
    struct Segment: Decodable {
      let text: String
      let words: [Word]
    }
    let segments: [Segment]
  }

  @Test("transcribes the reference words and emits ordered, in-range word timings")
  func transcribesWithWordTimings() async throws {
    let audioURL = try await IntegrationFixture.fetch(
      Self.audioURL, fileName: "librispeech-1089-134686-0000.flac", sha256: Self.audioSHA256)

    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LibriSpeechASRLiveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let outURL = outputDir.appendingPathComponent("librispeech.transcript.md")
    let sidecarURL = outputDir.appendingPathComponent("librispeech.transcript.json")

    // Real ASR, no diarizer — this exercises the word-timing path, not speaker
    // splitting.
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [audioURL.path], out: outURL.path),
      backendName: "fluidaudio",
      dependencies: TranscribePipeline.Dependencies.production())
    #expect(exitCode == 0)

    let sidecar = try JSONDecoder().decode(
      Sidecar.self, from: Data(contentsOf: sidecarURL))
    let text = sidecar.segments.map(\.text).joined(separator: " ").lowercased()
    for word in Self.contentWords {
      #expect(text.contains(word), "expected the transcript to contain '\(word)': \(text)")
    }

    // Word timings must be populated (the regression this guards) …
    let words = sidecar.segments.flatMap(\.words)
    #expect(words.count >= 20, "expected word timings, got \(words.count) words")

    // … non-decreasing in start, each `start <= end`, and within the ~10.4 s
    // clip (with a small tolerance for the model's end-of-audio padding).
    let starts = words.map(\.start)
    #expect(starts == starts.sorted(), "word starts must be non-decreasing")
    #expect(words.allSatisfy { $0.start >= 0 && $0.start <= $0.end })
    #expect(words.allSatisfy { $0.end <= 12.0 }, "word times must fall within the clip")
  }
}
