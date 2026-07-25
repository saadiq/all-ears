import EarsCore
import EarsDataStore
import Foundation
import Testing

import struct EarsCore.AudioBuffer

@testable import transcribe

/// End-to-end diarization check against a real, hand-transcribed multi-speaker
/// meeting: the first 5 minutes of AMI meeting `ES2004a`, using the
/// `Mix-Headset` stream (a monaural sum of every participant's headset mic —
/// one channel, several speakers, the same shape as the Dipanshu interview).
///
/// The AMI Meeting Corpus is CC BY 4.0. Audio is fetched on demand from the
/// official Edinburgh mirror and pinned by SHA-256; the reference speaker
/// segmentation (RTTM) comes from `pyannote/AMI-diarization-setup`. See
/// ``IntegrationFixture``.
///
/// The assertion is deliberately loose — diarization speaker *counts* are not
/// exactly reproducible — so it checks that the pipeline recovers a plausible
/// number of speakers (≥ 2, and no more than Sortformer's 4 slots) over a
/// window the reference says holds several. Opt-in (network + real ANE), off
/// unless `EARS_LIVE_MODEL_TEST=1`.
@Suite(
  "AMI diarization live (opt-in, real FluidAudio)",
  .enabled(if: IntegrationFixture.liveEnabled)
)
struct AMIDiarizationLiveTests {
  static let audioURL = URL(
    string:
      "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav"
  )!
  static let audioSHA256 = "3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f"

  /// Hand-annotated reference speaker turns (RTTM) for the same meeting, from
  /// `pyannote/AMI-diarization-setup`. Small and content-, not byte-, dependent,
  /// so it is fetched directly rather than pinned by hash.
  static let rttmURL = URL(
    string:
      "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test/ES2004a.rttm"
  )!

  /// The window we transcribe: the meeting runs ~17 min; 5 minutes is enough to
  /// exercise multi-speaker splitting without a multi-minute ANE run.
  static let windowSeconds = 300

  @Test("a real multi-speaker meeting diarizes into several speakers")
  func diarizesMeetingIntoMultipleSpeakers() async throws {
    let audioURL = try await IntegrationFixture.fetch(
      Self.audioURL, fileName: "ami-ES2004a.Mix-Headset.wav", sha256: Self.audioSHA256)

    // How many distinct speakers the hand transcript places in our window — a
    // sanity floor for what the diarizer ought to recover.
    let referenceSpeakers = try await referenceSpeakerCount(within: Double(Self.windowSeconds))
    #expect(referenceSpeakers >= 2, "fixture sanity: reference should hold ≥2 speakers")

    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AMIDiarizationLiveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let outURL = outputDir.appendingPathComponent("ami.transcript.md")

    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [audioURL.path], out: outURL.path),
      backendName: "fluidaudio",
      dependencies: TranscribePipeline.Dependencies.production(diarizeBackendName: "sortformer"),
      fileReader: Self.truncatingReader(seconds: Self.windowSeconds))
    #expect(exitCode == 0)

    let markdown = try String(contentsOf: outURL, encoding: .utf8)
    #expect(markdown.contains("diarization: { enabled: true"))

    let detected = distinctSpeakerLabels(in: markdown)
    #expect(
      detected.count >= 2 && detected.count <= 4,
      "expected 2–4 speakers (reference holds \(referenceSpeakers)), got \(detected.sorted())")
  }

  /// A ``FileAudioReader`` that decodes normally, then keeps only the first
  /// `seconds` of samples — so the pipeline transcribes a bounded window of a
  /// long meeting without a separate clipping step or temp file.
  private static func truncatingReader(seconds: Int) -> FileAudioReader {
    FileAudioReader(decode: { url in
      let full = try FileAudioReader.decodeWithAVFoundation(url)
      let limit = min(full.samples.count, seconds * full.sampleRate)
      return AudioBuffer(samples: Array(full.samples[..<limit]), sampleRate: full.sampleRate)
    })
  }

  /// Distinct reference speaker ids (RTTM column 8) whose turn *starts* before
  /// `cutoff` seconds. RTTM rows are `SPEAKER <file> 1 <start> <dur> <NA> <NA>
  /// <speaker> …`.
  private func referenceSpeakerCount(within cutoff: Double) async throws -> Int {
    let (data, _) = try await URLSession.shared.data(from: Self.rttmURL)
    let text = String(decoding: data, as: UTF8.self)
    var speakers: Set<String> = []
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: " ")
      guard fields.count >= 8, fields[0] == "SPEAKER", let start = Double(fields[3]) else {
        continue
      }
      if start < cutoff { speakers.insert(String(fields[7])) }
    }
    return speakers.count
  }

  /// Every distinct `Speaker N` sub-label appearing on a `## …` heading.
  private func distinctSpeakerLabels(in markdown: String) -> Set<String> {
    var labels: Set<String> = []
    for line in markdown.split(separator: "\n") where line.hasPrefix("## ") {
      guard let range = line.range(of: "Speaker ") else { continue }
      let number = line[range.lowerBound...].dropFirst("Speaker ".count).prefix { $0.isNumber }
      if !number.isEmpty { labels.insert("Speaker \(number)") }
    }
    return labels
  }
}
