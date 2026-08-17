import EarsCaptureKit
import EarsCore

/// One configured `app:*` source the monitor watches.
public struct WatchedAppSource: Sendable, Hashable {
  public var source: SourceID
  public var bundleID: String
  public var label: String

  public init(source: SourceID, bundleID: String, label: String) {
    self.source = source
    self.bundleID = bundleID
    self.label = label
  }
}

/// Polls the app-audio activity probe for every watched `app:*` source,
/// debounces the samples into episodes (``MeetingEpisodeTracker``), and
/// reports each confirmed edge through `onChange` — `EarsDaemon` wires that
/// to the event bus (`meeting.activity` telemetry) and to
/// ``SessionRegistry/appAudioActivity(source:active:)``. `snapshot()` serves
/// `status`'s `meeting_activity` list so a late-connecting client catches up
/// without waiting for an edge.
///
/// Watched entries sharing one bundle id would double-observe the tracker;
/// the initializer keeps the first entry per bundle id.
public actor MeetingActivityMonitor {
  public typealias ActivitySink = @Sendable (MeetingActivityStatus) async -> Void

  static let pollIntervalSeconds = 1.0

  private let watched: [WatchedAppSource]
  private let probe: any AppAudioActivityProbing
  private let clock: any NowProviding
  private let sleep: @Sendable (Double) async -> Void
  private let onChange: ActivitySink
  private var tracker: MeetingEpisodeTracker
  private var current: [SourceID: MeetingActivityStatus] = [:]
  private var pollTask: Task<Void, Never>?

  public init(
    watched: [WatchedAppSource],
    debounceSeconds: Double,
    probe: any AppAudioActivityProbing,
    clock: any NowProviding = SystemClock(),
    sleep: @escaping @Sendable (Double) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    },
    onChange: @escaping ActivitySink
  ) {
    var seen: Set<String> = []
    self.watched = watched.filter { seen.insert($0.bundleID).inserted }
    self.probe = probe
    self.clock = clock
    self.sleep = sleep
    self.onChange = onChange
    self.tracker = MeetingEpisodeTracker(debounceSeconds: debounceSeconds)
  }

  public func start() {
    guard pollTask == nil else { return }
    pollTask = Task { await run() }
  }

  public func stop() {
    pollTask?.cancel()
    pollTask = nil
  }

  public func snapshot() -> [MeetingActivityStatus] {
    current.values.sorted { $0.source < $1.source }
  }

  private func run() async {
    let bundleIDs = Set(watched.map(\.bundleID))
    while !Task.isCancelled {
      let activity = probe.inputActivity(bundleIDs: bundleIDs)
      let now = clock.now()
      for entry in watched {
        guard
          let change = tracker.observe(
            bundleID: entry.bundleID, active: activity[entry.bundleID] ?? false, at: now)
        else { continue }
        let status = MeetingActivityStatus(
          source: entry.source, bundleID: entry.bundleID, label: entry.label,
          active: change.active, episode: change.episode)
        current[entry.source] = status
        await onChange(status)
      }
      await sleep(Self.pollIntervalSeconds)
    }
  }
}
