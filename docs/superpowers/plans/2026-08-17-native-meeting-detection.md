# Native Meeting Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect native Zoom/Teams meetings via CoreAudio process input activity, prompt from the menu bar, enrich sessions with EventKit calendar data, and auto-end them on meeting-audio idle.

**Architecture:** The daemon polls the CoreAudio HAL process objects for "app is using the mic" on every configured `app:*` source, debounces that into activity episodes, publishes them as a new `meeting.activity` telemetry event, and auto-ends sessions with a new `app-detected` trigger once activity stays quiet past a grace period. The menu bar app subscribes, prompts (notification + menu row), and on accept starts the session — optionally enriched with a matched EventKit calendar event's title and attendees. An independent fix makes `transcribe` label app-source turns with the source's `meta.toml` label ("Zoom") instead of the raw id.

**Tech Stack:** Swift 6 (strict concurrency), swift-testing (`import Testing`, `@Test`/`#expect`), CoreAudio HAL process objects, EventKit, UserNotifications, SwiftUI MenuBarExtra. Shared JSON wire fixtures with the TypeScript extension.

**Spec:** `docs/superpowers/specs/2026-08-17-native-meeting-detection-design.md`

## Global Constraints

- Swift 6 strict concurrency; **no `@MainActor` in the core** (menu bar app target is the exception — it is already `@MainActor`).
- **No wall-clock time in tests**: inject `NowProviding` clocks and sleep closures; never `Date()` or real timers in a test path.
- Tests are swift-testing (`@Suite`/`@Test`/`#expect`), NOT XCTest.
- Run all Swift commands from `daemon/`; run all browser commands from `browser/`.
- Format before every commit: `swift format --recursive -i Sources/ Tests/` (CI runs `swift format lint --recursive --strict Sources/ Tests/`).
- Conventional Commits, one logical change each: `type(scope): summary` (scope = tool or package, e.g. `feat(earsd):`, `feat(menubar):`, `fix(transcribe):`).
- Max 300 lines per source file (hard limit), max 100 lines per function.
- Only `EarsCaptureKit` may touch Core Audio. Only the `ears-menubar` target may touch EventKit/AppKit UI; pure logic goes in `EarsMenuKit`.
- Wire canonical encodings: optional keys absent when nil, empty lists omitted (see `shared/protocol-fixtures/control-v2.json`'s comment). Additive keys decode with `decodeIfPresent ?? default`.
- Docs are contracts: when a task changes a wire shape, config key, or on-disk format, its doc update ships in the same commit.

---

### Task 1: Speaker-label fallback in TranscriptAssembly (pure)

The transcript currently labels an `app:us.zoom.xos` turn with that raw id. Add a descriptor-label fallback: reconciled `[[speaker]]` name → `mic` → "You" → descriptor label ("Zoom") → raw id.

**Files:**
- Modify: `daemon/Sources/transcribe/TranscriptAssembly.swift` (`speakerLabel` at ~line 40, `assemble` at ~line 145)
- Test: `daemon/Tests/TranscribeTests/TranscriptAssemblyTests.swift` (existing file — add tests; if speaker-label tests live in a differently named file, add them beside the existing `speakerLabel` tests found via `grep -rn "speakerLabel" daemon/Tests/`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `TranscriptAssembly.speakerLabel(for:speakers:sourceLabels:)` — new `sourceLabels: [String: String] = [:]` parameter (raw source id → descriptor label). `TranscriptAssembly.assemble(...)` gains `sourceLabels: [String: String] = [:]` after `speakers:`. Task 2 threads real labels in.

- [ ] **Step 1: Write the failing tests**

In the test file that already covers `speakerLabel` (find with `grep -rn "speakerLabel" daemon/Tests/TranscribeTests/`), add:

```swift
@Test("descriptor label beats the raw source id")
func descriptorLabelFallback() {
  let label = TranscriptAssembly.speakerLabel(
    for: SourceID("app:us.zoom.xos"),
    speakers: [:],
    sourceLabels: ["app:us.zoom.xos": "Zoom"])
  #expect(label == "Zoom")
}

@Test("reconciled speaker name beats the descriptor label")
func reconciledNameBeatsDescriptorLabel() {
  let label = TranscriptAssembly.speakerLabel(
    for: SourceID("app:us.zoom.xos"),
    speakers: ["app:us.zoom.xos": "Priya"],
    sourceLabels: ["app:us.zoom.xos": "Zoom"])
  #expect(label == "Priya")
}

@Test("mic stays You even when it carries a descriptor label")
func micStaysYou() {
  let label = TranscriptAssembly.speakerLabel(
    for: SourceID("mic"),
    speakers: [:],
    sourceLabels: ["mic": "MacBook Microphone"])
  #expect(label == "You")
}

@Test("empty descriptor label falls through to the raw id")
func emptyLabelFallsThrough() {
  let label = TranscriptAssembly.speakerLabel(
    for: SourceID("app:us.zoom.xos"),
    speakers: [:],
    sourceLabels: ["app:us.zoom.xos": ""])
  #expect(label == "app:us.zoom.xos")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscribeTests` (from `daemon/`)
Expected: FAIL — `extra argument 'sourceLabels' in call` (compile error is the failing state here).

- [ ] **Step 3: Implement**

In `TranscriptAssembly.swift`, replace `speakerLabel`:

```swift
static func speakerLabel(
  for sourceID: SourceID, speakers: [String: String] = [:],
  sourceLabels: [String: String] = [:]
) -> String {
  if let name = speakers[sourceID.rawValue] { return name }
  if sourceID == SourceID("mic") { return "You" }
  if let label = sourceLabels[sourceID.rawValue], !label.isEmpty { return label }
  return sourceID.rawValue
}
```

Add `sourceLabels: [String: String] = [:]` to `assemble`'s signature (directly after `speakers:`) and pass it through at the one `speakerLabel` call site inside `assemble` (`let base = speakerLabel(for: transcription.sourceID, speakers: names, sourceLabels: sourceLabels)`). Update `speakerLabel`'s doc comment to state the full precedence: reconciled name → mic→You → descriptor label → raw id.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscribeTests`
Expected: PASS (all — existing tests must stay green: the default `[:]` keeps prior behavior byte-identical).

- [ ] **Step 5: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/transcribe/TranscriptAssembly.swift Tests/TranscribeTests/
git commit -m "feat(transcribe): speaker labels fall back to the source descriptor label"
```

---

### Task 2: Thread descriptor labels through TranscribePipeline

**Files:**
- Modify: `daemon/Sources/transcribe/TranscribePipeline.swift` (the `assemble` call at ~line 551; `SourceAudioPlan` handling around `planSessionSources` ~line 689)
- Modify: `docs/data-formats.md` (the "attribution ladder" source-level paragraph, ~line 326: note that `app:`/`system` sources render under their `meta.toml` `label` when no reconciled name exists)
- Test: `daemon/Tests/TranscribeTests/` (a small pure test for the new helper)

**Interfaces:**
- Consumes: `TranscriptAssembly.assemble(sourceLabels:)` from Task 1; `EarsDataStore.SourceMetaStore.read(sourceID:dataRoot:) throws -> SourceDescriptor`; `DataStoreLayout.sessionDirectory(dataRoot:sessionID:)`.
- Produces: `TranscribePipeline.sourceLabels(sourceIDs:sessionID:dataRoot:) -> [String: String]` (internal static helper).

- [ ] **Step 1: Write the failing test**

The helper is I/O (reads `meta.toml`) but trivially testable against a temp directory the way `EarsDataStoreTests` do. Add to `daemon/Tests/TranscribeTests/` a new file `SourceLabelResolutionTests.swift`:

```swift
import EarsCore
import EarsDataStore
import Foundation
import Testing

@testable import transcribe

@Suite("Source label resolution")
struct SourceLabelResolutionTests {
  @Test("labels come from the per-session meta.toml, skipping empty and missing ones")
  func readsSessionMetaLabels() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("labels-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionRoot = DataStoreLayout.sessionDirectory(dataRoot: root, sessionID: "s1")
    let zoom = SourceDescriptor(
      schema: 1, id: SourceID("app:us.zoom.xos"), sourceClass: .app, label: "Zoom",
      nativeSampleRate: 48_000, asrSampleRate: 16_000, storeNative: true,
      channels: 1, codec: "aac", bitrate: 64_000,
      created: Instant(secondsSinceEpoch: 0))
    try SourceMetaStore.write(zoom, dataRoot: sessionRoot)

    let labels = TranscribePipeline.sourceLabels(
      sourceIDs: [SourceID("app:us.zoom.xos"), SourceID("mic")],
      sessionID: "s1", dataRoot: root)
    #expect(labels == ["app:us.zoom.xos": "Zoom"])
  }
}
```

(Adjust the `SourceDescriptor` initializer argument order to match `daemon/Sources/EarsCore/Models/SourceDescriptor.swift:25-51` exactly — `deviceUID:` is defaulted and can be omitted.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SourceLabelResolutionTests`
Expected: FAIL — `sourceLabels` not defined.

- [ ] **Step 3: Implement**

In `TranscribePipeline.swift` add (near `planSessionSources`):

```swift
/// Raw source id → the descriptor `label` from the source's `meta.toml`,
/// consulted per-session first (`sessions/<id>/sources/<source>/`) then the
/// global ring — the same order the audio reads use. Empty labels and
/// missing descriptors are simply absent: `TranscriptAssembly.speakerLabel`
/// falls through to the raw id, exactly as before labels existed.
static func sourceLabels(
  sourceIDs: [SourceID], sessionID: String?, dataRoot: URL
) -> [String: String] {
  var labels: [String: String] = [:]
  let roots: [URL] =
    sessionID.map {
      [DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: $0), dataRoot]
    } ?? [dataRoot]
  for sourceID in sourceIDs {
    for root in roots {
      guard let descriptor = try? SourceMetaStore.read(sourceID: sourceID, dataRoot: root)
      else { continue }
      if !descriptor.label.isEmpty { labels[sourceID.rawValue] = descriptor.label }
      break
    }
  }
  return labels
}
```

Call it just before the `TranscriptAssembly.assemble` call (~line 551) and pass the result:

```swift
let sourceLabels = Self.sourceLabels(
  sourceIDs: sourceIDs, sessionID: inputs.session, dataRoot: dataRoot)
```
…and add `sourceLabels: sourceLabels,` to the `assemble(...)` call after `speakers: speakers,`. Check whether the pipeline methods are instance or static (`Self.` vs bare call) and match. Add `import EarsDataStore` if not already imported.

- [ ] **Step 4: Run tests**

Run: `swift test --filter TranscribeTests`
Expected: PASS.

- [ ] **Step 5: Update the doc and commit**

In `docs/data-formats.md` (~line 326, the source-level attribution paragraph), change the `app:`/`system` clause to say each maps to the other side *labelled with the source's `meta.toml` `label` when no reconciled name exists (falling back to the raw source id)*.

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/transcribe/TranscribePipeline.swift Tests/TranscribeTests/SourceLabelResolutionTests.swift ../docs/data-formats.md
git commit -m "feat(transcribe): read per-source meta.toml labels for transcript speaker names"
```

---

### Task 3: `app-detected` trigger kind + on-end chain policy

**Files:**
- Modify: `daemon/Sources/EarsCore/Models/TriggerKind.swift`
- Modify: `daemon/Sources/EarsDaemonKit/OnEndChainPolicy.swift:30-32`
- Modify: `docs/data-formats.md:136` (`trigger = "browser-extension"  # manual | browser-extension` → add `app-detected`)
- Test: `daemon/Tests/EarsDaemonKitTests/OnEndChainPolicyTests.swift`, `daemon/Tests/EarsConfigTests/` (session TOML round-trip)

**Interfaces:**
- Consumes: existing `TriggerKind`, `OnEndChainPolicy.stages(declared:trigger:configured:)`.
- Produces: `TriggerKind.appDetected` (raw value `"app-detected"`). Every later task uses this exact case name.

- [ ] **Step 1: Write the failing tests**

In `OnEndChainPolicyTests.swift` add (mirroring the existing browser-extension default test):

```swift
@Test("app-detected sessions inherit the configured chain when undeclared")
func appDetectedInheritsConfiguredChain() {
  let result = OnEndChainPolicy.stages(
    declared: nil, trigger: .appDetected, configured: OnEndStage.allCases)
  #expect(result.stages == OnEndStage.allCases)
  #expect(result.problems.isEmpty)
}
```

In the `EarsConfigTests` suite that round-trips `SessionDescriptorTOML` (find with `grep -rln "SessionDescriptorTOML" daemon/Tests/`), add:

```swift
@Test("an app-detected trigger survives the session.toml round trip")
func appDetectedTriggerRoundTrips() throws {
  var session = Session(
    id: "s1", title: "t", state: .active,
    started: Instant(secondsSinceEpoch: 1_700_000_000),
    trigger: .appDetected)
  session.intervals = [SessionInterval(start: session.started)]
  let decoded = try SessionDescriptorTOML.decode(SessionDescriptorTOML.encode(session))
  #expect(decoded.trigger == .appDetected)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OnEndChainPolicyTests` — Expected: FAIL (no `.appDetected` case).

- [ ] **Step 3: Implement**

`TriggerKind.swift` — add a third case with a doc comment:

```swift
  /// Started from the menu bar's detect-and-prompt flow for a native app
  /// meeting (a configured `app:*` source began using the microphone). Its
  /// own provenance value because two policies key off it: these sessions
  /// inherit the configured on-end chain, and the daemon auto-ends them once
  /// the app's audio activity stays quiet past `[earsd.detection] idle_grace_s`.
  case appDetected = "app-detected"
```

`OnEndChainPolicy.swift:30-32` — change the guard body to:

```swift
    guard let declared else {
      let inherits = trigger == .browserExtension || trigger == .appDetected
      return (inherits ? configured : [], [])
    }
```

Update the type's doc comment (the "every other trigger runs nothing" sentence) to name both inheriting triggers. Update `docs/data-formats.md:136`'s comment to `# manual | browser-extension | app-detected`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter OnEndChainPolicyTests && swift test --filter EarsConfigTests`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsCore/Models/TriggerKind.swift Sources/EarsDaemonKit/OnEndChainPolicy.swift Tests/ ../docs/data-formats.md
git commit -m "feat(earsd): app-detected trigger kind inherits the configured on-end chain"
```

---

### Task 4: Registry auto-end on app-audio idle

**Files:**
- Modify: `daemon/Sources/EarsDaemonKit/SessionRegistry.swift` (`EndReason` at line 59; init at 142; `start(_:)` at 312; `loadFromDisk()` at 195; new members near the ingest-tracking section)
- Modify: `docs/specs/capture-daemon.md` (beside the orphaned-session/ingest-idle prose: document `app-idle` auto-end for `app-detected` sessions)
- Test: `daemon/Tests/EarsDaemonKitTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `TriggerKind.appDetected` (Task 3); existing `graceGeneration`/`scheduleGraceExpiry` patterns; the test file's existing `makeRegistry` helper, `ManualClock`, and sleep-gate.
- Produces:
  - `SessionRegistry.init(..., appIdleGraceSeconds: Double = 90, ...)` — new parameter directly after `graceSeconds`.
  - `SessionRegistry.EndReason.appIdle` (raw value `"app-idle"`).
  - `public func appAudioActivity(source: SourceID, active: Bool)` — Task 7 wires the monitor to this.

- [ ] **Step 1: Write the failing tests**

Extend the file's `makeRegistry` helper (line ~30) with `appIdleGraceSeconds: Double = 90` passed through to the registry (directly after `graceSeconds`). Then add, in a new `// MARK: - app-idle grace` section beside the orphan-grace tests (the same `ManualClock`/`SleepGate`/`waitUntil` harness those use, lines ~753-818):

```swift
@Test("an app-detected session auto-ends app-idle once activity stays quiet past grace")
func appDetectedAutoEndsOnIdle() async throws {
  let dataRoot = try makeDataRoot()
  let clock = ManualClock(base)
  let gate = SleepGate()
  let registry = makeRegistry(
    dataRoot: dataRoot, clock: clock, appIdleGraceSeconds: 90,
    sleep: { seconds in await gate.wait(seconds) })

  await registry.appAudioActivity(source: "app:us.zoom.xos", active: true)
  let session = try await registry.start(
    SessionStartParams(
      platform: "zoom-app", externalID: "us.zoom.xos#1",
      sources: ["mic", "app:us.zoom.xos"], trigger: .appDetected))
  await registry.appAudioActivity(source: "app:us.zoom.xos", active: false)

  await gate.releaseAll()
  await waitUntil { try await registry.get(id: session.id).state == .ended }
  let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
  #expect(timeline.last?.event == "ended")
  #expect(timeline.last?.reason == "app-idle")
}

@Test("activity resuming inside the grace window keeps the session alive")
func activityResumeCancelsAppIdleGrace() async throws {
  let dataRoot = try makeDataRoot()
  let gate = SleepGate()
  let registry = makeRegistry(
    dataRoot: dataRoot, clock: ManualClock(base), appIdleGraceSeconds: 90,
    sleep: { seconds in await gate.wait(seconds) })

  await registry.appAudioActivity(source: "app:us.zoom.xos", active: true)
  let session = try await registry.start(
    SessionStartParams(
      platform: "zoom-app", externalID: "us.zoom.xos#1",
      sources: ["mic", "app:us.zoom.xos"], trigger: .appDetected))
  await registry.appAudioActivity(source: "app:us.zoom.xos", active: false)
  // The meeting came back inside the grace window.
  await registry.appAudioActivity(source: "app:us.zoom.xos", active: true)

  await gate.releaseAll()
  // Give the (now-stale) expiry task a chance to run — it must be a no-op.
  for _ in 0..<50 { await Task.yield() }
  #expect(try await registry.get(id: session.id).state == .active)
}

@Test("an app-detected session started with no live activity arms the grace immediately")
func startWithoutActivityArmsGrace() async throws {
  let dataRoot = try makeDataRoot()
  let gate = SleepGate()
  let registry = makeRegistry(
    dataRoot: dataRoot, clock: ManualClock(base), appIdleGraceSeconds: 90,
    sleep: { seconds in await gate.wait(seconds) })

  // Accept-after-the-meeting-already-ended: no activity is ever reported.
  let session = try await registry.start(
    SessionStartParams(
      platform: "zoom-app", externalID: "us.zoom.xos#1",
      sources: ["mic", "app:us.zoom.xos"], trigger: .appDetected))

  await gate.releaseAll()
  await waitUntil { try await registry.get(id: session.id).state == .ended }
  let timeline = SessionEventLog.readAll(dataRoot: dataRoot, sessionID: session.id)
  #expect(timeline.last?.reason == "app-idle")
}

@Test("manual sessions never app-idle out")
func manualSessionsUntouchedByActivity() async throws {
  let dataRoot = try makeDataRoot()
  let gate = SleepGate()
  let registry = makeRegistry(
    dataRoot: dataRoot, clock: ManualClock(base), appIdleGraceSeconds: 0,
    sleep: { seconds in await gate.wait(seconds) })

  let session = try await registry.start(
    SessionStartParams(title: "standup", sources: ["mic", "app:us.zoom.xos"]))
  await registry.appAudioActivity(source: "app:us.zoom.xos", active: true)
  await registry.appAudioActivity(source: "app:us.zoom.xos", active: false)

  await gate.releaseAll()
  for _ in 0..<50 { await Task.yield() }
  #expect(try await registry.get(id: session.id).state == .active)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionRegistryTests`
Expected: FAIL — no `appAudioActivity`, no `.appIdle`.

- [ ] **Step 3: Implement**

In `SessionRegistry.swift`:

1. `EndReason` — add:
```swift
    /// An app-detected session's app-audio activity stayed quiet past
    /// `[earsd.detection] idle_grace_s` — the native-app mirror of
    /// ``ingestIdle``.
    case appIdle = "app-idle"
```
2. Stored state + init: `private let appIdleGraceSeconds: Double` (init param after `graceSeconds`, default `90`); `private var activeAppAudio: Set<SourceID> = []`.
3. New public entry point (place beside `ingestStreamOpened`):
```swift
  /// The meeting-activity monitor's feed: `active` transitions for one
  /// configured `app:*` source. Drives the app-idle auto-end policy for
  /// `app-detected` sessions; every other trigger ignores it (the daemon
  /// records, it doesn't decide).
  public func appAudioActivity(source: SourceID, active: Bool) {
    if active { activeAppAudio.insert(source) } else { activeAppAudio.remove(source) }
    for session in sessions.values
    where session.state != .ended && session.trigger == .appDetected {
      let appSources = session.sources.filter { $0.sourceClass == .app }
      guard appSources.contains(source) else { continue }
      if active {
        graceGeneration[session.id, default: 0] += 1
        log(
          "app-idle grace cancelled: session=\(session.id) source=\(source.rawValue) "
            + "generation=\(graceGeneration[session.id]!)")
      } else if appSources.allSatisfy({ !activeAppAudio.contains($0) }) {
        scheduleAppIdleExpiry(sessionID: session.id)
      }
    }
  }
```
4. Private scheduling, mirroring `scheduleGraceExpiry`/`expireIfStillOrphaned` (lines 767-801) with the app-idle checks:
```swift
  private func scheduleAppIdleExpiry(sessionID: String) {
    graceGeneration[sessionID, default: 0] += 1
    let generation = graceGeneration[sessionID]!
    log(
      "app-idle grace scheduled: session=\(sessionID) "
        + "deadline=\(ISO8601InstantCodec.format(clock.now().advanced(by: appIdleGraceSeconds))) "
        + "generation=\(generation)")
    let wait = sleep
    let seconds = appIdleGraceSeconds
    Task { [weak self] in
      await wait(seconds)
      await self?.expireIfStillAppIdle(sessionID: sessionID, generation: generation)
    }
  }

  private func expireIfStillAppIdle(sessionID: String, generation: Int) async {
    guard graceGeneration[sessionID] == generation,
      let session = sessions[sessionID],
      session.state != .ended,
      session.trigger == .appDetected,
      session.sources.filter({ $0.sourceClass == .app })
        .allSatisfy({ !activeAppAudio.contains($0) })
    else {
      log("app-idle expiry no-op: session=\(sessionID) generation=\(generation)")
      return
    }
    log("app-idle expiry firing: session=\(sessionID) generation=\(generation)")
    do {
      _ = try await end(id: sessionID, reason: .appIdle)
    } catch {
      log("session \(sessionID) app-idle expiry failed: \(error)")
    }
  }
```
5. In `start(_:)` after `await startCapture(...)` (line ~399): arm the grace for an app-detected session with no live activity:
```swift
    if trigger == .appDetected,
      session.sources.filter({ $0.sourceClass == .app })
        .allSatisfy({ !activeAppAudio.contains($0) })
    {
      scheduleAppIdleExpiry(sessionID: session.id)
    }
```
6. In `loadFromDisk()` beside the survivor's browser grace (line ~239-241): `if survivor.trigger == .appDetected { scheduleAppIdleExpiry(sessionID: survivor.id) }` — the monitor's first poll cancels it when the meeting is genuinely live.
7. Update the actor's doc comment's "Orphaned sessions" section for the new policy.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SessionRegistryTests`
Expected: PASS (new and existing).

- [ ] **Step 5: Update docs, format, commit**

Add to `docs/specs/capture-daemon.md`, next to the ingest-idle/orphaned-session prose: `app-detected` sessions auto-end with `reason = "app-idle"` after `idle_grace_s` of no app-audio activity; manual sessions remain never-auto-ended.

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsDaemonKit/SessionRegistry.swift Tests/EarsDaemonKitTests/SessionRegistryTests.swift ../docs/specs/capture-daemon.md
git commit -m "feat(earsd): auto-end app-detected sessions after app-audio idle grace"
```

---

### Task 5: `meeting.activity` on the wire — event kind, status, fixtures

**Files:**
- Create: `daemon/Sources/EarsCore/Socket/MeetingActivityStatus.swift`
- Modify: `daemon/Sources/EarsCore/Socket/EventKind.swift`, `daemon/Sources/EarsCore/Socket/EarsEvent.swift`, `daemon/Sources/EarsCore/Socket/StatusData.swift`
- Modify: `shared/protocol-fixtures/control-v2.json` (new `events` entry)
- Modify: `docs/specs/control-protocol.md` (events list + subscribe kinds)
- Test: `daemon/Tests/EarsCoreTests/ControlProtocolV2FixtureTests.swift` (fixture round-trip picks the new entry up automatically), plus a `StatusData` coding test beside the existing socket-type tests

**Interfaces:**
- Consumes: `SourceID`, `EventKind`, `EventFrame` coding patterns (`segment`/`job` cases encode their params struct directly).
- Produces:
  - `public struct MeetingActivityStatus: Sendable, Hashable, Codable { source: SourceID; bundleID: String; label: String; active: Bool; episode: String }` — wire keys `source`, `bundle_id`, `label`, `active`, `episode`.
  - `EventKind.meetingActivity` (raw `"meeting.activity"`, `isState == false`).
  - `EarsEvent.meetingActivity(MeetingActivityStatus)` with `filterSource == status.source`.
  - `StatusData.meetingActivity: [MeetingActivityStatus]` (key `meeting_activity`, absent ⇒ `[]`, omitted when empty).

- [ ] **Step 1: Add the golden fixture (the failing test)**

Append to the `events` array in `shared/protocol-fixtures/control-v2.json`:

```json
{
  "name": "meeting-activity-event",
  "frame": {
    "event": "meeting.activity",
    "params": {
      "source": "app:us.zoom.xos",
      "bundle_id": "us.zoom.xos",
      "label": "Zoom",
      "active": true,
      "episode": "us.zoom.xos#1"
    }
  }
}
```

- [ ] **Step 2: Run both fixture suites to verify the failure mode**

Run: `swift test --filter ControlProtocolV2FixtureTests` (from `daemon/`)
Expected: FAIL — the Swift decoder rejects the unknown `meeting.activity` kind.
Run: `bunx vitest run lib/protocol.test.ts` (from `browser/`)
Expected: PASS or FAIL — the TS `EventFrame` is structurally untyped (`event: string`, `params: Record<string, unknown>`, `browser/lib/protocol.ts:329`), so a generic round-trip passes; if the TS suite pattern-matches specific event names and fails on the new entry, add the mirrored expectation there following the existing event cases.

- [ ] **Step 3: Implement the Swift types**

New `daemon/Sources/EarsCore/Socket/MeetingActivityStatus.swift`:

```swift
/// One watched `app:*` source's meeting-audio activity — the payload of the
/// `meeting.activity` telemetry event and of `status`'s `meeting_activity`
/// snapshot. `active` flips when the app's confirmed (debounced) use of the
/// microphone starts or stops; `episode` is a daemon-boot-scoped id stable
/// for one continuous meeting, which clients key prompts and
/// `session.start` idempotency on.
public struct MeetingActivityStatus: Sendable, Hashable, Codable {
  public var source: SourceID
  public var bundleID: String
  public var label: String
  public var active: Bool
  public var episode: String

  public init(source: SourceID, bundleID: String, label: String, active: Bool, episode: String) {
    self.source = source
    self.bundleID = bundleID
    self.label = label
    self.active = active
    self.episode = episode
  }

  private enum CodingKeys: String, CodingKey {
    case source, label, active, episode
    case bundleID = "bundle_id"
  }
}
```

`EventKind.swift`: add `case meetingActivity = "meeting.activity"`; extend `isState` — `case .vad, .segment, .job, .meetingActivity: false`. Update the doc comment's telemetry list.

`EarsEvent.swift`: add `case meetingActivity(MeetingActivityStatus)`; `kind` → `.meetingActivity`; `filterSource` → `case .meetingActivity(let status): status.source`. In `EventFrame`'s `init(from:)` add `case .meetingActivity: event = .meetingActivity(try container.decode(MeetingActivityStatus.self, forKey: .params))` and in `encode(to:)` `case .meetingActivity(let status): try container.encode(status, forKey: .params)` (the `segment`/`job` pattern). Add the new frame shape to the type's doc-comment example block.

`StatusData.swift`: add `public var meetingActivity: [MeetingActivityStatus]`, init param `meetingActivity: [MeetingActivityStatus] = []`, CodingKey `meetingActivity = "meeting_activity"`, decode with `decodeIfPresent(...) ?? []`. Because `StatusData` currently has a synthesized encoder, hand-write `encode(to:)` (encode the other fields as before; encode `meeting_activity` only when non-empty) so existing wire output stays byte-identical.

- [ ] **Step 4: Add a StatusData coding test**

Beside the existing socket-type tests in `daemon/Tests/EarsCoreTests/` add:

```swift
@Test("status without meeting_activity decodes to empty and empty encodes absent")
func statusMeetingActivityIsAdditive() throws {
  let legacy = #"{"uptime_s":5,"sources":[],"sessions":[]}"#
  let decoded = try JSONDecoder().decode(StatusData.self, from: Data(legacy.utf8))
  #expect(decoded.meetingActivity.isEmpty)
  let encoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
  #expect(!encoded.contains("meeting_activity"))
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter EarsCoreTests` (from `daemon/`) — Expected: PASS.
Run: `bunx vitest run lib/protocol.test.ts` (from `browser/`) — Expected: PASS.

- [ ] **Step 6: Update the protocol spec doc**

`docs/specs/control-protocol.md`: add `meeting.activity` to the notification examples (~line 240) and to the telemetry-kinds prose (~line 247), with one sentence on the payload and that it is filterable like `vad`/`job`.

- [ ] **Step 7: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsCore/Socket/ Tests/EarsCoreTests/ ../shared/protocol-fixtures/control-v2.json ../docs/specs/control-protocol.md
git commit -m "feat(earsd): meeting.activity telemetry event and status snapshot on the wire"
```

---

### Task 6: Episode tracker (pure) + CoreAudio activity probe (shim)

**Files:**
- Create: `daemon/Sources/EarsCaptureKit/MeetingEpisodeTracker.swift`
- Create: `daemon/Sources/EarsCaptureKit/AppAudioActivityProbe.swift`
- Test: `daemon/Tests/EarsCaptureKitTests/MeetingEpisodeTrackerTests.swift`
- Test (live, gated): `daemon/Tests/EarsCaptureKitTests/AppAudioActivityProbeLiveTests.swift`

**Interfaces:**
- Consumes: `EarsCore.Instant` (`advanced(by:)`, `interval(since:)`).
- Produces:
  - `public struct MeetingActivityChange: Sendable, Hashable { bundleID: String; active: Bool; episode: String }`
  - `public struct MeetingEpisodeTracker: Sendable { init(debounceSeconds: Double); mutating func observe(bundleID: String, active: Bool, at now: Instant) -> MeetingActivityChange? }`
  - `public protocol AppAudioActivityProbing: Sendable { func inputActivity(bundleIDs: Set<String>) -> [String: Bool] }`
  - `public struct CoreAudioAppActivityProbe: AppAudioActivityProbing` — the only new Core Audio code.

- [ ] **Step 1: Write the failing tracker tests**

```swift
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
    #expect(change == MeetingActivityChange(bundleID: "us.zoom.xos", active: true, episode: "us.zoom.xos#1"))
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

  @Test("an ended episode carries the episode id that began it, and the next begin mints a fresh one")
  func episodeIdsAdvance() {
    var tracker = MeetingEpisodeTracker(debounceSeconds: 2)
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(0))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(2))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: false, at: at(10))
    let ended = tracker.observe(bundleID: "us.zoom.xos", active: false, at: at(12))
    #expect(ended == MeetingActivityChange(bundleID: "us.zoom.xos", active: false, episode: "us.zoom.xos#1"))
    _ = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(20))
    let second = tracker.observe(bundleID: "us.zoom.xos", active: true, at: at(22))
    #expect(second?.episode == "us.zoom.xos#2")
  }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter MeetingEpisodeTrackerTests` — FAIL (types missing).

- [ ] **Step 3: Implement the tracker**

`MeetingEpisodeTracker.swift`:

```swift
import EarsCore

