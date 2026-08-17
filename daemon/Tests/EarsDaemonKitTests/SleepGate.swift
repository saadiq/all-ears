import Testing

/// A controllable stand-in for an actor's sleep seam: waiters block until the
/// test releases them, so grace timers and poll loops are driven explicitly
/// instead of racing real time.
///
/// Release is sticky. Arming a timer only enqueues its `Task`, which has not
/// necessarily reached its first `wait` when the test calls `releaseAll()`;
/// without the flag, a `wait` arriving afterwards would register a
/// continuation nothing ever resumes and hang the test forever.
actor SleepGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func wait(_ seconds: Double) async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func releaseAll() {
    released = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}

/// Polls an async condition without real-time sleeps, failing the test rather
/// than returning quietly when it never comes true.
func waitUntil(_ condition: @Sendable () async throws -> Bool) async {
  for _ in 0..<2_000 {
    if (try? await condition()) == true { return }
    await Task.yield()
  }
  Issue.record("condition never became true")
}
