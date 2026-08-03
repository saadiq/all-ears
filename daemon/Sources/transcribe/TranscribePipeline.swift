import EarsCore
import EarsDataStore
import EarsDiarizeKit
import EarsLogging
import EarsTranscribeKit
import Foundation

/// `transcribe`'s actual pipeline, per `docs/specs/transcribe.md`'s
/// "Behaviour" section: resolve the requested range and sources, read each
/// source's real captured audio into decoded, natural-pause-segmented
/// slices (``SegmentedAudioReader``, the composition root already merged on
/// this base -- it resolves each source's `meta.toml` for the ASR sample
/// rate and reads the real, codec-decoded `asr/` chunk files itself), run
/// each slice through a ``Transcriber``, merge the results onto one shared
/// timeline (``TranscriptAssembly``), and write the Markdown transcript +
/// JSON sidecar atomically.
///
/// Deliberately takes `dataRoot`/`outputRoot`/`backendName` as plain,
/// already-resolved values rather than reading config/environment itself --
/// that resolution is ``TranscribeRuntime``'s job (the thin, tier-2/3 glue
/// layer that reads `ProcessInfo.environment`/the home directory/the real
/// config file). Splitting it this way means this type -- everything from
/// "have a data root and an output root" onward, which is most of
/// `transcribe`'s actual behaviour -- is directly unit-testable against a
/// fixture data root and an injected fake ``Transcriber`` with no
/// environment-variable or config-file setup at all, per
/// `docs/engineering-practices.md`'s tier-1 "fixture audio store on disk"
/// strategy.
enum TranscribePipeline {
  /// Everything real production code has to fake to test this type: the
  /// wall clock and which ``Transcriber`` to run. `log` is a side-channel
  /// for non-fatal, human-readable notices (the final run summary) --
  /// separate from the hard-failure `writeStderr` path, which always
  /// accompanies a non-zero exit code.
  struct Dependencies: Sendable {
    var clock: any NowProviding
    var transcriberFactory: @Sendable () throws -> any Transcriber
    var loadOptions: LoadOptions
    /// The optional diarization backend (`docs/specs/model-interface.md`'s
    /// `Diarizer`). `nil` ⇒ diarization is off (the default): segments keep
    /// source-only labels, exactly as before. When present, each multi-speaker
    /// far-end source is refined into `Speaker N` (the offline/stabilised pass).
    var diarizerFactory: (@Sendable () throws -> any Diarizer)? = nil
    /// Model/compute selection for the diarizer, resolved from `[diarize]`.
    var diarizerLoadOptions: LoadOptions = LoadOptions()
    var log: @Sendable (String) -> Void
    var writeStderr: @Sendable (String) -> Void
    /// Structured headline counts for the final `run.summary` (segments,
    /// words, sources consulted, output path), surfaced so the *log* — not
    /// just the human-readable stdout/stderr line — carries them, and an
    /// empty-but-successful run (`segments=0 words=0`) is distinguishable from
    /// a run that failed (issue #25). Optional: unit tests that only assert
    /// exit codes leave it `nil`.
    var onSummary: (@Sendable ([LogField]) -> Void)? = nil
    /// Emits the `stage.start`/`stage.end` pairs `docs/logging.md` specifies,
    /// so per-stage timing and `rtf` are queryable instead of only whole-run
    /// wall time. Optional: unit tests that don't assert on logging leave it
    /// `nil` and every `measure` call becomes a plain passthrough.
    var spans: StageSpans? = nil

