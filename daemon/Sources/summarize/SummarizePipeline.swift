import EarsCLISupport
import EarsCore
import EarsDataStore
import EarsLLMKit
import Foundation

/// `summarize`'s actual pipeline, per `docs/specs/llm-stages.md`'s
/// "summarize" section: read one or more transcripts at the paths given
/// (the caller names them — `summarize --session` resolves the session's
/// cleaned transcript, and the daemon chain passes cleanup's output
/// forward), optionally read each preset's companion notes file, run every
/// selected preset's prompt over the result, and write `<...>.summary.md`
/// (single preset) or `<...>.<preset>.summary.md` (multiple), with
/// `kind: summary`, `preset`, and `derived_from`.
///
/// A preset can override all of that: `out` names its own destination
/// through a ``PathTemplate`` (including `{notes}`, to write back over its
/// own notes file), and `frontmatter = false` emits the body alone for a
/// destination — an Obsidian vault, say — that owns its own frontmatter.
///
/// Split the same way `cleanup`'s `CleanupPipeline`/`CleanupRuntime` are:
/// this type takes already-resolved inputs (an injected `LLMBackend`,
/// already-loaded preset prompt contents) so it's directly unit-testable
/// against fixture transcript files and a `FakeLLMBackend`, with
/// ``SummarizeRuntime`` as the thin config/environment glue.
enum SummarizePipeline {
  /// A resolved `[[summarize.preset]]` entry: its name and its prompt file's
  /// already-read content (empty when `prompt_file` is unset/unreadable — a
  /// preset with no prompt still runs, just with no extra instructions
  /// beyond the transcript text itself, rather than failing the run).
  struct Preset: Sendable {
    var name: String
    var promptContent: String
    /// `notes`: a path template for a companion notes file, read as **plain
    /// Markdown** — no frontmatter parsing, no sidecar. When set and the
    /// expanded path doesn't exist, this preset fails (the others still
    /// run): a prompt written to fold jotted notes into its output would
    /// silently drop them otherwise.
    var notes: PathTemplate? = nil
    /// `out`: a path template for this preset's output, overriding the
    /// default sibling naming. May reference `{notes}` to write back over
    /// the notes file — safe because every input is read before any write.
    var out: PathTemplate? = nil
    /// `frontmatter`: `false` emits the summary body alone, with no YAML
    /// block and no JSON sidecar — the artifact is then plain Markdown, not
    /// an ears document, which is what writing into a vault (whose own
    /// frontmatter the `kind:`/`preset:` stamp would collide with) needs.
    var frontmatter: Bool = true
  }

  /// One preset's outcome, reported through
  /// ``Dependencies/onPresetResult`` as the run progresses — the per-preset
  /// result surface `--json`'s envelope carries (issue #63), so partial
  /// success ("2 of 3 presets") is expressible instead of collapsing into a
  /// single exit code. `path` is the written summary's absolute path on
  /// success, absent on failure. Doubles as the envelope's wire type
  /// (`{preset, path, ok}` per `shared/stage-envelopes/summarize.v1.schema.json`).
  struct PresetResult: Codable, Sendable, Equatable {
    var preset: String
    var path: String? = nil
    var ok: Bool
  }

  struct Dependencies: Sendable {
    var clock: any NowProviding
    var llmBackend: any LLMBackend
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void
    /// Called once per selected preset, in run order, with that preset's
    /// outcome. Default no-op: plain-mode callers don't consume it.
    var onPresetResult: @Sendable (PresetResult) -> Void = { _ in }

