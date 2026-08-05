# Menu Bar App (`ears-menubar`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the menu bar frontend specified in `docs/plans/menubar-app.md`: a glanceable icon + dropdown menu with session verbs, pipeline visibility, and macOS notifications — plus the daemon-side change that makes the on-end pipeline observable (job events for every stage) and applicable (runs for manual sessions too).

**Architecture:** Two new SwiftPM targets in `daemon/Package.swift`: `EarsMenuKit` (pure library — state reducer, menu renderer, notification policy, artifact locator; zero I/O, fully TDD'd) and `ears-menubar` (thin SwiftUI `MenuBarExtra` shell — socket client wiring, disk reads, `UNUserNotificationCenter`). The Makefile assembles and signs `All Ears.app`. Daemon change: `OnClosePipelineRunner` publishes `job.publish` events for cleanup/summarize via an injected closure wired to the daemon's `EventBus`, and the on-end chain runs for every session trigger.

**Tech Stack:** Swift 6 (strict concurrency), swift-testing (`import Testing`, `@Test`/`#expect` — never XCTest), SwiftUI `MenuBarExtra`, `UserNotifications`, `ServiceManagement`, plain Makefile packaging (`sips`/`iconutil`/`codesign` only).

## Global Constraints

- Platform: macOS 15+, `swift-tools-version: 6.0` (`daemon/Package.swift:1-8`). All Swift work happens in `daemon/`.
- **No `@MainActor` in `EarsMenuKit`** or any existing library. `@MainActor` is permitted only inside the `ears-menubar` executable target (UI shell) — this deviation is recorded in `docs/plans/menubar-app.md:63-64`.
- Format: `cd daemon && swift format --recursive -i Sources/ Tests/` before every commit; CI runs `swift format lint --recursive --strict Sources/ Tests/`. 2-space indent, 100-column lines, `///` doc comments, no block comments.
- Max 300 lines per file. Split files rather than exceed it.
- Tests: swift-testing only. **No wall-clock in tests** — pass explicit `Instant` values; never call `Date()` in a test or in `EarsMenuKit`.
- Commits: Conventional Commits, one logical change each, every commit builds and passes `swift test`. Scope = tool or package: `feat(daemon): …`, `feat(menubar): …`, `docs: …`. End every commit message with the trailer line:
  `Claude-Session: https://claude.ai/code/session_01SDSU94sbhao3mBijgB6dQ4`
- The default test suite stays hermetic — no model downloads, no real hardware, no TCC. Smoke tests use the existing escape hatches (`ALLEARS_TRANSCRIBE_BACKEND=null`, scripted `[llm] command`, `EARS_CONFIG`).
- Bundle-id convention: `net.tomelliot.ears.<tool>` (see `daemon/Sources/earsd/Info.plist`). The app is `net.tomelliot.ears.menubar`.
- Version literals: this suite hardcodes `"0.1.0"` everywhere (e.g. `EarsDaemon.swift:485` `"earsd 0.1.0"`). Use `"0.1.0"` and hello client string `"menubar/0.1.0"`.
- `docs/` is contractual: when a task changes wire behavior, the same task updates `docs/specs/control-protocol.md` and `shared/protocol-fixtures/control-v2.json`. Code/doc disagreement is a bug.

**Upstream note (flag in the PR description, decided during design):** Task 2 makes `session.end` run the on-end pipeline for *manual* sessions too (today: browser-triggered only, `EarsDaemon.swift:429-431`). This changes `ears session start/end` behavior for CLI users; the escape hatch is `[earsd.sessions] on_end_stages = []`. PR 1 = Tasks 1–3 (daemon), PR 2 = Tasks 4–15 (app).

---

### Task 1: `OnClosePipelineRunner` publishes cleanup/summarize job events

**Files:**
- Modify: `daemon/Sources/EarsDaemonKit/OnClosePipelineRunner.swift`
- Modify: `daemon/Sources/EarsDaemonKit/EarsDaemon.swift:425-446` (wiring)
- Modify: `daemon/Sources/EarsCore/Socket/ControlCall.swift:258` (doc comment)
- Modify: `docs/specs/control-protocol.md:196` (method table row)
- Modify: `shared/protocol-fixtures/control-v2.json` (one new event fixture)
- Test: `daemon/Tests/EarsDaemonKitTests/OnClosePipelineRunnerTests.swift`

**Interfaces:**
- Consumes: `JobPublishParams` / `JobState` (`EarsCore/Socket/ControlCall.swift:243-278`), `EventBus.publish(_:)` (`EarsDaemonKit/EventBus.swift:82`), existing test fakes `ScriptedRunner` / `LogCollector` / `transcribeOutcome` / `cleanupOutcome` (`OnClosePipelineRunnerTests.swift:18-63`) and `StageEnvelopeFixtures` (`Tests/EarsDaemonKitTests/StageEnvelopeFixtures.swift`).
- Produces: `OnClosePipelineRunner.JobPublisher` typealias and a new `publishJob:` init parameter (default no-op). Job ids `"cleanup-<8 hex>"` / `"summarize-<8 hex>"`; states `.started` then `.done`/`.failed`. `transcribe` is untouched (it self-publishes; `Sources/transcribe/JobEventPublisher.swift`).

- [ ] **Step 1: Write the failing tests**

Add to `OnClosePipelineRunnerTests.swift` (alongside the existing fakes; `Mutex` is already imported there via `Synchronization`):

```swift
/// Collects the JobPublishParams the runner hands to its publishJob seam.
private final class JobCollector: Sendable {
  private let entries = Mutex<[JobPublishParams]>([])
  func append(_ params: JobPublishParams) { entries.withLock { $0.append(params) } }
  var snapshot: [JobPublishParams] { entries.withLock { $0 } }
}

@Test("the full chain publishes started/done for cleanup and summarize, never transcribe")
func fullChainPublishesJobEvents() async throws {
  let dir = try makeTempDirectory("onend-jobs")
  let transcript = try makeFile("t.transcript.md", in: dir)
  let clean = try makeFile("t.clean.md", in: dir)
  // Mirror the summarize arrange used by fullChainThreadsPaths (:83) for the third outcome.
  let runner = ScriptedRunner([
    transcribeOutcome(output: transcript),
    cleanupOutcome(output: clean),
    SpawnOutcome(
      exitCode: 0,
      stdout: StageEnvelopeFixtures.summarizeAllPresetsSuccess(
        presets: /* same literal as fullChainThreadsPaths */)),
  ])
  let jobs = JobCollector()
  let pipeline = OnClosePipelineRunner(
    runProcess: runner.runner, log: { _ in }, publishJob: { jobs.append($0) })

  let transcribed = await pipeline.runOnEndChain(
    sessionID: "s1", stages: OnEndStage.allCases, context: "test")

  #expect(transcribed)
  let published = jobs.snapshot
  #expect(published.map(\.kind) == ["cleanup", "cleanup", "summarize", "summarize"])
  #expect(published.map(\.state) == [.started, .done, .started, .done])
  #expect(published.allSatisfy { $0.session == "s1" })
  #expect(published[0].job == published[1].job)
  #expect(published[0].job.hasPrefix("cleanup-"))
  #expect(published[2].job == published[3].job)
  #expect(published[2].job.hasPrefix("summarize-"))
}

@Test("a failing cleanup publishes started/failed and no summarize events")
func failingCleanupPublishesFailed() async throws {
  let dir = try makeTempDirectory("onend-jobs-fail")
  let transcript = try makeFile("t.transcript.md", in: dir)
  let runner = ScriptedRunner([
    transcribeOutcome(output: transcript),
    SpawnOutcome(exitCode: 4, stderr: "boom"),
  ])
  let jobs = JobCollector()
  let pipeline = OnClosePipelineRunner(
    runProcess: runner.runner, log: { _ in }, publishJob: { jobs.append($0) })

  _ = await pipeline.runOnEndChain(sessionID: "s1", stages: OnEndStage.allCases, context: "test")

  #expect(jobs.snapshot.map(\.kind) == ["cleanup", "cleanup"])
  #expect(jobs.snapshot.map(\.state) == [.started, .failed])
}

@Test("a failing summarize publishes failed with the exit code as detail")
func failingSummarizePublishesFailedDetail() async throws {
  let dir = try makeTempDirectory("onend-jobs-sumfail")
  let transcript = try makeFile("t.transcript.md", in: dir)
  let clean = try makeFile("t.clean.md", in: dir)
  let runner = ScriptedRunner([
    transcribeOutcome(output: transcript),
    cleanupOutcome(output: clean),
    SpawnOutcome(exitCode: 4, stderr: "llm exploded"),
  ])
  let jobs = JobCollector()
  let pipeline = OnClosePipelineRunner(
    runProcess: runner.runner, log: { _ in }, publishJob: { jobs.append($0) })

  _ = await pipeline.runOnEndChain(sessionID: "s1", stages: OnEndStage.allCases, context: "test")

  let summarize = jobs.snapshot.filter { $0.kind == "summarize" }
  #expect(summarize.map(\.state) == [.started, .failed])
  #expect(summarize[1].detail == "exit 4")
}

@Test("a failing transcribe publishes nothing")
func failingTranscribePublishesNothing() async throws {
  let runner = ScriptedRunner([SpawnOutcome(exitCode: 4)])
  let jobs = JobCollector()
  let pipeline = OnClosePipelineRunner(
    runProcess: runner.runner, log: { _ in }, publishJob: { jobs.append($0) })
  _ = await pipeline.runOnEndChain(sessionID: "s1", stages: OnEndStage.allCases, context: "test")
  #expect(jobs.snapshot.isEmpty)
}
```

For the `summarizeAllPresetsSuccess(presets:)` argument, copy the exact literal the existing `fullChainThreadsPaths` test (`OnClosePipelineRunnerTests.swift:83`) passes — do not invent a new shape.

- [ ] **Step 2: Run tests, verify they fail to compile** (no `publishJob:` parameter yet)

Run: `cd daemon && swift test --filter OnClosePipelineRunnerTests`
Expected: compile error — `extra argument 'publishJob' in call`.

- [ ] **Step 3: Implement the seam and publish calls**

In `OnClosePipelineRunner.swift`:

```swift
/// How the runner reports per-stage job lifecycle to subscribers. Wired to the
/// daemon's EventBus in production; a no-op by default so existing callers and
/// tests are unaffected. `transcribe` is absent here on purpose — it reports
/// itself over the socket (JobEventPublisher).
public typealias JobPublisher = @Sendable (JobPublishParams) async -> Void
```

Extend the stored properties and init (keeping existing defaults):

```swift
private let publishJob: JobPublisher

public init(
  runProcess: @escaping ProcessRunner = OnClosePipelineRunner.realProcessRunner,
  log: @escaping @Sendable (String) -> Void = { _ in },
  publishJob: @escaping JobPublisher = { _ in }
) {
  self.runProcess = runProcess
  self.log = log
  self.publishJob = publishJob
}
```

Add a job-id helper:

```swift
static func jobID(for stage: OnEndStage) -> String {
  "\(stage.rawValue)-\(UUID().uuidString.lowercased().prefix(8))"
}
```

In `runOnEndChain` (`:132-170`), wrap the **cleanup** stage:

```swift
if stages.contains(.cleanup) {
  let jobID = Self.jobID(for: .cleanup)
  await publishJob(
    JobPublishParams(job: jobID, kind: OnEndStage.cleanup.rawValue, session: sessionID, state: .started))
  let cleanPath = await runPathStage(
    .cleanup, arguments: [transcriptPath, "--json"], sessionID: sessionID, context: context)
  await publishJob(
    JobPublishParams(
      job: jobID, kind: OnEndStage.cleanup.rawValue, session: sessionID,
      state: cleanPath == nil ? .failed : .done))
  guard let cleanPath else { return true }
  nextInput = cleanPath
}
```

and the **summarize** stage (keep the existing `spawn` + `logSummarizeResults` flow; insert publishes around it, deriving done/failed from `outcome.exitCode == 0`, with `detail: "exit \(outcome.exitCode)"` on failure and `detail: "spawn failed"` if `spawn` returned nil). Do not add publishes around transcribe.

Wire production in `EarsDaemon.swift` (the composition at `:425-446`):

```swift
let pipeline = OnClosePipelineRunner(
  log: log,
  publishJob: { [eventBus] params in await eventBus.publish(.job(params)) })
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd daemon && swift test --filter OnClosePipelineRunnerTests`
Expected: all pass, including every pre-existing test (the default no-op keeps them green).

- [ ] **Step 5: Update the contract docs and fixtures**

1. `docs/specs/control-protocol.md:196` — change the `job.publish` row's params to
   `` {job, kind: "transcribe"\|"cleanup"\|"summarize", session?, state: …} `` and append to the row's prose: "`transcribe` reports itself; the daemon's on-end chain reports `cleanup` and `summarize`."
2. `daemon/Sources/EarsCore/Socket/ControlCall.swift:258` — replace `/// Today always `transcribe`.` with `/// `transcribe` (self-reported), or `cleanup`/`summarize` (reported by the daemon's on-end chain).`
3. `shared/protocol-fixtures/control-v2.json` — add to the `events` array (events need no Swift-side registration; `eventsRoundTrip` covers all entries automatically):

```json
{
  "name": "job-event-summarize-done",
  "frame": {
    "event": "job",
    "params": {
      "job": "summarize-9be04d11",
      "kind": "summarize",
      "session": "0d5e1111-aaaa-bbbb-cccc-222233334444",
      "state": "done"
    }
  }
}
```

- [ ] **Step 6: Verify fixtures round-trip on both sides**

Run: `cd daemon && swift test --filter ControlProtocolV2FixtureTests`
Expected: PASS (new event fixture round-trips).
Run: `cd browser && bun install && bun run test`
Expected: PASS. If a TS test enumerates event fixtures exhaustively and fails on the new name, extend that test's expectation — the fixture stays.

- [ ] **Step 7: Format, lint, full daemon test run, commit**

```bash
cd daemon && swift format --recursive -i Sources/ Tests/ && swift format lint --recursive --strict Sources/ Tests/ && swift test
cd .. && git add -A && git commit -m "feat(daemon): publish cleanup/summarize job events from the on-end chain"
```
(Include the body explaining the seam + the Claude-Session trailer.)

---

### Task 2: On-end chain runs for manual sessions too

**Files:**
- Modify: `daemon/Sources/EarsDaemonKit/EarsDaemon.swift:429-431`
- Modify: `docs/specs/control-protocol.md:155-159`
- Modify: `daemon/Package.swift:330-332` (CLISmokeTests dependency comment)
- Check/modify: `docs/specs/capture-daemon.md` (grep for browser-only phrasing)

**Interfaces:**
- Consumes: the `onSessionEnded` hook composition (`EarsDaemon.swift:425-446`).
- Produces: the on-end chain fires for every ended session regardless of `trigger`. Verified end-to-end by Task 3's smoke test (composition code has no unit seam; the guard is a single line in the wiring closure).

- [ ] **Step 1: Remove the trigger guard**

In `EarsDaemon.swift`, delete the line `guard session.trigger == .browserExtension else { return }` from the `onSessionEnded` closure. Leave everything else intact.

- [ ] **Step 2: Update the spec and stale comments**

1. `docs/specs/control-protocol.md:155-159` — change "For browser-triggered sessions the daemon then runs the on-end pipeline" to "The daemon then runs the on-end pipeline for every ended session, whatever its trigger (disable with `[earsd.sessions] on_end_stages = []`)". Keep the surrounding text (transcript stamping, retention clock) unchanged.
2. `grep -rn "browser" docs/specs/capture-daemon.md` — update any sentence that scopes the session-end pipeline to browser-triggered sessions.
3. `daemon/Package.swift:330-332` — the `CLISmokeTests` comment says the hook "only fires for browser-triggered sessions"; rewrite to say the smoke test predates the all-triggers change and now covers both trigger kinds.
4. `daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift` — the comment near `:167` justifying the browser trigger; soften to "browser-triggered variant" (Task 3 adds the manual variant).

- [ ] **Step 3: Build and run the daemon suites**

Run: `cd daemon && swift build && swift test --filter EarsDaemonKitTests`
Expected: PASS (existing `EarsDaemonTests` pass `onEndStages: []` and are unaffected).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(daemon): run the on-end pipeline for manual sessions too"
```
Body must note the CLI-visible behavior change and the `on_end_stages = []` escape hatch, plus the trailer.

---

### Task 3: Smoke test — manual session end emits job events for all three stages

**Files:**
- Modify: `daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift`

**Interfaces:**
- Consumes: `ControlSocketClient` (`connect(toPath:)`, `hello(client:)`, `send(_:expecting:)`, `subscribe(_:)` — `EarsIPC/ControlSocketClient.swift:38-67`), `SubscribeParams(events: [.job])`, the existing arrange in `onEndChainRunsRealStagesWithJSONEnvelopes` (`:91-220`: temp config TOML, fake-llm.sh, `ALLEARS_TRANSCRIBE_BACKEND=null`, products-dir-first `PATH`, socket polling).
- Produces: a shared arrange helper both tests use, and end-to-end proof of Tasks 1+2.

- [ ] **Step 1: Extract the shared arrange into a helper**

Move the existing test's arrange block (temp dir, fake-llm script, config TOML including `on_end_stages`, daemon spawn, socket wait — currently `:105-163`) verbatim into:

```swift
private struct OnEndDaemonHarness {
  var socketPath: String
  var outputRoot: URL
  var daemonLogPath: String
  var daemon: Process
  var tempDir: URL
}

/// Boots a real earsd wired for hermetic on-end runs (null ASR, scripted LLM, no sources).
private static func bootOnEndDaemon(label: String) throws -> OnEndDaemonHarness
```

Refactor `onEndChainRunsRealStagesWithJSONEnvelopes` to use it. Run `swift test --filter OnEndChainSmokeTests` — the existing test must still pass before adding the new one.

- [ ] **Step 2: Write the failing manual-session test**

```swift
@Test(
  "a manual session end runs the chain and publishes job events for every stage",
  .timeLimit(.minutes(2)))
func manualSessionEndPublishesJobEvents() async throws {
  let harness = try Self.bootOnEndDaemon(label: "onend-manual")
  defer { harness.daemon.terminate(); harness.daemon.waitUntilExit() }

  let watcher = try await ControlSocketClient.connect(toPath: harness.socketPath)
  try await watcher.hello(client: "onend-manual-watch")
  let (_, events) = try await watcher.subscribe(SubscribeParams(events: [.job]))
  let collector = Task { () -> [JobPublishParams] in
    var jobs: [JobPublishParams] = []
    for await frame in events {
      guard case .job(let params) = frame.event else { continue }
      jobs.append(params)
      let doneKinds = Set(jobs.filter { $0.state == .done }.map(\.kind))
      if doneKinds.isSuperset(of: ["transcribe", "cleanup", "summarize"]) { break }
    }
    return jobs
  }

  let client = try await ControlSocketClient.connect(toPath: harness.socketPath)
  try await client.hello(client: "onend-manual")
  let session = try await client.send(
    .sessionStart(SessionStartParams(title: "manual smoke", sources: ["mic"])),
    expecting: Session.self)
  #expect(session.trigger == .manual)
  try await Task.sleep(for: .milliseconds(1_500))  // session persistence is 1 s resolution
  let ended = try await client.send(.sessionEnd(session: session.id), expecting: Session.self)
  #expect(ended.state == .ended)

  let jobs = await collector.value
  for kind in ["transcribe", "cleanup", "summarize"] {
    #expect(jobs.contains { $0.kind == kind && $0.state == .started }, "missing \(kind) started")
    #expect(jobs.contains { $0.kind == kind && $0.state == .done }, "missing \(kind) done")
  }
  #expect(jobs.allSatisfy { $0.session == session.id })
  await watcher.close()
  await client.close()
}
```

(The `.timeLimit` kills the test if the events never arrive; the browser-triggered variant keeps covering artifacts-on-disk.)

- [ ] **Step 3: Run it**

Run: `cd daemon && swift test --filter OnEndChainSmokeTests`
Expected: PASS with Tasks 1+2 in place. If the manual test fails, debug the daemon change — do not weaken assertions.

- [ ] **Step 4: Format, lint, commit**

```bash
cd daemon && swift format --recursive -i Tests/ && swift format lint --recursive --strict Sources/ Tests/
git add -A && git commit -m "test(daemon): smoke-test manual-session on-end chain and its job events"
```

---

### Task 4: New targets + `MenuState` + snapshot/connection reduction

**Files:**
- Modify: `daemon/Package.swift`
- Create: `daemon/Sources/EarsMenuKit/MenuState.swift`
- Create: `daemon/Sources/EarsMenuKit/MenuStateReducer.swift`
- Create: `daemon/Sources/ears-menubar/MenuBarApp.swift` (placeholder `@main`)
- Test: `daemon/Tests/EarsMenuKitTests/MenuStateReducerTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionState`, `SessionInterval`, `SourceStatus`, `SourceRuntimeState`, `SourceID`, `Instant`, `SnapshotData`, `EventFrame`, `EarsEvent`, `JobPublishParams`, `JobState` — all from `EarsCore`. **First step: check `Sources/EarsCore/Models/Instant.swift` has a public `init(secondsSinceEpoch:)`; if the memberwise init is internal, add a public one to `EarsCore` as a separate tiny commit before proceeding.**
- Produces (used by every later task):

```swift
public enum ConnectionPhase: Sendable, Hashable { case connecting, connected, unreachable }

public struct MenuState: Sendable, Hashable {
  public var connection: ConnectionPhase   // starts .connecting
  public var daemon: String?               // hello.daemon, e.g. "earsd 0.1.0"
  public var sessions: [Session]           // live + recently ended, daemon-fed
  public var sources: [SourceStatus]
  public var jobs: [JobPublishParams]      // upserted by job id; .done removed, .failed retained
  public var lastRev: Int?
  public init()                            // empty state, .connecting
  public var activeSession: Session?       // first session in .active or .paused
  public var runningJobs: [JobPublishParams]
  public var failedJobs: [JobPublishParams]
}

public enum ReduceOutcome: Sendable, Hashable { case applied, ignoredStale, gap }

public enum MenuStateReducer {
  public static func connected(
    _ state: inout MenuState, daemon: String, bootChanged: Bool, snapshot: SnapshotData)
  public static func disconnected(_ state: inout MenuState)
  public static func apply(_ state: inout MenuState, _ frame: EventFrame) -> ReduceOutcome
  public static func dismissJob(_ state: inout MenuState, id: String)
}
```

- [ ] **Step 1: Add the targets to `Package.swift`**

Products: add `.executable(name: "ears-menubar", targets: ["ears-menubar"])`. Targets:

```swift
.target(
  name: "EarsMenuKit",
  dependencies: ["EarsCore"]
),
.executableTarget(
  name: "ears-menubar",
  dependencies: ["EarsMenuKit", "EarsCore", "EarsConfig", "EarsIPC", "EarsDataStore"]
),
.testTarget(
  name: "EarsMenuKitTests",
  dependencies: ["EarsMenuKit", "EarsCoreTestSupport"]
),
```

Create `Sources/ears-menubar/MenuBarApp.swift` as a compiling placeholder (replaced in Task 10):

```swift
/// Placeholder entry point; the real MenuBarExtra scene lands with the shell work.
@main
struct MenuBarApp {
  static func main() {
    print("ears-menubar: UI shell not wired yet")
  }
}
```

Run: `cd daemon && swift build` → builds.

- [ ] **Step 2: Write the failing snapshot/connection tests**

`Tests/EarsMenuKitTests/MenuStateReducerTests.swift`:

```swift
import EarsCore
import Testing

@testable import EarsMenuKit

func instant(_ seconds: Double) -> Instant { Instant(secondsSinceEpoch: seconds) }

func makeSession(
  id: String = "s1", title: String = "Weekly sync", state: SessionState = .active,
  started: Double = 1_000
) -> Session {
  Session(
    id: id, title: title, state: state, started: instant(started),
    intervals: [SessionInterval(start: instant(started))], sources: [SourceID("mic")])
}

func makeSnapshot(rev: Int = 41, sessions: [Session] = [], sources: [SourceStatus] = [])
  -> SnapshotData
{
  SnapshotData(rev: rev, sessions: sessions, sources: sources)
}

@Suite("MenuStateReducer: connection + snapshot")
struct ConnectionReductionTests {
  @Test("a fresh state is connecting and empty")
  func freshState() {
    let state = MenuState()
    #expect(state.connection == .connecting)
    #expect(state.sessions.isEmpty && state.jobs.isEmpty && state.lastRev == nil)
  }

  @Test("connected() installs the snapshot and daemon identity")
  func connectedInstallsSnapshot() {
    var state = MenuState()
    let session = makeSession()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(rev: 41, sessions: [session]))
    #expect(state.connection == .connected)
    #expect(state.daemon == "earsd 0.1.0")
    #expect(state.sessions == [session])
    #expect(state.lastRev == 41)
  }

  @Test("a boot change drops non-terminal jobs but keeps failures visible")
  func bootChangePrunesJobs() {
    var state = MenuState()
    state.jobs = [
      JobPublishParams(job: "a", kind: "transcribe", session: "s1", state: .running),
      JobPublishParams(job: "b", kind: "summarize", session: "s0", state: .failed),
    ]
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: true, snapshot: makeSnapshot())
    #expect(state.jobs.map(\.job) == ["b"])
  }

  @Test("disconnected() flips the phase and keeps last-known state for display")
  func disconnectedKeepsState() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(sessions: [makeSession()]))
    MenuStateReducer.disconnected(&state)
    #expect(state.connection == .unreachable)
    #expect(state.sessions.count == 1)
  }
}
```

- [ ] **Step 3: Run tests, verify they fail** (`swift test --filter EarsMenuKitTests` — types don't exist)

- [ ] **Step 4: Implement `MenuState.swift` and the two connection functions**

`MenuState.swift` — exactly the interface above:

```swift
import EarsCore

