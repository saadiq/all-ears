/// Built-in defaults and declared schema for the config keys Phase 0 needs:
/// the shared paths (`data_root`, `output_root`, `socket_path`) and the `[log]`
/// table. Values match the reference config in `docs/configuration.md` exactly.
///
/// Every other top-level table in that reference config — `[earsd]`,
/// `[transcribe]`, `[llm]`, `[cleanup]`, `[[summarize.preset]]`,
/// `[vocab]`, `[[earsd.source]]` — plus the top-level `schema` version key, is
/// deliberately out of scope: later phases declare their own ``ConfigSchema``
/// slice when they implement that subsystem. Until then, ``validateConfig(_:against:)``
/// passes those keys through the merged tree untouched rather than rejecting
/// them as unknown. `[triggers]` is deliberately NOT passed through: the
/// app-signal trigger path was deleted (#42), so a leftover `[triggers]`
/// table is rejected as unknown rather than silently ignored.
public enum Phase0ConfigSchema {
  public static let defaults: ConfigValue = .table([
    "data_root": .string("~/Library/Application Support/ears"),
    "output_root": .string("~/Documents/Transcripts"),
    "socket_path": .string(""),
    "log": .table([
      "level": .string("info"),
      "file": .string(""),
      "format": .string("auto"),
      "oslog": .bool(true),
      "subsystem": .string("net.tomelliot.ears"),
      "rotate_max_bytes": .int(52_428_800),
      "rotate_max_files": .int(5),
    ]),
  ])

  public static let schema = ConfigSchema(
    fields: [
      "data_root": ConfigSchema.Field(
        type: .string,
        description: "Root directory for captured audio, indexes, and session state."),
      "output_root": ConfigSchema.Field(
        type: .string, description: "Directory where transcripts and summaries are written."),
      "socket_path": ConfigSchema.Field(
        type: .string,
        description: "Control-socket path; empty derives <data_root>/runtime/earsd.sock."),
      "log": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "level": ConfigSchema.Field(
              type: .string, description: "Effective log level: debug, info, notice, or error."),
            "file": ConfigSchema.Field(
              type: .string,
              description:
                "JSON Lines log file path; empty derives a per-tool path under data_root."
            ),
            "format": ConfigSchema.Field(
              type: .string, description: "Log format: \"auto\", \"json\", or \"text\"."),
            "oslog": ConfigSchema.Field(
              type: .bool, description: "Mirror logs to the unified logging system (os_log)."),
            "subsystem": ConfigSchema.Field(
              type: .string, description: "Unified-logging subsystem identifier."),
            "rotate_max_bytes": ConfigSchema.Field(
              type: .int, description: "Rotate the log file once it exceeds this many bytes."),
            "rotate_max_files": ConfigSchema.Field(
              type: .int, description: "Number of rotated log files to keep."),
          ]
        ),
        description: "Logging destinations, level, and rotation. See docs/logging.md."),
    ],
    passthroughKeys: [
      "schema",
      "earsd",
      "transcribe",
      "diarize",
      "llm",
      "cleanup",
      "summarize",
      "vocab",
    ]
  )
}