    static func production(
      llmBackend: any LLMBackend,
      onError: (@Sendable (String) -> Void)? = nil
    ) -> Dependencies {
      Dependencies(
        clock: SystemClock(),
        llmBackend: llmBackend,
        log: { message in
          FileHandle.standardError.write(Data(("summarize: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
          onError?(line)
        }
      )
    }
  }

  struct Inputs: Sendable {
    var transcriptPaths: [String]
    var presets: [Preset]
    var out: String?
    /// `--notes <path>`: an ad-hoc companion notes file, overriding the
    /// selected preset's own `notes` template. Single-preset runs only —
    /// the runtime rejects it otherwise.
    var notes: String? = nil
    /// The configured `output_root`, already `~`-expanded.
    var outputRoot: String = ""
    var weekNumbering: WeekNumbering = .us
  }

  static func run(inputs: Inputs, dependencies: Dependencies) async -> Int32 {
    // Defensive twins of the runtime's own guards: usage-shaped absences.
    guard !inputs.transcriptPaths.isEmpty else {
      dependencies.writeStderr("error: at least one transcript path is required")
      return ExitClass.usage.code
    }
    guard !inputs.presets.isEmpty else {
      dependencies.writeStderr("error: at least one preset is required (--preset or --all-presets)")
      return ExitClass.usage.code
    }

    var documents: [TranscriptDocument] = []
    var resolvedNames: [String] = []
    for path in inputs.transcriptPaths {
      let resolvedURL = URL(fileURLWithPath: path)
      let markdown: String
      do {
        markdown = try String(contentsOf: resolvedURL, encoding: .utf8)
      } catch {
        dependencies.writeStderr(
          "error: could not read transcript at \(resolvedURL.path): \(error)")
        return ExitClass.inputMissing.code
      }
      let sidecarURL = resolvedURL.deletingPathExtension().appendingPathExtension("json")
      let jsonSidecar = try? String(contentsOf: sidecarURL, encoding: .utf8)
      do {
        documents.append(try TranscriptParser.parse(markdown: markdown, jsonSidecar: jsonSidecar))
      } catch {
        dependencies.writeStderr(
          "error: could not parse transcript at \(resolvedURL.path): \(error)")
        return ExitClass.inputMissing.code
      }
      resolvedNames.append(resolvedURL.lastPathComponent)
    }

    let combinedText = documents.map(bodyText).joined(separator: "\n\n")
    let baseFrontmatter = mergedFrontmatter(
      documents.map(\.frontmatter), now: dependencies.clock.now())
    let baseOutputURL = outputBaseURL(
      for: URL(fileURLWithPath: inputs.transcriptPaths[0]), explicitOut: inputs.out)

    // Every preset's destination and companion notes are resolved, and every
    // notes file read, **before any write happens**. That ordering is what
    // makes an `out = "{notes}"` preset safe: the file it overwrites has
    // already been read, by this preset and by any other.
    let context = templateContext(inputs, baseFrontmatter, documents)
    let plans = inputs.presets.map { preset -> PresetPlan in
      let notesPath =
        inputs.notes ?? preset.notes.map { $0.expand(context) }
      var notesContext = context
      notesContext.notes = notesPath
      return PresetPlan(
        preset: preset,
        notesPath: notesPath,
        notes: notesPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) },
        outputURL: preset.out.map { URL(fileURLWithPath: $0.expand(notesContext)) })
    }

    // Presets run independently (issue #63): one preset's failure no longer
    // aborts the rest — each outcome is reported through `onPresetResult`, so
    // partial success ("2 of 3 presets") is expressible in the `--json`
    // envelope instead of collapsing into the first failure. The run still
    // exits non-zero unless *all* presets succeeded, carrying the first
    // failure's taxonomy class (issue #61).
    var firstFailure: ExitClass? = nil
    for plan in plans {
      let preset = plan.preset
      // A configured notes file that isn't there is this preset's failure,
      // not the run's: its prompt is written to fold those notes into its
      // output, so summarizing without them would silently lose them.
      if let notesPath = plan.notesPath, plan.notes == nil {
        dependencies.writeStderr(
          "error: preset '\(preset.name)': no notes file at \(notesPath)")
        dependencies.onPresetResult(PresetResult(preset: preset.name, ok: false))
        if firstFailure == nil { firstFailure = .inputMissing }
        continue
      }

      let prompt = LLMPrompt(
        stablePrefix: preset.promptContent,
        dynamicSuffix: promptBody(notes: plan.notes, transcript: combinedText))
      let summaryText: String
      do {
        summaryText = try await dependencies.llmBackend.complete(prompt).text
      } catch {
        // Classified at the site that knows the cause (issue #61): a timeout
        // is a retryable upstream outage (5); a crashed or missing model
        // command is a hard stage failure (4). Either way the remaining
        // presets still run — presets are few, and keeping a mostly
        // -successful run's other summaries beats discarding them.
        dependencies.writeStderr(
          "error: LLM call failed for preset '\(preset.name)': \(error)")
        dependencies.onPresetResult(PresetResult(preset: preset.name, ok: false))
        if firstFailure == nil { firstFailure = ExitClass.classifying(llmError: error) }
        continue
      }

      var frontmatter = baseFrontmatter
      frontmatter.preset = preset.name
      frontmatter.derivedFrom = resolvedNames.joined(separator: ", ")
      let document = TranscriptDocument(
        frontmatter: frontmatter,
        segments: [
          TranscriptSegment(
            source: baseFrontmatter.sources.first ?? "unknown", speaker: "Summary",
            segment: Segment(start: 0, end: 0, text: summaryText))
        ])

      let outputURL =
        plan.outputURL
        ?? outputURL(
          for: baseOutputURL, preset: preset.name, isOnlyPreset: inputs.presets.count == 1)
      do {
        // `frontmatter = false` means this artifact is plain Markdown, not an
        // ears document — so it gets no YAML block, and no JSON sidecar
        // either: a stray `.json` beside a vault note is pollution, and there
        // is no ears document for it to describe.
        let body = summaryText.hasSuffix("\n") ? summaryText : summaryText + "\n"
        let markdown = preset.frontmatter ? TranscriptRenderer.renderMarkdown(document) : body
        try AtomicFileIO.writeAtomically(to: outputURL) { tempURL in
          try markdown.write(to: tempURL, atomically: false, encoding: .utf8)
        }
        if preset.frontmatter {
          let sidecarURL = outputURL.deletingPathExtension().appendingPathExtension("json")
          try AtomicFileIO.writeAtomically(to: sidecarURL) { tempURL in
            try TranscriptRenderer.renderJSON(document).write(
              to: tempURL, atomically: false, encoding: .utf8)
          }
        }
      } catch {
        dependencies.writeStderr(
          "error: failed to write summary for preset '\(preset.name)': \(error)")
        dependencies.onPresetResult(PresetResult(preset: preset.name, ok: false))
        if firstFailure == nil { firstFailure = .stageFailed }
        continue
      }
      dependencies.log("run.summary: preset=\(preset.name) output=\(outputURL.path)")
      // Standardized so the reported path is always absolute with no `.`/`..`
      // components — consumers (the daemon, `--json` scripting) read it from
      // a different cwd, matching the plain result line's own convention.
      dependencies.onPresetResult(
        PresetResult(
          preset: preset.name,
          path: URL(fileURLWithPath: outputURL.path).standardizedFileURL.path,
          ok: true))
    }

    return (firstFailure ?? .success).code
  }

