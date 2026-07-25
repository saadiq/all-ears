import Testing

@testable import EarsCore

/// Covers `describeConfig`, the renderer behind `ears config describe`: a
/// schema + defaults projected into a human-readable settings reference.
@Suite("describeConfig")
struct DescribeConfigTests {
  @Test("a leaf renders its path, type, and default")
  func leafLine() {
    let schema = ConfigSchema(fields: ["data_root": ConfigSchema.Field(type: .string)])
    let output = describeConfig(schema: schema, defaults: .table(["data_root": .string("/x")]))
    #expect(output == "data_root : string = \"/x\"")
  }

  @Test("a declared description is shown indented beneath its key")
  func descriptionLine() {
    let schema = ConfigSchema(
      fields: [
        "channels": ConfigSchema.Field(type: .int, description: "Number of audio channels.")
      ])
    let output = describeConfig(schema: schema, defaults: .table(["channels": .int(1)]))
    #expect(output == "channels : int = 1\n    Number of audio channels.")
  }

  @Test("a nested table renders a [path] header then its dotted children")
  func nestedTable() {
    let schema = ConfigSchema(
      fields: [
        "log": ConfigSchema.Field(
          type: .table,
          children: ConfigSchema(fields: ["level": ConfigSchema.Field(type: .string)]))
      ])
    let output = describeConfig(
      schema: schema, defaults: .table(["log": .table(["level": .string("info")])]))
    #expect(output.contains("[log]"))
    #expect(output.contains("log.level : string = \"info\""))
  }

  @Test("an array-of-tables renders a [[path]] header and its element fields")
  func arrayOfTables() {
    let schema = ConfigSchema(
      fields: [
        "source": ConfigSchema.Field(
          type: .array,
          elementSchema: ConfigSchema(fields: ["id": ConfigSchema.Field(type: .string)]))
      ])
    let output = describeConfig(schema: schema, defaults: .table([:]))
    #expect(output.contains("[[source]]"))
    #expect(output.contains("source[].id : string"))
  }

  @Test("an empty-array default renders as [] so it's distinguishable")
  func emptyArrayDefault() {
    let schema = ConfigSchema(fields: ["origins": ConfigSchema.Field(type: .array)])
    let output = describeConfig(schema: schema, defaults: .table(["origins": .array([])]))
    #expect(output == "origins : array = []")
  }

  @Test("the full config schema lists keys from every tool's slice")
  func fullSchemaCoversEveryTool() {
    let output = describeConfig(
      schema: FullConfigSchema.schema, defaults: FullConfigSchema.defaults)
    #expect(output.contains("log.level"))  // Phase 0
    #expect(output.contains("[earsd]"))  // earsd
    #expect(output.contains("llm.model"))  // LLM stages
    #expect(output.contains("transcribe.backend : string = \"fluidaudio\""))  // transcribe
    #expect(output.contains("Speaker-diarization backend"))  // a declared description
  }
}
