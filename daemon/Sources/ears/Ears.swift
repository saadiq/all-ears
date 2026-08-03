import ArgumentParser
import EarsCLISupport
import EarsCore
import EarsDataStore
import EarsIPC
import Foundation

/// Control client for `earsd`: source status, meeting lifecycle, and the
/// live event feed, over the v2 control socket. See
/// `docs/specs/control-protocol.md`.
///
/// The root is a pure dispatcher — it declares no flags of its own, so no
/// root option can collide with a subcommand's. Phase 0's day-one
/// config-discovery contract lives on the `config` subcommand. Each real
/// subcommand below is a thin `ClientOptions`-driven wrapper around
/// ``ControlClientRuntime``/``OutputFormatting``, so none of them duplicate
/// socket-connection or output-formatting logic.
@main
struct Ears: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ears",
    abstract: "Control client for the earsd capture daemon.",
    subcommands: [
      ConfigCommand.self, StatusCommand.self, SourcesCommand.self, CaptureCommand.self,
      MeetingCommand.self, WatchCommand.self,
      FlushCommand.self,
    ]
  )
}

/// The one declaration site for `--config` in this tool. Every subcommand
/// that needs it composes this via `@OptionGroup` — directly, or through
/// ``ClientOptions`` — so the flag is never redeclared with the same
/// string in two places.
struct ConfigOptions: ParsableArguments {
  @Option(name: .customLong("config"), help: "Path to a TOML config file.")
  var config: String?
}

/// Options every daemon-facing subcommand shares: which config to resolve
/// the socket path from (via ``ConfigOptions``), whether to emit raw JSON
/// instead of a human-readable summary, and whether to trace the
/// client↔daemon exchange.
struct ClientOptions: ParsableArguments {
  @OptionGroup var configOptions: ConfigOptions

  @Flag(name: .customLong("json"), help: "Emit raw JSON instead of human-readable output.")
  var json = false

  @Flag(
    name: [.customShort("v"), .customLong("verbose")],
    help: "Trace socket resolution, requests, and replies to stderr (see DebugLog).")
  var verbose = false

  var config: String? { configOptions.config }

  /// The subcommand's ``DebugLog``, built from `--verbose`.
  var debug: DebugLog { DebugLog(enabled: verbose) }
}

/// The connect → send → emit sequence every simple request/response
/// subcommand shares.
private func runSimpleCommand<Payload: Codable & Sendable & Hashable>(
  _ call: ControlCall,
  expecting: Payload.Type,
  options: ClientOptions,
  humanSuccess: (Payload) -> String
) async throws {
  let debug = options.debug
  guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
  else {
    throw ExitCode(1)
  }
  let result = try await ControlClientRuntime.send(
    call, expecting: Payload.self, via: client, debug: debug)
  await client.close()
  let code = OutputFormatting.emit(result, json: options.json, humanSuccess: humanSuccess)
  if code != 0 { throw ExitCode(code) }
}

// MARK: - config show / path

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Inspect config discovery and the resolved, merged config.",
    subcommands: [ConfigShowCommand.self, ConfigPathCommand.self, ConfigDescribeCommand.self]
  )
}

struct ConfigDescribeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "describe",
    abstract:
      "List every config setting across all tools with its type, default, and description.")

  func run() async throws {
    // A static reference rendered from the schema itself — every tool's slice
    // composed into one listing — so a user can discover which keys exist,
    // what they mean, and their defaults without reading the source or the
    // docs. The current resolved value of each key is `ears config show`'s job;
    // this answers "what can I set, and to what?", including via `--set`.
    print(describeConfig(schema: FullConfigSchema.schema, defaults: FullConfigSchema.defaults))
  }
}