    /// The real backend: ``ParakeetTranscriber``, FluidAudio-backed Parakeet
    /// on the ANE/Metal (`docs/specs/model-interface.md`'s "Backend
    /// 1 -- native"), loaded once per run in ``TranscribePipeline/run``
    /// below with `loadOptions` resolved from `[transcribe].model`/`compute`
    /// config (``TranscribeRuntime``).
    ///
    /// `onError`/`onSummary` are the structured-logging seams
    /// ``TranscribeRuntime`` wires to a ``RunDiagnostics``: `onError` observes
    /// every `error: …` line the pipeline writes to stderr (the last one wins,
    /// becoming the summary's `error` field), `onSummary` receives the final
    /// counts. Both default to `nil`, so this factory behaves exactly as
    /// before for any caller that doesn't need them.
    static func production(
      loadOptions: LoadOptions = LoadOptions(),
      diarizeBackendName: String = "none",
      diarizerLoadOptions: LoadOptions = LoadOptions(),
      onError: (@Sendable (String) -> Void)? = nil,
      onSummary: (@Sendable ([LogField]) -> Void)? = nil,
      spans: StageSpans? = nil
    ) -> Dependencies {
      // One shared ANE gate for both the ASR and diarization backends: the
      // macOS 14 Core ML SIGBUS this serializes against is process-wide, so
      // Parakeet and Sortformer must never run inference concurrently.
      let gate = ANEInferenceGate()
      // The closure is annotated `@Sendable` explicitly: inference does not
      // propagate the optional's `@Sendable` element type through the ternary
      // to a bare closure literal (it does for the direct `transcriberFactory:`
      // argument below, which is why that one needs no annotation).
      let diarizerFactory: (@Sendable () throws -> any Diarizer)? =
        diarizeBackendName == "sortformer"
        ? { @Sendable in SortformerDiarizerBackend(gate: gate) }
        : nil
      return Dependencies(
        clock: SystemClock(),
        transcriberFactory: { ParakeetTranscriber(gate: gate) },
        loadOptions: loadOptions,
        diarizerFactory: diarizerFactory,
        diarizerLoadOptions: diarizerLoadOptions,
        log: { message in
          FileHandle.standardError.write(Data(("transcribe: " + message + "\n").utf8))
        },
        writeStderr: { line in
          FileHandle.standardError.write(Data((line + "\n").utf8))
          onError?(line)
        },
        onSummary: onSummary,
        spans: spans
      )
    }
  }

  struct Inputs: Sendable {
    var last: String?
    var from: String?
    var to: String?
    /// `--meeting <id>`: union the meeting's intervals into one transcript
    /// (paused spans are skipped exactly like silence). Mutually exclusive
    /// with every other range flag — `Transcribe` validates that before the
    /// pipeline runs.
    var meeting: String? = nil
    var sourceIDs: [String]
    var out: String?
  }

  /// Entry point. `socketPath` (when resolvable) lets a `--meeting` run
  /// report its lifecycle through the daemon's `job.publish` feed —
  /// best-effort, never load-bearing.
  static func run(
    inputs: Inputs,
    dataRoot: URL,
    outputRoot: URL,
    backendName: String,
    socketPath: String? = nil,
    dependencies: Dependencies
  ) async -> Int32 {
    guard let meetingID = inputs.meeting else {
      return await runResolved(
        inputs: inputs, dataRoot: dataRoot, outputRoot: outputRoot, backendName: backendName,
        dependencies: dependencies)
    }
    let job = JobEventPublisher(
      socketPath: socketPath,
      jobID: "transcribe-\(UUID().uuidString.lowercased().prefix(8))",
      meetingID: meetingID,
      log: dependencies.log)
    await job.publish(state: .started)
    let code = await runResolved(
      inputs: inputs, dataRoot: dataRoot, outputRoot: outputRoot, backendName: backendName,
      dependencies: dependencies)
    await job.publish(
      state: code == 0 ? .done : .failed, detail: code == 0 ? nil : "exit \(code)")
    await job.shutdown()
    return code
  }