public enum ConnectionPhase: Sendable, Hashable {
  case connecting
  case connected
  case unreachable
}

/// The single immutable value everything renders from. Sessions/sources mirror
/// the daemon's revision-synced state; jobs are telemetry accumulated locally.
public struct MenuState: Sendable, Hashable {
  public var connection: ConnectionPhase
  public var daemon: String?
  public var sessions: [Session]
  public var sources: [SourceStatus]
  public var jobs: [JobPublishParams]
  public var lastRev: Int?

  public init() {
    connection = .connecting
    daemon = nil
    sessions = []
    sources = []
    jobs = []
    lastRev = nil
  }

  public var activeSession: Session? {
    sessions.first { $0.state == .active || $0.state == .paused }
  }
  public var runningJobs: [JobPublishParams] {
    jobs.filter { $0.state == .started || $0.state == .running }
  }
  public var failedJobs: [JobPublishParams] {
    jobs.filter { $0.state == .failed }
  }
}
```

`MenuStateReducer.swift` — `connected`/`disconnected` now; `apply`/`dismissJob` stubs are **not** added (they come test-first in Task 5):

```swift
import EarsCore

public enum ReduceOutcome: Sendable, Hashable {
  case applied
  case ignoredStale
  case gap
}

public enum MenuStateReducer {
  public static func connected(
    _ state: inout MenuState, daemon: String, bootChanged: Bool, snapshot: SnapshotData
  ) {
    state.connection = .connected
    state.daemon = daemon
    state.sessions = snapshot.sessions
    state.sources = snapshot.sources
    state.lastRev = snapshot.rev
    if bootChanged {
      state.jobs.removeAll { $0.state != .failed }
    }
  }

