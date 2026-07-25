/// Built-in defaults and declared schema for `earsd`'s own config slice: the
/// `[earsd]` table, its nested `[earsd.vad]` table, and its `[[earsd.source]]`
/// array of tables. Values match the reference config in
/// `docs/configuration.md` exactly, except `[[earsd.source]]`'s default list:
/// the doc's `mic`/`system`/`app:us.zoom.xos` trio there is an *example*
/// config, not the zero-config default — per the "Conventions" section, "with
/// no file present, the daemon captures `mic` with the defaults", so the
/// built-in default source list is just that one enabled `mic` entry.
///
/// Like ``Phase0ConfigSchema``, this schema only declares its own slice
/// (`earsd`); the shared keys every tool needs (`data_root`, `output_root`,
/// `[log]`, ...) are Phase 0's concern. ``effectiveSchema``/``effectiveDefaults``
/// compose the two via ``ConfigSchema/union(_:)`` into what `earsd` actually
/// validates against, so a caller doesn't have to know how to combine them.
public enum EarsdConfigSchema {
  public static let defaults: ConfigValue = .table([
    "earsd": .table([
      "chunk_seconds": .int(30),
      "codec": .string("aac"),
      "bitrate": .int(64000),
      "native_sample_rate": .int(48000),
      "asr_sample_rate": .int(16000),
      "store_native": .bool(true),
      "channels": .int(1),
      "vad": .table([
        "backend": .string("silero"),
        "speech_pad_ms": .int(300),
        "min_silence_ms": .int(700),
      ]),
      "ingest_ws": .table([
        "enabled": .bool(false),
        "port": .int(47811),
        "allowed_origins": .array([]),
      ]),
      "control_ws": .table([
        "enabled": .bool(false),
        "port": .int(47812),
        "allowed_origins": .array([]),
      ]),
      "meetings": .table([
        "ingest_close_grace_s": .int(120),
        "local_sources": .array([.string("mic")]),
      ]),
      "retention": .table([
        "evict_after_transcript_seconds": .int(7200),
        "max_audio_age_seconds": .int(604800),
      ]),
      "source": .array([
        .table([
          "id": .string("mic"),
          "class": .string("mic"),
          "device_uid": .string(""),
        ])
      ]),
    ]),
    "triggers": .table([
      "enabled": .bool(false),
      "transcribe_on_browser_session_close": .bool(true),
      "rule": .array([]),
    ]),
  ])

  /// Schema for a single `[[earsd.source]]` element. Every field is optional
  /// per-element (a source may override only some of the capture defaults);
  /// this schema engine has no "required field" concept, so an element
  /// omitting a key is simply not checked for it, matching the doc's examples
  /// (e.g. the `mic` source sets no `label`, the `system` source sets no
  /// `device_uid`).
  private static let sourceElementSchema = ConfigSchema(
    fields: [
      "id": ConfigSchema.Field(type: .string, description: "Unique source id."),
      "class": ConfigSchema.Field(
        type: .string, description: "Source class: mic, system, app, or device."),
      "device_uid": ConfigSchema.Field(
        type: .string, description: "Core Audio device UID (device-class sources)."),
      "label": ConfigSchema.Field(type: .string, description: "Human-readable label."),
      "enabled": ConfigSchema.Field(type: .bool, description: "Whether this source is captured."),
    ]
  )

  /// Schema for a single `[[triggers.rule]]` element, per
  /// `docs/configuration.md`'s "Auto-triggers" example. `on`'s only
  /// documented value today is `"app-audio-active"`; left as a plain string
  /// (not an enum) since this schema engine has no closed-set-of-strings
  /// concept and a stricter check belongs at resolution time, matching how
  /// `class` is validated for `[[earsd.source]]`.
  private static let triggerRuleElementSchema = ConfigSchema(
    fields: [
      "name": ConfigSchema.Field(type: .string, description: "Rule name."),
      "on": ConfigSchema.Field(
        type: .string, description: "Trigger signal (e.g. \"app-audio-active\")."),
      // Array of scalars (bundle ids/app names) — left unvalidated
      // element-wise, matching `ingest_ws.allowed_origins`'s convention.
      "apps": ConfigSchema.Field(
        type: .array, description: "Bundle ids / app names this rule matches."),
      "open_session": ConfigSchema.Field(
        type: .bool, description: "Open a capture session when the rule fires."),
      "sources": ConfigSchema.Field(type: .array, description: "Sources to capture for this rule."),
      "on_close": ConfigSchema.Field(
        type: .array, description: "Stages to run when the rule's session closes."),
      // Session pre-roll: widen the transcribed range backward by this many
      // seconds of already-buffered ring audio when transcribing this
      // rule's sessions (see `TranscribeRangeResolution`'s pre-roll
      // widening). 0 (the default) means no widening.
      "pre_roll_seconds": ConfigSchema.Field(
        type: .int,
        description: "Seconds of already-buffered audio to include before the session opened."),
    ]
  )