  private static func runResolved(
    inputs: Inputs,
    dataRoot: URL,
    outputRoot: URL,
    backendName: String,
    dependencies: Dependencies
  ) async -> Int32 {
    let now = dependencies.clock.now()

    // `--meeting` resolves to the meeting's interval union; the raw range
    // flags (`--last`, `--from`/`--to`) resolve to exactly one range.
    let requestedRange: TimeRange
    let intervalRanges: [TimeRange]
    let meetingRecord: Meeting?
    if let meetingID = inputs.meeting {
      let meeting: Meeting
      do {
        meeting = try MeetingStore.read(meetingID: meetingID, dataRoot: dataRoot)
      } catch {
        dependencies.writeStderr("error: unknown meeting '\(meetingID)': \(error)")
        return 1
      }
      // A still-open interval (meeting active) reads up to now — "give me
      // what's there so far", matching `--last`'s own "ending now" semantics.
      let ranges = meeting.intervals.compactMap { interval -> TimeRange? in
        let end = interval.end ?? now
        return interval.start < end ? TimeRange(start: interval.start, end: end) : nil
      }
      guard let first = ranges.first, let last = ranges.last else {
        dependencies.writeStderr("error: meeting '\(meetingID)' has no non-empty intervals")
        return 1
      }
      requestedRange = TimeRange(start: first.start, end: last.end)
      intervalRanges = ranges
      meetingRecord = meeting
    } else {
      switch TranscribeRangeResolution.resolve(
        last: inputs.last, from: inputs.from, to: inputs.to, now: now
      ) {
      case .success(let value): requestedRange = value
      case .failure(let error):
        dependencies.writeStderr("error: \(error.description)")
        return 1
      }
      intervalRanges = [requestedRange]
      meetingRecord = nil
    }

    // A meeting names its own sources; otherwise --source is required,
    // exactly as before.
    let sourceIDs = meetingRecord?.sources ?? inputs.sourceIDs.map { SourceID($0) }
    guard !sourceIDs.isEmpty else {
      dependencies.writeStderr("error: at least one --source is required (or --meeting naming one)")
      return 1
    }

    // Resolve, per source, which store to read from.
    //
    // A `--meeting` run consults each source's per-meeting copy
    // (`meetings/<id>/sources/<source>/`) *and* the global ring
    // (`<data-root>/sources/<source>/`), preferring the per-meeting copy when
    // it holds chunks and falling back to the ring only where it doesn't
    // (issue #20). It logs both consultations and never fails on a source that
    // exists in neither store — that source simply contributes nothing, with a
    // logged reason, so the meeting's other sources still transcribe. The raw
    // range path (`--last`/`--from`/`--to`) reads one shared root and keeps
    // the fail-fast "unknown source" guard.
    let plans: [SourceAudioPlan]
    if let meetingID = inputs.meeting {
      plans = planMeetingSources(
        sourceIDs: sourceIDs, meetingID: meetingID, dataRoot: dataRoot,
        intervalRanges: intervalRanges, log: dependencies.log)
    } else {
      // Audio is meeting-scoped: the ad-hoc flags (--last/--from/--to) have
      // no meeting context and keep the global root; there is no global audio
      // store any more, so they only find audio a caller staged there
      // deliberately.
      let audioRoot = dataRoot
      // Fail fast on an unknown source before loading the (expensive) ASR
      // model or reading any audio, per docs/specs/transcribe.md: "exits
      // non-zero with a precise error if ... sources are unknown." Checking
      // the source's directory (sources/<id>/) rather than requiring
      // meta.toml specifically: every source earsd has ever started capturing
      // gets this directory (EarsDaemon.init creates it unconditionally), so
      // its presence is the honest "does this source exist at all" signal --
      // a missing meta.toml on an existing directory (a stale capture from
      // before EarsDaemon started writing it) surfaces instead as
      // SegmentedAudioReader's own clear error below, not a misleading
      // "unknown source".
      let reader = SegmentedAudioReader(dataRoot: audioRoot)
      for sourceID in sourceIDs {
        let sourceDirectory = reader.sourceDirectory(for: sourceID)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
          dependencies.writeStderr(
            "error: unknown source '\(sourceID.rawValue)': no data found under \(sourceDirectory.path)"
          )
          return 1
        }
      }
      plans = sourceIDs.map { SourceAudioPlan(sourceID: $0, reader: reader, store: nil) }
    }

    // The run's correlation identifier is resolved up front so every stage
    // record below can carry it as its correlation key, matching the worked
    // example in docs/logging.md: the meeting id for a `--meeting` run, a
    // synthesized `<start-timestamp>_<slug>` identifier for a raw range run.
    let runIdentifier =
      meetingRecord?.id
      ?? OutputPathResolution.sessionIdentifier(
        requestedStart: requestedRange.start, sourceIDs: sourceIDs)