  public static func disconnected(_ state: inout MenuState) {
    state.connection = .unreachable
  }
}
```

- [ ] **Step 5: Run tests, verify they pass** (`swift test --filter EarsMenuKitTests`)

- [ ] **Step 6: Format, lint, commit**

```bash
cd daemon && swift format --recursive -i Sources/ Tests/ && swift format lint --recursive --strict Sources/ Tests/ && swift test
git add -A && git commit -m "feat(menubar): EarsMenuKit target with connection/snapshot state reduction"
```

---

### Task 5: Reducer — event application (rev rule, jobs, dismissal)

**Files:**
- Modify: `daemon/Sources/EarsMenuKit/MenuStateReducer.swift`
- Test: `daemon/Tests/EarsMenuKitTests/MenuStateReducerTests.swift`

**Interfaces:**
- Consumes: Task 4's types; `EventFrame(event:rev:)`, `EarsEvent.session/.source/.job/.vad/.segment`.
- Produces: `MenuStateReducer.apply(_:_:) -> ReduceOutcome` and `dismissJob(_:id:)` per the Task 4 interface block. Spec rule implemented here: state events apply iff `rev == lastRev + 1`; `rev <= lastRev` → `.ignoredStale`; anything else (including missing rev or no snapshot yet) → `.gap` (caller redials for a fresh snapshot).

- [ ] **Step 1: Write the failing tests**

Add a suite to `MenuStateReducerTests.swift`:

```swift
@Suite("MenuStateReducer: event application")
struct EventApplicationTests {
  func connectedState(rev: Int = 41, sessions: [Session] = [makeSession()]) -> MenuState {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(rev: rev, sessions: sessions))
    return state
  }

  @Test("an in-order session event upserts and advances lastRev")
  func inOrderSessionApplies() {
    var state = connectedState(rev: 41)
    var renamed = makeSession()
    renamed.title = "Renamed"
    renamed.rev = 42
    let outcome = MenuStateReducer.apply(&state, EventFrame(event: .session(renamed), rev: 42))
    #expect(outcome == .applied)
    #expect(state.sessions.map(\.title) == ["Renamed"])
    #expect(state.lastRev == 42)
  }

  @Test("an unseen session id appends")
  func unseenSessionAppends() {
    var state = connectedState(rev: 41)
    let other = makeSession(id: "s2", title: "Standup")
    let outcome = MenuStateReducer.apply(&state, EventFrame(event: .session(other), rev: 42))
    #expect(outcome == .applied)
    #expect(state.sessions.map(\.id) == ["s1", "s2"])
  }

  @Test("a stale state event is ignored without touching lastRev")
  func staleIgnored() {
    var state = connectedState(rev: 41)
    let old = makeSession(title: "Old title")
    let outcome = MenuStateReducer.apply(&state, EventFrame(event: .session(old), rev: 40))
    #expect(outcome == .ignoredStale)
    #expect(state.sessions.map(\.title) == ["Weekly sync"])
    #expect(state.lastRev == 41)
  }

  @Test("a rev gap demands resubscription and applies nothing")
  func gapDetected() {
    var state = connectedState(rev: 41)
    let outcome = MenuStateReducer.apply(
      &state, EventFrame(event: .session(makeSession()), rev: 43))
    #expect(outcome == .gap)
    #expect(state.lastRev == 41)
  }

  @Test("a source event updates the matching source's runtime state")
  func sourceEventApplies() {
    var state = connectedState(rev: 41)
    state.sources = [SourceStatus(id: SourceID("mic"), state: .capturing, codec: "opus")]
    let outcome = MenuStateReducer.apply(
      &state, EventFrame(event: .source(id: SourceID("mic"), state: .paused), rev: 42))
    #expect(outcome == .applied)
    #expect(state.sources.first?.state == .paused)
  }

  @Test("job telemetry upserts by id, never touches lastRev, and done removes the job")
  func jobLifecycle() {
    var state = connectedState(rev: 41)
    let started = JobPublishParams(job: "cleanup-1", kind: "cleanup", session: "s1", state: .started)
    #expect(MenuStateReducer.apply(&state, EventFrame(event: .job(started))) == .applied)
    #expect(state.jobs.map(\.job) == ["cleanup-1"])
    #expect(state.lastRev == 41)

    let done = JobPublishParams(job: "cleanup-1", kind: "cleanup", session: "s1", state: .done)
    #expect(MenuStateReducer.apply(&state, EventFrame(event: .job(done))) == .applied)
    #expect(state.jobs.isEmpty)
  }

  @Test("a failed job is retained until dismissed")
  func failedJobRetainedUntilDismissed() {
    var state = connectedState(rev: 41)
    let failed = JobPublishParams(job: "sum-1", kind: "summarize", session: "s1", state: .failed)
    _ = MenuStateReducer.apply(&state, EventFrame(event: .job(failed)))
    #expect(state.failedJobs.map(\.job) == ["sum-1"])
    MenuStateReducer.dismissJob(&state, id: "sum-1")
    #expect(state.jobs.isEmpty)
  }

  @Test("vad and segment telemetry are no-op applied")
  func otherTelemetryIgnored() {
    var state = connectedState(rev: 41)
    let outcome = MenuStateReducer.apply(
      &state,
      EventFrame(event: .vad(source: SourceID("mic"), state: .speech, t: instant(1_005))))
    #expect(outcome == .applied)
    #expect(state.lastRev == 41)
  }
}
```

- [ ] **Step 2: Run tests, verify they fail to compile** (`apply` doesn't exist)

- [ ] **Step 3: Implement `apply` and `dismissJob`**

Append to `MenuStateReducer`:

```swift
public static func apply(_ state: inout MenuState, _ frame: EventFrame) -> ReduceOutcome {
  switch frame.event {
  case .session(let session):
    return applyState(&state, rev: frame.rev) { $0.upsertSession(session) }
  case .source(let id, let runtimeState):
    return applyState(&state, rev: frame.rev) { $0.updateSource(id: id, to: runtimeState) }
  case .job(let params):
    upsertJob(&state, params)
    return .applied
  case .vad, .segment:
    return .applied
  }
}