struct ConfigShowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Print the resolved, merged config as TOML.")

  @OptionGroup var options: ConfigOptions

  @Option(
    name: .customLong("log-level"),
    help: "Override the effective log level (debug|info|notice|error).")
  var logLevel: String?

  @Option(name: .customLong("log-file"), help: "Override the JSON Lines log file path.")
  var logFile: String?

  func run() async throws {
    let exitCode = await EarsCLI.run(
      tool: "ears",
      version: "0.1.0",
      arguments: EarsCLI.Arguments(
        config: options.config,
        printConfig: true,
        logLevel: logLevel,
        logFile: logFile
      )
    )
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

struct ConfigPathCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path",
    abstract: "Print which config file would be loaded (or that none was found).")

  @OptionGroup var options: ConfigOptions

  func run() async throws {
    let exitCode = await EarsCLI.run(
      tool: "ears",
      version: "0.1.0",
      arguments: EarsCLI.Arguments(config: options.config, configPath: true)
    )
    guard exitCode == 0 else { throw ExitCode(exitCode) }
  }
}

// MARK: - status

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Daemon + per-source state, buffer occupancy, active meetings.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await runSimpleCommand(
      .status, expecting: StatusData.self, options: options,
      humanSuccess: OutputFormatting.humanStatus)
  }
}

// MARK: - sources list / enable / disable

struct SourcesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sources",
    subcommands: [
      SourcesListCommand.self, SourcesAddCommand.self, SourcesRemoveCommand.self,
      SourcesEnableCommand.self, SourcesDisableCommand.self,
    ]
  )
}

struct SourcesListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "All configured sources and state.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await runSimpleCommand(
      .sourcesList, expecting: SourcesListData.self, options: options,
      humanSuccess: OutputFormatting.humanSourcesList)
  }
}

struct SourcesAddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract:
      "Add a source at runtime (currently rejected: Phase 4 seam, see docs/specs/capture-daemon.md)."
  )

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. app:us.zoom.xos.") var source: String

  @Option(name: .customLong("class"), help: "Source class: mic|system|app|browser|device.")
  var sourceClass: String

  @Option(name: .customLong("label"), help: "Human-readable label.") var label: String?
  @Option(name: .customLong("device-uid"), help: "Core Audio device UID.") var deviceUID: String?
  @Option(name: .customLong("native-sample-rate"), help: "Native capture sample rate, in Hz.")
  var nativeSampleRate: Int?
  @Option(name: .customLong("asr-sample-rate"), help: "ASR-rate sample rate, in Hz.")
  var asrSampleRate: Int?
  @Flag(name: .customLong("store-native"), help: "Also store the native-rate chunk stream.")
  var storeNative = false
  @Option(name: .customLong("channels"), help: "Channel count.") var channels: Int?
  @Option(name: .customLong("codec"), help: "Chunk codec, e.g. aac.") var codec: String?
  @Option(name: .customLong("bitrate"), help: "Chunk encoder bitrate.") var bitrate: Int?

  func run() async throws {
    guard let sourceClass = SourceClass(rawValue: sourceClass) else {
      ControlClientRuntime.writeStderr(
        "error: '\(sourceClass)' is not a recognised source class "
          + "(expected one of: \(SourceClass.allCases.map(\.rawValue).joined(separator: ", ")))")
      throw ExitCode(1)
    }
    let spec = SourceSpec(
      id: SourceID(source),
      sourceClass: sourceClass,
      label: label,
      deviceUID: deviceUID,
      nativeSampleRate: nativeSampleRate,
      asrSampleRate: asrSampleRate,
      storeNative: storeNative ? true : nil,
      channels: channels,
      codec: codec,
      bitrate: bitrate
    )
    try await runSimpleCommand(
      .sourcesAdd(spec), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct SourcesRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove", abstract: "Remove a source at runtime.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    try await runSimpleCommand(
      .sourcesRemove(source: SourceID(source)), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct SourcesEnableCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enable", abstract: "Start capturing a source.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    try await runSimpleCommand(
      .sourcesEnable(source: SourceID(source)), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct SourcesDisableCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disable", abstract: "Stop capturing a source.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic.") var source: String

  func run() async throws {
    try await runSimpleCommand(
      .sourcesDisable(source: SourceID(source)), expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}

// MARK: - capture pause / resume

struct CaptureCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    subcommands: [CapturePauseCommand.self, CaptureResumeCommand.self]
  )
}

struct CapturePauseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pause",
    abstract: "Pause a source, or every source when omitted (records a gap).")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic. Omit to pause every source.") var source: String?

  func run() async throws {
    try await runSimpleCommand(
      .capturePause(source: source.map { SourceID($0) }), expecting: EmptyData.self,
      options: options, humanSuccess: OutputFormatting.humanEmpty)
  }
}

struct CaptureResumeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume", abstract: "Resume a source, or every source when omitted.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Source id, e.g. mic. Omit to resume every source.") var source: String?

  func run() async throws {
    try await runSimpleCommand(
      .captureResume(source: source.map { SourceID($0) }), expecting: EmptyData.self,
      options: options, humanSuccess: OutputFormatting.humanEmpty)
  }
}