    // Optional per-meeting vocabulary, keyed by meeting id by convention:
    // `<data-root>/vocab/<meeting-id>.txt`. Parsed terms feed the
    // ``TranscribeContext`` handed to each transcribe call; absent file (or a
    // raw range run) means no vocabulary, exactly as before.
    var vocabulary: [String] = []
    if let meetingID = inputs.meeting {
      let vocabURL =
        dataRoot
        .appendingPathComponent("vocab")
        .appendingPathComponent("\(meetingID).txt")
      if let content = try? String(contentsOf: vocabURL, encoding: .utf8) {
        vocabulary = VocabFile.parse(content)
        dependencies.log(
          "vocab: merged \(vocabulary.count) terms from \(vocabURL.path)")
      }
    }
    let transcribeContext = TranscribeContext(vocabulary: vocabulary)

    let transcriber: any Transcriber
    do {
      transcriber = try await measure(
        dependencies.spans, "model_load", session: runIdentifier,
        fields: [LogField("backend", .string(backendName))]
      ) {
        let loaded = try dependencies.transcriberFactory()
        try loaded.load(dependencies.loadOptions)
        return loaded
      }
    } catch {
      dependencies.writeStderr("error: failed to load transcriber: \(error)")
      return 1
    }

    // Optional diarizer (`[diarize].backend`). Loading it is best-effort and
    // never fatal: a diarization failure degrades to source-only labels rather
    // than failing the whole transcript (the ASR output is the load-bearing
    // artifact). A `nil` factory means diarization is off.
    var diarizer: (any Diarizer)?
    if let factory = dependencies.diarizerFactory {
      do {
        diarizer = try await measure(
          dependencies.spans, "diarizer_load", session: runIdentifier
        ) {
          let loaded = try factory()
          try loaded.load(dependencies.diarizerLoadOptions)
          return loaded
        }
      } catch {
        dependencies.log(
          "diarizer.load failed: \(error); continuing without diarization")
        diarizer = nil
      }
    }

    var transcriptions: [SourceTranscription] = []
    // Per-source speaker spans from the offline diarization pass, on the shared
    // (range-relative) timeline; empty when diarization is off or a source is
    // single-speaker.
    var diarization: [SourceID: [SpeakerSpan]] = [:]
    var speechSeconds: Double = 0
    // Per-source read outcome, for the segments=0 reason lines below.
    var readOutcomes: [ReadOutcome] = []

