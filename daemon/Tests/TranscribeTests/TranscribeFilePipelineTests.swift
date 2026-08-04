import EarsCore
import EarsCoreTestSupport
import EarsDataStore
import Foundation
import Testing

@testable import transcribe

/// Wiring coverage of ``TranscribeFilePipeline``: an injected
/// ``FileAudioReader`` (fake decoder) and ``ScriptedTranscriber`` stand in for
/// a real audio file and ASR backend, so the file-input path is proven -- each
/// file transcribed independently, transcript written beside the input (or to
/// `--out`), and the same precise-error discipline the capture-store pipeline
/// uses -- with no FluidAudio model or real audio needed.
@Suite("TranscribeFilePipeline")
struct TranscribeFilePipelineTests {
  private let now = Instant(secondsSinceEpoch: 2_000_000_000)

  private func makeTempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TranscribeFilePipelineTests-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A ``FileAudioReader`` whose fake decoder returns one second of already-16k
  /// audio for any path, so `slices` yields exactly one whole-file slice.
  private func fakeReader() -> FileAudioReader {
    FileAudioReader(decode: { _ in
      AudioBuffer(samples: [Float](repeating: 0.1, count: 16000), sampleRate: 16000)
    })
  }

  private func dependencies(
    _ transcriber: any Transcriber,
    writeStderr: @escaping @Sendable (String) -> Void = { line in
      Issue.record("unexpected stderr: \(line)")
    }
  ) -> TranscribePipeline.Dependencies {
    .init(
      clock: ManualClock(now),
      transcriberFactory: { transcriber },
      loadOptions: LoadOptions(),
      log: { _ in },
      writeStderr: writeStderr)
  }

  @Test("a single file is transcribed to <name>.transcript.md beside the input")
  func singleFileWritesTranscriptBesideInput() async throws {
    let directory = makeTempDirectory("single")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("session.m4a")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data())

