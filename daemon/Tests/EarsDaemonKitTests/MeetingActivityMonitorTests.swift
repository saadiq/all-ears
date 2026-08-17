import EarsCore
import EarsCoreTestSupport
import Synchronization
import Testing

@testable import EarsDaemonKit

@Suite("Meeting activity monitor")
struct MeetingActivityMonitorTests {
  private let zoom = WatchedAppSource(
    source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos", label: "Zoom")

  @Test("a confirmed begin is published once with its episode id and lands in the snapshot")
  func publishesConfirmedBegin() async throws {
    let gate = SleepGate()
    let seen = Mutex<[MeetingActivityStatus]>([])
    // Debounce 0: a state observed on two consecutive polls is confirmed —
    // the debounce *duration* itself is MeetingEpisodeTracker's own test's job.
    let monitor = MeetingActivityMonitor(
      watched: [zoom], debounceSeconds: 0, probe: ScriptedProbe([["us.zoom.xos": true]]),
      clock: ManualClock(Instant(secondsSinceEpoch: 0)),
      sleep: { seconds in await gate.wait(seconds) },
      onChange: { status in seen.withLock { $0.append(status) } })
    await monitor.start()
    await gate.releaseAll()  // poll 1 done (pending) → poll 2 confirms
    await waitUntil { seen.withLock { $0.count == 1 } }

    let published = seen.withLock { $0 }
    #expect(
      published == [
        MeetingActivityStatus(
          source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
          label: "Zoom", active: true, episode: "us.zoom.xos#1")
      ])
    #expect(await monitor.snapshot() == published)
    await monitor.stop()
  }

  @Test("stop() halts polling — no further changes after it")
  func stopHaltsPolling() async throws {
    let gate = SleepGate()
    let seen = Mutex<[MeetingActivityStatus]>([])
    let monitor = MeetingActivityMonitor(
      watched: [zoom], debounceSeconds: 0, probe: ScriptedProbe([["us.zoom.xos": true]]),
      clock: ManualClock(Instant(secondsSinceEpoch: 0)),
      sleep: { seconds in await gate.wait(seconds) },
      onChange: { status in seen.withLock { $0.append(status) } })
    await monitor.start()
    await monitor.stop()
    await gate.releaseAll()
    for _ in 0..<50 { await Task.yield() }
    #expect(seen.withLock { $0.isEmpty })
  }
}