// MARK: - meeting start / end / pause / resume / rename / list

/// The daemon-owned meeting lifecycle, from any frontend — manual meetings
/// give CLI recordings the same naming, pause-as-marks, and roster powers as
/// browser calls (`docs/specs/control-protocol.md`'s "Meeting").
struct MeetingCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "meeting",
    abstract: "Daemon-owned meeting lifecycle: start, end, pause/resume marks, rename, list.",
    subcommands: [
      MeetingStartCommand.self, MeetingEndCommand.self, MeetingPauseCommand.self,
      MeetingResumeCommand.self, MeetingRenameCommand.self, MeetingListCommand.self,
    ]
  )
}

struct MeetingStartCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start",
    abstract: "Start a meeting (manual unless --platform/--external-id name an identity).")

  @OptionGroup var options: ClientOptions
  @Option(name: .customLong("title"), help: "Meeting title.") var title: String?
  @Option(name: .customLong("source"), help: "Source id; repeatable.") var sources: [String] = []
  @Option(name: .customLong("platform"), help: "Platform of an external identity, e.g. meet.")
  var platform: String?
  @Option(
    name: .customLong("external-id"),
    help: "The platform's own meeting id (idempotent with --platform).")
  var externalID: String?

  func run() async throws {
    let params = MeetingStartParams(
      platform: platform, externalID: externalID, title: title,
      sources: sources.map { SourceID($0) })
    try await runSimpleCommand(
      .meetingStart(params), expecting: Meeting.self, options: options,
      humanSuccess: OutputFormatting.humanMeeting)
  }
}

struct MeetingEndCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "end",
    abstract: "End a meeting: closes the open mark and finalizes the meeting.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Meeting id.") var meeting: String

  func run() async throws {
    try await runSimpleCommand(
      .meetingEnd(meeting: meeting), expecting: Meeting.self, options: options,
      humanSuccess: OutputFormatting.humanMeeting)
  }
}

struct MeetingPauseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pause",
    abstract: "Pause a meeting's transcription mark (capture is untouched).")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Meeting id.") var meeting: String

  func run() async throws {
    try await runSimpleCommand(
      .meetingPause(meeting: meeting), expecting: Meeting.self, options: options,
      humanSuccess: OutputFormatting.humanMeeting)
  }
}

struct MeetingResumeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume", abstract: "Resume a paused meeting (opens a new mark).")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Meeting id.") var meeting: String

  func run() async throws {
    try await runSimpleCommand(
      .meetingResume(meeting: meeting), expecting: Meeting.self, options: options,
      humanSuccess: OutputFormatting.humanMeeting)
  }
}

struct MeetingRenameCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rename", abstract: "Rename a meeting.")

  @OptionGroup var options: ClientOptions
  @Argument(help: "Meeting id.") var meeting: String
  @Option(name: .customLong("title"), help: "The new title.") var title: String
  @Option(
    name: .customLong("if-rev"),
    help: "Compare-and-set: fail with 'conflict' unless the meeting is at this revision.")
  var ifRev: Int?

  func run() async throws {
    try await runSimpleCommand(
      .meetingRename(MeetingRenameParams(meeting: meeting, title: title, ifRev: ifRev)),
      expecting: Meeting.self, options: options,
      humanSuccess: OutputFormatting.humanMeeting)
  }
}

