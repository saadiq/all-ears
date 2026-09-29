import Testing

@testable import EarsMenuKit

@Suite("ReconnectBackoff")
struct ReconnectBackoffTests {
  @Test("delays double from 1s and cap at 15s")
  func schedule() {
    #expect(
      (0...5).map { ReconnectBackoff.delay(attempt: $0) } == [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15),
      ])
  }
}