public static func dismissJob(_ state: inout MenuState, id: String) {
  state.jobs.removeAll { $0.job == id }
}

private static func applyState(
  _ state: inout MenuState, rev: Int?, mutate: (inout MenuState) -> Void
) -> ReduceOutcome {
  guard let rev, let lastRev = state.lastRev else { return .gap }
  if rev <= lastRev { return .ignoredStale }
  guard rev == lastRev + 1 else { return .gap }
  mutate(&state)
  state.lastRev = rev
  return .applied
}

private static func upsertJob(_ state: inout MenuState, _ params: JobPublishParams) {
  if params.state == .done {
    state.jobs.removeAll { $0.job == params.job }
    return
  }
  if let index = state.jobs.firstIndex(where: { $0.job == params.job }) {
    state.jobs[index] = params
  } else {
    state.jobs.append(params)
  }
}
```

And in the same file, the private mutations:

```swift
extension MenuState {
  fileprivate mutating func upsertSession(_ session: Session) {
    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[index] = session
    } else {
      sessions.append(session)
    }
  }

  fileprivate mutating func updateSource(id: SourceID, to newState: SourceRuntimeState) {
    if let index = sources.firstIndex(where: { $0.id == id }) {
      sources[index].state = newState
    } else {
      sources.append(SourceStatus(id: id, state: newState, codec: ""))
    }
  }
}
```

If `MenuStateReducer.swift` nears 300 lines, move the `MenuState` extension into `MenuState.swift`.

- [ ] **Step 4: Run tests, verify pass** (`swift test --filter EarsMenuKitTests`)

- [ ] **Step 5: Format, lint, commit** — `feat(menubar): revision-synced event reduction for menu state`

---

### Task 6: Menu renderer — `MenuState → MenuContent`

**Files:**
- Create: `daemon/Sources/EarsMenuKit/MenuContent.swift`
- Create: `daemon/Sources/EarsMenuKit/MenuRenderer.swift`
- Create: `daemon/Sources/EarsMenuKit/ElapsedFormatter.swift`
- Test: `daemon/Tests/EarsMenuKitTests/MenuRendererTests.swift`

**Interfaces:**
- Consumes: `MenuState` (Task 4/5), `Instant.interval(since:)`.
- Produces:

```swift
public enum IconVariant: String, Sendable, Hashable { case idle, recording, paused, busy, attention }

public enum Verb: Sendable, Hashable {
  case startRecording
  case pause(session: String)
  case resume(session: String)
  case rename(session: String, currentTitle: String)
  case end(session: String)
}

public struct PipelineLine: Sendable, Hashable {
  public var text: String
  public var dismissibleJobID: String?   // non-nil → UI offers Dismiss
  public init(text: String, dismissibleJobID: String? = nil)
}

public struct MenuContent: Sendable, Hashable {
  public var icon: IconVariant
  public var header: String
  public var verbs: [Verb]
  public var pipeline: [PipelineLine]
  public init(icon: IconVariant, header: String, verbs: [Verb], pipeline: [PipelineLine])
}

public enum MenuRenderer {
  public static func render(_ state: MenuState, now: Instant) -> MenuContent
  static func stageLabel(_ kind: String) -> String   // "Transcription"/"Cleanup"/"Summary", internal — NotificationPolicy reuses it
}

public enum ElapsedFormatter {
  public static func clock(_ seconds: Double) -> String            // 723 → "12:03"; 3_723 → "1:02:03"
  public static func compactDuration(_ seconds: Double) -> String  // 11_520 → "3h 12m"
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("MenuRenderer")
struct MenuRendererTests {
  func state(
    _ phase: ConnectionPhase = .connected, sessions: [Session] = [],
    jobs: [JobPublishParams] = []
  ) -> MenuState {
    var state = MenuState()
    if phase != .connecting {
      MenuStateReducer.connected(
        &state, daemon: "earsd 0.1.0", bootChanged: false,
        snapshot: makeSnapshot(rev: 41, sessions: sessions))
    }
    if phase == .unreachable { MenuStateReducer.disconnected(&state) }
    state.jobs = jobs
    return state
  }

  @Test("recording header carries the mark, title, and elapsed clock")
  func recordingHeader() {
    let content = MenuRenderer.render(
      state(sessions: [makeSession(started: 1_000)]), now: instant(1_723))
    #expect(content.header == "● Recording · Weekly sync · 12:03")
    #expect(content.icon == .recording)
    #expect(content.verbs == [
      .pause(session: "s1"), .rename(session: "s1", currentTitle: "Weekly sync"),
      .end(session: "s1"),
    ])
  }

  @Test("a paused session renders the paused mark, icon, and resume verb")
  func pausedHeader() {
    let content = MenuRenderer.render(
      state(sessions: [makeSession(state: .paused, started: 1_000)]), now: instant(1_063))
    #expect(content.header == "⏸ Paused · Weekly sync · 1:03")
    #expect(content.icon == .paused)
    #expect(content.verbs.first == .resume(session: "s1"))
  }

  @Test("idle shows only Start Recording")
  func idleContent() {
    let content = MenuRenderer.render(state(), now: instant(0))
    #expect(content.header == "Idle")
    #expect(content.icon == .idle)
    #expect(content.verbs == [.startRecording])
  }

  @Test("an unreachable daemon shows attention and no verbs")
  func unreachableContent() {
    let content = MenuRenderer.render(state(.unreachable), now: instant(0))
    #expect(content.header == "⚠ Daemon not running")
    #expect(content.icon == .attention)
    #expect(content.verbs.isEmpty)
  }

  @Test("connecting is idle-iconed with a connecting header")
  func connectingContent() {
    let content = MenuRenderer.render(state(.connecting), now: instant(0))
    #expect(content.header == "Connecting to earsd…")
    #expect(content.icon == .idle)
  }

  @Test("running jobs render busy lines titled by their session")
  func pipelineLines() {
    let jobs = [
      JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .running)
    ]
    let content = MenuRenderer.render(
      state(sessions: [makeSession(state: .ended)], jobs: jobs), now: instant(0))
    #expect(content.icon == .busy)
    #expect(content.pipeline == [PipelineLine(text: "Transcribing ‘Weekly sync’…")])
  }

  @Test("a failed job renders a dismissible attention line and wins the icon")
  func failedJobLine() {
    let jobs = [
      JobPublishParams(job: "sum-1", kind: "summarize", session: "s1", state: .failed)
    ]
    let content = MenuRenderer.render(
      state(sessions: [makeSession(state: .ended)], jobs: jobs), now: instant(0))
    #expect(content.icon == .attention)
    #expect(content.pipeline == [
      PipelineLine(text: "⚠ Summary failed — Weekly sync", dismissibleJobID: "sum-1")
    ])
  }

  @Test("recording outranks a failed job for the icon")
  func recordingOutranksAttention() {
    let jobs = [
      JobPublishParams(job: "sum-1", kind: "summarize", session: "s0", state: .failed)
    ]
    let content = MenuRenderer.render(
      state(sessions: [makeSession()], jobs: jobs), now: instant(1_001))
    #expect(content.icon == .recording)
  }
}

@Suite("ElapsedFormatter")
struct ElapsedFormatterTests {
  @Test("clock renders m:ss below an hour and h:mm:ss above")
  func clockFormats() {
    #expect(ElapsedFormatter.clock(63) == "1:03")
    #expect(ElapsedFormatter.clock(723) == "12:03")
    #expect(ElapsedFormatter.clock(3_723) == "1:02:03")
    #expect(ElapsedFormatter.clock(-5) == "0:00")
  }

  @Test("compactDuration picks a humane unit")
  func compactFormats() {
    #expect(ElapsedFormatter.compactDuration(42) == "42s")
    #expect(ElapsedFormatter.compactDuration(180) == "3m")
    #expect(ElapsedFormatter.compactDuration(11_520) == "3h 12m")
    #expect(ElapsedFormatter.compactDuration(90_000) == "1d 1h")
  }
}
```

- [ ] **Step 2: Run tests, verify they fail to compile**

- [ ] **Step 3: Implement**

`ElapsedFormatter.swift`:

```swift
public enum ElapsedFormatter {
  public static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
  }

  public static func compactDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)s" }
    if total < 3_600 { return "\(total / 60)m" }
    if total < 86_400 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
    return "\(total / 86_400)d \((total % 86_400) / 3_600)h"
  }
}
```

`MenuContent.swift`: the four public types from the interface block, memberwise public inits.

`MenuRenderer.swift`:

```swift
import EarsCore

public enum MenuRenderer {
  public static func render(_ state: MenuState, now: Instant) -> MenuContent {
    MenuContent(
      icon: icon(for: state), header: header(for: state, now: now),
      verbs: verbs(for: state), pipeline: pipeline(for: state))
  }

  static func icon(for state: MenuState) -> IconVariant {
    if state.connection == .unreachable { return .attention }
    if let active = state.activeSession {
      return active.state == .paused ? .paused : .recording
    }
    if !state.failedJobs.isEmpty { return .attention }
    if !state.runningJobs.isEmpty { return .busy }
    return .idle
  }

  static func header(for state: MenuState, now: Instant) -> String {
    switch state.connection {
    case .connecting: return "Connecting to earsd…"
    case .unreachable: return "⚠ Daemon not running"
    case .connected: break
    }
    guard let session = state.activeSession else { return "Idle" }
    let elapsed = ElapsedFormatter.clock(now.interval(since: session.started))
    let mark = session.state == .paused ? "⏸ Paused" : "● Recording"
    return "\(mark) · \(session.title) · \(elapsed)"
  }

  static func verbs(for state: MenuState) -> [Verb] {
    guard state.connection == .connected else { return [] }
    guard let session = state.activeSession else { return [.startRecording] }
    let toggle: Verb =
      session.state == .paused ? .resume(session: session.id) : .pause(session: session.id)
    return [toggle, .rename(session: session.id, currentTitle: session.title), .end(session: session.id)]
  }

  static func pipeline(for state: MenuState) -> [PipelineLine] {
    state.jobs.map { job in
      let title = state.sessions.first { $0.id == job.session }?.title
        ?? job.session.map { String($0.prefix(8)) } ?? "session"
      switch job.state {
      case .started, .running:
        return PipelineLine(text: "\(progressLabel(job.kind)) ‘\(title)’…")
      case .failed:
        return PipelineLine(
          text: "⚠ \(stageLabel(job.kind)) failed — \(title)", dismissibleJobID: job.job)
      case .done:
        return PipelineLine(text: "\(stageLabel(job.kind)) done — \(title)")
      }
    }
  }

  static func progressLabel(_ kind: String) -> String {
    switch kind {
    case "transcribe": return "Transcribing"
    case "cleanup": return "Cleaning up"
    case "summarize": return "Summarizing"
    default: return kind
    }
  }

