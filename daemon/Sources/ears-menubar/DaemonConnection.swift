import EarsCore
import EarsIPC
import EarsMenuKit

/// Owns the socket client lifecycle. One generation per dial; a bounce or a
/// dropped stream invalidates the generation so stale loops exit silently.
actor DaemonConnection {
  enum Event: Sendable {
    case ready(daemon: String, snapshot: SnapshotData)
    case event(EventFrame)
    case down
  }

  private let socketPath: String
  private let stream: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private var client: ControlSocketClient?
  private var generation = 0

  init(socketPath: String) {
    self.socketPath = socketPath
    (stream, continuation) = AsyncStream.makeStream(of: Event.self)
  }

  nonisolated var events: AsyncStream<Event> { stream }

  func run() async {
    var attempt = 0
    while !Task.isCancelled {
      generation += 1
      let mine = generation
      // Held outside the `do` so the teardown below can close a socket that
      // was dialled but never adopted as `client`. `hello`/`subscribe`
      // throwing on a socket the daemon accepted and then closed — a daemon
      // mid-restart, or a protocol mismatch — is a normal path, and neither
      // the teardown (which closes `client`, still nil) nor `bounce()` (which
      // has no reference to it) would ever have closed it.
      var pending: ControlSocketClient?
      do {
        let dialled = try await ControlSocketClient.connect(toPath: socketPath)
        pending = dialled
        let hello = try await dialled.hello(client: "menubar/0.1.0")
        let (snapshot, frames) = try await dialled.subscribe(SubscribeParams(events: [.job]))
        guard generation == mine else {
          // A bounce() landed mid-dial and already owns a newer generation;
          // abandon this connection instead of adopting it as `client`.
          await dialled.close()
          pending = nil
          continue
        }
        client = dialled
        pending = nil  // adopted: the teardown below owns it as `client`
        attempt = 0
        continuation.yield(.ready(daemon: hello.daemon, snapshot: snapshot))
        for await frame in frames {
          guard generation == mine else { break }
          continuation.yield(.event(frame))
        }
      } catch {
        // fall through to the shared teardown below
      }
      // Close, don't just drop: the transport cancels its `NWConnection` in
      // `close()` and nowhere else, so releasing the last reference on a
      // peer-closed socket leaks its descriptor — one per failed dial, and a
      // crash-looping daemon eventually exhausts the app's limit, stranding
      // the menu on "⚠ Daemon not running" even after earsd comes back.
      await pending?.close()
      if generation == mine {
        let stale = client
        client = nil
        await stale?.close()
        continuation.yield(.down)
      }
      attempt += 1
      try? await Task.sleep(for: ReconnectBackoff.delay(attempt: attempt - 1))
    }
  }

  /// Drops the current socket so `run()` redials.
  ///
  /// Deliberately silent: bumping the generation suppresses the `.down` the
  /// teardown would otherwise yield, because a bounce is *asked for* and the
  /// caller already knows the connection is gone. The caller therefore owns
  /// the state transition that goes with it — `MenuStateReducer.resubscribing`
  /// — and a caller that skips it leaves the menu offering Pause/End over a
  /// socket that no longer exists.
  func bounce() async {
    generation += 1
    // Clear `client` synchronously before the suspending `close()` below —
    // otherwise a `run()` redial that completes while this awaits could set
    // a fresh `client`, and the unconditional `client = nil` on resume would
    // wipe out that healthy connection instead of the stale one.
    let stale = client
    client = nil
    await stale?.close()
  }

  func perform(_ call: ControlCall) async -> WireError? {
    guard let client else {
      return WireError(code: .internalError, message: "not connected to earsd")
    }
    do {
      _ = try await client.send(call, expecting: EmptyData.self)
      return nil
    } catch let error as WireError {
      return error
    } catch {
      return WireError(code: .internalError, message: "\(error)")
    }
  }

  func status() async -> StatusData? {
    guard let client else { return nil }
    return try? await client.send(.status, expecting: StatusData.self)
  }
}