    for plan in plans {
      let sourceID = plan.sourceID
      // One read per interval: a paused span is simply never read, so it is
      // provably absent from the output, exactly like silence. A meeting
      // source with no resolved store (`reader == nil`) contributes nothing.
      var slices: [AudioSlice] = []
      var chunksInRange = 0
      var speechIntervals = 0
      if let reader = plan.reader {
        for range in intervalRanges {
          do {
            let report = try reader.read(source: sourceID, range: range)
            slices.append(contentsOf: report.slices)
            chunksInRange += report.chunksInRange
            speechIntervals += report.speechIntervals
            // A chunk that wouldn't open/decode (e.g. a Bluetooth-rate-switch
            // -poisoned m4a `ExtAudioFileOpenURL` refuses) is skipped by the
            // reader and reported here, per-chunk, so it degrades only its own
            // span — the run continues and the surrounding audio still
            // transcribes, instead of one opaque stderr line aborting six
            // meetings (all-ears issue #26).
            for unreadable in report.unreadableChunks {
              dependencies.log(
                "chunk.unreadable: source=\(sourceID.rawValue) file=\(unreadable.file) "
                  + "error=\(unreadable.error)")
            }
          } catch {
            dependencies.writeStderr(
              "error: failed to read audio for source '\(sourceID.rawValue)': \(error)")
            return 1
          }
        }
      }
      readOutcomes.append(
        ReadOutcome(
          sourceID: sourceID, storeExists: plan.reader != nil, chunks: chunksInRange,
          speech: speechIntervals, slices: slices.count))

      var segments: [Segment] = []
      let sliceAudioSeconds = slices.reduce(0.0) { $0 + $1.audio.duration }
      // `Transcriber.transcribe` is a plain synchronous, throwing call
      // (docs/specs/model-interface.md's base protocol). ParakeetTranscriber
      // bridges FluidAudio's async API with a blocking semaphore inside a
      // detached Task (see that type's doc comment for exactly when that
      // bridge is and isn't safe): it is safe here because `transcribe` is
      // a single-shot batch CLI process running one command to completion
      // on its own cooperative-thread-pool task, not a long-lived,
      // multi-actor runtime -- and this loop calls
      // `transcribe(_:context:)` sequentially, never from inside a
      // spawned concurrent `Task`, so the blocking wait here cannot starve
      // other in-flight work. If sources/slices are ever parallelised with
      // `withThrowingTaskGroup`, a blocking call from inside each spawned
      // Task would risk exhausting the limited cooperative thread pool and
      // should move to a genuinely async transcribe API or a dedicated
      // thread instead. The `measure` wrapper adds no concurrency: it awaits
      // the body inline on this same task.
      do {
        segments = try await measure(
          dependencies.spans, "asr", session: runIdentifier,
          audioSeconds: sliceAudioSeconds,
          fields: [
            LogField("source", .string(sourceID.rawValue)),
            LogField("slices", .int(slices.count)),
          ]
        ) {
          var shiftedSegments: [Segment] = []
          for slice in slices {
            // Segment.start/end are relative to the audio buffer a Transcriber
            // decoded (its own doc comment), i.e. relative to *this slice*'s
            // start -- not the overall requested range. Shifting by the
            // slice's own offset from the range start puts every source's
            // segments on one shared timeline before TranscriptAssembly merges
            // them, per docs/specs/transcribe.md's "merge sources on a shared
            // timeline" step.
            let sliceOffset = slice.range.start.interval(since: requestedRange.start)
            let sliceSegments = try transcriber.transcribe(
              slice.audio, context: transcribeContext)
            for segment in sliceSegments {
              shiftedSegments.append(shifted(segment, by: sliceOffset))
            }
          }
          return shiftedSegments
        }
      } catch {
        dependencies.writeStderr(
          "error: transcription failed for source '\(sourceID.rawValue)': \(error)")
        return 1
      }
      speechSeconds += sliceAudioSeconds

      transcriptions.append(SourceTranscription(sourceID: sourceID, segments: segments))

      // Diarization refines a *multi-speaker far-end* source into `Speaker N`;
      // it never runs on the mic (you) or an already-per-participant browser
      // stream (single speaker each). A failure here is logged and skipped, so
      // the source keeps its source-only label rather than failing the run.
      if let diarizer, shouldDiarize(sourceID), !slices.isEmpty {
        do {
          let spans = try await measure(
            dependencies.spans, "diarize", session: runIdentifier,
            audioSeconds: sliceAudioSeconds,
            fields: [LogField("source", .string(sourceID.rawValue))]
          ) {
            try diarizeSource(
              slices: slices, requestedStart: requestedRange.start, diarizer: diarizer)
          }
          if !spans.isEmpty { diarization[sourceID] = spans }
        } catch {
          dependencies.log(
            "diarize failed for source '\(sourceID.rawValue)': \(error)")
        }
      }
    }

    let generated = dependencies.clock.now()
    let modelInfo = TranscriptModelInfo(
      name: transcriber.info.name, backend: backendName, version: transcriber.info.version)

    // The meeting roster's name map (attendee source → display name) feeds
    // speaker labels, so real names flow into the transcript directly.
    var speakers: [String: String] = [:]
    if let meetingRecord {
      for attendee in meetingRecord.attendees {
        if let source = attendee.source, let name = attendee.displayName {
          speakers[source.rawValue] = name
        }
      }
    }