  static func stageLabel(_ kind: String) -> String {
    switch kind {
    case "transcribe": return "Transcription"
    case "cleanup": return "Cleanup"
    case "summarize": return "Summary"
    default: return kind
    }
  }
}
```

(If `Instant.interval(since:)` has a different argument order than `now.interval(since: session.started)` expects, adapt at the call site — the tests pin the correct arithmetic: 1_723 − 1_000 = 723 s = "12:03".)

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Format, lint, commit** — `feat(menubar): pure menu renderer with icon/header/verb/pipeline content`

---

### Task 7: Notification policy

**Files:**
- Create: `daemon/Sources/EarsMenuKit/NotificationPolicy.swift`
- Test: `daemon/Tests/EarsMenuKitTests/NotificationPolicyTests.swift`

**Interfaces:**
- Consumes: `MenuState`, `EventFrame`, `MenuRenderer.stageLabel` (internal, same module).
- Produces:

```swift
public struct NotificationRequest: Sendable, Hashable {
  public enum Action: Sendable, Hashable {
    case openSummary(session: String)
    case revealSession(session: String)
    case none
  }
  public var title: String
  public var body: String
  public var action: Action
  public init(title: String, body: String, action: Action)
}

public enum NotificationPolicy {
  /// Call with the state AFTER the reducer applied `frame` (titles resolve from it).
  public static func onEvent(_ frame: EventFrame, state: MenuState) -> NotificationRequest?
  public static func onDisconnect(state: MenuState) -> NotificationRequest?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite("NotificationPolicy")
struct NotificationPolicyTests {
  func stateWithEndedSession() -> MenuState {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(rev: 41, sessions: [makeSession(state: .ended)]))
    return state
  }

  @Test("summarize done notifies summary-ready with an open action")
  func summarizeDoneNotifies() {
    let frame = EventFrame(
      event: .job(JobPublishParams(job: "sum-1", kind: "summarize", session: "s1", state: .done)))
    let request = NotificationPolicy.onEvent(frame, state: stateWithEndedSession())
    #expect(request == NotificationRequest(
      title: "Summary ready", body: "Weekly sync", action: .openSummary(session: "s1")))
  }

  @Test("any failed stage notifies with a reveal action")
  func failureNotifies() {
    let frame = EventFrame(
      event: .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .failed)))
    let request = NotificationPolicy.onEvent(frame, state: stateWithEndedSession())
    #expect(request == NotificationRequest(
      title: "Transcription failed", body: "Weekly sync", action: .revealSession(session: "s1")))
  }

  @Test("the quiet cases stay quiet")
  func quietCases() {
    let state = stateWithEndedSession()
    let quiet: [EarsEvent] = [
      .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .started)),
      .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .done)),
      .job(JobPublishParams(job: "c-1", kind: "cleanup", session: "s1", state: .done)),
      .session(makeSession()),
      .source(id: SourceID("mic"), state: .paused),
    ]
    for event in quiet {
      #expect(NotificationPolicy.onEvent(EventFrame(event: event, rev: 42), state: state) == nil)
    }
  }

  @Test("disconnect during an active session warns; while idle it does not")
  func disconnectPolicy() {
    var recording = MenuState()
    MenuStateReducer.connected(
      &recording, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(rev: 41, sessions: [makeSession()]))
    #expect(NotificationPolicy.onDisconnect(state: recording) == NotificationRequest(
      title: "Recording at risk",
      body: "earsd stopped while ‘Weekly sync’ was recording.", action: .none))
    #expect(NotificationPolicy.onDisconnect(state: stateWithEndedSession()) == nil)
  }
}
```

- [ ] **Step 2: Run tests, verify they fail to compile**

- [ ] **Step 3: Implement**

```swift
import EarsCore

public enum NotificationPolicy {
  public static func onEvent(_ frame: EventFrame, state: MenuState) -> NotificationRequest? {
    guard case .job(let job) = frame.event else { return nil }
    let title = sessionTitle(job.session, in: state)
    switch (job.kind, job.state) {
    case ("summarize", .done):
      return NotificationRequest(
        title: "Summary ready", body: title,
        action: job.session.map { .openSummary(session: $0) } ?? .none)
    case (_, .failed):
      return NotificationRequest(
        title: "\(MenuRenderer.stageLabel(job.kind)) failed", body: title,
        action: job.session.map { .revealSession(session: $0) } ?? .none)
    default:
      return nil
    }
  }

  public static func onDisconnect(state: MenuState) -> NotificationRequest? {
    guard let session = state.activeSession else { return nil }
    return NotificationRequest(
      title: "Recording at risk",
      body: "earsd stopped while ‘\(session.title)’ was recording.", action: .none)
  }

  private static func sessionTitle(_ id: String?, in state: MenuState) -> String {
    guard let id else { return "session" }
    return state.sessions.first { $0.id == id }?.title ?? String(id.prefix(8))
  }
}
```

Plus `NotificationRequest` as in the interface block (same file).

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Format, lint, commit** — `feat(menubar): notification policy for results, failures, and at-risk recordings`

---

### Task 8: Artifact locator, recent-session selection, reconnect backoff

**Files:**
- Create: `daemon/Sources/EarsMenuKit/SessionArtifacts.swift`
- Create: `daemon/Sources/EarsMenuKit/ReconnectBackoff.swift`
- Test: `daemon/Tests/EarsMenuKitTests/SessionArtifactsTests.swift`
- Test: `daemon/Tests/EarsMenuKitTests/ReconnectBackoffTests.swift`

**Interfaces:**
- Consumes: `FilenameTimestampCodec.string(for:)` (`EarsCore/Timestamps/FilenameTimestampCodec.swift` — ISO-8601 with `:` → `-`, e.g. `2026-07-17T10-30-00Z`). Path recipe mirrors `transcribe`'s `OutputPathResolution` (`Sources/transcribe/OutputPathResolution.swift:32-59`): day dir + `<time>_<sessionID>` prefix; `.transcript.md` / `.clean.md` / `[.<preset>].summary.md` suffixes.
- Produces:

```swift
public struct SessionArtifactKey: Sendable, Hashable {
  public var day: String         // "2026-07-17"
  public var filePrefix: String  // "10-30-00_<session-id>"
  public init(day: String, filePrefix: String)
}

public struct SessionArtifacts: Sendable, Hashable {
  public var transcript: String?
  public var clean: String?
  public var summaries: [String]
  public init(transcript: String? = nil, clean: String? = nil, summaries: [String] = [])
}

public enum SessionArtifactLocator {
  public static func key(for session: Session) -> SessionArtifactKey?          // nil if no non-empty interval
  public static func classify(filenames: [String], key: SessionArtifactKey) -> SessionArtifacts
}

public enum RecentSessions {
  public static func select(from sessions: [Session], limit: Int = 7) -> [Session]  // ended only, newest first
}

public enum ReconnectBackoff {
  public static func delay(attempt: Int) -> Duration   // 1,2,4,8 then 15s cap
}
```

- [ ] **Step 1: Write the failing tests**

`SessionArtifactsTests.swift`:

```swift
import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("SessionArtifactLocator")
struct SessionArtifactLocatorTests {
  func endedSession(id: String = "0d5e7f6a") -> Session {
    // 2026-07-17T10:30:00Z == 1_784_284_200 — verify with
    // `TZ=UTC date -j -f %Y-%m-%dT%H:%M:%SZ 2026-07-17T10:30:00Z +%s` and inline the value.
    let start = instant(1_784_284_200)
    return Session(
      id: id, title: "standup", state: .ended, started: start,
      ended: start.advanced(by: 600),
      intervals: [SessionInterval(start: start, end: start.advanced(by: 600))])
  }

  @Test("the key mirrors transcribe's day directory and time_slug prefix")
  func keyMatchesTranscribeLayout() {
    let key = SessionArtifactLocator.key(for: endedSession())
    #expect(key == SessionArtifactKey(day: "2026-07-17", filePrefix: "10-30-00_0d5e7f6a"))
  }

  @Test("a session with no non-empty interval has no key")
  func emptyIntervalsNoKey() {
    var session = endedSession()
    session.intervals = []
    #expect(SessionArtifactLocator.key(for: session) == nil)
  }

  @Test("classify picks transcript, clean, and every summary; ignores sidecars and strangers")
  func classifyFilenames() {
    let key = SessionArtifactKey(day: "2026-07-17", filePrefix: "10-30-00_0d5e7f6a")
    let artifacts = SessionArtifactLocator.classify(
      filenames: [
        "10-30-00_0d5e7f6a.transcript.md",
        "10-30-00_0d5e7f6a.transcript.json",
        "10-30-00_0d5e7f6a.clean.md",
        "10-30-00_0d5e7f6a.brief.summary.md",
        "10-30-00_0d5e7f6a.decisions.summary.md",
        "10-30-00_0d5e7f6a.summary.json",
        "09-00-00_other.transcript.md",
      ],
      key: key)
    #expect(artifacts.transcript == "10-30-00_0d5e7f6a.transcript.md")
    #expect(artifacts.clean == "10-30-00_0d5e7f6a.clean.md")
    #expect(artifacts.summaries == [
      "10-30-00_0d5e7f6a.brief.summary.md", "10-30-00_0d5e7f6a.decisions.summary.md",
    ])
  }
}

@Suite("RecentSessions")
struct RecentSessionsTests {
  @Test("select keeps ended sessions, newest first, capped")
  func selectsEndedNewestFirst() {
    let sessions = [
      makeSession(id: "live", state: .active, started: 5_000),
      makeSession(id: "old", state: .ended, started: 1_000),
      makeSession(id: "new", state: .ended, started: 3_000),
      makeSession(id: "mid", state: .ended, started: 2_000),
    ]
    #expect(RecentSessions.select(from: sessions, limit: 2).map(\.id) == ["new", "mid"])
  }
}
```

`ReconnectBackoffTests.swift`:

```swift
import Testing

@testable import EarsMenuKit

@Suite("ReconnectBackoff")
struct ReconnectBackoffTests {
  @Test("delays double from 1s and cap at 15s")
  func schedule() {
    #expect((0...5).map { ReconnectBackoff.delay(attempt: $0) } == [
      .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15),
    ])
  }
}
```

Before finalizing the epoch literal, compute it: `TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-07-17T10:30:00Z" +%s`. If it differs from `1_784_284_200`, use the computed value in both the fixture and this plan's expectation (the *string* expectations `"2026-07-17"` / `"10-30-00"` are what matter).

- [ ] **Step 2: Run tests, verify they fail to compile**

- [ ] **Step 3: Implement**

`SessionArtifacts.swift`:

```swift
import EarsCore

// … the three types from the interface block, then:

public enum SessionArtifactLocator {
  /// Mirrors transcribe's OutputPathResolution for session runs: the timestamp
  /// comes from the first non-empty interval's start and the slug is the
  /// session id. Keep in lockstep with Sources/transcribe/OutputPathResolution.swift.
  public static func key(for session: Session) -> SessionArtifactKey? {
    guard let start = firstNonEmptyIntervalStart(session) else { return nil }
    let timestamp = FilenameTimestampCodec.string(for: start)  // "2026-07-17T10-30-00Z"
    let parts = timestamp.split(separator: "T", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return SessionArtifactKey(
      day: String(parts[0]),
      filePrefix: "\(String(parts[1].dropLast()))_\(session.id)")
  }

  public static func classify(filenames: [String], key: SessionArtifactKey) -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    for name in filenames.sorted() where name.hasPrefix(key.filePrefix) {
      if name == "\(key.filePrefix).transcript.md" {
        artifacts.transcript = name
      } else if name == "\(key.filePrefix).clean.md" {
        artifacts.clean = name
      } else if name.hasSuffix(".summary.md") {
        artifacts.summaries.append(name)
      }
    }
    return artifacts
  }

  private static func firstNonEmptyIntervalStart(_ session: Session) -> Instant? {
    for interval in session.intervals {
      guard let end = interval.end ?? session.ended else { continue }
      if interval.start < end { return interval.start }
    }
    return nil
  }
}

public enum RecentSessions {
  public static func select(from sessions: [Session], limit: Int = 7) -> [Session] {
    Array(
      sessions.filter { $0.state == .ended }
        .sorted { $0.started > $1.started }
        .prefix(limit))
  }
}
```

`ReconnectBackoff.swift`:

```swift
public enum ReconnectBackoff {
  public static func delay(attempt: Int) -> Duration {
    let clamped = min(max(attempt, 0), 3)
    let seconds = attempt > 3 ? 15 : 1 << clamped
    return .seconds(seconds)
  }
}
```

(`Instant.advanced(by:)` exists per `Models/Instant.swift`; if `Session.started` comparison needs it, `Instant` is `Comparable`.)

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Format, lint, commit** — `feat(menubar): artifact locator, recent-session selection, reconnect backoff`

---

### Task 9: Shell — config resolution + `DaemonConnection` actor

**Files:**
- Create: `daemon/Sources/ears-menubar/ClientConfig.swift`
- Create: `daemon/Sources/ears-menubar/DaemonConnection.swift`