/// One confirmed activity edge for a watched bundle id.
public struct MeetingActivityChange: Sendable, Hashable {
  public var bundleID: String
  public var active: Bool
  /// Daemon-boot-scoped: `<bundle-id>#<n>`, stable across one continuous
  /// meeting. An `active == false` change carries the id of the episode that
  /// just ended.
  public var episode: String

  public init(bundleID: String, active: Bool, episode: String) {
    self.bundleID = bundleID
    self.active = active
    self.episode = episode
  }
}

/// Pure debounce state machine turning raw per-poll activity samples into
/// **episodes**: a transition is confirmed only once the observed state has
/// persisted for `debounceSeconds`, so a mic-permission flap or a one-poll
/// glitch never begins or ends a meeting. Clock-injected via the `at`
/// parameter — no wall time.
public struct MeetingEpisodeTracker: Sendable {
  private let debounceSeconds: Double
  private var confirmed: [String: Bool] = [:]
  private var pendingSince: [String: (active: Bool, since: Instant)] = [:]
  private var episodeCounts: [String: Int] = [:]
  private var currentEpisode: [String: String] = [:]

  public init(debounceSeconds: Double) {
    self.debounceSeconds = debounceSeconds
  }

  public mutating func observe(
    bundleID: String, active: Bool, at now: Instant
  ) -> MeetingActivityChange? {
    let current = confirmed[bundleID] ?? false
    guard active != current else {
      pendingSince[bundleID] = nil
      return nil
    }
    guard let pending = pendingSince[bundleID], pending.active == active else {
      pendingSince[bundleID] = (active, now)
      return nil
    }
    guard now.interval(since: pending.since) >= debounceSeconds else { return nil }
    pendingSince[bundleID] = nil
    confirmed[bundleID] = active
    if active {
      let next = (episodeCounts[bundleID] ?? 0) + 1
      episodeCounts[bundleID] = next
      currentEpisode[bundleID] = "\(bundleID)#\(next)"
    }
    return MeetingActivityChange(
      bundleID: bundleID, active: active,
      episode: currentEpisode[bundleID] ?? "\(bundleID)#0")
  }
}
```

- [ ] **Step 4: Run tracker tests** — `swift test --filter MeetingEpisodeTrackerTests` — PASS.

- [ ] **Step 5: Implement the Core Audio probe (shim, tier 2)**

`AppAudioActivityProbe.swift` — the HAL patterns mirror `ProcessTapEngine.swift:176-193`'s `AudioObjectGetPropertyData` usage:

```swift
import CoreAudio
import Foundation

