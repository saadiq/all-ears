import Foundation
import Testing

@testable import EarsDaemonKit

/// Unit coverage for the daemon's `--json` result-envelope decode (issue #64)
/// — the consumer half of the stage contract frozen in
/// `shared/stage-envelopes/<tool>.v1.schema.json`, exercised against the
/// recorded fixtures in `StageEnvelopeFixtures`.
@Suite("StageResultEnvelope")
struct StageResultEnvelopeTests {
  // MARK: - success documents

  @Test("a recorded v1 success document decodes; output and schema surface")
  func successDocumentDecodes() throws {
    let envelope = try StageResultEnvelope.decodeSuccessDocument(
      stdout: StageEnvelopeFixtures.transcribeSuccess(output: "/out/t.transcript.md"),
      tool: "transcribe"
    ).get()
    #expect(envelope.ok)
    #expect(envelope.schema == "allears.transcribe/v1")
    #expect(envelope.output == "/out/t.transcript.md")
    // transcribe's `outputs` are plain path strings — not the preset form.
    #expect(envelope.presetOutputs == nil)
  }

  @Test("unknown extra keys — a newer v1 minor — decode fine, by Codable construction")
  func unknownExtraKeysDecode() throws {
    let envelope = try StageResultEnvelope.decodeSuccessDocument(
      stdout: StageEnvelopeFixtures.transcribeSuccessWithUnknownKeys(
        output: "/out/t.transcript.md"),
      tool: "transcribe"
    ).get()
    #expect(envelope.output == "/out/t.transcript.md")
  }

  @Test("summarize's success document decodes its per-preset outputs")
  func summarizePresetOutputsDecode() throws {
    let envelope = try StageResultEnvelope.decodeSuccessDocument(
      stdout: StageEnvelopeFixtures.summarizeAllPresetsSuccess(
        presets: [(preset: "brief", path: "/out/t.brief.summary.md")]),
      tool: "summarize"
    ).get()
    let presets = try #require(envelope.presetOutputs)
    #expect(presets.map(\.preset) == ["brief"])
    #expect(presets.allSatisfy { $0.ok })
  }

  // MARK: - violations

  @Test("a wrong major is refused, naming both the expected and the received schema")
  func wrongMajorRefused() {
    let result = StageResultEnvelope.decodeSuccessDocument(
      stdout: StageEnvelopeFixtures.transcribeWrongMajor(output: "/out/t.transcript.md"),
      tool: "transcribe")
    guard case .failure(let violation) = result else {
      Issue.record("expected a schema-mismatch violation, got \(result)")
      return
    }
    #expect(violation.message.contains("expected allears.transcribe/v1"))
    #expect(violation.message.contains("got allears.transcribe/v2"))
  }

  @Test("another tool's v1 envelope is a schema mismatch too")
  func wrongToolRefused() {
    let result = StageResultEnvelope.decodeSuccessDocument(
      stdout: StageEnvelopeFixtures.cleanupSuccess(output: "/out/t.clean.md"),
      tool: "transcribe")
    guard case .failure(let violation) = result else {
      Issue.record("expected a schema-mismatch violation, got \(result)")
      return
    }
    #expect(violation.message.contains("expected allears.transcribe/v1"))
    #expect(violation.message.contains("got allears.cleanup/v1"))
  }

  @Test("non-JSON stdout is a violation quoting the bounded pollution; empty stdout says so")
  func nonJSONStdoutViolations() {
    for polluted in [
      "/out/t.transcript.md\n",  // the retired bare-path line
      "notice\n" + StageEnvelopeFixtures.transcribeSuccess(output: "/out/t.md"),
    ] {
      let result = StageResultEnvelope.decodeSuccessDocument(stdout: polluted, tool: "transcribe")
      guard case .failure(let violation) = result else {
        Issue.record("expected a violation for \(polluted.debugDescription), got \(result)")
        continue
      }
      #expect(violation.message.contains("stdout is not one JSON envelope document"))
      #expect(violation.message.contains("stdout: "))
    }
    let empty = StageResultEnvelope.decodeSuccessDocument(stdout: "  \n", tool: "transcribe")
    if case .failure(let violation) = empty {
      #expect(violation.message.contains("no stdout captured"))
    } else {
      Issue.record("expected a violation for empty stdout, got \(empty)")
    }
  }

  @Test("ok=false in a success-position document is a violation carrying the stage's message")
  func okFalseIsViolation() {
    let result = StageResultEnvelope.decodeSuccessDocument(
      stdout: StageEnvelopeFixtures.transcribeError(
        exitClass: "stage-failed", message: "error: output write failed") + "\n",
      tool: "transcribe")
    guard case .failure(let violation) = result else {
      Issue.record("expected an ok=false violation, got \(result)")
      return
    }
    #expect(violation.message.contains("ok=false despite exit 0"))
    #expect(violation.message.contains("error: output write failed"))
  }

  // MARK: - error envelopes

  @Test("the last stderr line decodes as the error envelope, ignoring noise above it")
  func errorEnvelopeFromLastStderrLine() throws {
    let stderr =
      "transcribe: loading model\nwarning: slow disk\n"
      + StageEnvelopeFixtures.transcribeError(
        exitClass: "input-missing", message: "error: unknown session 'nope'")
    let envelope = try #require(StageResultEnvelope.decodeErrorEnvelope(stderr: stderr))
    #expect(envelope.exitClass == "input-missing")
    #expect(envelope.message == "error: unknown session 'nope'")
  }

  @Test("summarize's error envelope keeps per-preset outputs — partial success is expressible")
  func errorEnvelopeCarriesPresetOutputs() throws {
    let stderr = StageEnvelopeFixtures.summarizePartialFailureError(
      briefPath: "/out/t.brief.summary.md", decisionsPath: "/out/t.decisions.summary.md")
    let envelope = try #require(StageResultEnvelope.decodeErrorEnvelope(stderr: stderr))
    let presets = try #require(envelope.presetOutputs)
    #expect(presets.map(\.preset) == ["brief", "actions", "decisions"])
    #expect(presets.filter(\.ok).count == 2)
  }

  @Test("plain stderr with no envelope line decodes to nil — augmentation stays best-effort")
  func plainStderrDecodesToNil() {
    #expect(StageResultEnvelope.decodeErrorEnvelope(stderr: "error: kaboom\n") == nil)
    #expect(StageResultEnvelope.decodeErrorEnvelope(stderr: "") == nil)
    // A success document on stderr is not an *error* envelope.
    #expect(
      StageResultEnvelope.decodeErrorEnvelope(
        stderr: StageEnvelopeFixtures.transcribeSuccess(output: "/out/t.md")) == nil)
  }
}
