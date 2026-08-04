import EarsCore
import EarsCoreTestSupport
import Foundation
import Testing

@testable import summarize

@Suite("SummarizePipeline")
struct SummarizePipelineTests {
  private static func makeTempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "SummarizePipelineTests-\(label)-\(UUID().uuidString)")
  }

  private static func writeFixtureTranscript(
    at directory: URL,
    name: String = "standup.transcript.md",
    sources: [SourceID] = ["mic"],
    text: String = "Morning standup. Let's keep this quick."
  ) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      rangeRun: "2026-07-17T10-30-00Z_standup",
      sources: sources,
      range: TimeRange(start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 60)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Instant(secondsSinceEpoch: 60),
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 10,
      vocab: ["global"]
    )
    let document = TranscriptDocument(
      frontmatter: frontmatter,
      segments: [
        TranscriptSegment(
          source: sources[0], speaker: "You", segment: Segment(start: 0, end: 3, text: text))
      ])
    let url = directory.appendingPathComponent(name)
    try TranscriptRenderer.renderMarkdown(document).write(
      to: url, atomically: true, encoding: .utf8)
    return url
  }

  private static func dependencies(llmResults: [Result<LLMCompletionResult, Error>])
    -> (SummarizePipeline.Dependencies, FakeLLMBackend)
  {
    let backend = FakeLLMBackend(results: llmResults)
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      log: { _ in },
      writeStderr: { _ in }
    )
    return (deps, backend)
  }

  @Test("single transcript, single preset writes <...>.summary.md")
  func singlePresetWritesSummary() async throws {
    let directory = Self.makeTempDirectory("single")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Quick standup, no blockers."))
    ])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Summarize briefly:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded.count == 1)
    #expect(recorded[0].stablePrefix == "Summarize briefly:")

    let outputURL = directory.appendingPathComponent("standup.summary.md")
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let content = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(content.contains("kind: summary"))
    #expect(content.contains("preset: brief"))
    #expect(content.contains("derived_from: standup.transcript.md"))
    #expect(content.contains("Quick standup, no blockers."))
  }

  @Test("multiple presets each get their own <...>.<preset>.summary.md")
  func multiplePresetsWriteSeparateFiles() async throws {
    let directory = Self.makeTempDirectory("multi-preset")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    let (deps, _) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Brief summary.")),
      .success(LLMCompletionResult(text: "- Action 1\n- Action 2")),
    ])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(name: "brief", promptContent: "Brief:"),
          SummarizePipeline.Preset(name: "actions", promptContent: "Actions:"),
        ],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.brief.summary.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.actions.summary.md").path))
  }

  @Test("prefers a sibling .clean.md over the .transcript.md it was pointed at")
  func prefersCleanedSibling() async throws {
    let directory = Self.makeTempDirectory("prefer-clean")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(
      at: directory, text: "raw unclean text")
    _ = try Self.writeFixtureTranscript(
      at: directory, name: "standup.clean.md", text: "Cleaned, readable text.")

    let (deps, _) = Self.dependencies(llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.summary.md").path))
    let content = try String(
      contentsOf: directory.appendingPathComponent("standup.summary.md"), encoding: .utf8)
    #expect(content.contains("derived_from: standup.clean.md"))
  }

  @Test("merges sources/vocab and spans the range across multiple input transcripts")
  func mergesMultipleTranscripts() async throws {
    let directory = Self.makeTempDirectory("multi-input")
    defer { try? FileManager.default.removeItem(at: directory) }
    let micURL = try Self.writeFixtureTranscript(
      at: directory, name: "mic.transcript.md", sources: ["mic"], text: "Mic side.")
    let appURL = try Self.writeFixtureTranscript(
      at: directory, name: "app.transcript.md", sources: ["app:us.zoom.xos"], text: "App side.")

    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "Combined summary."))
    ])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [micURL.path, appURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: nil),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded[0].dynamicSuffix.contains("Mic side."))
    #expect(recorded[0].dynamicSuffix.contains("App side."))

    let content = try String(
      contentsOf: directory.appendingPathComponent("mic.summary.md"), encoding: .utf8)
    #expect(content.contains("sources: [mic, \"app:us.zoom.xos\"]"))
    // Quoted: the comma-joined value contains a "," (a YAML flow-significant
    // character), so FrontmatterRenderer's needsQuoting quotes it.
    #expect(content.contains("derived_from: \"mic.transcript.md, app.transcript.md\""))
  }

  @Test("--out overrides the single-preset output path")
  func explicitOutOverridesSinglePreset() async throws {
    let directory = Self.makeTempDirectory("explicit-out")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)
    let customOut = directory.appendingPathComponent("custom.md").path

    let (deps, _) = Self.dependencies(llmResults: [.success(LLMCompletionResult(text: "Summary."))])

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")],
        out: customOut),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: customOut))
  }

  @Test("no presets is a clear, non-zero error")
  func noPresetsIsError() async {
    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: ["/tmp/whatever.transcript.md"], presets: [], out: nil),
      dependencies: deps)
    #expect(exitCode == 64)
  }

  @Test(
    "a failing preset is reported per-preset — the rest still run, outputs[] carries ok:false, exit is non-zero"
  )
  func partialPresetFailureIsExpressible() async throws {
    let directory = Self.makeTempDirectory("partial-failure")
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriptURL = try Self.writeFixtureTranscript(at: directory)

    // Presets run in order; the middle one's LLM call fails hard (non-zero
    // exit — a stage failure, not a retryable timeout).
    let backend = FakeLLMBackend(results: [
      .success(LLMCompletionResult(text: "Brief summary.")),
      .failure(LLMBackendError.nonZeroExit(code: 1, stderr: "model crashed")),
      .success(LLMCompletionResult(text: "- Decision 1")),
    ])
    let collected = ResultCollector()
    let deps = SummarizePipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      log: { _ in },
      writeStderr: { _ in },
      onPresetResult: { collected.record($0) }
    )

    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: [transcriptURL.path],
        presets: [
          SummarizePipeline.Preset(name: "brief", promptContent: "Brief:"),
          SummarizePipeline.Preset(name: "actions", promptContent: "Actions:"),
          SummarizePipeline.Preset(name: "decisions", promptContent: "Decisions:"),
        ],
        out: nil),
      dependencies: deps)

    // Exit 0 only when all presets succeeded: one hard LLM failure is a
    // stage failure (exit-code taxonomy, issue #61).
    #expect(exitCode == 4)

    // Every preset is reported, in run order — the failed one with ok:false
    // and no path, the others with their written summary's absolute path.
    let results = collected.results
    try #require(
      results.count == 3, "every preset must be reported, got \(results.count): \(results)")
    #expect(results.map(\.preset) == ["brief", "actions", "decisions"])
    #expect(results.map(\.ok) == [true, false, true])
    #expect(results[1].path == nil)
    for result in results where result.ok {
      let path = try #require(result.path)
      #expect(path.hasPrefix("/"), "a per-preset path must be absolute, got: \(path)")
      #expect(FileManager.default.fileExists(atPath: path))
    }

    // The surviving presets' files were still written: partial success is
    // real work kept, not discarded by the failure.
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.brief.summary.md").path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("standup.decisions.summary.md").path))

    // The error envelope built from these results expresses the partial
    // success ("2 of 3 presets"): outputs[] has ok:false for the failed
    // preset while the succeeded ones keep their paths.
    let envelope = SummarizeResultEnvelope.failure(
      exitClass: "stage-failed",
      message: "error: LLM call failed for preset 'actions'",
      results: results)
    #expect(!envelope.ok)
    #expect(envelope.outputs?.map(\.ok) == [true, false, true])
    #expect(envelope.outputs?[1].preset == "actions")
    #expect(envelope.output == nil)
  }

  /// Thread-safe per-preset result collector for `onPresetResult` (the hook
  /// is `@Sendable`, so a plain `var` capture won't do).
  private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SummarizePipeline.PresetResult] = []
    func record(_ result: SummarizePipeline.PresetResult) {
      lock.withLock { storage.append(result) }
    }
    var results: [SummarizePipeline.PresetResult] { lock.withLock { storage } }
  }

  @Test("a missing transcript file is a clear, non-zero error")
  func missingTranscriptIsError() async {
    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await SummarizePipeline.run(
      inputs: SummarizePipeline.Inputs(
        transcriptPaths: ["/nonexistent/path.transcript.md"],
        presets: [SummarizePipeline.Preset(name: "brief", promptContent: "Brief:")], out: nil),
      dependencies: deps)
    #expect(exitCode == 3)
  }
}
