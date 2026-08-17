import EarsCore
import Testing

@testable import EarsCaptureKit

@Suite("Meeting episode tracker")
struct MeetingEpisodeTrackerTests {
  private func at(_ seconds: Double) -> Instant { Instant(secondsSinceEpoch: seconds) }

  @Test("activity must persist past the debounce before an episode begins")
  func debouncedBegin() {
    var tracker = MeetingEpisodeTracker(debounceSeconds: 2)
    #expect(tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(0)) == nil)
    #expect(tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(1)) == nil)
    let change = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(2))
    #expect(
      change
        == MeetingActivityChange(bundleID: "us.zoom.xos", active: true, episode: "us.zoom.xos#1"))
  }

  @Test("a sub-debounce flap reports nothing")
  func flapSuppressed() {
    var tracker = MeetingEpisodeTracker(debounceSeconds: 2)
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(0))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(2))  // began
    #expect(tracker.observe(bundleID: "us.zoom.xos", active: false, at: at(3)) == nil)
    // Back on before debounce elapsed: the pending end is discarded.
    #expect(tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(4)) == nil)
    #expect(tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(7)) == nil)
  }

  @Test(
    "an ended episode carries the episode id that began it, and the next begin mints a fresh one")
  func episodeIdsAdvance() {
    var tracker = MeetingEpisodeTracker(debounceSeconds: 2)
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(0))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(2))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: false, at: at(10))
    let ended = tracker.observe(bundleID: "us.zoom.xos", active: false, at: at(12))
    #expect(
      ended
        == MeetingActivityChange(bundleID: "us.zoom.xos", active: false, episode: "us.zoom.xos#1"))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(20))
    let second = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(22))
    #expect(second?.episode == "us.zoom.xos#2")
  }
}
