import EarsCLISupport
import Foundation
import Testing

@testable import cleanup
@testable import summarize
@testable import transcribe

/// Golden fixtures for the `--json` result envelopes (issue #63), loaded from
/// `shared/stage-envelopes/` at the repo root — the same home pattern as
/// `shared/protocol-fixtures/control-v2.json`.
///
/// Two properties are pinned without any third-party JSON Schema validator:
///
/// 1. **Every example fixture decodes** into its tool's `Codable` envelope
///    struct and **re-encodes to the identical JSON object** (via
///    `StageEnvelopeJSON`, the production printer) — so a fixture key the
///    struct doesn't carry, or a struct key the fixture doesn't show, fails
///    loudly instead of drifting silently.
/// 2. **The `.schema.json` files stay structurally in step**: each parses as
///    JSON, and its `schema` const matches the struct's frozen `schemaID`.
@Suite("Stage envelope golden fixtures")
struct StageEnvelopeFixtureTests {
  /// `<repo>/shared/stage-envelopes`, resolved exactly the way
  /// `ControlProtocolV2FixtureTests` resolves its shared fixture directory.
  private static var fixturesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CLISmokeTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // daemon
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("shared/stage-envelopes")
  }

  /// Loads `<tool>.v1.examples.json` as named raw-JSON entries, re-serialized
  /// per entry so each can be decoded and compared independently.
  private static func loadExamples(_ tool: String) throws -> [String: Data] {
    let url = fixturesDirectory.appendingPathComponent("\(tool).v1.examples.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let entries = try #require(object as? [String: Any], "\(tool) examples must be an object")
    var result: [String: Data] = [:]
    for (name, value) in entries {
      result[name] = try JSONSerialization.data(withJSONObject: value)
    }
    return result
  }

  /// Decodes one fixture entry as `Envelope`, re-encodes it through the
  /// production printer, and requires JSON-object equality with the fixture.
  private static func roundTrip<Envelope: Codable>(
    _ raw: Data, as type: Envelope.Type, entry: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> Envelope {
    let envelope = try JSONDecoder().decode(Envelope.self, from: raw)
    let reencoded = try #require(
      StageEnvelopeJSON.encodeLine(envelope), "the production printer must encode '\(entry)'")
    let fixtureObject = try JSONSerialization.jsonObject(with: raw) as? NSDictionary
    let reencodedObject =
      try JSONSerialization.jsonObject(with: Data(reencoded.utf8)) as? NSDictionary
    #expect(
      reencodedObject == fixtureObject,
      "fixture '\(entry)' drifted from the envelope struct:\n\(reencoded)",
      sourceLocation: sourceLocation)
    return envelope
  }

  @Test("every transcribe example decodes and round-trips through the envelope struct")
  func transcribeExamples() throws {
    let examples = try Self.loadExamples("transcribe")
    #expect(Set(examples.keys) == ["success", "error"])
    for (name, raw) in examples {
      let envelope = try Self.roundTrip(
        raw, as: TranscribeResultEnvelope.self, entry: "transcribe/\(name)")
      #expect(envelope.schema == TranscribeResultEnvelope.schemaID)
      if name == "success" {
        #expect(envelope.ok)
        #expect(envelope.output != nil)
        #expect(envelope.outputs?.isEmpty == false)
        #expect(envelope.warnings != nil)
        #expect(envelope.stats != nil)
      } else {
        #expect(!envelope.ok)
        #expect(envelope.exitClass != nil)
        #expect(envelope.message != nil)
      }
    }
  }

  @Test("every cleanup example decodes and round-trips through the envelope struct")
  func cleanupExamples() throws {
    let examples = try Self.loadExamples("cleanup")
    #expect(Set(examples.keys) == ["success", "error"])
    for (name, raw) in examples {
      let envelope = try Self.roundTrip(
        raw, as: CleanupResultEnvelope.self, entry: "cleanup/\(name)")
      #expect(envelope.schema == CleanupResultEnvelope.schemaID)
      if name == "success" {
        #expect(envelope.ok)
        #expect(envelope.output != nil)
        #expect(envelope.outputs?.isEmpty == false)
        #expect(envelope.warnings != nil)
        #expect(envelope.stats != nil)
      } else {
        #expect(!envelope.ok)
        #expect(envelope.exitClass != nil)
        #expect(envelope.message != nil)
      }
    }
  }

  @Test("every summarize example decodes and round-trips through the envelope struct")
  func summarizeExamples() throws {
    let examples = try Self.loadExamples("summarize")
    #expect(Set(examples.keys) == ["success", "all_presets_success", "partial_failure_error"])
    for (name, raw) in examples {
      let envelope = try Self.roundTrip(
        raw, as: SummarizeResultEnvelope.self, entry: "summarize/\(name)")
      #expect(envelope.schema == SummarizeResultEnvelope.schemaID)
      switch name {
      case "success":
        #expect(envelope.ok)
        #expect(envelope.output != nil, "single-preset success carries output")
        #expect(envelope.outputs?.count == 1)
      case "all_presets_success":
        #expect(envelope.ok)
        #expect(envelope.output == nil, "multi-preset success has no single primary artifact")
        #expect(envelope.outputs?.allSatisfy(\.ok) == true)
      case "partial_failure_error":
        #expect(!envelope.ok)
        #expect(envelope.exitClass != nil)
        #expect(envelope.message != nil)
        let outputs = try #require(envelope.outputs)
        #expect(outputs.contains { !$0.ok }, "a partial failure names the failed preset")
        #expect(outputs.contains { $0.ok && $0.path != nil }, "and the presets that still wrote")
      default:
        Issue.record("unknown summarize fixture '\(name)' — add assertions for it")
      }
    }
  }

  @Test(
    "each schema file parses and its schema const matches the struct's frozen schemaID",
    arguments: [
      ("transcribe", TranscribeResultEnvelope.schemaID),
      ("cleanup", CleanupResultEnvelope.schemaID),
      ("summarize", SummarizeResultEnvelope.schemaID),
    ])
  func schemaFilesMatchStructs(tool: String, schemaID: String) throws {
    let url = Self.fixturesDirectory.appendingPathComponent("\(tool).v1.schema.json")
    let raw = try Data(contentsOf: url)
    let schema = try #require(
      try JSONSerialization.jsonObject(with: raw) as? [String: Any],
      "\(tool).v1.schema.json must be a JSON object")
    #expect((schema["$id"] as? String)?.contains("\(tool).v1.schema.json") == true)
    let variants = try #require(schema["oneOf"] as? [[String: Any]])
    #expect(variants.count == 2, "one success variant, one error variant")
    for variant in variants {
      let properties = try #require(variant["properties"] as? [String: Any])
      let schemaProperty = try #require(properties["schema"] as? [String: Any])
      #expect(
        schemaProperty["const"] as? String == schemaID,
        "\(tool)'s schema const must match the struct's frozen schemaID")
    }
  }
}