    // The chosen lookup order, recorded in frontmatter so a wrong-store read is
    // visible after the fact (issue #20). Only a `--meeting` run resolves a
    // per-source store; every other path reads one shared root and records
    // nothing here. A source with no store at all is recorded as `none`.
    let audioStores: [TranscriptAudioStore] =
      inputs.meeting == nil
      ? []
      : plans.map { TranscriptAudioStore(source: $0.sourceID, store: $0.store?.label ?? "none") }

    let document = TranscriptAssembly.assemble(
      sourceIDs: sourceIDs,
      transcriptions: transcriptions,
      requested: requestedRange,
      // A meeting transcript is keyed by `meeting:` alone; only a raw range
      // run still carries the synthesized `session:` identifier.
      session: meetingRecord == nil ? runIdentifier : nil,
      meeting: meetingRecord?.id,
      speakers: speakers,
      diarization: diarization,
      diarizationBackend: diarizer?.info.name,
      model: modelInfo,
      generated: generated,
      speechSeconds: speechSeconds,
      audioStores: audioStores
    )

    let paths = OutputPathResolution.resolve(
      outputRoot: outputRoot, requestedStart: requestedRange.start, sourceIDs: sourceIDs,
      explicitOut: inputs.out, slug: meetingRecord?.id)

    do {
      let markdown = TranscriptRenderer.renderMarkdown(document)
      try AtomicFileIO.writeAtomically(to: paths.markdown) { tempURL in
        try markdown.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
      let json = TranscriptRenderer.renderJSON(document)
      try AtomicFileIO.writeAtomically(to: paths.sidecar) { tempURL in
        try json.write(to: tempURL, atomically: false, encoding: String.Encoding.utf8)
      }
    } catch {
      dependencies.writeStderr("error: failed to write transcript: \(error)")
      return 1
    }

    // A run that produced no segments is only diagnosable if each source says
    // *why* it was silent — no chunks, chunks-but-silence, or store missing
    // (issue #20). Logged for every path, but it is a meeting spanning several
    // sources where a one-line-per-source breakdown matters most.
    if document.segments.count == 0 {
      for outcome in readOutcomes {
        // A source with `nil` reason did produce audio slices — the model just
        // returned no text for them; every other case names the missing input.
        let reason =
          MeetingAudioResolution.emptyReason(
            storeExists: outcome.storeExists, chunksInRange: outcome.chunks,
            speechIntervals: outcome.speech, sliceCount: outcome.slices)
          ?? "audio produced no segments"
        dependencies.log("run.empty: source=\(outcome.sourceID.rawValue) reason=\(reason)")
      }
    }

    // How many of the meeting's listed sources actually resolved to a store
    // versus had no data anywhere — so a "successful" empty run is honestly
    // distinguishable from silence (issue #21's "summary honesty":
    // sources-resolved / sources-missing counts). Every non-`--meeting` path
    // has already fail-fast-rejected unknown sources above, so all its sources
    // are resolved and `sources_missing` is 0.
    let sourcesResolved = readOutcomes.filter { $0.storeExists }.count
    let sourcesMissing = readOutcomes.count - sourcesResolved

    dependencies.log(
      "run.summary: segments=\(document.segments.count) words=\(document.frontmatter.wordCount) "
        + "sources_resolved=\(sourcesResolved) sources_missing=\(sourcesMissing) "
        + "speech_seconds=\(speechSeconds) duration_seconds=\(requestedRange.duration) "
        + "output=\(paths.markdown.path)"
    )
    dependencies.onSummary?([
      LogField("segments", .int(document.segments.count)),
      LogField("words", .int(document.frontmatter.wordCount)),
      LogField("sources", .int(sourceIDs.count)),
      LogField("sources_resolved", .int(sourcesResolved)),
      LogField("sources_missing", .int(sourcesMissing)),
      LogField("speech_seconds", .double(speechSeconds)),
      LogField("duration_seconds", .double(requestedRange.duration)),
      LogField("output", .string(paths.markdown.path)),
    ])

    return 0
  }