  public static let schema = ConfigSchema(
    fields: [
      "earsd": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "chunk_seconds": ConfigSchema.Field(
              type: .int, description: "Length of each captured audio chunk, in seconds."),
            "codec": ConfigSchema.Field(
              type: .string, description: "Audio codec for stored chunks (e.g. \"aac\")."),
            "bitrate": ConfigSchema.Field(
              type: .int, description: "Encoder bitrate in bits per second."),
            "native_sample_rate": ConfigSchema.Field(
              type: .int, description: "Sample rate of the stored native-quality audio, in Hz."),
            "asr_sample_rate": ConfigSchema.Field(
              type: .int, description: "Sample rate of the ASR-facing downmix, in Hz."),
            "store_native": ConfigSchema.Field(
              type: .bool, description: "Keep the native-quality audio alongside the ASR downmix."),
            "channels": ConfigSchema.Field(
              type: .int, description: "Number of captured audio channels."),
            "vad": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "backend": ConfigSchema.Field(
                    type: .string, description: "Voice-activity-detection backend."),
                  "speech_pad_ms": ConfigSchema.Field(
                    type: .int, description: "Padding kept around detected speech, in milliseconds."
                  ),
                  "min_silence_ms": ConfigSchema.Field(
                    type: .int,
                    description: "Minimum silence to split speech segments, in milliseconds."),
                ]
              ),
              description: "Voice-activity detection (silence skipping)."),
            "ingest_ws": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "enabled": ConfigSchema.Field(
                    type: .bool, description: "Enable the browser-extension audio-ingest WebSocket."
                  ),
                  "port": ConfigSchema.Field(
                    type: .int, description: "Loopback port the ingest WebSocket listens on."),
                  // Array of scalars (origin strings) — left unvalidated
                  // element-wise per ConfigSchema.Field's documented
                  // elementSchema-nil convention.
                  "allowed_origins": ConfigSchema.Field(
                    type: .array,
                    description: "Fail-closed Origin allowlist for the ingest WebSocket."),
                ]
              ),
              description: "Browser-extension audio-ingest WebSocket."),
            // The loopback control-plane WebSocket — same shape and
            // fail-closed Origin allowlist as `ingest_ws`, distinct default
            // port. See `EarsIPC.ControlWebSocketServer`.
            "control_ws": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "enabled": ConfigSchema.Field(
                    type: .bool, description: "Enable the loopback control-plane WebSocket."),
                  "port": ConfigSchema.Field(
                    type: .int, description: "Loopback port the control WebSocket listens on."),
                  "allowed_origins": ConfigSchema.Field(
                    type: .array,
                    description: "Fail-closed Origin allowlist for the control WebSocket."),
                ]
              ),
              description: "Loopback control-plane WebSocket."),
            // Meeting lifecycle knobs: how long a browser meeting's last
            // ingest stream may stay closed before the daemon auto-ends the
            // meeting (`reason = "ingest-idle"`), and which locally-captured
            // sources (your own mic, system audio) the daemon folds into every
            // browser meeting so your side is transcribed alongside the
            // extension's per-participant streams. See `MeetingRegistry`.
            // `local_sources` is a plain string array (elementSchema-nil
            // convention, like `ingest_ws.allowed_origins`).
            "meetings": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "ingest_close_grace_s": ConfigSchema.Field(
                    type: .int,
                    description:
                      "Grace period before a browser meeting's idle ingest stream auto-ends it, in seconds."
                  ),
                  "local_sources": ConfigSchema.Field(
                    type: .array,
                    description: "Local sources folded into every browser meeting (e.g. your mic)."),
                ]
              ),
              description: "Meeting lifecycle knobs."),
            // Transcript-driven retention: evict a meeting's audio this many
            // seconds after its transcript completes successfully, or — for a
            // meeting whose transcript never completed — this many seconds
            // after it ended, whichever deadline comes first. Transcripts are
            // never evicted. See `EvictionSweeper`.
            "retention": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "evict_after_transcript_seconds": ConfigSchema.Field(
                    type: .int,
                    description:
                      "Evict a meeting's audio this many seconds after its transcript completes."
                  ),
                  "max_audio_age_seconds": ConfigSchema.Field(
                    type: .int,
                    description: "Hard cap on audio age before eviction, in seconds."),
                ]
              ),
              description: "Transcript-driven audio retention."),
            "source": ConfigSchema.Field(
              type: .array, elementSchema: sourceElementSchema,
              description: "Audio sources to capture (mic, system, app:*, device:*)."),
          ]
        ),
        description: "Capture daemon settings: audio format, VAD, sources, and networking."),
      "triggers": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "enabled": ConfigSchema.Field(
              type: .bool, description: "Enable app-signal auto-triggers."),
            // Run the transcribe stage automatically when a session opened by
            // the browser extension (`trigger = "browser-extension"`) closes
            // — the browser-side analogue of a rule's `on_close`, which only
            // fires on app-signal rule matches.
            "transcribe_on_browser_session_close": ConfigSchema.Field(
              type: .bool,
              description: "Auto-transcribe when a browser-extension session closes."),
            "rule": ConfigSchema.Field(
              type: .array, elementSchema: triggerRuleElementSchema,
              description: "App-signal trigger rules."),
          ]
        ),
        description: "Automatic capture/transcribe triggers driven by app signals."),
    ],
    passthroughKeys: [
      "schema",
      "transcribe",
      "diarize",
      "llm",
      "cleanup",
      "summarize",
      "vocab",
    ]
  )

  /// ``defaults`` merged with ``Phase0ConfigSchema/defaults``: the full set of
  /// built-in defaults an `earsd` caller needs, since `earsd` still reads
  /// `data_root`/`output_root`/`[log]` alongside its own `[earsd]` slice.
  public static let effectiveDefaults: ConfigValue = mergeConfigValues(
    base: Phase0ConfigSchema.defaults,
    overlay: defaults
  )

  /// ``schema`` composed with ``Phase0ConfigSchema/schema`` via
  /// ``ConfigSchema/union(_:)``: what `earsd` actually validates its merged
  /// config against.
  public static let effectiveSchema = Phase0ConfigSchema.schema.union(schema)
}
