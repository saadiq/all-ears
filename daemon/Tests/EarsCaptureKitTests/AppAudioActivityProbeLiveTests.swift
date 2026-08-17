import Foundation
import Testing

@testable import EarsCaptureKit

/// Real, hardware-touching proof of concept for ``CoreAudioAppActivityProbe``:
/// actually enumerates this machine's live Core Audio HAL process object
/// list. Per the tier-2 rule in `docs/engineering-practices.md`, this is
/// deliberately **not** part of the default `swift test` run — its result
/// depends on which real processes happen to be running audio input on this
/// machine, which doesn't belong in a gating CI suite. It only runs when
/// `EARS_LIVE_MEETING_DETECT_TEST=1` is set.
@Suite(
  "App audio activity probe (live)",
  .enabled(if: ProcessInfo.processInfo.environment["EARS_LIVE_MEETING_DETECT_TEST"] == "1")
)
struct AppAudioActivityProbeLiveTests {
  @Test("probing real HAL process objects returns an answer for every asked bundle id")
  func probeAnswersEveryBundle() {
    let probe = CoreAudioAppActivityProbe()
    let asked: Set<String> = ["us.zoom.xos", "com.apple.notarealapp"]
    let activity = probe.inputActivity(bundleIDs: asked)
    #expect(Set(activity.keys) == asked)
    #expect(activity["com.apple.notarealapp"] == false)
  }
}