  /// One preset's fully-resolved destination and companion notes, computed
  /// for every preset before any write happens.
  private struct PresetPlan: Sendable {
    var preset: Preset
    /// The expanded `notes` path, when this preset configures one.
    var notesPath: String?
    /// That file's contents — `nil` when it doesn't exist or can't be read,
    /// which fails this preset (see the run loop).
    var notes: String?
    /// The expanded `out` path, or `nil` for the default sibling naming.
    var outputURL: URL?
  }

  /// The LLM input. With a companion notes file both halves are labelled, so
  /// a prompt can address each ("fold the jotted notes into a narrative,
  /// using the transcript for detail"). With no notes the transcript is sent
  /// bare, exactly as before — an unlabelled single input needs no heading.
  private static func promptBody(notes: String?, transcript: String) -> String {
    guard let notes else { return transcript }
    return "## Jotted notes\n\n\(notes)\n\n## Transcript\n\n\(transcript)"
  }

  /// The path-template context for this run, read off the input documents'
  /// merged frontmatter — the same context `cleanup` publishes by, so a
  /// preset's `notes`/`out` templates address the same session.
  private static func templateContext(
    _ inputs: Inputs, _ frontmatter: TranscriptFrontmatter, _ documents: [TranscriptDocument]
  ) -> PathTemplate.Context {
    PathTemplate.Context(
      outputRoot: inputs.outputRoot,
      start: frontmatter.started ?? frontmatter.range.start,
      weekNumbering: inputs.weekNumbering,
      session: frontmatter.session,
      slug: frontmatter.sources.map(\.pathSafe).joined(separator: "_"),
      title: frontmatter.title,
      fallbackName: URL(fileURLWithPath: inputs.transcriptPaths[0])
        .deletingPathExtension().lastPathComponent)
  }