/// Answers "is any live process with this bundle id currently running audio
/// *input* (using the microphone)?" — the meeting-detection signal. A seam
/// so the monitor is testable with a scripted fake; the Core Audio
/// conformance below is the only real one.
public protocol AppAudioActivityProbing: Sendable {
  func inputActivity(bundleIDs: Set<String>) -> [String: Bool]
}

/// The production probe: enumerates the HAL's process objects
/// (`kAudioHardwarePropertyProcessObjectList`), reads each one's bundle id
/// (`kAudioProcessPropertyBundleID`) and input-running flag
/// (`kAudioProcessPropertyIsRunningInput`), and ORs the flags per watched
/// bundle id. Read-only global HAL properties — no tap is created and no TCC
/// grant is required.
public struct CoreAudioAppActivityProbe: AppAudioActivityProbing {
  public init() {}

  public func inputActivity(bundleIDs: Set<String>) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for id in bundleIDs { result[id] = false }
    for object in processObjectList() {
      guard let bundle = stringProperty(object, kAudioProcessPropertyBundleID),
        bundleIDs.contains(bundle)
      else { continue }
      if uint32Property(object, kAudioProcessPropertyIsRunningInput) == 1 {
        result[bundle] = true
      }
    }
    return result
  }

  private func processObjectList() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else { return [] }
    var objects = [AudioObjectID](
      repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objects)
    return status == noErr ? objects : []
  }

  private func stringProperty(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private func uint32Property(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
    return status == noErr ? value : 0
  }
}
```

- [ ] **Step 6: Add the env-gated live smoke test**

`AppAudioActivityProbeLiveTests.swift` (mirrors the repo's live-test gating style — check `IntegrationFixture.swift`/`AMIDiarizationLiveTests` for the exact enable pattern and copy it):

```swift
import Foundation
import Testing

