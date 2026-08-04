import EarsCLISupport
import EarsCore
import EarsDataStore
import EarsLLMKit
import Foundation

/// `cleanup`'s actual pipeline, per `docs/specs/llm-stages.md`'s
/// "cleanup" section: read a `.transcript.md` (+ JSON sidecar if present),
/// run each segment through the LLM guardrail chain (skip high-confidence
/// utterances, build a minimal-change prompt, validate the candidate against
/// the original), and write `<...>.clean.md` atomically with `kind: clean`
/// and `derived_from` naming the source transcript.
///
/// Split the same way `transcribe`'s `TranscribePipeline`/`TranscribeRuntime`
/// are: this type takes already-resolved inputs (an injected `LLMBackend`,
/// already-read vocabulary terms, already-read prompt override) rather than
/// touching config/environment/the real LLM subprocess itself, so it's
/// directly unit-testable against fixture transcript files and a
/// `FakeLLMBackend` with no environment or real config file
/// (`docs/engineering-practices.md`'s tier-1 strategy). ``CleanupRuntime`` is
/// the thin glue that resolves those inputs from real config and calls in.
///
/// **Scope decision — no cross-segment chunking:** each ``TranscriptSegment``
/// (one speaker turn) is sent to the LLM independently; there is no
/// chunking-with-overlap of a single pathologically long segment's text.
/// Segments are already naturally short (VAD-bounded utterances), so this is
/// a defensible scope bound for now, not silently assumed — a future task
/// can add chunking if a real transcript ever needs it.
///
/// **Scope decision — no speaker name map:** `docs/specs/llm-stages.md`'s
/// optional "apply a speaker name map if present" step is
/// diarization-dependent (not yet built — see
/// `docs/specs/model-interface.md`), so it is not applied here.
enum CleanupPipeline {
  struct Dependencies: Sendable {
    var clock: any NowProviding
    var llmBackend: any LLMBackend
    var validator: CleanupValidator
    var skipPolicy: HighConfidenceSkipPolicy
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void
    /// The machine-readable stdout channel: a successful run's **final stdout
    /// line is the cleaned transcript's absolute path** — the same contract
    /// `transcribe` follows (see `TranscribePipeline.Dependencies`), parsed by
    /// the daemon's on-end stage chain to feed `summarize`. ``CleanupRuntime``
    /// routes this through the process's `EarsCLISupport.ResultChannel` — the
    /// *only* route to the real stdout once the channel is active — so the
    /// default is a no-op rather than a direct `FileHandle.standardOutput`
    /// write pollution could share.
    var writeStdout: @Sendable (String) -> Void = { _ in }
    /// Structured headline counts for the final `run.summary` (segments,
    /// accepted, fallback, skipped, output) — the same numbers the
    /// human-readable `run.summary:` stderr line carries, surfaced as fields
    /// so `RunDiagnostics` can fold them into the structured summary and the
    /// `--json` envelope's `stats` (issue #63). Mirrors
    /// `TranscribePipeline.Dependencies.onSummary`.
    var onSummary: (@Sendable ([LogField]) -> Void)? = nil

    static func production(
      llmBackend: any LLMBackend,
      onError: (@Sendable (String) -> Void)? = nil
    ) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        llmBackend: llmBackend,
        validator: CleanupValidator(),
        skipPolicy: HighConfidenceSkipPolicy(),
        log: { message in
          FileHandle.standardError.write(Data(("cleanup: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
          onError?(line)
        }
      )
    }
  }

  struct Inputs: Sendable {
    /// Path to the source `.transcript.md` (or `.clean.md` — any rendered
    /// transcript document; cleanup doesn't care which stage produced it).
    var transcriptPath: String
    var out: String?
    /// The cleanup system prompt to use, or `nil` for
    /// `CleanupPromptBuilder`'s built-in default.
    var systemPrompt: String?
    /// Already-read, merged vocabulary terms (global + `--vocab`), or empty
    /// when vocab is disabled (`--no-vocab` / `[cleanup].use_vocab = false`).
    var vocabulary: [String]
  }