  /// Where one source's audio is read from for this run: the ``reader`` bound
  /// to the chosen data root (`nil` on a `--meeting` run when no store holds the
  /// source at all — it then contributes nothing), and, for a `--meeting` run,
  /// which ``MeetingAudioStore`` was chosen (`nil` for every other path).
  private struct SourceAudioPlan {
    let sourceID: SourceID
    let reader: SegmentedAudioReader?
    let store: MeetingAudioStore?
  }

  /// One source's read result, kept so a `segments=0` run can name why each
  /// source was silent (issue #20).
  private struct ReadOutcome {
    let sourceID: SourceID
    let storeExists: Bool
    let chunks: Int
    let speech: Int
    let slices: Int
  }

  /// Resolves each meeting source to a store, logging every consultation.
  ///
  /// For each source it probes both the per-meeting copy and the global ring
  /// (index-only, no decode), logs what each holds with its concrete path, then
  /// picks the store per ``MeetingAudioResolution/chooseStore(meeting:ring:)``
  /// — per-meeting chunks preferred, ring fallback. A source found in neither
  /// store gets a `nil` reader (it contributes nothing, with a logged reason at
  /// the end of the run) rather than failing the whole meeting.
  private static func planMeetingSources(
    sourceIDs: [SourceID], meetingID: String, dataRoot: URL, intervalRanges: [TimeRange],
    log: @Sendable (String) -> Void
  ) -> [SourceAudioPlan] {
    let meetingRoot = DataStoreLayout.meetingDirectory(dataRoot: dataRoot, meetingID: meetingID)
    let meetingReader = SegmentedAudioReader(dataRoot: meetingRoot)
    let ringReader = SegmentedAudioReader(dataRoot: dataRoot)

    return sourceIDs.map { sourceID in
      let meetingProbe = summedProbe(meetingReader, source: sourceID, ranges: intervalRanges)
      let ringProbe = summedProbe(ringReader, source: sourceID, ranges: intervalRanges)
      logConsultation(
        meeting: meetingID, source: sourceID, store: .meeting,
        path: meetingReader.sourceDirectory(for: sourceID).path, probe: meetingProbe, log: log)
      logConsultation(
        meeting: meetingID, source: sourceID, store: .ring,
        path: ringReader.sourceDirectory(for: sourceID).path, probe: ringProbe, log: log)

      let chosen = MeetingAudioResolution.chooseStore(meeting: meetingProbe, ring: ringProbe)
      switch chosen {
      case .some(.meeting):
        log("meeting \(meetingID) source \(sourceID.rawValue): reading from meeting store")
        return SourceAudioPlan(sourceID: sourceID, reader: meetingReader, store: .meeting)
      case .some(.ring):
        log("meeting \(meetingID) source \(sourceID.rawValue): reading from ring store")
        return SourceAudioPlan(sourceID: sourceID, reader: ringReader, store: .ring)
      case .none:
        log("meeting \(meetingID) source \(sourceID.rawValue): no audio store found")
        return SourceAudioPlan(sourceID: sourceID, reader: nil, store: nil)
      }
    }
  }

  /// A source's probe summed over every interval range the run reads (a paused
  /// meeting has several). `sourceExists` is range-independent, so the first
  /// probe's flag stands for the whole source.
  private static func summedProbe(
    _ reader: SegmentedAudioReader, source sourceID: SourceID, ranges: [TimeRange]
  ) -> SegmentedAudioReader.RangeProbe {
    var exists = false
    var chunks = 0
    var speech = 0
    for range in ranges {
      let probe = reader.probe(source: sourceID, range: range)
      exists = exists || probe.sourceExists
      chunks += probe.chunksInRange
      speech += probe.speechIntervals
    }
    return SegmentedAudioReader.RangeProbe(
      sourceExists: exists, chunksInRange: chunks, speechIntervals: speech)
  }

