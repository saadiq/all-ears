import EarsCore
import Foundation
import Testing

@testable import transcribe

/// End-to-end proof that diarization actually splits a real, single-file
/// recording into multiple speakers — the regression this fixes: a whole-file
/// `.m4a` decodes to one ASR segment, and without per-word timings + the
/// per-speaker split, every turn collapsed to `Speaker 1`.
///
/// Real and hardware-touching (downloads Parakeet + Sortformer weights, runs
/// ANE inference over ~46 minutes of audio), so it follows the same tier-2,
/// opt-in discipline as ``ParakeetLiveModelTests``: off unless
/// `EARS_LIVE_MODEL_TEST=1`. The audio file is not committed (it is 17 MB); the
/// test resolves it from `EARS_DIARIZE_TEST_FILE`, else the default
/// `~/Downloads/Dipanshu.m4a`, and the suite stays disabled unless that file is
/// present — so it never fails merely because the fixture is absent.
/// Resolves the recording under test: `EARS_DIARIZE_TEST_FILE` if set, else
/// `~/Downloads/Dipanshu.m4a`. A free helper (not a member of the suite type)
/// so the `.enabled(if:)` trait can call it without a circular reference to the
/// `@Suite` it gates.
enum DipanshuDiarizeFixture {
  static var audioPath: String {
    if let override = ProcessInfo.processInfo.environment["EARS_DIARIZE_TEST_FILE"],
      !override.isEmpty
    {
      return override
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Downloads/Dipanshu.m4a").path
  }

  /// Opt-in flag set *and* the audio actually on disk.
  static var shouldRun: Bool {
    ProcessInfo.processInfo.environment["EARS_LIVE_MODEL_TEST"] == "1"
      && FileManager.default.fileExists(atPath: audioPath)
  }
}

@Suite(
  "Dipanshu diarization live (opt-in, real FluidAudio)",
  .enabled(if: DipanshuDiarizeFixture.shouldRun)
)
struct DipanshuDiarizeLiveTests {
  @Test("a two-speaker recording diarizes into more than one speaker")
  func diarizesRealFileIntoMultipleSpeakers() async throws {
    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DipanshuDiarizeLiveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let outURL = outputDir.appendingPathComponent("Dipanshu.transcript.md")

    // The real production wiring with Sortformer enabled: ParakeetTranscriber +
    // SortformerDiarizerBackend on one shared ANE gate, exactly as a
    // `[diarize].backend = "sortformer"` run builds them.
    let dependencies = TranscribePipeline.Dependencies.production(
      diarizeBackendName: "sortformer")

    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [DipanshuDiarizeFixture.audioPath], out: outURL.path),
      backendName: "fluidaudio",
      dependencies: dependencies)
    #expect(exitCode == 0)

    let markdown = try String(contentsOf: outURL, encoding: .utf8)

    // Diarization must be recorded as enabled in the frontmatter…
    #expect(markdown.contains("diarization: { enabled: true"))

    // …and, the crux, the body must carry at least two distinct `Speaker N`
    // labels rather than a single collapsed speaker.
    let speakerLabels = distinctSpeakerLabels(in: markdown)
    #expect(
      speakerLabels.count >= 2,
      "expected at least two speakers, got \(speakerLabels.sorted())")
  }

  /// Every distinct `Speaker N` sub-label appearing on a `## …` heading.
  private func distinctSpeakerLabels(in markdown: String) -> Set<String> {
    var labels: Set<String> = []
    for line in markdown.split(separator: "\n") where line.hasPrefix("## ") {
      guard let range = line.range(of: "Speaker ") else { continue }
      let trailing = line[range.lowerBound...]
      // "Speaker" + following digits.
      let number = trailing.dropFirst("Speaker ".count).prefix { $0.isNumber }
      if !number.isEmpty { labels.insert("Speaker \(number)") }
    }
    return labels
  }
}