  static func run(inputs: Inputs, dependencies: Dependencies) async -> Int32 {
    let transcriptURL = URL(fileURLWithPath: inputs.transcriptPath)
    let markdown: String
    do {
      markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
    } catch {
      dependencies.writeStderr(
        "error: could not read transcript at \(inputs.transcriptPath): \(error)")
      return ExitClass.inputMissing.code
    }

    let inputSidecarURL = sidecarURL(for: transcriptURL)
    let jsonSidecar = try? String(contentsOf: inputSidecarURL, encoding: .utf8)

    let document: TranscriptDocument
    do {
      document = try TranscriptParser.parse(markdown: markdown, jsonSidecar: jsonSidecar)
    } catch {
      dependencies.writeStderr(
        "error: could not parse transcript at \(inputs.transcriptPath): \(error)")
      return ExitClass.inputMissing.code
    }

    let promptBuilder = CleanupPromptBuilder(
      systemPrompt: inputs.systemPrompt ?? CleanupPromptBuilder.defaultSystemPrompt,
      vocabulary: inputs.vocabulary
    )

    var skipped = 0
    var accepted = 0
    var fellBack = 0
    var cleanedSegments: [TranscriptSegment] = []
    cleanedSegments.reserveCapacity(document.segments.count)

    for turn in document.segments {
      if dependencies.skipPolicy.shouldSkip(turn.segment) {
        skipped += 1
        cleanedSegments.append(turn)
        continue
      }

      let prompt = promptBuilder.build(transcript: turn.segment.text)
      let candidateText: String
      do {
        candidateText = try await dependencies.llmBackend.complete(prompt).text
      } catch {
        // A timeout is an upstream outage, not a per-segment degrade: every
        // remaining segment would stall against the same wall (each waiting
        // the full timeout), so the run aborts with the retryable class a
        // future retry policy keys on (issue #61). Every *other* LLM failure
        // keeps the per-segment fallback — one crashed completion shouldn't
        // discard the rest of a mostly-successful pass.
        if ExitClass.classifying(llmError: error) == .retryableUpstream {
          dependencies.writeStderr(
            "error: LLM call timed out; aborting cleanup as retryable: \(error)")
          return ExitClass.retryableUpstream.code
        }
        dependencies.log(
          "LLM call failed for a segment, keeping the original text: \(error)")
        fellBack += 1
        cleanedSegments.append(turn)
        continue
      }

      switch dependencies.validator.validate(original: turn.segment.text, candidate: candidateText)
      {
      case .accept(let cleaned):
        accepted += 1
        var cleanedTurn = turn
        cleanedTurn.segment.text = cleaned
        cleanedSegments.append(cleanedTurn)
      case .fallback(let reason):
        fellBack += 1
        dependencies.log("rejected a cleanup candidate (\(reason)), keeping the original text")
        cleanedSegments.append(turn)
      }
    }

    // Every attempted (non-skipped) segment falling back means the stage
    // produced nothing: the "cleaned" output would be a byte-for-byte copy of
    // the input. That is a stage failure under the exit-code taxonomy
    // (issue #61's "every-segment-rejected"), reported loudly rather than
    // dressed up as a success the chain would then feed forward.
    let attempted = document.segments.count - skipped
    if attempted > 0 && accepted == 0 {
      dependencies.writeStderr(
        "error: cleanup produced no accepted segments "
          + "(\(fellBack) of \(attempted) attempted segments fell back)")
      return ExitClass.stageFailed.code
    }

    let generated = dependencies.clock.now()
    // frontmatter.vocab records the *named lists* merged for a run (e.g.
    // "global", per TranscriptFrontmatter's doc comment) — not the raw terms
    // this pipeline injects into the LLM prompt (inputs.vocabulary). Cleanup
    // inherits whatever the source transcript already recorded there rather
    // than guessing a mapping from terms back to list names.
    var frontmatter = document.frontmatter
    frontmatter.kind = .clean
    frontmatter.derivedFrom = transcriptURL.lastPathComponent
    frontmatter.generated = generated

    let cleanedDocument = TranscriptDocument(frontmatter: frontmatter, segments: cleanedSegments)

    let outputURL =
      inputs.out.map { URL(fileURLWithPath: $0) } ?? cleanOutputURL(for: transcriptURL)
    let outputSidecarURL = sidecarURL(for: outputURL)

    do {
      let outputMarkdown = TranscriptRenderer.renderMarkdown(cleanedDocument)
      try AtomicFileIO.writeAtomically(to: outputURL) { tempURL in
        try outputMarkdown.write(to: tempURL, atomically: false, encoding: .utf8)
      }
      let outputJSON = TranscriptRenderer.renderJSON(cleanedDocument)
      try AtomicFileIO.writeAtomically(to: outputSidecarURL) { tempURL in
        try outputJSON.write(to: tempURL, atomically: false, encoding: .utf8)
      }
    } catch {
      dependencies.writeStderr("error: failed to write cleaned transcript: \(error)")
      return ExitClass.stageFailed.code
    }

    dependencies.log(
      "run.summary: segments=\(document.segments.count) accepted=\(accepted) "
        + "fallback=\(fellBack) skipped=\(skipped) output=\(outputURL.path)"
    )
    dependencies.onSummary?([
      LogField("segments", .int(document.segments.count)),
      LogField("accepted", .int(accepted)),
      LogField("fallback", .int(fellBack)),
      LogField("skipped", .int(skipped)),
      LogField("output", .string(outputURL.path)),
    ])
    // The stdout path contract (see Dependencies.writeStdout): emitted only
    // after both output files are durably written. Re-wrapped and
    // standardized so the emitted line is always an absolute path with no
    // `.`/`..` components — the daemon parses it from a different cwd, where
    // a relative `--out` spelling means nothing.
    dependencies.writeStdout(URL(fileURLWithPath: outputURL.path).standardizedFileURL.path)
    return 0
  }

  /// `<...>.transcript.json` for `<...>.transcript.md` (same stem, `.md` →
  /// `.json`) — the sidecar naming convention `OutputPathResolution` also
  /// uses on the write side.
  private static func sidecarURL(for markdownURL: URL) -> URL {
    markdownURL.deletingPathExtension().appendingPathExtension("json")
  }

  /// `<...>.transcript.md` → `<...>.clean.md`; any other name gets `.clean.md`
  /// appended after stripping its extension, so `cleanup` still produces a
  /// sensible sibling file when pointed at a non-standard filename.
  private static func cleanOutputURL(for transcriptURL: URL) -> URL {
    let name = transcriptURL.lastPathComponent
    let directory = transcriptURL.deletingLastPathComponent()
    if name.hasSuffix(".transcript.md") {
      let stem = String(name.dropLast(".transcript.md".count))
      return directory.appendingPathComponent("\(stem).clean.md")
    }
    let stem = transcriptURL.deletingPathExtension().lastPathComponent
    return directory.appendingPathComponent("\(stem).clean.md")
  }
}