  private static func logConsultation(
    meeting meetingID: String, source sourceID: SourceID, store: MeetingAudioStore, path: String,
    probe: SegmentedAudioReader.RangeProbe, log: @Sendable (String) -> Void
  ) {
    let result =
      probe.sourceExists
      ? "chunks=\(probe.chunksInRange) speech_intervals=\(probe.speechIntervals)"
      : "no data (store missing)"
    log(
      "meeting \(meetingID) source \(sourceID.rawValue): consulted \(store.label) store at \(path) — \(result)"
    )
  }

  /// Run `body` as a measured stage when a ``StageSpans`` emitter is wired,
  /// otherwise call it directly. Keeping the optionality here rather than at
  /// each call site means instrumenting a stage costs one wrapper and never
  /// changes its control flow — a pipeline built without logging behaves
  /// exactly as it did before.
  private static func measure<T>(
    _ spans: StageSpans?,
    _ stage: String,
    session: String? = nil,
    audioSeconds: Double? = nil,
    fields: [LogField] = [],
    _ body: () async throws -> T
  ) async rethrows -> T {
    guard let spans else { return try await body() }
    return try await spans.measure(
      stage, session: session, audioSeconds: audioSeconds, fields: fields, body: body)
  }

  private static func shifted(_ segment: Segment, by offset: Double) -> Segment {
    var result = segment
    result.start += offset
    result.end += offset
    result.words = segment.words.map { word in
      var shiftedWord = word
      shiftedWord.start += offset
      shiftedWord.end += offset
      return shiftedWord
    }
    return result
  }

  /// Which sources the diarizer refines into `Speaker N`. Source-of-origin is
  /// the primary label, so single-speaker sources are left alone: the `mic`
  /// (you) and each per-participant `browser:*` stream (one named speaker each)
  /// are never diarized. Everything else — `system`, `app:*`, `device:*` — is a
  /// potentially multi-speaker far end worth splitting. (This coarse rule is a
  /// documented first cut; see `docs/plans/diarization-sortformer.md`.)
  static func shouldDiarize(_ sourceID: SourceID) -> Bool {
    let raw = sourceID.rawValue
    return raw != "mic" && !raw.hasPrefix("browser:")
  }

  /// Runs the offline diarization pass over one source and returns its speaker
  /// spans on the shared (range-relative) timeline.
  ///
  /// The reader hands back VAD-gated speech slices, not one contiguous buffer.
  /// Diarizing each slice independently would reset `Speaker N` per slice, so
  /// instead the slices are **concatenated** into one buffer (the diarizer sees
  /// only speech, which is what it wants) and diarized in a single call, keeping
  /// speaker identity stable across the whole source. Each returned span, in
  /// concatenated time, is then clipped back to the slice(s) it overlaps and
  /// translated to the slice's real offset from the requested range start — so a
  /// span that would straddle a removed silence gap is split at that gap, which
  /// is the correct behaviour (the gap was silence).
  static func diarizeSource(
    slices: [AudioSlice], requestedStart: Instant, diarizer: any Diarizer
  ) throws -> [SpeakerSpan] {
    struct Placement {
      let concatStart: Double
      let concatEnd: Double
      let realStart: Double
    }
    var samples: [Float] = []
    var placements: [Placement] = []
    var sampleRate = 16_000
    var cursor = 0.0
    for slice in slices {
      sampleRate = slice.audio.sampleRate
      let duration = slice.audio.duration
      placements.append(
        Placement(
          concatStart: cursor,
          concatEnd: cursor + duration,
          realStart: slice.range.start.interval(since: requestedStart)))
      samples.append(contentsOf: slice.audio.samples)
      cursor += duration
    }
    guard !samples.isEmpty else { return [] }

    let rawSpans = try diarizer.diarize(AudioBuffer(samples: samples, sampleRate: sampleRate))

    var spans: [SpeakerSpan] = []
    for span in rawSpans {
      for placement in placements {
        let start = max(span.start, placement.concatStart)
        let end = min(span.end, placement.concatEnd)
        guard end > start else { continue }
        spans.append(
          SpeakerSpan(
            start: placement.realStart + (start - placement.concatStart),
            end: placement.realStart + (end - placement.concatStart),
            speaker: span.speaker))
      }
    }
    return spans.sorted { $0.start < $1.start }
  }
}