  private static func bodyText(_ document: TranscriptDocument) -> String {
    document.segments.map { "\($0.speaker): \($0.segment.text)" }.joined(separator: "\n")
  }

  /// Merges multiple input transcripts' frontmatter into one summary
  /// frontmatter: sources/vocab are unioned, the range spans the earliest
  /// start to the latest end, and speech/word totals are summed. `model`/
  /// `diarization` are echoed from the first document — summarize doesn't
  /// run its own ASR/diarization pass, so these describe what produced the
  /// underlying transcript(s), not this summary.
  private static func mergedFrontmatter(_ inputs: [TranscriptFrontmatter], now: Instant)
    -> TranscriptFrontmatter
  {
    let first = inputs[0]
    var sources: [SourceID] = []
    var seenSources = Set<SourceID>()
    var vocab: [String] = []
    var seenVocab = Set<String>()
    var start = first.range.start
    var end = first.range.end
    var speechSeconds = 0.0
    var wordCount = 0

    for frontmatter in inputs {
      for source in frontmatter.sources where seenSources.insert(source).inserted {
        sources.append(source)
      }
      for term in frontmatter.vocab where seenVocab.insert(term).inserted {
        vocab.append(term)
      }
      start = min(start, frontmatter.range.start)
      end = max(end, frontmatter.range.end)
      speechSeconds += frontmatter.speechSeconds
      wordCount += frontmatter.wordCount
    }

    return TranscriptFrontmatter(
      schema: first.schema,
      kind: .summary,
      rangeRun: first.rangeRun,
      session: first.session,
      // The path-template context, carried forward from the first document:
      // a summary of several transcripts still belongs to the session that
      // one names, and this is what a preset's `notes`/`out` expand against.
      title: first.title,
      started: first.started,
      sources: sources,
      range: TimeRange(start: start, end: end),
      model: first.model,
      diarization: first.diarization,
      generated: now,
      durationSeconds: end.interval(since: start),
      speechSeconds: speechSeconds,
      wordCount: wordCount,
      vocab: vocab
    )
  }

  /// `<...>.transcript.md`/`<...>.clean.md` → `<...>.summary.md` (or the
  /// explicit `--out`, when given).
  private static func outputBaseURL(for firstTranscriptURL: URL, explicitOut: String?) -> URL {
    if let explicitOut { return URL(fileURLWithPath: explicitOut) }
    let name = firstTranscriptURL.lastPathComponent
    let directory = firstTranscriptURL.deletingLastPathComponent()
    for suffix in [".transcript.md", ".clean.md"] where name.hasSuffix(suffix) {
      let stem = String(name.dropLast(suffix.count))
      return directory.appendingPathComponent("\(stem).summary.md")
    }
    let stem = firstTranscriptURL.deletingPathExtension().lastPathComponent
    return directory.appendingPathComponent("\(stem).summary.md")
  }

  /// **Decision:** with exactly one preset, `baseOutputURL` (which already
  /// honors `--out` when given — see ``outputBaseURL(for:explicitOut:)``) is
  /// used as-is. With more than one preset there is no single unambiguous
  /// destination for one bare `--out` path to name, so each preset's output
  /// is `baseOutputURL` with `.<preset>` inserted before `.summary.md` —
  /// still built from `--out` when given, just disambiguated per preset
  /// rather than colliding on one path.
  private static func outputURL(
    for baseOutputURL: URL, preset: String, isOnlyPreset: Bool
  ) -> URL {
    if isOnlyPreset { return baseOutputURL }
    let name = baseOutputURL.lastPathComponent
    let directory = baseOutputURL.deletingLastPathComponent()
    guard name.hasSuffix(".summary.md") else {
      return directory.appendingPathComponent("\(name).\(preset).summary.md")
    }
    let stem = String(name.dropLast(".summary.md".count))
    return directory.appendingPathComponent("\(stem).\(preset).summary.md")
  }
}