@testable import EarsCaptureKit

@Suite("App audio activity probe (live)", .enabled(if: ProcessInfo.processInfo.environment["EARS_LIVE_MEETING_DETECT_TEST"] == "1"))
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
```

- [ ] **Step 7: Run, format, commit**

Run: `swift test --filter EarsCaptureKitTests` — Expected: PASS (live suite skipped by default).

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsCaptureKit/MeetingEpisodeTracker.swift Sources/EarsCaptureKit/AppAudioActivityProbe.swift Tests/EarsCaptureKitTests/
git commit -m "feat(capture): meeting episode tracker and CoreAudio app-activity probe"
```

---

### Task 7: MeetingActivityMonitor + daemon wiring + `[earsd.detection]` config

**Files:**
- Create: `daemon/Sources/EarsDaemonKit/MeetingActivityMonitor.swift`
- Modify: `daemon/Sources/EarsDaemonKit/EarsDaemon.swift` (configuration struct ~line 18-126, `init` ~293, `start()` ~431, `stop()` ~637)
- Modify: `daemon/Sources/EarsDaemonKit/ControlServer.swift` (init ~46, `handleStatus` ~152)
- Modify: `daemon/Sources/EarsCore/Config/EarsdConfigSchema.swift` (defaults ~line 16-59, schema ~79)
- Modify: `daemon/Sources/earsd/DaemonConfigResolution.swift` (~line 107 configuration build)
- Modify: `daemon/Sources/earsd/EarsdRuntime.swift` (pass the real probe where `EarsDaemon(...)` is constructed)
- Modify: `docs/configuration.md` (new `[earsd.detection]` section beside `[earsd.sessions]` ~line 102)
- Modify: `docs/architecture.md` (one paragraph: the activity monitor component and `meeting.activity` event)
- Test: `daemon/Tests/EarsDaemonKitTests/MeetingActivityMonitorTests.swift`; extend the `DaemonConfigResolution` tests in `daemon/Tests/` (find via `grep -rln "DaemonConfigResolution" daemon/Tests/`)

**Interfaces:**
- Consumes: `MeetingEpisodeTracker`, `AppAudioActivityProbing` (Task 6); `MeetingActivityStatus`, `EarsEvent.meetingActivity` (Task 5); `SessionRegistry.appAudioActivity` (Task 4); `EventBus.publish`.
- Produces:
  - `public struct WatchedAppSource: Sendable, Hashable { source: SourceID; bundleID: String; label: String }`
  - `public actor MeetingActivityMonitor { init(watched:debounceSeconds:probe:clock:sleep:onChange:); func start(); func stop(); func snapshot() -> [MeetingActivityStatus] }` with `public typealias ActivitySink = @Sendable (MeetingActivityStatus) async -> Void`.
  - `public struct DetectionSettings: Sendable { enabled: Bool; debounceSeconds: Double; appIdleGraceSeconds: Double }` on `EarsDaemonConfiguration` as `public var detection: DetectionSettings` (default `DetectionSettings()` = enabled, 2s, 90s).
  - `ControlServer.init(..., meetingActivity: @Sendable () async -> [MeetingActivityStatus] = { [] })`.
  - `EarsDaemon.init(..., activityProbe: (any AppAudioActivityProbing)? = nil, ...)` — `nil` (the default) builds no monitor, keeping every existing daemon test hermetic.

- [ ] **Step 1: Write the failing monitor tests**

`MeetingActivityMonitorTests.swift` — drive the poll loop with a scripted probe and a gated sleep. `SleepGate` and `waitUntil` live in `SessionRegistryTests.swift` (~line 1010/1030); if they are file-private there, copy these standalone versions in:

```swift
import EarsCaptureKit
import EarsCore
import EarsCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// A probe whose answer repeats its script's last entry once exhausted, so a
/// finished script holds steady instead of reading as "everything went quiet".
private final class ScriptedProbe: AppAudioActivityProbing, @unchecked Sendable {
  private let lock = NSLock()
  private var script: [[String: Bool]]
  init(_ script: [[String: Bool]]) { self.script = script }
  func inputActivity(bundleIDs: Set<String>) -> [String: Bool] {
    lock.lock()
    defer { lock.unlock() }
    guard let first = script.first else { return [:] }
    if script.count > 1 { script.removeFirst() }
    return first
  }
}

private actor SleepGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait(_ seconds: Double) async {
    await withCheckedContinuation { waiters.append($0) }
  }
  func releaseAll() {
    let current = waiters
    waiters = []
    for waiter in current { waiter.resume() }
  }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
  for _ in 0..<2_000 {
    if await condition() { return }
    await Task.yield()
  }
  Issue.record("condition never became true")
}

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
```