struct MeetingListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "Live + recent meetings from the daemon; --all reads full history from disk.")

  @OptionGroup var options: ClientOptions

  @Flag(
    name: .customLong("all"),
    help: "Read every meetings/*/meeting.toml from the data root, daemon-free.")
  var all = false

  func run() async throws {
    if all {
      // Closed history is read from disk, not the socket — works with no
      // daemon running at all.
      let dataRoot: String
      switch ControlClientRuntime.resolveDataRoot(configFlag: options.config) {
      case .failure(let error):
        ControlClientRuntime.writeStderr(error.description)
        throw ExitCode(1)
      case .success(let root):
        dataRoot = root
      }
      let meetings = MeetingStore.readAll(dataRoot: URL(fileURLWithPath: dataRoot))
        .sorted { $0.started < $1.started }
      let code = OutputFormatting.emit(
        MeetingListData(meetings: meetings), json: options.json,
        humanSuccess: OutputFormatting.humanMeetingList)
      if code != 0 { throw ExitCode(code) }
      return
    }
    try await runSimpleCommand(
      .meetingList, expecting: MeetingListData.self, options: options,
      humanSuccess: OutputFormatting.humanMeetingList)
  }
}

// MARK: - watch

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch", abstract: "Subscribe and print the snapshot, then the live feed.")

  @OptionGroup var options: ClientOptions
  @Option(
    name: .customLong("events"),
    help: "Telemetry kinds to receive (vad,segment,job); state events are always delivered.")
  var events: String = ""
  @Option(name: .customLong("source"), help: "Source id filter; repeatable. Omit for all sources.")
  var sources: [String] = []

  /// Runs until the daemon closes the connection or the process is
  /// interrupted (Ctrl-C) — `watch` is read-only, so the default SIGINT
  /// disposition is a clean-enough exit.
  func run() async throws {
    let debug = options.debug
    guard let client = await ControlClientRuntime.connect(configFlag: options.config, debug: debug)
    else {
      throw ExitCode(1)
    }
    let tokens = events.split(separator: ",").map(String.init)
    let kinds = tokens.compactMap { EventKind(rawValue: $0) }
    let unrecognized = tokens.filter { EventKind(rawValue: $0) == nil }
    if !unrecognized.isEmpty {
      debug.log(
        "ignoring unrecognized event kind(s): \(unrecognized.joined(separator: ", ")) "
          + "(known: \(EventKind.allCases.map(\.rawValue).joined(separator: ",")))")
    }
    let params = SubscribeParams(events: kinds, sources: sources.map { SourceID($0) })

    let snapshot: SnapshotData
    let stream: AsyncStream<EventFrame>
    do {
      (snapshot, stream) = try await client.subscribe(params)
    } catch {
      debug.log("subscribe failed: \(error)")
      ControlClientRuntime.writeStderr("error: could not subscribe: \(error)")
      throw ExitCode(1)
    }

    let encoder = JSONEncoder()
    if options.json {
      if let data = try? encoder.encode(snapshot), let line = String(data: data, encoding: .utf8) {
        print(line)
      }
    } else {
      print("snapshot rev=\(snapshot.rev)")
      print(OutputFormatting.humanMeetings(snapshot.meetings))
      print(OutputFormatting.humanSourcesList(SourcesListData(sources: snapshot.sources)))
    }

    var eventCount = 0
    for await frame in stream {
      eventCount += 1
      if options.json {
        if let data = try? encoder.encode(frame), let line = String(data: data, encoding: .utf8) {
          print(line)
        }
      } else {
        print(OutputFormatting.humanEvent(frame))
      }
    }
    // Reaching here means the daemon (not Ctrl-C) ended the stream.
    debug.log("event stream closed by daemon after \(eventCount) event(s)")
  }
}

// MARK: - flush

struct FlushCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "flush",
    abstract: "Force-flush in-flight chunks and the index for every enabled source.")

  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await runSimpleCommand(
      .flush, expecting: EmptyData.self, options: options,
      humanSuccess: OutputFormatting.humanEmpty)
  }
}
