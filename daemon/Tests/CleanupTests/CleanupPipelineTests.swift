import EarsCore
import EarsCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import cleanup

/// Tier-1 fixture-driven tests, mirroring `TranscribePipelineTests`' pattern:
/// a real `.transcript.md` (+ JSON sidecar) is written to a temp directory
/// via the real renderers, `CleanupPipeline.run` is driven against it with a
/// `FakeLLMBackend`, and the real `.clean.md`/`.clean.json` output is read
/// back and asserted on. No environment or real config file involved.
@Suite("CleanupPipeline")
struct CleanupPipelineTests {
  private static func makeTempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "CleanupPipelineTests-\(label)-\(UUID().uuidString)")
  }

  /// The publishing template these tests run under — the reference default's
  /// shape, flattened to one directory level so assertions stay readable.
  private static let outputTemplate = PathTemplate("{output_root}/published/{date} - {title}.md")

  /// Where ``outputTemplate`` puts the fixture transcript: its range starts
  /// at the epoch and it carries no `title:`, so `{title}` degrades to the
  /// `{slug}` its single `mic` source supplies.
  private static func publishedURL(under outputRoot: URL) -> URL {
    outputRoot.appendingPathComponent("published/1970-01-01 - mic.md")
  }

  private static func writeFixtureTranscript(
    at directory: URL,
    segments: [TranscriptSegment],
    writeSidecar: Bool = true,
    session: String? = nil,
    title: String? = nil,
    started: Instant? = nil,
    sources: [SourceID] = ["mic"],
    name: String = "standup.transcript.md"
  ) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      rangeRun: session == nil ? "2026-07-17T10-30-00Z_standup" : nil,
      session: session,
      title: title,
      started: started,
      sources: sources,
      range: TimeRange(start: Instant(secondsSinceEpoch: 0), end: Instant(secondsSinceEpoch: 60)),
      model: TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x"),
      diarization: TranscriptDiarizationInfo(enabled: false),
      generated: Instant(secondsSinceEpoch: 60),
      durationSeconds: 60,
      speechSeconds: 30,
      wordCount: 10,
      vocab: []
    )
    let document = TranscriptDocument(frontmatter: frontmatter, segments: segments)
    let markdownURL = directory.appendingPathComponent(name)
    try TranscriptRenderer.renderMarkdown(document).write(
      to: markdownURL, atomically: true, encoding: .utf8)
    if writeSidecar {
      let jsonURL = markdownURL.deletingPathExtension().appendingPathExtension("json")
      try TranscriptRenderer.renderJSON(document).write(
        to: jsonURL, atomically: true, encoding: .utf8)
    }
    return markdownURL
  }

  private static func dependencies(
    llmResults: [Result<LLMCompletionResult, Error>],
    writeStdout: @escaping @Sendable (String) -> Void = { _ in }
  )
    -> (CleanupPipeline.Dependencies, FakeLLMBackend)
  {
    let backend = FakeLLMBackend(results: llmResults)
    let deps = CleanupPipeline.Dependencies(
      clock: ManualClock(Instant(secondsSinceEpoch: 120)),
      llmBackend: backend,
      validator: CleanupValidator(),
      skipPolicy: HighConfidenceSkipPolicy(),
      log: { _ in },
      writeStderr: { _ in },
      writeStdout: writeStdout
    )
    return (deps, backend)
  }

  @Test("accepts a valid LLM correction and writes it to .clean.md")
  func acceptsValidCorrection() async throws {
    let directory = Self.makeTempDirectory("accept")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "hello there how are you"))
      ])

    // Punctuation/casing only -- no word changes -- so CleanupValidator's
    // novel-word-ratio check has nothing to flag. Marked with the turn marker
    // `CleanupPromptBuilder` asks for and parses back.
    let stdoutLines = Mutex<[String]>([])
    let (deps, backend) = Self.dependencies(
      llmResults: [
        .success(LLMCompletionResult(text: "[[1|You]] Hello there, how are you?"))
      ],
      writeStdout: { line in stdoutLines.withLock { $0.append(line) } })

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded.count == 1)

    let cleanedMarkdown = try String(
      contentsOf: Self.publishedURL(under: directory), encoding: .utf8)
    #expect(cleanedMarkdown.contains("kind: clean"))
    // Not quoted: "standup.transcript.md" needs no YAML quoting (no leading
    // digit/special character), per FrontmatterRenderer's `needsQuoting`.
    #expect(cleanedMarkdown.contains("derived_from: standup.transcript.md"))
    #expect(cleanedMarkdown.contains("Hello there, how are you?"))
    // The stdout path contract the daemon's on-end chain parses: the final
    // stdout line of a successful run is the cleaned transcript's path.
    #expect(
      stdoutLines.withLock { $0 }.last
        == Self.publishedURL(under: directory).path)
  }

  @Test("the emitted stdout path is absolute and standardized, not --out's raw spelling")
  func stdoutPathIsAbsoluteAndStandardized() async throws {
    let directory = Self.makeTempDirectory("stdout-path")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "hello there how are you"))
      ])

    // The relative-spelling case (a relative `--out`): Foundation resolves a
    // relative `fileURLWithPath` against cwd at URL creation, so what actually
    // survives to the emitter is the un-normalized dot component — the daemon
    // parsing the emitted line must get the standardized absolute path, not
    // the argument's raw spelling.
    let out = directory.path + "/./cleaned/standup.clean.md"
    let stdoutLines = Mutex<[String]>([])
    let (deps, _) = Self.dependencies(
      llmResults: [
        .success(LLMCompletionResult(text: "[[1|You]] Hello there, how are you?"))
      ],
      writeStdout: { line in stdoutLines.withLock { $0.append(line) } })

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: out,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let emitted = try #require(stdoutLines.withLock { $0 }.last)
    #expect(emitted.hasPrefix("/"))
    #expect(!emitted.contains("/./"))
    #expect(
      emitted
        == directory.appendingPathComponent("cleaned")
        .appendingPathComponent("standup.clean.md").path)
  }

  @Test("falls back to the original text when the LLM candidate fails validation")
  func fallsBackOnInvalidCandidate() async throws {
    let directory = Self.makeTempDirectory("fallback")
    defer { try? FileManager.default.removeItem(at: directory) }

    // Two segments in one chunk: turn 1 comes back with an accepted
    // correction, turn 2 with a rejected one — so the run is a partial success
    // (exit 0, per issue #61's taxonomy only an *all*-rejected run is a stage
    // failure) and the fallback keeps turn 2's original text. Validation is
    // per turn even though the call was batched, which is what stops one bad
    // turn in a response from poisoning the rest.
    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "hello there how are you")),
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 4, end: 6, text: "Hello there.")),
      ])

    let (deps, backend) = Self.dependencies(llmResults: [
      // Wildly different length + invented content on turn 2 -> rejected.
      .success(
        LLMCompletionResult(
          text: """
            [[1|You]] Hello there, how are you?
            [[2|You]] This is a completely different sentence about something the original never mentioned at all.
            """))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    // Both turns rode one call, not one each.
    #expect(await backend.receivedPrompts.count == 1)
    let cleanedMarkdown = try String(
      contentsOf: Self.publishedURL(under: directory), encoding: .utf8)
    #expect(cleanedMarkdown.contains("Hello there, how are you?"))
    #expect(cleanedMarkdown.contains("Hello there."))
  }

  @Test("every attempted segment rejected is a stage failure (exit 4), not a do-nothing success")
  func everySegmentRejectedIsStageFailure() async throws {
    let directory = Self.makeTempDirectory("all-rejected")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 0, end: 3, text: "Hello there."))
      ])

    // The only attempted segment's candidate fails validation, so the run
    // produced nothing: a "cleaned" file would be a byte-for-byte copy.
    let (deps, _) = Self.dependencies(llmResults: [
      .success(
        LLMCompletionResult(
          text:
            "[[1|You]] This is a completely different sentence about something the original never mentioned at all."
        ))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 4, "expected exit 4 (stage-failed), got \(exitCode)")
    #expect(
      !FileManager.default.fileExists(
        atPath: Self.publishedURL(under: directory).path),
      "an all-rejected run must not write a do-nothing copy of its input")
  }

  @Test(
    """
    confidence-based skipping never fires against a persisted transcript, \
    since neither the Markdown body nor the JSON sidecar records confidence \
    (TranscriptParser's documented lossy field) -- this locks in that known \
    limitation rather than assuming it works.
    """)
  func confidenceBasedSkipNeverFiresOnARereadTranscript() async throws {
    let directory = Self.makeTempDirectory("skip")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Already clean.", confidence: 0.99))
      ])

    let (deps, backend) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "[[1|You]] Already clean."))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(recorded.count == 1)
  }

  @Test("keeps the original text when the LLM call itself throws (non-timeout)")
  func keepsOriginalOnLLMFailure() async throws {
    let directory = Self.makeTempDirectory("llm-error")
    defer { try? FileManager.default.removeItem(at: directory) }

    // Two segments, one per chunk (`chunkSeconds: 2` is below either turn's
    // 3s, so neither can share a chunk): the first chunk's LLM call crashes (a
    // per-chunk degrade, kept as a fallback), the second is accepted — so the
    // run still succeeds. A *timeout* is different: it aborts the whole run as
    // retryable upstream (see `llmTimeoutExitsRetryableUpstream`), and an
    // all-fallback run is a stage failure (see
    // `everySegmentRejectedIsStageFailure`).
    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 0, end: 3, text: "Original text.")),
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 4, end: 7, text: "hello there how are you")),
      ])

    let (deps, _) = Self.dependencies(llmResults: [
      .failure(LLMBackendError.nonZeroExit(code: 1, stderr: "model crashed")),
      .success(LLMCompletionResult(text: "[[1|You]] Hello there, how are you?")),
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: [], chunkSeconds: 2),
      dependencies: deps)

    #expect(exitCode == 0)
    let cleanedMarkdown = try String(
      contentsOf: Self.publishedURL(under: directory), encoding: .utf8)
    #expect(cleanedMarkdown.contains("Original text."))
    #expect(cleanedMarkdown.contains("Hello there, how are you?"))
  }

  @Test("many turns ride a handful of batched calls, not one call each")
  func turnsAreBatchedIntoChunkedCalls() async throws {
    let directory = Self.makeTempDirectory("chunking")
    defer { try? FileManager.default.removeItem(at: directory) }

    // 60 turns × 10s = 600s of talking: two 300s chunks, so two LLM calls
    // where the per-turn shape would have made sixty.
    let segments = (0..<60).map { index in
      TranscriptSegment(
        source: "mic", speaker: "You",
        segment: Segment(
          start: Double(index) * 10, end: Double(index) * 10 + 10,
          text: "hello there how are you"))
    }
    let markdownURL = try Self.writeFixtureTranscript(at: directory, segments: segments)

    // No scripted results: FakeLLMBackend echoes the dynamic suffix, which is
    // the rendered chunk — already in the marker format, so every turn round
    // trips and is accepted unchanged.
    let (deps, backend) = Self.dependencies(llmResults: [])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: [], chunkSeconds: 300),
      dependencies: deps)

    #expect(exitCode == 0)
    let recorded = await backend.receivedPrompts
    #expect(
      recorded.count == 2, "expected 2 chunked calls for 600s of talking, got \(recorded.count)")
    // Every turn reached the model exactly once across the two calls.
    let markedLines = recorded.map { $0.dynamicSuffix.split(separator: "\n").count }
    #expect(markedLines == [30, 30])
  }

  @Test("a chunk response that drops turns falls back only for the turns it dropped")
  func droppedTurnsFallBackIndividually() async throws {
    let directory = Self.makeTempDirectory("dropped-turns")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "hello there how are you")),
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 4, end: 7, text: "the deploy went out last night")),
      ])

    // The model answers turn 1 and silently drops turn 2 — the failure mode
    // batching introduces. Turn 2 must keep its original text, not inherit
    // turn 1's or shift into its place.
    let (deps, _) = Self.dependencies(llmResults: [
      .success(LLMCompletionResult(text: "[[1|You]] Hello there, how are you?"))
    ])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let cleanedMarkdown = try String(
      contentsOf: Self.publishedURL(under: directory), encoding: .utf8)
    #expect(cleanedMarkdown.contains("Hello there, how are you?"))
    #expect(cleanedMarkdown.contains("the deploy went out last night"))
  }

  @Test("--out overrides the output path")
  func explicitOutOverridesPath() async throws {
    let directory = Self.makeTempDirectory("explicit-out")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ])
    let customOut = directory.appendingPathComponent("custom.clean.md").path

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: customOut,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: customOut))
    // Sidecar is derived from the output path itself (custom.clean.md ->
    // custom.clean.json), not from the input transcript's name.
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("custom.clean.json").path))
  }

  @Test("works with no JSON sidecar present (Markdown-only fallback)")
  func worksWithoutSidecar() async throws {
    let directory = Self.makeTempDirectory("no-sidecar")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ],
      writeSidecar: false)

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: Self.publishedURL(under: directory).path))
  }

  @Test("an LLM timeout aborts the run with exit 5 (retryable upstream failure)")
  func llmTimeoutExitsRetryableUpstream() async throws {
    let directory = Self.makeTempDirectory("llm-timeout")
    defer { try? FileManager.default.removeItem(at: directory) }

    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You", segment: Segment(start: 0, end: 3, text: "Original text."))
      ])

    let (deps, _) = Self.dependencies(llmResults: [.failure(LLMBackendError.timedOut)])

    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    // A timed-out LLM is an upstream outage, not a per-segment degrade: the
    // remaining segments would hit the same wall, so the run aborts with the
    // retryable class a future retry policy keys on (issue #61).
    #expect(exitCode == 5, "expected exit 5 (retryable-upstream), got \(exitCode)")
  }

  @Test("publishes through the template, keyed on the transcript's own title and start")
  func publishesThroughTemplate() async throws {
    let directory = Self.makeTempDirectory("publish")
    defer { try? FileManager.default.removeItem(at: directory) }

    // A session transcript: title and `started:` (2026-08-05T09:04:07Z, US
    // week 32) are the context the template reads, and `started` is
    // deliberately a different day from the transcribed range's start, so a
    // narrowed rerun provably files under the day the session began.
    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ],
      session: "0d5e7f6a",
      title: "Kevin Weekly",
      started: Instant(secondsSinceEpoch: 1_785_920_647))

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: PathTemplate(
          "{output_root}/{year}/{month}/{day}/{week}/{date} - {title}.md"),
        outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    let published = directory.appendingPathComponent(
      "2026/08/05/32/2026-08-05 - Kevin Weekly.md")
    #expect(FileManager.default.fileExists(atPath: published.path))
    // The sidecar follows the Markdown wherever it lands.
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("2026/08/05/32/2026-08-05 - Kevin Weekly.json")
          .path))
  }

  @Test("week_numbering = iso changes {week} where the conventions disagree")
  func isoWeekNumbering() async throws {
    let directory = Self.makeTempDirectory("iso-week")
    defer { try? FileManager.default.removeItem(at: directory) }

    // 2027-01-01 is a Friday: US week 01 of 2027, ISO week 53 of 2026.
    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "mic", speaker: "You",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ],
      title: "New Year",
      started: Instant(secondsSinceEpoch: 1_798_761_600))

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: PathTemplate("{output_root}/{week}/{title}.md"),
        outputRoot: directory.path, weekNumbering: .iso,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("53/New Year.md").path))
  }

  @Test("a --file transcript with no session context publishes under the input's basename")
  func fileTranscriptFallsBackToBasename() async throws {
    let directory = Self.makeTempDirectory("file-fallback")
    defer { try? FileManager.default.removeItem(at: directory) }

    // `transcribe --file memo.m4a` names its single source after the file, so
    // a transcript with neither a title nor a session still resolves
    // `{title}` — through `{slug}` — to something that identifies the input.
    let markdownURL = try Self.writeFixtureTranscript(
      at: directory,
      segments: [
        TranscriptSegment(
          source: "memo", speaker: "memo",
          segment: Segment(start: 0, end: 3, text: "Hi.", confidence: 1.0))
      ],
      sources: ["memo"],
      name: "memo.transcript.md")

    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: markdownURL.path, out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: directory.path, weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)

    #expect(exitCode == 0)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("published/1970-01-01 - memo.md").path))
  }

  @Test("a missing transcript file is a clear, non-zero error")
  func missingTranscriptIsError() async {
    let (deps, _) = Self.dependencies(llmResults: [])
    let exitCode = await CleanupPipeline.run(
      inputs: CleanupPipeline.Inputs(
        transcriptPath: "/nonexistent/path.transcript.md", out: nil,
        outputTemplate: Self.outputTemplate, outputRoot: "/nonexistent", weekNumbering: .us,
        systemPrompt: nil, vocabulary: []),
      dependencies: deps)
    #expect(exitCode == 3)
  }
}