**Interfaces:**
- Consumes: `loadConfig` / `ConfigLoadInputs` (`EarsConfig/ConfigLoader.swift:73`), `DefaultSocketPath.resolve(dataRoot:)` / `.lengthError(forPath:)` (`EarsConfig/DefaultSocketPath.swift`), `ConfigValue` (`.table`/`.string` cases), `ControlSocketClient` (`EarsIPC`), `ReconnectBackoff` (Task 8). Copy the resolution pattern from `Sources/ears/ControlClientRuntime.swift:82-117` — that code is internal to the `ears` target, so reimplement (do not move it).
- Produces (consumed by Task 10's `AppModel`):

```swift
struct ClientConfig: Sendable {
  var socketPath: String
  var dataRoot: String    // for SessionStore reads + reveal-in-Finder
  var outputRoot: String  // for artifact URLs
  static func resolve() -> Result<ClientConfig, String>
}

actor DaemonConnection {
  enum Event: Sendable {
    case ready(daemon: String, bootChanged: Bool, snapshot: SnapshotData)
    case event(EventFrame)
    case down
  }
  init(socketPath: String)
  nonisolated var events: AsyncStream<Event> { get }
  func run() async                                  // forever: dial → hello → subscribe → pump; backoff on failure
  func bounce() async                               // force redial (rev gap / user retry)
  func perform(_ call: ControlCall) async -> WireError?
  func status() async -> StatusData?
}
```

This is tier-2 I/O glue (`docs/engineering-practices.md`): no unit-test target; the pure parts it leans on (backoff, reducer) are already tested. Verified live in Task 10.

- [ ] **Step 1: Implement `ClientConfig.swift`**

```swift
import EarsConfig
import EarsCore
import Foundation

/// Resolves the same config layers every tool honors: defaults → TOML →
/// EARS_* env. Mirrors ears' ControlClientRuntime (internal there).
struct ClientConfig: Sendable {
  var socketPath: String
  var dataRoot: String
  var outputRoot: String

  static func resolve() -> Result<ClientConfig, String> {
    let inputs = ConfigLoadInputs(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    switch loadConfig(inputs) {
    case .failure(let error):
      return .failure("config load failed: \(error)")
    case .success(let loaded):
      let dataRoot = string(loaded.value, "data_root")
      let configured = string(loaded.value, "socket_path")
      let socketPath =
        configured.isEmpty ? DefaultSocketPath.resolve(dataRoot: dataRoot) : configured
      if let message = DefaultSocketPath.lengthError(forPath: socketPath) {
        return .failure(message)
      }
      return .success(
        ClientConfig(
          socketPath: socketPath, dataRoot: dataRoot,
          outputRoot: string(loaded.value, "output_root")))
    }
  }

  private static func string(_ value: ConfigValue, _ key: String) -> String {
    guard case .table(let table) = value, let entry = table[key],
      case .string(let text) = entry
    else { return "" }
    return text
  }
}
```

(If `ConfigValue` lives in `EarsCore` under a different access path, follow how `ears/ControlClientRuntime.swift` names it.)

- [ ] **Step 2: Implement `DaemonConnection.swift`**

```swift
import EarsCore
import EarsIPC
import EarsMenuKit

/// Owns the socket client lifecycle. One generation per dial; a bounce or a
/// dropped stream invalidates the generation so stale loops exit silently.
actor DaemonConnection {
  enum Event: Sendable {
    case ready(daemon: String, bootChanged: Bool, snapshot: SnapshotData)
    case event(EventFrame)
    case down
  }

  private let socketPath: String
  private let stream: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private var client: ControlSocketClient?
  private var lastBootID: String?
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
      do {
        let dialled = try await ControlSocketClient.connect(toPath: socketPath)
        let hello = try await dialled.hello(client: "menubar/0.1.0")
        let (snapshot, frames) = try await dialled.subscribe(SubscribeParams(events: [.job]))
        client = dialled
        attempt = 0
        let bootChanged = lastBootID != nil && lastBootID != hello.bootID
        lastBootID = hello.bootID
        continuation.yield(
          .ready(daemon: hello.daemon, bootChanged: bootChanged, snapshot: snapshot))
        for await frame in frames {
          guard generation == mine else { break }
          continuation.yield(.event(frame))
        }
      } catch {
        // fall through to the shared teardown below
      }
      if generation == mine {
        client = nil
        continuation.yield(.down)
      }
      attempt += 1
      try? await Task.sleep(for: ReconnectBackoff.delay(attempt: attempt - 1))
    }
  }

  func bounce() async {
    generation += 1
    await client?.close()
    client = nil
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
```

Notes that matter: `subscribe` may be called only once per `ControlSocketClient` (a second call strands the first stream — `ControlSocketClient.swift:73`), which is why a rev gap is handled by `bounce()` + redial, never by re-subscribing. `perform` decodes every result as `EmptyData` deliberately — a decodable struct with no properties accepts any result object, and real state arrives via events.

- [ ] **Step 3: Build**

Run: `cd daemon && swift build`
Expected: builds clean under strict concurrency (no `@unchecked`, no `@MainActor` here).

- [ ] **Step 4: Format, lint, commit** — `feat(menubar): daemon connection actor and config resolution for the shell`

---

### Task 10: Shell — `AppModel`, `MenuBarExtra` scene, verbs

**Files:**
- Modify: `daemon/Sources/ears-menubar/MenuBarApp.swift` (replace placeholder)
- Create: `daemon/Sources/ears-menubar/AppModel.swift`
- Create: `daemon/Sources/ears-menubar/MenuContentView.swift`

**Interfaces:**
- Consumes: everything above; SwiftUI `MenuBarExtra` (`.menuBarExtraStyle(.menu)`), `@Observable`.
- Produces:

```swift
@MainActor @Observable final class AppModel {
  private(set) var content: MenuContent
  private(set) var recents: [RecentSessionItem]     // filled in Task 11; [] until then
  private(set) var uptimeSeconds: Int?
  var configError: String?                          // non-nil → header shows it, no connection
  init(config: ClientConfig)
  init(configError: String)
  func start()                                      // spawns run + pump tasks, bootstraps notifier (Task 12)
  func perform(_ verb: Verb)
  func startRecording()
  func dismiss(jobID: String)
  func menuWillOpen()                               // rerender clock, refresh recents + uptime
  func restartDaemon()                              // Task 13
}

struct RecentSessionItem: Identifiable, Hashable, Sendable {
  var session: Session
  var transcript: URL?
  var clean: URL?
  var summaries: [URL]
  var id: String { session.id }
}
```

- [ ] **Step 1: Implement `AppModel.swift`**

```swift
import AppKit
import EarsCore
import EarsMenuKit
import Foundation
import Observation

/// One ended session plus its located output files (Task 11 fills these in;
/// until then every AppModel leaves `recents` empty).
struct RecentSessionItem: Identifiable, Hashable, Sendable {
  var session: Session
  var transcript: URL?
  var clean: URL?
  var summaries: [URL]
  var id: String { session.id }
}

@MainActor @Observable final class AppModel {
  private(set) var state = MenuState()
  private(set) var content = MenuContent(
    icon: .idle, header: "Connecting to earsd…", verbs: [], pipeline: [])
  private(set) var recents: [RecentSessionItem] = []
  private(set) var uptimeSeconds: Int?
  let configError: String?
  let dataRoot: String
  let outputRoot: String

  private let connection: DaemonConnection?

  init(config: ClientConfig) {
    configError = nil
    dataRoot = config.dataRoot
    outputRoot = config.outputRoot
    connection = DaemonConnection(socketPath: config.socketPath)
  }

  init(configError message: String) {
    configError = message
    dataRoot = ""
    outputRoot = ""
    connection = nil
    content = MenuContent(icon: .attention, header: "⚠ \(message)", verbs: [], pipeline: [])
  }

  func start() {
    guard let connection else { return }
    Task { await connection.run() }
    Task { await pump(connection) }
  }

  private func pump(_ connection: DaemonConnection) async {
    for await event in connection.events {
      switch event {
      case .ready(let daemon, let bootChanged, let snapshot):
        MenuStateReducer.connected(
          &state, daemon: daemon, bootChanged: bootChanged, snapshot: snapshot)
      case .event(let frame):
        switch MenuStateReducer.apply(&state, frame) {
        case .gap:
          await connection.bounce()
        case .applied:
          handleApplied(frame)
        case .ignoredStale:
          break
        }
      case .down:
        if let request = NotificationPolicy.onDisconnect(state: state) {
          post(request)
        }
        MenuStateReducer.disconnected(&state)
      }
      rerender()
    }
  }

  /// Notifier lands in Task 12; until then applied frames only trigger rerenders.
  private func handleApplied(_ frame: EventFrame) {
    if let request = NotificationPolicy.onEvent(frame, state: state) {
      post(request)
    }
  }

  private func post(_ request: NotificationRequest) {
    // Replaced by the Notifier in Task 12.
  }

  func rerender() {
    content = MenuRenderer.render(
      state, now: Instant(secondsSinceEpoch: Date().timeIntervalSince1970))
  }

  func perform(_ verb: Verb) {
    guard let connection else { return }
    let call: ControlCall
    switch verb {
    case .startRecording:
      startRecording()
      return
    case .pause(let session): call = .sessionPause(session: session)
    case .resume(let session): call = .sessionResume(session: session)
    case .end(let session): call = .sessionEnd(session: session)
    case .rename(let session, let currentTitle):
      promptRename(session: session, currentTitle: currentTitle)
      return
    }
    Task { _ = await connection.perform(call) }
  }

  func startRecording() {
    guard let connection else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let title = "Recording \(formatter.string(from: Date()))"
    Task {
      _ = await connection.perform(
        .sessionStart(SessionStartParams(title: title, sources: [SourceID("mic")])))
    }
  }

  func dismiss(jobID: String) {
    MenuStateReducer.dismissJob(&state, id: jobID)
    rerender()
  }

  func menuWillOpen() {
    rerender()
    guard let connection else { return }
    Task {
      uptimeSeconds = await connection.status()?.uptimeSeconds
    }
  }

  private func promptRename(session: String, currentTitle: String) {
    // NSAlert with an accessory NSTextField; LSUIElement apps must activate first.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Rename Session"
    let field = NSTextField(string: currentTitle)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn, let connection else { return }
    let title = field.stringValue
    guard !title.isEmpty else { return }
    Task {
      _ = await connection.perform(
        .sessionRename(SessionRenameParams(session: session, title: title)))
    }
  }
}
```

(Add `import AppKit`. `ControlCall` comes from `EarsCore` — same import as the params types.)

- [ ] **Step 2: Implement `MenuContentView.swift`**

```swift
import EarsMenuKit
import SwiftUI

struct MenuContentView: View {
  let model: AppModel

  var body: some View {
    Text(model.content.header)
    ForEach(model.content.verbs, id: \.self) { verb in
      Button(label(for: verb)) { model.perform(verb) }
    }
    if !model.content.pipeline.isEmpty {
      Divider()
      ForEach(model.content.pipeline, id: \.self) { line in
        if let jobID = line.dismissibleJobID {
          Menu(line.text) {
            Button("Dismiss") { model.dismiss(jobID: jobID) }
          }
        } else {
          Text(line.text)
        }
      }
    }
    Divider()
    // Recent Sessions + Daemon submenus land in Tasks 11/13.
    Button("Quit All Ears") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func label(for verb: Verb) -> String {
    switch verb {
    case .startRecording: return "Start Recording"
    case .pause: return "Pause"
    case .resume: return "Resume"
    case .rename: return "Rename Session…"
    case .end: return "End Session"
    }
  }
}

struct MenuBarLabel: View {
  let variant: IconVariant

  var body: some View {
    Image(systemName: variant.systemImage)
      .opacity(variant == .paused ? 0.55 : 1)
  }
}

extension IconVariant {
  var systemImage: String {
    switch self {
    case .idle: return "ear"
    case .recording: return "ear.and.waveform"
    case .paused: return "ear.and.waveform"
    case .busy: return "ear.badge.checkmark"
    case .attention: return "ear.trianglebadge.exclamationmark"
    }
  }
}
```

- [ ] **Step 3: Replace `MenuBarApp.swift`**

```swift
import SwiftUI

@main
struct MenuBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model: AppModel

  init() {
    switch ClientConfig.resolve() {
    case .success(let config):
      let model = AppModel(config: config)
      _model = State(initialValue: model)
      model.start()
    case .failure(let message):
      _model = State(initialValue: AppModel(configError: message))
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(model: model)
        .onAppear { model.menuWillOpen() }
    } label: {
      MenuBarLabel(variant: model.content.icon)
    }
    .menuBarExtraStyle(.menu)
  }
}

/// Keeps dev runs (`swift run ears-menubar`, no bundle) out of the Dock.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
```

- [ ] **Step 4: Build + live verification (tier 2, manual)**

Run: `cd daemon && swift build && swift run ears-menubar` with the real daemon running (`make status` to confirm).
Checklist — verify each, then quit with the menu's own Quit item:
1. Ear icon appears in the menu bar; menu opens with "Idle" and "Start Recording" (daemon idle).
2. Start Recording → icon flips to `ear.and.waveform`, header shows "● Recording · Recording <date> · m:ss"; Pause → paused opacity + "⏸ Paused"; Resume; Rename → dialog renames (visible next menu open); End Session → job lines appear ("Transcribing …", then gone as stages finish).
3. `launchctl bootout gui/$UID/net.tomelliot.ears.earsd` → icon flips to attention, header "⚠ Daemon not running"; `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/net.tomelliot.ears.earsd.plist` → reconnects within ~15 s.
4. If any SF Symbol renders blank, substitute (`ear.fill` for busy is the fallback) and note it in the commit body.

- [ ] **Step 5: Format, lint, full test run, commit** — `feat(menubar): MenuBarExtra shell with live state and session verbs`

---

### Task 11: Shell — Recent Sessions submenu + open actions

**Files:**
- Create: `daemon/Sources/ears-menubar/RecentSessionsProvider.swift`
- Modify: `daemon/Sources/ears-menubar/AppModel.swift` (refreshRecents)
- Modify: `daemon/Sources/ears-menubar/MenuContentView.swift` (submenu)

**Interfaces:**
- Consumes: `SessionStore.readAll(dataRoot:onSkip:)` (`EarsDataStore/SessionStore.swift:40`), `RecentSessions.select`, `SessionArtifactLocator` (Task 8), `RecentSessionItem` (Task 10 interface block).
- Produces: `struct RecentSessionsProvider: Sendable { init(dataRoot: String, outputRoot: String); func load(limit: Int = 7) -> [RecentSessionItem] }`.

- [ ] **Step 1: Implement the provider**

```swift
import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation

/// Read-only bridge from the on-disk stores to menu items. Never writes —
/// earsd stays the only writer.
struct RecentSessionsProvider: Sendable {
  var dataRoot: String
  var outputRoot: String

  func load(limit: Int = 7) -> [RecentSessionItem] {
    let all = SessionStore.readAll(dataRoot: URL(fileURLWithPath: dataRoot))
    return RecentSessions.select(from: all, limit: limit).map { session in
      guard let key = SessionArtifactLocator.key(for: session) else {
        return RecentSessionItem(session: session, transcript: nil, clean: nil, summaries: [])
      }
      let day = URL(fileURLWithPath: outputRoot).appendingPathComponent(key.day)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: day.path)) ?? []
      let artifacts = SessionArtifactLocator.classify(filenames: names, key: key)
      return RecentSessionItem(
        session: session,
        transcript: artifacts.transcript.map { day.appendingPathComponent($0) },
        clean: artifacts.clean.map { day.appendingPathComponent($0) },
        summaries: artifacts.summaries.map { day.appendingPathComponent($0) })
    }
  }
}
```

- [ ] **Step 2: Wire into `AppModel`**

Add a `private let recentsProvider: RecentSessionsProvider` (init from config), and:

```swift
func refreshRecents() {
  let provider = recentsProvider
  Task.detached { [weak self] in
    let items = provider.load()
    await MainActor.run { self?.recents = items }
  }
}
```

Call `refreshRecents()` from `menuWillOpen()` and from `handleApplied` when the frame is a terminal job event (`.done`/`.failed`) — new files may exist.

- [ ] **Step 3: Add the submenu to `MenuContentView`**

Insert before the Quit divider:

```swift
Menu("Recent Sessions") {
  if model.recents.isEmpty {
    Text("No ended sessions")
  }
  ForEach(model.recents) { item in
    Menu(item.session.title) {
      Button("Open Summary") { open(item.summaries.first) }
        .disabled(item.summaries.isEmpty)
      Button("Open Transcript") { open(item.clean ?? item.transcript) }
        .disabled(item.clean == nil && item.transcript == nil)
      Button("Show in Finder") { reveal(item.transcript ?? item.summaries.first ?? item.clean) }
        .disabled(item.transcript == nil && item.summaries.isEmpty && item.clean == nil)
    }
  }
}
```

with helpers in the view:

```swift
private func open(_ url: URL?) {
  guard let url else { return }
  NSWorkspace.shared.open(url)
}

private func reveal(_ url: URL?) {
  guard let url else { return }
  NSWorkspace.shared.activateFileViewerSelecting([url])
}
```

- [ ] **Step 4: Build + live verification**

`swift run ears-menubar`: Recent Sessions lists ended sessions newest-first with real titles; Open Summary/Transcript open in the default Markdown app; entries with missing artifacts show disabled items.

- [ ] **Step 5: Format, lint, commit** — `feat(menubar): recent-sessions submenu backed by the on-disk session store`

---

### Task 12: Shell — notifications adapter

**Files:**
- Create: `daemon/Sources/ears-menubar/Notifier.swift`
- Modify: `daemon/Sources/ears-menubar/AppModel.swift` (replace the `post` stub)

**Interfaces:**
- Consumes: `NotificationRequest` (Task 7), `UserNotifications`, `RecentSessionsProvider` (action → URL resolution), `DataStoreLayout.sessionDirectory(dataRoot:sessionID:)` (`EarsDataStore/DataStoreLayout.swift:67`).
- Produces: `@MainActor final class Notifier: NSObject { func bootstrap(resolve:); func post(_:) }`.

- [ ] **Step 1: Implement `Notifier.swift`**

```swift
import AppKit
import EarsMenuKit
import UserNotifications

/// UNUserNotificationCenter requires a real bundle; a bare `swift run` binary
/// has none, so the notifier degrades to a no-op there (bundle-gated).
@MainActor
final class Notifier: NSObject {
  private var available = false
  private var resolve: (@Sendable (NotificationRequest.Action) -> URL?)?

  func bootstrap(resolve: @escaping @Sendable (NotificationRequest.Action) -> URL?) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    available = true
    self.resolve = resolve
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func post(_ request: NotificationRequest) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.userInfo = Self.encode(request.action)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  static func encode(_ action: NotificationRequest.Action) -> [String: String] {
    switch action {
    case .openSummary(let session): return ["action": "openSummary", "session": session]
    case .revealSession(let session): return ["action": "revealSession", "session": session]
    case .none: return [:]
    }
  }

  static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationRequest.Action {
    guard let session = userInfo["session"] as? String else { return .none }
    switch userInfo["action"] as? String {
    case "openSummary": return .openSummary(session: session)
    case "revealSession": return .revealSession(session: session)
    default: return .none
    }
  }
}

extension Notifier: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let action = Notifier.decode(userInfo)
    Task { @MainActor [weak self] in
      guard let url = self?.resolve?(action) else { return }
      switch action {
      case .revealSession: NSWorkspace.shared.activateFileViewerSelecting([url])
      default: NSWorkspace.shared.open(url)
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
```

- [ ] **Step 2: Wire into `AppModel`**

Add `private let notifier = Notifier()`. In `start()`, after spawning the tasks (capture the paths as locals first — instance properties can't appear bare in a capture list):

```swift
let dataRoot = self.dataRoot
let outputRoot = self.outputRoot
notifier.bootstrap { action in
  switch action {
  case .openSummary(let session):
    let provider = RecentSessionsProvider(dataRoot: dataRoot, outputRoot: outputRoot)
    return provider.load(limit: 50).first { $0.session.id == session }?.summaries.first
  case .revealSession(let session):
    return DataStoreLayout.sessionDirectory(
      dataRoot: URL(fileURLWithPath: dataRoot), sessionID: session)
  case .none:
    return nil
  }
}
```

Replace the `post(_:)` stub with `notifier.post(request)`. Add `import EarsDataStore` if missing.

- [ ] **Step 3: Build; note that click-through verification needs the bundle (Task 14's checklist covers it)**

Run: `cd daemon && swift build` → clean.

- [ ] **Step 4: Format, lint, commit** — `feat(menubar): bundle-gated notification adapter with click-through actions`

---

### Task 13: Shell — Daemon submenu, restart, launch-at-login

**Files:**
- Create: `daemon/Sources/ears-menubar/SystemActions.swift`
- Modify: `daemon/Sources/ears-menubar/MenuContentView.swift`
- Modify: `daemon/Sources/ears-menubar/AppModel.swift` (restart passthrough)

**Interfaces:**
- Consumes: `launchctl` (label `net.tomelliot.ears.earsd`, Makefile:25), `SMAppService`, `ElapsedFormatter.compactDuration`, `AppModel.uptimeSeconds`.
- Produces: `enum SystemActions { static func restartDaemon(); static func openLogs(); static func openFolder(_ path: String) }` and a `LaunchAtLoginToggle` view.

- [ ] **Step 1: Implement `SystemActions.swift`**

```swift
import AppKit
import Foundation

enum SystemActions {
  static let daemonLabel = "net.tomelliot.ears.earsd"

  /// `launchctl kickstart -k` — same restart the Makefile documents.
  static func restartDaemon() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(daemonLabel)"]
    try? process.run()
  }

  static func openLogs() {
    openFolder(NSHomeDirectory() + "/Library/Logs/ears")
  }

  static func openFolder(_ path: String) {
    guard !path.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }
}
```

- [ ] **Step 2: Daemon submenu + login toggle in `MenuContentView`**

Between Recent Sessions and Quit:

```swift
Menu("Daemon") {
  Text(daemonLine)
  Button("Restart Daemon") { model.restartDaemon() }
  Button("Open Logs") { SystemActions.openLogs() }
  Button("Open Data Folder") { SystemActions.openFolder(model.dataRoot) }
}
Divider()
LaunchAtLoginToggle()
```

with:

```swift
private var daemonLine: String {
  guard let daemon = model.state.daemon else { return "Not connected" }
  guard let uptime = model.uptimeSeconds else { return daemon }
  return "\(daemon) · up \(ElapsedFormatter.compactDuration(Double(uptime)))"
}
```

(`model.state` is `private(set)` — expose it read-only, or add a `daemonLine` computed on `AppModel`; pick whichever keeps `AppModel` under 300 lines.)

`LaunchAtLoginToggle` (same file or its own if the view file nears the limit):

```swift
import ServiceManagement

struct LaunchAtLoginToggle: View {
  @State private var enabled = SMAppService.mainApp.status == .enabled

  var body: some View {
    if Bundle.main.bundleIdentifier != nil {
      Toggle("Launch at Login", isOn: Binding(
        get: { enabled },
        set: { wanted in
          do {
            if wanted { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
          } catch {
            // status re-read below reflects reality
          }
          enabled = SMAppService.mainApp.status == .enabled
        }))
    }
  }
}
```

`AppModel.restartDaemon()`:

```swift
func restartDaemon() {
  SystemActions.restartDaemon()
  guard let connection else { return }
  Task { await connection.bounce() }
}
```

- [ ] **Step 3: Build + live verification**

`swift run ears-menubar`: Daemon submenu shows "earsd 0.1.0 · up …" when connected; Restart Daemon bounces the daemon (icon flickers to attention, reconnects); Open Logs/Data Folder open Finder windows. (Launch at Login is hidden in bare-binary runs — verified in Task 14.)

- [ ] **Step 4: Format, lint, full `swift test`, commit** — `feat(menubar): daemon submenu with restart, logs, and launch-at-login`

---

### Task 14: Makefile — assemble, sign, install `All Ears.app`

**Files:**
- Create: `packaging/ears-menubar.Info.plist`
- Modify: `Makefile`

**Interfaces:**
- Consumes: existing Makefile variables (`RELEASE`, `SIGN_IDENTITY` detection block at Makefile:70-96), `docs/brand/exports/icon-tile-light-1024.png` (1024×1024 RGBA; its source SVG's own comment lists the icns export sizes), stock `sips`/`iconutil`/`codesign` per the Makefile's no-external-tooling constraint (Makefile:1-16).
- Produces: `make menubar` (build+assemble+sign+install+relaunch), `install`/`uninstall` wiring, `$(APP_DEST) = ~/Applications/All Ears.app`.

- [ ] **Step 1: Write `packaging/ears-menubar.Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>All Ears</string>
    <key>CFBundleDisplayName</key>
    <string>All Ears</string>
    <key>CFBundleIdentifier</key>
    <string>net.tomelliot.ears.menubar</string>
    <key>CFBundleExecutable</key>
    <string>ears-menubar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Add Makefile variables and targets**

Variables (near the existing block, Makefile:18-37):

```make
MENUBAR_BIN   := ears-menubar
APP_NAME      := All Ears
APP_BUNDLE_ID := net.tomelliot.ears.menubar
APP_STAGE     := $(RELEASE)/$(APP_NAME).app
APP_DEST      := $(HOME)/Applications/$(APP_NAME).app
MENUBAR_PLIST := packaging/ears-menubar.Info.plist
ICON_SRC      := docs/brand/exports/icon-tile-light-1024.png
```

First extract the identity detection into a shared macro (still stock Make — no external tooling) and refactor the existing `sign` recipe (Makefile:70-96) to use it, preserving `sign`'s existing no-identity warning echos:

```make
# Resolve the codesign identity: explicit SIGN_IDENTITY, else the first
# "Developer ID Application" in the keychain, else ad-hoc ("-").
define RESOLVE_IDENTITY
IDENTITY="$(SIGN_IDENTITY)"; \
if [ -z "$$IDENTITY" ]; then \
  IDENTITY="$$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $$2; exit}')"; \
fi; \
if [ -z "$$IDENTITY" ]; then IDENTITY="-"; fi
endef
```

Targets (the `menubar` recipe invokes the macro instead of inlining the detection):

```make
menubar: build
	@echo "==> Assembling $(APP_NAME).app"
	@rm -rf "$(APP_STAGE)"
	@mkdir -p "$(APP_STAGE)/Contents/MacOS" "$(APP_STAGE)/Contents/Resources"
	@cp "$(MENUBAR_PLIST)" "$(APP_STAGE)/Contents/Info.plist"
	@cp "$(RELEASE)/$(MENUBAR_BIN)" "$(APP_STAGE)/Contents/MacOS/$(MENUBAR_BIN)"
	@echo "  render AppIcon.icns from $(ICON_SRC)"
	@rm -rf "$(RELEASE)/AppIcon.iconset"
	@mkdir -p "$(RELEASE)/AppIcon.iconset"
	@for s in 16 32 128 256 512; do \
	  sips -z $$s $$s "$(ICON_SRC)" --out "$(RELEASE)/AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
	  d=$$((s*2)); \
	  sips -z $$d $$d "$(ICON_SRC)" --out "$(RELEASE)/AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	@iconutil -c icns "$(RELEASE)/AppIcon.iconset" -o "$(APP_STAGE)/Contents/Resources/AppIcon.icns"
	@$(RESOLVE_IDENTITY); \
	echo "  codesign $(APP_NAME).app (identity: $$IDENTITY)"; \
	codesign --force --options runtime --sign "$$IDENTITY" "$(APP_STAGE)"
	@echo "==> Installing to $(APP_DEST)"
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(APP_DEST)"
	@cp -R "$(APP_STAGE)" "$(APP_DEST)"
	@pkill -x $(MENUBAR_BIN) 2>/dev/null || true
	@open "$(APP_DEST)"

uninstall-menubar:
	@echo "==> Removing $(APP_DEST)"
	@pkill -x $(MENUBAR_BIN) 2>/dev/null || true
	@rm -rf "$(APP_DEST)"
```

Wire-up: add `menubar` to the `install` dependency list (after `install-agent`), `uninstall-menubar` to `uninstall`'s, both to `.PHONY`, and a `help` line: `menubar        Build, sign, and install the All Ears menu bar app`.

- [ ] **Step 3: Verify the bundle end-to-end**

```bash
make menubar SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
```
Checklist:
1. `~/Applications/All Ears.app` exists, launches, brand icon appears (in Finder; menu bar shows the SF-Symbol ear).
2. First launch prompts for notification permission (bundle present now). End a session → "Summary ready" banner → click opens the summary file. Kill the daemon mid-recording → "Recording at risk" banner.
3. `Launch at Login` toggle appears and flips `SMAppService` state (System Settings → Login Items shows "All Ears").
4. `make uninstall-menubar` removes the app and kills the process.

- [ ] **Step 4: Commit** — `feat(menubar): package All Ears.app via make menubar`

---

### Task 15: Docs sweep + final verification

**Files:**
- Modify: `CLAUDE.md` (daemon binary count/list)
- Modify: `README.md` (mention the menu bar app + `make menubar`)
- Modify: `docs/plans/menubar-app.md` (status line)
- Modify: `docs/specs/control-protocol.md` ("a future menu-bar app" → the menu-bar app is real)
- Modify: `docs/architecture.md` (frontends list, if it enumerates them — grep first)

**Interfaces:** none — documentation truth-up.

- [ ] **Step 1: Update the docs**

1. `CLAUDE.md`: "one Swift 6 package … producing five binaries" → six, adding `ears-menubar`; if the browser/daemon overview mentions frontends, add the menu bar app.
2. `README.md`: add the app to the component list and `make menubar` to the install instructions.
3. `docs/plans/menubar-app.md`: `Status: **design approved, not yet implemented.**` → `Status: **stage 1 implemented** (dropdown menu + notifications; the stage-2 dashboard window remains future work). Also extend its "Daemon-side change" section with the second change made during implementation: the on-end chain now runs for every session trigger, not just browser-triggered ones, so menu-started manual recordings feed the pipeline (escape hatch `on_end_stages = []`).
4. `docs/specs/control-protocol.md` "One job" paragraph: "a future menu-bar app" → "the menu-bar app (`ears-menubar`)".
5. `grep -rn "menu-bar\|menu bar\|five binaries\|frontends" docs/ CLAUDE.md README.md` — fix any remaining stale claims (docs are contractual here).

- [ ] **Step 2: Full verification**

```bash
cd daemon && swift format lint --recursive --strict Sources/ Tests/ && swift build && swift test
cd ../browser && bun run test
```
Expected: all green. Then `make status` + open the menu once more as a smoke check.

- [ ] **Step 3: Commit** — `docs: record the menu bar app as shipped stage 1`

---

## Execution notes

- Tasks 1–3 are PR 1 (daemon, upstream-relevant); Tasks 4–15 are PR 2. Push order matters only at PR time — locally the tasks are strictly sequential.
- If `swift run ears-menubar` can't connect during live verification, check `EARS_SOCKET_PATH`/`ears status` first — the app resolves config exactly like `ears` does.
- Any deviation discovered mid-task (a signature that doesn't match this plan, a missing public init) gets fixed in the smallest possible separate commit, noted in the task's commit body.