(If `Mutex`'s generic spelling differs in this toolchain, use the same `Mutex` usage `SessionRegistryTests.swift:37` already compiles with.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter MeetingActivityMonitorTests` — FAIL.

- [ ] **Step 3: Implement the monitor**

`MeetingActivityMonitor.swift`:

```swift
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
```

- [ ] **Step 4: Run monitor tests** — `swift test --filter MeetingActivityMonitorTests` — PASS.

- [ ] **Step 5: Config schema + resolution (test-first within this step)**

Add to the `DaemonConfigResolution` test suite:

```swift
@Test("[earsd.detection] resolves with defaults and explicit values")
func detectionSettingsResolve() {
  let defaults = DaemonConfigResolution.resolve(
    config: .table([:]), now: Instant(secondsSinceEpoch: 0))
  #expect(defaults.configuration.detection.enabled)
  #expect(defaults.configuration.detection.debounceSeconds == 2)
  #expect(defaults.configuration.detection.appIdleGraceSeconds == 90)

  let explicit = DaemonConfigResolution.resolve(
    config: .table([
      "earsd": .table([
        "detection": .table([
          "enabled": .bool(false), "debounce_s": .int(5), "idle_grace_s": .int(30),
        ])
      ])
    ]),
    now: Instant(secondsSinceEpoch: 0))
  #expect(!explicit.configuration.detection.enabled)
  #expect(explicit.configuration.detection.debounceSeconds == 5)
  #expect(explicit.configuration.detection.appIdleGraceSeconds == 30)
}
```

Then implement:

1. `EarsDaemon.swift` — add to `EarsDaemonConfiguration`:
```swift
/// `[earsd.detection]`: native-app meeting detection. See `MeetingActivityMonitor`.
public struct DetectionSettings: Sendable {
  public var enabled: Bool
  public var debounceSeconds: Double
  public var appIdleGraceSeconds: Double

  public init(enabled: Bool = true, debounceSeconds: Double = 2, appIdleGraceSeconds: Double = 90) {
    self.enabled = enabled
    self.debounceSeconds = debounceSeconds
    self.appIdleGraceSeconds = appIdleGraceSeconds
  }
}
```
   with `public var detection: DetectionSettings` and an `detection: DetectionSettings = DetectionSettings()` init parameter (place after `browserSessionLocalSources`).
2. `EarsdConfigSchema.swift` — defaults: add under `"earsd"`:
```swift
"detection": .table([
  "enabled": .bool(true),
  "debounce_s": .int(2),
  "idle_grace_s": .int(90),
]),
```
   and the matching schema field (same shape as the `sessions` table field, with descriptions: master switch; seconds an activity sample must persist before an episode edge is confirmed; seconds of continuous inactivity before an `app-detected` session auto-ends).
3. `DaemonConfigResolution.swift` — read it:
```swift
let detectionTable = nestedTable(earsd, "detection")
```
   and pass `detection: DetectionSettings(enabled: bool(detectionTable, "enabled", default: true), debounceSeconds: Double(int(detectionTable, "debounce_s", default: 2)), appIdleGraceSeconds: Double(int(detectionTable, "idle_grace_s", default: 90)))` in the `EarsDaemonConfiguration(...)` build.

Run: `swift test --filter EarsConfigTests` and the daemon-config suite — PASS. Also run `swift test --filter CLISmokeTests` if it exercises `ears config describe` (schema snapshot drift shows up there).

- [ ] **Step 6: Wire the monitor into EarsDaemon and ControlServer**

`ControlServer.swift`: add `private let meetingActivity: @Sendable () async -> [MeetingActivityStatus]` with init parameter `meetingActivity: @escaping @Sendable () async -> [MeetingActivityStatus] = { [] }` (after `sessions:`), and in `handleStatus()` build `StatusData(..., meetingActivity: await meetingActivity())`.

`EarsDaemon.swift`:
1. Actor stored property `private var meetingMonitor: MeetingActivityMonitor?` and init parameter `activityProbe: (any AppAudioActivityProbing)? = nil` stored as `private let activityProbe: (any AppAudioActivityProbing)?`.
2. In `start()`, after `sessionRegistry = sessions` and **before** the `ControlServer` is constructed:
```swift
    // Native-app meeting detection: watch every configured app:* source's
    // process audio input, publish confirmed edges as meeting.activity
    // telemetry, and feed the registry's app-idle auto-end policy. Built only
    // when a probe was injected (earsd's main passes the real Core Audio
    // one; tests default to none) and there is something to watch.
    let watchedApps = configuration.sources
      .filter { $0.sourceClass == .app }
      .compactMap { descriptor -> WatchedAppSource? in
        guard let bundleID = descriptor.id.detail else { return nil }
        return WatchedAppSource(source: descriptor.id, bundleID: bundleID, label: descriptor.label)
      }
    if configuration.detection.enabled, let activityProbe, !watchedApps.isEmpty {
      meetingMonitor = MeetingActivityMonitor(
        watched: watchedApps,
        debounceSeconds: configuration.detection.debounceSeconds,
        probe: activityProbe,
        clock: clock,
        onChange: { [eventBus] status in
          await eventBus.publish(.meetingActivity(status))
          await sessions.appAudioActivity(source: status.source, active: status.active)
        })
    }
```
3. Pass the registry the grace: `appIdleGraceSeconds: configuration.detection.appIdleGraceSeconds` in the `SessionRegistry(...)` construction.
4. `ControlServer(...)` construction gains `meetingActivity: { [weak self] in await self?.meetingMonitor?.snapshot() ?? [] }` — if capturing `self` weakly there fights actor-isolation, capture the monitor into a local `let monitor = meetingMonitor` first and use `{ await monitor?.snapshot() ?? [] }`.
5. At the end of `start()` (after `eventBus.attach`): `await meetingMonitor?.start()`.
6. In `stop()` (before the capture-actor loop): `if let meetingMonitor { await meetingMonitor.stop() }; meetingMonitor = nil`.

`EarsdRuntime.swift`: find the `EarsDaemon(configuration:backendFactory:...)` construction and add `activityProbe: CoreAudioAppActivityProbe()` (add `import EarsCaptureKit` if missing — `RealCaptureBackendFactory.swift` in the same target already imports it).

- [ ] **Step 7: Real-socket integration test (spec's tier-1 item)**

Extend `daemon/Tests/EarsDaemonKitTests/EarsDaemonTests.swift` with one end-to-end test, copying the file's existing real-socket arrangement (it already builds an `EarsDaemon` with a synthetic backend factory, `start()`s it, and connects a `ControlSocketClient`; find the pattern via `grep -n "ControlSocketClient" Tests/EarsDaemonKitTests/EarsDaemonTests.swift`):

```swift
@Test("meeting activity reaches a real-socket subscriber and the status snapshot")
func meetingActivityOverTheSocket() async throws {
  // Arrange exactly like the existing socket test, with two additions to the
  // configuration/daemon construction:
  //   - configuration.sources includes an app-class descriptor:
  //     id app:us.zoom.xos, label "Zoom" (same capture params as the mic one).
  //   - EarsDaemon(..., activityProbe: ScriptedProbe([["us.zoom.xos": true]]))
  //     with detection: DetectionSettings(enabled: true, debounceSeconds: 0,
  //     appIdleGraceSeconds: 90) on the configuration.
  // Then: hello + subscribe(SubscribeParams(events: [.meetingActivity])) on a
  // real ControlSocketClient; await the first event frame and expect
  // .meetingActivity with source app:us.zoom.xos, label "Zoom", active true,
  // episode "us.zoom.xos#1"; then send .status and expect
  // status.meetingActivity to carry the same entry.
}
```

The body is a transcription of the existing test's harness with those deltas — reuse its listener/socket-path/teardown code verbatim (`ScriptedProbe` from the monitor tests: move it into a shared test-support file in `Tests/EarsDaemonKitTests/` if both files need it).

- [ ] **Step 8: Build, run the full daemon-kit suite**

Run: `swift build && swift test --filter EarsDaemonKitTests`
Expected: PASS (existing `EarsDaemonTests` untouched — no probe injected means no monitor).

- [ ] **Step 9: Docs, format, commit**

`docs/configuration.md`: add an `[earsd.detection]` section beside `[earsd.sessions]` (~line 102) documenting `enabled`/`debounce_s`/`idle_grace_s` with defaults, and a sentence pointing at the `app:us.zoom.xos` source example (~line 153) as what gets watched. `docs/architecture.md`: one paragraph in the daemon section describing the monitor, the `meeting.activity` event, and the app-idle auto-end.

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/ Tests/ ../docs/configuration.md ../docs/architecture.md
git commit -m "feat(earsd): meeting-activity monitor, [earsd.detection] config, status wiring"
```

---

### Task 8: Menu bar state — subscribe, reduce, catch up

**Files:**
- Modify: `daemon/Sources/ears-menubar/DaemonConnection.swift:43` (subscribe kinds) and add a typed session-start call
- Modify: `daemon/Sources/EarsMenuKit/MenuState.swift`, `daemon/Sources/EarsMenuKit/MenuStateReducer.swift`
- Modify: `daemon/Sources/ears-menubar/AppModel.swift` (`anchorUptime` ~line 253 → status catch-up)
- Test: `daemon/Tests/EarsMenuKitTests/` (reducer tests — extend the existing reducer suite)

**Interfaces:**
- Consumes: `MeetingActivityStatus`, `StatusData.meetingActivity`, `EarsEvent.meetingActivity` (Task 5).
- Produces:
  - `MenuState.meetingActivity: [MeetingActivityStatus]` (init `[]`) and `MenuState.activeMeetings: [MeetingActivityStatus]` (filter `active`).
  - `MenuStateReducer.apply` handles `.meetingActivity` (upsert by `source`, returns `.applied`).
  - `MenuStateReducer.catchUpMeetingActivity(_ state: inout MenuState, _ list: [MeetingActivityStatus])` (replace wholesale).
  - `DaemonConnection.startSession(_ params: SessionStartParams) async -> Result<Session, WireError>`.

- [ ] **Step 1: Write the failing reducer tests**

In the EarsMenuKit reducer test suite add:

```swift
@Test("meeting.activity telemetry upserts by source and applies without a rev")
func meetingActivityUpserts() {
  var state = MenuState()
  state.connection = .connected
  state.lastRev = 1
  let began = MeetingActivityStatus(
    source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
    label: "Zoom", active: true, episode: "us.zoom.xos#1")
  #expect(MenuStateReducer.apply(&state, EventFrame(event: .meetingActivity(began))) == .applied)
  #expect(state.activeMeetings == [began])
  var ended = began
  ended.active = false
  _ = MenuStateReducer.apply(&state, EventFrame(event: .meetingActivity(ended)))
  #expect(state.activeMeetings.isEmpty)
  #expect(state.meetingActivity == [ended])
}

@Test("reconnect clears stale activity until status catches up")
func reconnectClearsActivity() {
  var state = MenuState()
  state.meetingActivity = [
    MeetingActivityStatus(
      source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
      label: "Zoom", active: true, episode: "us.zoom.xos#1")
  ]
  MenuStateReducer.connected(&state, daemon: "earsd", snapshot: SnapshotData(rev: 0, sessions: [], sources: []))
  #expect(state.meetingActivity.isEmpty)
  MenuStateReducer.catchUpMeetingActivity(&state, [
    MeetingActivityStatus(
      source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
      label: "Zoom", active: true, episode: "us.zoom.xos#2")
  ])
  #expect(state.activeMeetings.count == 1)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter EarsMenuKitTests` — FAIL.

- [ ] **Step 3: Implement**

`MenuState.swift`: add `public var meetingActivity: [MeetingActivityStatus]` (init `[]`) and

```swift
  public var activeMeetings: [MeetingActivityStatus] {
    meetingActivity.filter(\.active)
  }
```
plus a `mutating func upsertMeetingActivity(_ status: MeetingActivityStatus)` in the extension (replace the entry whose `source` matches, else append).

`MenuStateReducer.swift`: in `connected(...)` add `state.meetingActivity = []` (the snapshot doesn't carry it; status catch-up refills). In `apply` add:

```swift
    case .meetingActivity(let status):
      state.upsertMeetingActivity(status)
      return .applied
```

and:

```swift
  /// `status`'s `meeting_activity` list, applied wholesale — the catch-up a
  /// freshly connected client does instead of waiting for the next edge.
  public static func catchUpMeetingActivity(
    _ state: inout MenuState, _ list: [MeetingActivityStatus]
  ) {
    state.meetingActivity = list
  }
```

`DaemonConnection.swift`: line 43 → `subscribe(SubscribeParams(events: [.job, .meetingActivity]))`. Add:

```swift
  /// `session.start`, decoding the full session result — the menu needs the
  /// daemon-assigned id back to upsert calendar attendees against it.
  func startSession(_ params: SessionStartParams) async -> Result<Session, WireError> {
    guard let client else {
      return .failure(WireError(code: .internalError, message: "not connected to earsd"))
    }
    do {
      return .success(try await client.send(.sessionStart(params), expecting: Session.self))
    } catch let error as WireError {
      return .failure(error)
    } catch {
      return .failure(WireError(code: .internalError, message: "\(error)"))
    }
  }
```

`AppModel.swift`: rename/extend `anchorUptime` into the status catch-up — after `let seconds = await connection.status()?.uptimeSeconds`, fetch the whole `StatusData` once instead:

```swift
    Task { [weak self] in
      let status = await connection.status()
      guard let self else { return }
      self.uptime = status.map { DaemonUptime(reported: Double($0.uptimeSeconds), anchor: Self.now()) }
      if let status {
        MenuStateReducer.catchUpMeetingActivity(&self.state, status.meetingActivity)
      }
      self.rerender()
    }
```
(`state` is `private(set)`; mutate via a small internal method if the property setter isn't reachable — add `func applyStatusCatchUp(_ status: StatusData)` on `AppModel` if needed.)

- [ ] **Step 4: Run tests + build** — `swift test --filter EarsMenuKitTests && swift build` — PASS.

- [ ] **Step 5: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsMenuKit/ Sources/ears-menubar/ Tests/EarsMenuKitTests/
git commit -m "feat(menubar): track meeting.activity telemetry with status catch-up"
```

---

### Task 9: Prompt policy, notification action, menu offer, detected session start

**Files:**
- Create: `daemon/Sources/EarsMenuKit/MeetingPromptPolicy.swift` (policy + `DetectedSessionIdentity`)
- Modify: `daemon/Sources/EarsMenuKit/MenuContent.swift` (Verb case), `daemon/Sources/EarsMenuKit/MenuRenderer.swift` (verbs), `daemon/Sources/EarsMenuKit/NotificationPolicy.swift` (Action case)
- Modify: `daemon/Sources/ears-menubar/Notifier.swift` (encode/decode/route), `daemon/Sources/ears-menubar/SessionNotifications.swift` (post + start-handler wiring), `daemon/Sources/ears-menubar/AppModel.swift` (prompt trigger + start flow), `daemon/Sources/ears-menubar/MenuContentView.swift` (verb label)
- Create: `daemon/Sources/ears-menubar/PromptedEpisodeStore.swift`
- Test: `daemon/Tests/EarsMenuKitTests/MeetingPromptPolicyTests.swift`

**Interfaces:**
- Consumes: `MenuState.activeMeetings` (Task 8), `NotificationRequest`, `TriggerKind.appDetected`, `DaemonConnection.startSession` (Task 8).
- Produces:
  - `public struct MeetingPrompt: Sendable, Hashable { source: SourceID; episode: String; label: String; request: NotificationRequest }`
  - `public enum MeetingPromptPolicy { static func prompts(state: MenuState, alreadyPrompted: Set<String>) -> [MeetingPrompt] }`
  - `public enum DetectedSessionIdentity { static func platform(forBundleID: String) -> String }` (`us.zoom.xos` → `zoom-app`, `com.microsoft.teams2`/`com.microsoft.teams` → `teams-app`, else the bundle id).
  - `Verb.startDetected(source: String, episode: String, label: String)`.
  - `NotificationRequest.Action.startDetected(source: String, episode: String, label: String)`.
  - `AppModel.startDetectedSession(source: String, episode: String)` (Task 12 extends it with calendar enrichment).

- [ ] **Step 1: Write the failing policy tests**

```swift
import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("Meeting prompt policy")
struct MeetingPromptPolicyTests {
  private func zoomActive(_ episode: String = "us.zoom.xos#1") -> MeetingActivityStatus {
    MeetingActivityStatus(
      source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
      label: "Zoom", active: true, episode: episode)
  }
  private func connectedState(_ activity: [MeetingActivityStatus]) -> MenuState {
    var state = MenuState()
    state.connection = .connected
    state.meetingActivity = activity
    return state
  }

  @Test("an active meeting with no live session prompts once")
  func promptsForActiveMeeting() {
    let prompts = MeetingPromptPolicy.prompts(state: connectedState([zoomActive()]), alreadyPrompted: [])
    #expect(prompts.count == 1)
    #expect(prompts[0].episode == "us.zoom.xos#1")
    #expect(prompts[0].request.title == "Zoom meeting detected")
    #expect(prompts[0].request.action == .startDetected(source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom"))
  }

  @Test("an already-prompted episode stays quiet")
  func dedupsByEpisode() {
    let prompts = MeetingPromptPolicy.prompts(
      state: connectedState([zoomActive()]), alreadyPrompted: ["us.zoom.xos#1"])
    #expect(prompts.isEmpty)
  }

  @Test("a live session suppresses (drops) the prompt")
  func activeSessionSuppresses() {
    var state = connectedState([zoomActive()])
    state.sessions = [
      Session(id: "s1", title: "t", state: .active, started: Instant(secondsSinceEpoch: 0))
    ]
    #expect(MeetingPromptPolicy.prompts(state: state, alreadyPrompted: []).isEmpty)
  }

  @Test("ended activity never prompts")
  func endedActivityQuiet() {
    var ended = zoomActive()
    ended.active = false
    #expect(MeetingPromptPolicy.prompts(state: connectedState([ended]), alreadyPrompted: []).isEmpty)
  }

  @Test("bundle ids map to platform slugs with a bundle-id fallback")
  func platformSlugs() {
    #expect(DetectedSessionIdentity.platform(forBundleID: "us.zoom.xos") == "zoom-app")
    #expect(DetectedSessionIdentity.platform(forBundleID: "com.microsoft.teams2") == "teams-app")
    #expect(DetectedSessionIdentity.platform(forBundleID: "com.example.other") == "com.example.other")
  }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter MeetingPromptPolicyTests` — FAIL.

- [ ] **Step 3: Implement the pure pieces**

`MeetingPromptPolicy.swift`:

```swift
import EarsCore

/// One prompt-worthy detected meeting: what to say and the action a click
/// performs.
public struct MeetingPrompt: Sendable, Hashable {
  public var source: SourceID
  public var episode: String
  public var label: String
  public var request: NotificationRequest

  public init(source: SourceID, episode: String, label: String, request: NotificationRequest) {
    self.source = source
    self.episode = episode
    self.label = label
    self.request = request
  }
}

/// Decides which detected meetings deserve a prompt right now. Policy, not
/// state: the caller owns the already-prompted set (persisted across app
/// restarts, keyed on the daemon's episode ids) and marks episodes as it
/// posts. Episodes that begin while a session is live are dropped, not
/// deferred — no prompt fires for them later.
public enum MeetingPromptPolicy {
  public static func prompts(
    state: MenuState, alreadyPrompted: Set<String>
  ) -> [MeetingPrompt] {
    guard state.connection == .connected, state.activeSession == nil else { return [] }
    return state.activeMeetings
      .filter { !alreadyPrompted.contains($0.episode) }
      .map { activity in
        let label = activity.label.isEmpty ? activity.source.rawValue : activity.label
        return MeetingPrompt(
          source: activity.source,
          episode: activity.episode,
          label: label,
          request: NotificationRequest(
            title: "\(label) meeting detected",
            body: "Start recording?",
            action: .startDetected(
              source: activity.source.rawValue, episode: activity.episode, label: label)))
      }
  }
}

/// The `session.start` platform slug for a detected native-app meeting.
public enum DetectedSessionIdentity {
  public static func platform(forBundleID bundleID: String) -> String {
    switch bundleID {
    case "us.zoom.xos": return "zoom-app"
    case "com.microsoft.teams2", "com.microsoft.teams": return "teams-app"
    default: return bundleID
    }
  }
}
```

`NotificationPolicy.swift` — extend the Action enum:

```swift
    case startDetected(source: String, episode: String, label: String)
```

`MenuContent.swift` — `Verb` gains `case startDetected(source: String, episode: String, label: String)`.

`MenuRenderer.swift` — in `verbs(for:)`, replace the no-session branch:

```swift
    guard let session = state.activeSession else {
      let offers = state.activeMeetings.map { activity in
        Verb.startDetected(
          source: activity.source.rawValue, episode: activity.episode,
          label: activity.label.isEmpty ? activity.source.rawValue : activity.label)
      }
      return offers + [.startRecording]
    }
```

- [ ] **Step 4: Run policy + renderer tests** — `swift test --filter EarsMenuKitTests` — PASS (extend the existing renderer verb test with a detected-offer case if one exists).

- [ ] **Step 5: App-target wiring**

`PromptedEpisodeStore.swift` (new, `ears-menubar` target):

```swift
import Foundation

/// Episodes already prompted (or accepted), persisted so a menu bar restart
/// mid-meeting doesn't re-prompt for the same episode. Bounded: only the
/// most recent entries are kept.
struct PromptedEpisodeStore {
  private static let key = "promptedMeetingEpisodes"
  private static let cap = 50
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var episodes: Set<String> {
    Set(defaults.stringArray(forKey: Self.key) ?? [])
  }

  func mark(_ episode: String) {
    var list = defaults.stringArray(forKey: Self.key) ?? []
    guard !list.contains(episode) else { return }
    list.append(episode)
    if list.count > Self.cap { list.removeFirst(list.count - Self.cap) }
    defaults.set(list, forKey: Self.key)
  }
}
```

`Notifier.swift` — extend `encode`/`decode` with the new action (`["action": "startDetected", "source": source, "episode": episode, "label": label]`; decode requires `source`+`episode`, label defaults `""`). Store a start handler: `private var startDetected: (@MainActor @Sendable (String, String) -> Void)?`, set from a new `bootstrap` parameter `startDetected: @escaping @MainActor @Sendable (String, String) -> Void`. In `didReceive`, route `.startDetected(source, episode, _)` to it on the main actor; every other action keeps the URL-resolve path. Update `decode`'s guard: `.startDetected` doesn't carry a `session` key, so restructure the guard to switch on `action` first.

`SessionNotifications.swift` — pass the new closure through `bootstrap(dataRoot:provider:startDetected:report:)` and add:

```swift
  /// Posts detection prompts the policy produced. The caller marks the
  /// episodes prompted.
  func announceMeetingPrompts(_ prompts: [MeetingPrompt]) {
    for prompt in prompts { notifier.post(prompt.request) }
  }
```

`AppModel.swift`:
1. `private let promptedEpisodes = PromptedEpisodeStore()`.
2. In `start()`, pass `startDetected: { [weak self] source, episode in self?.startDetectedSession(source: source, episode: episode) }` into `announcements.bootstrap`.
3. New private method, called from `handleApplied` (when the frame is `.meetingActivity`) and from the status catch-up path of Task 8:
```swift
  private func offerDetectedMeetings() {
    if state.activeSession != nil {
      // Dropped, not deferred (the spec's prompt policy): an episode that
      // began while a session was live never prompts later — marking it
      // prompted now is what encodes the drop. The menu row still renders
      // from live state, so manual start remains available.
      for activity in state.activeMeetings { promptedEpisodes.mark(activity.episode) }
      return
    }
    let prompts = MeetingPromptPolicy.prompts(
      state: state, alreadyPrompted: promptedEpisodes.episodes)
    guard !prompts.isEmpty else { return }
    for prompt in prompts { promptedEpisodes.mark(prompt.episode) }
    announcements.announceMeetingPrompts(prompts)
  }
```
4. `perform(_:)` gains `case .startDetected(let source, let episode, _): startDetectedSession(source: source, episode: episode); return`.
5. The start flow (Task 12 extends this with calendar enrichment):
```swift
  func startDetectedSession(source: String, episode: String) {
    guard let connection else { return }
    reloadDeclarations()
    let app = SourceID(source)
    var declared = sources.filter { $0 == SourceID("mic") }
    declared.append(app)
    promptedEpisodes.mark(episode)
    // No on_end_stages: the daemon's own policy runs the configured chain
    // for app-detected sessions (OnEndChainPolicy), unlike manual starts.
    let params = SessionStartParams(
      platform: DetectedSessionIdentity.platform(forBundleID: app.detail ?? app.rawValue),
      externalID: episode,
      sources: declared,
      trigger: .appDetected)
    Task { [weak self] in
      if case .failure(let error) = await connection.startSession(params) {
        self?.report(error.message)
      } else {
        self?.actionError = nil
      }
    }
  }
```

`MenuContentView.swift` — `label(for:)` gains `case .startDetected(_, _, let label): return "Start Recording ‘\(label)’ Meeting"`.

- [ ] **Step 6: Build + full menu-kit tests** — `swift build && swift test --filter EarsMenuKitTests` — PASS.

- [ ] **Step 7: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsMenuKit/ Sources/ears-menubar/ Tests/EarsMenuKitTests/
git commit -m "feat(menubar): detect-and-prompt flow starting app-detected sessions"
```

---

### Task 10: `calendar` attendee origin

**Files:**
- Modify: `daemon/Sources/EarsCore/Models/Session.swift:200-207` (`AttendeeOrigin`)
- Modify: `docs/data-formats.md:165` (origin comment: add `"calendar"`)
- Test: the `SessionDescriptorTOML` round-trip suite (Task 3's file) + the `RosterReconciler` suite (find via `grep -rln "namedRemoteAttendees\|RosterReconciler" daemon/Tests/`)

**Interfaces:**
- Consumes: `AttendeeOrigin`, `RosterReconciler`.
- Produces: `AttendeeOrigin.calendar`.

- [ ] **Step 1: Write the failing tests**

TOML round-trip (beside Task 3's trigger test):

```swift
@Test("a calendar-origin attendee survives the session.toml round trip")
func calendarOriginRoundTrips() throws {
  var session = Session(
    id: "s1", title: "t", state: .active,
    started: Instant(secondsSinceEpoch: 1_700_000_000))
  session.attendees = [
    SessionAttendee(id: "calendar-0", displayName: "Priya", origin: .calendar)
  ]
  let decoded = try SessionDescriptorTOML.decode(SessionDescriptorTOML.encode(session))
  #expect(decoded.attendees.first?.origin == .calendar)
}
```

Reconciler (in its suite — a calendar attendee is a *person*, unlike synthetic rows; with no `browser:*` sources nothing gets bound, and the derived title includes them):

```swift
@Test("calendar attendees count as named people and produce no speaker bindings for app sessions")
func calendarAttendeesAreRosterOnly() {
  let outcome = RosterReconciler.reconcile(
    attendees: [
      SessionAttendee(id: "calendar-0", displayName: "Saadiq", origin: .calendar, isLocal: true),
      SessionAttendee(id: "calendar-1", displayName: "Priya", origin: .calendar),
    ],
    sources: [SourceID("mic"), SourceID("app:us.zoom.xos")],
    sessionStart: Instant(secondsSinceEpoch: 0),
    hints: [], speech: nil)
  #expect(outcome.speakers.isEmpty)
  let title = RosterReconciler.derivedTitle(
    attendees: [
      SessionAttendee(id: "calendar-0", displayName: "Saadiq", origin: .calendar, isLocal: true),
      SessionAttendee(id: "calendar-1", displayName: "Priya", origin: .calendar),
    ],
    localAttendeeID: "calendar-0")
  #expect(title?.contains("Priya") == true)
}
```

(Match `reconcile`'s exact signature from `daemon/Sources/EarsCore/Session/RosterReconciler.swift:171` — adjust parameter labels as found.)

- [ ] **Step 2: Run to verify failure** — the TOML test fails (`.calendar` missing).

- [ ] **Step 3: Implement**

Add to `AttendeeOrigin`:

```swift
  /// An attendee copied from a matched calendar event — a person invited to
  /// the meeting, not necessarily one who spoke. Roster/summary enrichment
  /// only: calendar rows carry no source binding, and reconciliation treats
  /// them as named people (never as track stand-ins like ``synthetic``).
  case calendar
```

Then check `RosterReconciler` for any `origin == .synthetic` / `origin != .synthetic` branching (`grep -n "synthetic" daemon/Sources/EarsCore/Session/RosterReconciler.swift`) and confirm `.calendar` flows down the "named person" path; adjust only if a switch is exhaustive over origins. Update `docs/data-formats.md:165`'s origin comment to name all three values.

- [ ] **Step 4: Run tests** — `swift test --filter EarsCoreTests && swift test --filter EarsConfigTests` — PASS.

- [ ] **Step 5: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsCore/ Tests/ ../docs/data-formats.md
git commit -m "feat(earsd): calendar attendee origin for roster enrichment"
```

---

### Task 11: Calendar event matching (pure)

**Files:**
- Create: `daemon/Sources/EarsMenuKit/CalendarMatching.swift`
- Test: `daemon/Tests/EarsMenuKitTests/CalendarMatchingTests.swift`

**Interfaces:**
- Consumes: `EarsCore.Instant`.
- Produces:
  - `public struct CalendarAttendee: Sendable, Hashable { name: String; isCurrentUser: Bool }`
  - `public struct CalendarEventInfo: Sendable, Hashable { title: String; start: Instant; end: Instant; matchText: String; attendees: [CalendarAttendee] }` (`matchText` = lowercased concatenation of location/notes/URL, built by the shim)
  - `public enum CalendarMatching { static let joinSlackSeconds: Double = 600; static func marker(forBundleID: String) -> String?; static func best(events: [CalendarEventInfo], now: Instant, platformMarker: String?) -> CalendarEventInfo? }`

- [ ] **Step 1: Write the failing tests**

```swift
import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("Calendar event matching")
struct CalendarMatchingTests {
  private func event(
    _ title: String, start: Double, end: Double, matchText: String = ""
  ) -> CalendarEventInfo {
    CalendarEventInfo(
      title: title, start: Instant(secondsSinceEpoch: start),
      end: Instant(secondsSinceEpoch: end), matchText: matchText, attendees: [])
  }

  @Test("an event overlapping now wins over one already over")
  func overlappingWins() {
    let match = CalendarMatching.best(
      events: [event("old", start: 0, end: 900), event("current", start: 1_000, end: 2_800)],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: nil)
    #expect(match?.title == "current")
  }

  @Test("joining early (inside the slack) still matches")
  func earlyJoinMatches() {
    let match = CalendarMatching.best(
      events: [event("upcoming", start: 2_000, end: 3_800)],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: nil)
    #expect(match?.title == "upcoming")
  }

  @Test("a platform marker breaks a tie between two overlapping events")
  func markerBreaksTie() {
    let match = CalendarMatching.best(
      events: [
        event("no-link", start: 1_000, end: 2_800),
        event("zoom-link", start: 1_000, end: 2_800, matchText: "https://zoom.us/j/123"),
      ],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: "zoom.us")
    #expect(match?.title == "zoom-link")
  }

  @Test("without a marker match the nearest start wins")
  func nearestStartWins() {
    let match = CalendarMatching.best(
      events: [event("long", start: 0, end: 7_200), event("near", start: 1_400, end: 2_800)],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: nil)
    #expect(match?.title == "near")
  }

  @Test("no candidate → nil")
  func noCandidates() {
    #expect(
      CalendarMatching.best(
        events: [event("done", start: 0, end: 900)],
        now: Instant(secondsSinceEpoch: 5_000), platformMarker: nil) == nil)
  }

  @Test("bundle ids resolve to platform markers")
  func markers() {
    #expect(CalendarMatching.marker(forBundleID: "us.zoom.xos") == "zoom.us")
    #expect(CalendarMatching.marker(forBundleID: "com.microsoft.teams2") == "teams.microsoft")
    #expect(CalendarMatching.marker(forBundleID: "com.example.other") == nil)
  }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter CalendarMatchingTests` — FAIL.

- [ ] **Step 3: Implement**

```swift
import EarsCore

/// One attendee from a calendar event, as the EventKit shim maps it.
public struct CalendarAttendee: Sendable, Hashable {
  public var name: String
  public var isCurrentUser: Bool

  public init(name: String, isCurrentUser: Bool) {
    self.name = name
    self.isCurrentUser = isCurrentUser
  }
}

/// One calendar event, reduced to what matching and enrichment need.
/// `matchText` is the lowercased concatenation of the event's location,
/// notes, and URL — where a meeting link lives varies by inviter, so all
/// three are searched as one haystack.
public struct CalendarEventInfo: Sendable, Hashable {
  public var title: String
  public var start: Instant
  public var end: Instant
  public var matchText: String
  public var attendees: [CalendarAttendee]

  public init(
    title: String, start: Instant, end: Instant, matchText: String,
    attendees: [CalendarAttendee]
  ) {
    self.title = title
    self.start = start
    self.end = end
    self.matchText = matchText
    self.attendees = attendees
  }
}

/// Picks the calendar event a just-detected meeting most plausibly is.
/// Candidates overlap now (with slack for joining early); an event whose
/// link/location carries the detected platform's marker wins outright;
/// otherwise the candidate whose start is nearest to now. Calendar data is a
/// garnish, never a gate: `nil` simply means the session starts unenriched.
public enum CalendarMatching {
  /// How early before an event's start a join still counts as that event.
  public static let joinSlackSeconds: Double = 600

  public static func marker(forBundleID bundleID: String) -> String? {
    switch bundleID {
    case "us.zoom.xos": return "zoom.us"
    case "com.microsoft.teams2", "com.microsoft.teams": return "teams.microsoft"
    default: return nil
    }
  }

  public static func best(
    events: [CalendarEventInfo], now: Instant, platformMarker: String?
  ) -> CalendarEventInfo? {
    let candidates = events.filter { event in
      now.secondsSinceEpoch >= event.start.secondsSinceEpoch - joinSlackSeconds
        && now.secondsSinceEpoch <= event.end.secondsSinceEpoch
    }
    guard !candidates.isEmpty else { return nil }
    func markerMatches(_ event: CalendarEventInfo) -> Bool {
      guard let platformMarker else { return false }
      return event.matchText.contains(platformMarker)
    }
    return candidates.min { lhs, rhs in
      if markerMatches(lhs) != markerMatches(rhs) { return markerMatches(lhs) }
      let lhsDistance = abs(now.secondsSinceEpoch - lhs.start.secondsSinceEpoch)
      let rhsDistance = abs(now.secondsSinceEpoch - rhs.start.secondsSinceEpoch)
      if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
      return lhs.title < rhs.title
    }
  }
}
```

(Verify `Instant` exposes `secondsSinceEpoch`; it does — `Instant(secondsSinceEpoch:)` appears throughout the codebase.)

- [ ] **Step 4: Run tests** — `swift test --filter CalendarMatchingTests` — PASS.

- [ ] **Step 5: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/EarsMenuKit/CalendarMatching.swift Tests/EarsMenuKitTests/CalendarMatchingTests.swift
git commit -m "feat(menubar): pure calendar event matching for detected meetings"
```

---

### Task 12: EventKit shim + enriched detected start

**Files:**
- Create: `daemon/Sources/ears-menubar/CalendarProvider.swift`
- Modify: `daemon/Sources/ears-menubar/AppModel.swift` (`startDetectedSession`)
- Modify: `packaging/ears-menubar.Info.plist` (usage string)
- Modify: `docs/superpowers/specs/2026-08-17-native-meeting-detection-design.md` (one amendment, below)
- Test: build-only for the shim (tier 2); the flow's pure parts are covered by Tasks 9/11

**Interfaces:**
- Consumes: `CalendarMatching`, `CalendarEventInfo`, `CalendarAttendee` (Task 11); `DaemonConnection.startSession` (Task 8); `SessionAttendeeParams`, `AttendeeOrigin.calendar` (Task 10).
- Produces: `CalendarProvider.eventsAroundNow() async -> [CalendarEventInfo]?` (`nil` = access denied/unavailable; `[]` = access granted, nothing on).

- [ ] **Step 1: Implement the shim**

`CalendarProvider.swift`:

```swift
import EarsMenuKit
import EarsCore
import EventKit
import Foundation

/// The EventKit shim: requests calendar access lazily on first use and maps
/// today's nearby events into the pure ``CalendarEventInfo`` shape
/// ``CalendarMatching`` consumes. All EventKit types stay inside this file —
/// `EarsMenuKit` never imports EventKit, so the matching logic tests without
/// a calendar grant.
final class CalendarProvider: Sendable {
  private let store = EKEventStore()

  /// Events overlapping a window around now (4 h back, 2 h forward), or
  /// `nil` when access is denied or the request fails — the caller starts
  /// the session unenriched either way (calendar is a garnish, never a gate).
  func eventsAroundNow() async -> [CalendarEventInfo]? {
    let granted = (try? await store.requestFullAccessToEvents()) ?? false
    guard granted else { return nil }
    let now = Date()
    let predicate = store.predicateForEvents(
      withStart: now.addingTimeInterval(-4 * 3_600),
      end: now.addingTimeInterval(2 * 3_600),
      calendars: nil)
    return store.events(matching: predicate).map { event in
      let matchText = [event.location, event.notes, event.url?.absoluteString]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
      let attendees: [CalendarAttendee] = (event.attendees ?? []).compactMap { participant in
        guard participant.participantType == .person, let name = participant.name,
          !name.isEmpty
        else { return nil }
        return CalendarAttendee(name: name, isCurrentUser: participant.isCurrentUser)
      }
      return CalendarEventInfo(
        title: event.title ?? "",
        start: Instant(secondsSinceEpoch: event.startDate.timeIntervalSince1970),
        end: Instant(secondsSinceEpoch: event.endDate.timeIntervalSince1970),
        matchText: matchText,
        attendees: attendees)
    }
  }
}
```

(`Date()` here is the app shim, not a test path — the pure matcher takes `now` as a parameter. If `EKEventStore`'s Sendability fights Swift 6, make the class `@MainActor` instead of `Sendable` — the app model is already main-actor.)

- [ ] **Step 2: Add the usage string**

In `packaging/ears-menubar.Info.plist`, inside the `<dict>`:

```xml
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>All Ears reads your calendar to title detected meetings and record who was invited. Nothing is sent anywhere; it only annotates your local session records.</string>
```

- [ ] **Step 3: Enrich the start flow**

In `AppModel.swift`, add `private let calendar = CalendarProvider()` and rework `startDetectedSession` (from Task 9) so the accept path fetches, matches, starts with the title, then upserts attendees:

```swift
  func startDetectedSession(source: String, episode: String) {
    guard let connection else { return }
    reloadDeclarations()
    let app = SourceID(source)
    var declared = sources.filter { $0 == SourceID("mic") }
    declared.append(app)
    promptedEpisodes.mark(episode)
    let platform = DetectedSessionIdentity.platform(forBundleID: app.detail ?? app.rawValue)
    let marker = CalendarMatching.marker(forBundleID: app.detail ?? "")
    Task { [weak self] in
      let events = await self?.calendar.eventsAroundNow()
      let matched = events.flatMap {
        CalendarMatching.best(events: $0, now: Self.now(), platformMarker: marker)
      }
      let params = SessionStartParams(
        platform: platform,
        externalID: episode,
        title: (matched?.title.isEmpty == false) ? matched?.title : nil,
        sources: declared,
        trigger: .appDetected)
      switch await connection.startSession(params) {
      case .failure(let error):
        self?.report(error.message)
      case .success(let session):
        self?.actionError = nil
        guard let matched else { return }
        for (index, attendee) in matched.attendees.enumerated() {
          let upsert = SessionAttendeeParams(
            session: session.id,
            id: "calendar-\(index)",
            displayName: attendee.name,
            origin: .calendar,
            isLocal: attendee.isCurrentUser ? true : nil)
          if let error = await connection.perform(.sessionAttendee(upsert)) {
            self?.report(error.message)
            break
          }
        }
      }
    }
  }
```

Note the **spec amendment** this encodes: calendar attendees carry **no `source` binding** — not even `mic` for the local user — so the transcript keeps labelling the mic "You" (a reconciled `mic → name` entry would override it). The roster still marks `self: true`.

- [ ] **Step 4: Amend the spec**

In `docs/superpowers/specs/2026-08-17-native-meeting-detection-design.md`, change the attendee bullet

> The user (EventKit marks the current user's attendee): `self: true`, `source: mic`.

to

> The user (EventKit marks the current user's attendee): `self: true`, with **no source binding** — binding `mic` would rename the transcript's "You" turns to the user's own name via the reconciled speaker map.

- [ ] **Step 5: Build and verify**

Run: `swift build && swift test` (from `daemon/`)
Expected: builds; full suite PASS.

- [ ] **Step 6: Format and commit**

```bash
swift format --recursive -i Sources/ Tests/
git add Sources/ears-menubar/ ../packaging/ears-menubar.Info.plist ../docs/superpowers/specs/2026-08-17-native-meeting-detection-design.md
git commit -m "feat(menubar): EventKit enrichment for detected meeting sessions"
```

---

### Task 13: Docs sweep and full verification

**Files:**
- Modify: `docs/overview.md` (~line 54 "Not built yet" — native-app detection is now built; note what still isn't: within-stream diarization, attendee→voice mapping)
- Modify: `docs/architecture.md` / `docs/data-formats.md` / `docs/configuration.md` / `docs/specs/capture-daemon.md` / `docs/specs/control-protocol.md` — verify each per-task doc edit landed; fix any gap
- Modify: `CLAUDE.md` — the "Not built yet" list mentions nothing about detection; if it needs no change, leave it, but remove anything the feature now contradicts

**Interfaces:** none — verification only.

- [ ] **Step 1: Cross-check every contract doc against the code**

For each: trigger values (`data-formats.md`), attendee origins (`data-formats.md`), `[earsd.detection]` (`configuration.md`), `meeting.activity` + `meeting_activity` (`control-protocol.md`), app-idle auto-end (`capture-daemon.md`), monitor component (`architecture.md`). Repo rule: when code and a doc disagree, that is a bug — fix it now.

Also amend the spec (`docs/superpowers/specs/2026-08-17-native-meeting-detection-design.md`): its "MeetingActivityMonitor (EarsCaptureKit)" section places the whole monitor in `EarsCaptureKit`; as built, the Core Audio probe and the pure episode tracker live in `EarsCaptureKit` while the polling/orchestration actor lives in `EarsDaemonKit` (the `EvictionSweeper` pattern) — the seam and the "only EarsCaptureKit touches Core Audio" rule both hold. Update the heading and first sentence to match.

- [ ] **Step 2: Full daemon verification**

Run (from `daemon/`):
```bash
swift format lint --recursive --strict Sources/ Tests/
swift build
swift test
```
Expected: lint clean, build clean, all tests pass.

- [ ] **Step 3: Browser verification**

Run (from `browser/`):
```bash
bun run test
bun run compile
```
Expected: PASS (the only browser-adjacent change is the shared fixture file).

- [ ] **Step 4: Commit the sweep**

```bash
git add ../docs/ ../CLAUDE.md
git commit -m "docs: native meeting detection contracts and overview sweep"
```

- [ ] **Step 5: Manual smoke test (operator step — report, don't skip silently)**

`make install` (with `SIGN_IDENTITY` if available), confirm `[[earsd.source]]` has the `app:us.zoom.xos` entry, start a Zoom test meeting, and verify: notification fires within a few seconds of joining; clicking Start begins a session titled from the calendar (if an event matches); leaving the meeting ends the session ~90 s later; the summary notification arrives; the transcript labels remote audio "Zoom". Report each observation.