    let scripted = ScriptedTranscriber(results: [[Segment(start: 0, end: 1, text: "hello world")]])
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [fileURL.path], out: nil),
      backendName: "fluidaudio",
      dependencies: dependencies(scripted),
      fileReader: fakeReader())

    #expect(exitCode == 0)
    let markdownURL = directory.appendingPathComponent("session.transcript.md")
    let sidecarURL = directory.appendingPathComponent("session.transcript.json")
    #expect(FileManager.default.fileExists(atPath: markdownURL.path))
    #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    #expect(markdown.contains("hello world"))
    // The source id / range-run is derived from the file's base name.
    #expect(markdown.contains("session"))
  }

  @Test("--out overrides the output path for a single file")
  func outOverridesPath() async throws {
    let directory = makeTempDirectory("out")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("clip.m4a")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    let outURL = directory.appendingPathComponent("custom.md")

    let scripted = ScriptedTranscriber(results: [[Segment(start: 0, end: 1, text: "hi")]])
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [fileURL.path], out: outURL.path),
      backendName: "fluidaudio",
      dependencies: dependencies(scripted),
      fileReader: fakeReader())

    #expect(exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: outURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("custom.json").path))
  }

  @Test("each of two files is transcribed independently into its own transcript")
  func twoFilesEachGetOwnTranscript() async throws {
    let directory = makeTempDirectory("two")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("a.m4a")
    let second = directory.appendingPathComponent("b.m4a")
    FileManager.default.createFile(atPath: first.path, contents: Data())
    FileManager.default.createFile(atPath: second.path, contents: Data())

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 1, text: "first file")],
      [Segment(start: 0, end: 1, text: "second file")],
    ])
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [first.path, second.path], out: nil),
      backendName: "fluidaudio",
      dependencies: dependencies(scripted),
      fileReader: fakeReader())

    #expect(exitCode == 0)
    let firstMarkdown = try String(
      contentsOf: directory.appendingPathComponent("a.transcript.md"), encoding: .utf8)
    let secondMarkdown = try String(
      contentsOf: directory.appendingPathComponent("b.transcript.md"), encoding: .utf8)
    #expect(firstMarkdown.contains("first file"))
    #expect(secondMarkdown.contains("second file"))
    // Independence: the first file's text never leaks into the second's transcript.
    #expect(!secondMarkdown.contains("first file"))
  }

  @Test("onSummary carries the totals and every transcript's real output path")
  func summaryCarriesTotalsAndOutputPaths() async throws {
    let directory = makeTempDirectory("summary")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("a.m4a")
    let second = directory.appendingPathComponent("b.m4a")
    FileManager.default.createFile(atPath: first.path, contents: Data())
    FileManager.default.createFile(atPath: second.path, contents: Data())

    let scripted = ScriptedTranscriber(results: [
      [Segment(start: 0, end: 1, text: "one two")],
      [Segment(start: 0, end: 1, text: "three")],
    ])
    let summaries = FieldsMailbox()
    var deps = dependencies(scripted)
    deps.onSummary = { summaries.append($0) }

    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [first.path, second.path], out: nil),
      backendName: "fluidaudio",
      dependencies: deps,
      fileReader: fakeReader())

    #expect(exitCode == 0)
    // One summary for the whole run, after every file transcribed.
    #expect(summaries.all.count == 1)
    let fields = try #require(summaries.all.first)
    #expect(fields.contains(LogField("files", .int(2))))
    #expect(fields.contains(LogField("segments", .int(2))))
    #expect(fields.contains(LogField("words", .int(3))))
    // `output` names where the transcripts actually landed — beside their
    // inputs, since `--file` never writes into `output_root`.
    let output = fields.first { $0.key == "output" }
    let expected =
      directory.appendingPathComponent("a.transcript.md").path + ", "
      + directory.appendingPathComponent("b.transcript.md").path
    #expect(output?.value == .string(expected))
  }

  @Test("--out with more than one file is a precise, non-zero error")
  func outWithMultipleFilesIsError() async throws {
    let directory = makeTempDirectory("out-multi")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("a.m4a")
    let second = directory.appendingPathComponent("b.m4a")
    FileManager.default.createFile(atPath: first.path, contents: Data())
    FileManager.default.createFile(atPath: second.path, contents: Data())

    let messages = Mailbox()
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(
        files: [first.path, second.path], out: directory.appendingPathComponent("x.md").path),
      backendName: "fluidaudio",
      dependencies: dependencies(NullTranscriber(), writeStderr: { messages.append($0) }),
      fileReader: fakeReader())

    #expect(exitCode == 64)
    #expect(messages.all.contains { $0.contains("--out cannot be combined with multiple") })
  }

  @Test("a missing file is a precise, non-zero error before any model load")
  func missingFileIsError() async throws {
    let messages = Mailbox()
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: ["/no/such/file.m4a"], out: nil),
      backendName: "fluidaudio",
      dependencies: dependencies(NullTranscriber(), writeStderr: { messages.append($0) }),
      fileReader: fakeReader())

    #expect(exitCode == 3)
    #expect(messages.all.contains { $0.contains("no such file") })
  }

  @Test("a configured diarizer refines the file's turns into <source> · Speaker N")
  func fileDiarizationRefinesLabels() async throws {
    let directory = makeTempDirectory("diarize")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("session.m4a")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data())

    // One whole-file slice of 1s (fakeReader); the ASR yields one turn over it,
    // and the diarizer attributes that second to Speaker 1.
    let scripted = ScriptedTranscriber(results: [[Segment(start: 0, end: 1, text: "hello world")]])
    let stub = StubFileDiarizer(spans: [SpeakerSpan(start: 0, end: 1, speaker: "Speaker 1")])
    var deps = dependencies(scripted)
    deps.diarizerFactory = { @Sendable in stub }

    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [fileURL.path], out: nil),
      backendName: "fluidaudio",
      dependencies: deps,
      fileReader: fakeReader())

    #expect(exitCode == 0)
    let markdown = try String(
      contentsOf: directory.appendingPathComponent("session.transcript.md"), encoding: .utf8)
    // Source attribution stays primary; the diarizer only adds the sub-label.
    #expect(markdown.contains("session · Speaker 1"))
    // The Markdown frontmatter records the diarization backend that ran
    // (`diarization: { enabled: true, backend: stub-diarizer }`).
    #expect(markdown.contains("stub-diarizer"))
  }

  @Test("with no diarizer configured, file labels are unchanged (source only)")
  func fileWithoutDiarizerKeepsSourceLabel() async throws {
    let directory = makeTempDirectory("no-diarize")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("memo.m4a")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data())

    let scripted = ScriptedTranscriber(results: [[Segment(start: 0, end: 1, text: "hello")]])
    let exitCode = await TranscribeFilePipeline.run(
      inputs: .init(files: [fileURL.path], out: nil),
      backendName: "fluidaudio",
      dependencies: dependencies(scripted),
      fileReader: fakeReader())

    #expect(exitCode == 0)
    let markdown = try String(
      contentsOf: directory.appendingPathComponent("memo.transcript.md"), encoding: .utf8)
    #expect(!markdown.contains("Speaker"))
  }
}

/// A ``Diarizer`` returning fixed spans, so the file pipeline's diarization
/// wiring is proven without a real model.
private struct StubFileDiarizer: Diarizer {
  let info = DiarizerInfo(name: "stub-diarizer", version: "0")
  let spans: [SpeakerSpan]
  func load(_ options: LoadOptions) throws {}
  func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan] { spans }
}

/// Like ``Mailbox``, but collecting the `onSummary` field batches.
private final class FieldsMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var batches: [[LogField]] = []
  func append(_ fields: [LogField]) {
    lock.lock()
    defer { lock.unlock() }
    batches.append(fields)
  }
  var all: [[LogField]] {
    lock.lock()
    defer { lock.unlock() }
    return batches
  }
}

/// A tiny `Sendable` collector for stderr lines a test wants to assert on
/// (rather than fail on, as the default `dependencies` writeStderr does).
private final class Mailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    lines.append(line)
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}
