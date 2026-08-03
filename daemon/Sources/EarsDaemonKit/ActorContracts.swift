/// Cross-actor design notes for `earsd`'s orchestration actors —
/// ``CaptureActor``, ``MeetingRegistry``, and ``ControlServer``.
/// `docs/architecture.md`'s "Concurrency & runtime model" section and
/// `docs/specs/capture-daemon.md` are the source of truth; the decisions
/// recorded here resolve the ambiguities those leave open.
///
/// ## Actor decomposition (from `docs/architecture.md`)
///
/// - One ``CaptureActor`` **per source**: owns that source's capture backend,
///   `ChunkEncoder`, `IndexAppender`, and `VAD`. Sources are independent, so a
///   per-source actor isolates one source's failure/teardown from another's.
/// - One ``MeetingRegistry`` owning the meeting lifecycle and `meeting.toml`
///   persistence (via `EarsDataStore.MeetingStore`).
/// - One ``ControlServer`` owning control-socket command dispatch: it plugs
///   into `EarsIPC.ControlSocketServer`'s request-handler seam and routes each
///   of the `ControlCall` methods to the right actor method. It is
///   deliberately thin wiring — the real work lives in the other actors.
///
/// ## Domain / wire split
///
/// Following the split this codebase already draws between domain types and
/// their control-socket wire shapes (`IndexedChunk` ↔ `IndexEvent.chunk`),
/// the logic actors return **domain** types and ``ControlServer`` converts to
/// wire payloads at the socket boundary:
///
/// - ``CaptureActor/status()`` returns the domain ``CaptureSourceStatus``;
///   ``ControlServer`` maps it to the wire `SourceStatus`.
public enum ActorContracts {}
