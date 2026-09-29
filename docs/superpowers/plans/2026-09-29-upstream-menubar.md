# Upstream Menu Bar App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a branch off `upstream/main`, build the linear commit stack W1 → W2 → W3 → R1 → App that upstreams `ears-menubar` stage 1 without detection or calendar.

**Architecture:**
- The daemon and wire changes are additive:
  - job events for the on-end LLM stages, carrying the paths they wrote;
  - a per-session declared on-end chain;
  - `status.configured`.
- The session scanner moves from the `ears` executable into `EarsDataStore`.
- The app is `EarsMenuKit` (pure) plus `ears-menubar` (a thin SwiftUI shell). It learns what to record from the daemon and reads sessions back through the shared scanner, so it never parses daemon config.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, swift-testing, SwiftUI `MenuBarExtra`, UserNotifications, ServiceManagement, Make.

**Spec:** `docs/superpowers/specs/2026-09-29-upstream-menubar-design.md`. Read it before starting; this plan argues from it.

**Scope:** this plan covers the upstream stack only. The spec's Phase 0 independent fixes get their own small plan, and so does fork convergence, which is written once this stack is green because it builds on the stack's final shape.

## Global Constraints

- **Base:** `upstream/main` at `d3dd9a4`. Work branch: `upstream-menubar`, in its own worktree.
- **Porting from the fork:** fork code is on local branch `main`. Read it with `git show main:<path>`. Never merge or cherry-pick fork `main` wholesale: the fork's commits conflict when replayed onto upstream. The one exception is Task 8, which cherry-picks cleanly.
- **Toolchain:** Swift 6 strict concurrency, macOS 15. Tests use swift-testing (`import Testing`, `@Test`, `#expect`), never XCTest.
- **Actors:** no `@MainActor` in any library target (`EarsCore`, `EarsConfig`, `EarsDataStore`, `EarsDaemonKit`, `EarsMenuKit`). It's allowed only in `ears-menubar`.
- **Time in tests:** no wall-clock. Inject `Instant` or `ManualClock`, and never call `Date()` in a test path.
- **Size limits:** at most 300 lines per file and 100 per function. Split along real responsibilities. Never make a member less private just so a split compiles.
- **Every commit is green.** From `daemon/`, run:
  `swift format lint --recursive --strict Sources/ Tests/ && swift build && swift test`
  A task that touches `shared/protocol-fixtures/` also runs `cd browser && bun run test`.
- **Commits:** Conventional Commits, `type(scope): summary`. One logical change per commit, with a body that says *why*. Every message ends with the trailer
  `Claude-Session: https://claude.ai/code/session_01RdkKH69c4dxS5rXwCc8o7A`
- **Detection-free gate.** Run from the worktree root before every commit. It must print nothing:
  ```bash
  git grep -nE 'appDetected|app-detected|meetingActivity|meeting\.activity|MeetingActivity|appIdle|app-idle|earsd\.detection|KnownMeetingApp|PromptedEpisode|startDetected|MeetingPrompt|NSUserNotificationAlertStyle|NSCalendars|CaptureSourceEntry|ManualSession(Sources|Stages)|case calendar|PublishingSettings|SessionArtifactLocator' -- daemon docs packaging shared README.md Makefile
  ```
- **Fork-only files never land here:** `CLAUDE.md` and anything under `docs/superpowers/`.
- **Comments** explain *why*. Never write history into them ("an earlier version…", "was tried and was wrong"); that belongs in the commit message.
- **`make install`** must behave exactly as it does upstream.
- **Nothing outward-facing:** no `git push`, no issue, no PR. The user decides when.

## Review Focus

1. **A re-declared session keeps its declared chain.** A session started with identity `{platform, external_id}` and `on_end_stages: ["transcribe"]`, then started again with the same identity and no `on_end_stages` (an extension reconnect), must still run `["transcribe"]`. Pinned in Task 7 (`redeclareWithoutStagesKeepsDeclaration`).
2. **A partly failed summarize doesn't claim outputs.** If summarize exits non-zero after writing 2 of 3 presets, the job is published `failed` with `detail: "exit 4"` and `outputs == nil`. A click must never open a half-run's file as if it were the summary. Pinned in Task 4 (`partialSummarizeFailureCarriesNoOutputs`).
3. **The app refuses to start against an older daemon.** If `status` has no `configured` block, Start Recording sends no `session.start` and shows "earsd is older than this menu bar app…". Pinned in Task 17 (`olderDaemonIsRefused`).
4. **The app refuses to record nothing.** If `configured.sources` is empty, Start Recording sends nothing and says no sources are configured. Pinned in Task 17 (`noSourcesIsRefused`).
5. **A moved summary falls back to scanning.** If "Summary ready" is clicked after the reported file was moved or deleted, the resolver falls back to scanning for the session. If nothing is found, nothing opens. Pinned in Task 17 (`missingWrittenFileFallsBack`).

---

## Task 0: Worktree and baseline

**Files:** none. This is setup only.

- [ ] **Step 1: Create the worktree.** Use superpowers:using-git-worktrees with branch `upstream-menubar` based on `upstream/main`. The equivalent commands:
  ```bash
  cd /Users/saadiq/dev/all-ears && git fetch upstream
  git worktree add -b upstream-menubar ../all-ears-upstream-menubar upstream/main
  cd ../all-ears-upstream-menubar && git config core.hooksPath .githooks
  ```
- [ ] **Step 2: Confirm the fork ref is readable** from the worktree.
  Run: `git show main:daemon/Sources/EarsCore/Session/OnEndStage.swift | head -3`
  Expected: the `/// One stage of the on-end pipeline` header.
- [ ] **Step 3: Record a green baseline.**
  Run: `cd daemon && swift format lint --recursive --strict Sources/ Tests/ && swift build && swift test 2>&1 | tail -3`
  Expected: build succeeds and the test summary reports 0 failures. Note the test count.
- [ ] **Step 4: Confirm the browser baseline.**
  Run: `cd ../browser && bun install && bun run test 2>&1 | tail -3`
  Expected: all pass.

---

# PR W1 — job events for the on-end LLM stages

## Task 1: Move the on-end stage vocabulary into EarsCore

The read side (`ears`, and later the app) must know the stage names without depending on the daemon.

**Files:**
- Create: `daemon/Sources/EarsCore/Session/OnEndStage.swift`
- Modify: `daemon/Sources/EarsDaemonKit/OnClosePipelineRunner.swift` (delete the `OnEndStage` enum)
- Test: `daemon/Tests/EarsCoreTests/OnEndStageTests.swift` (new; the `resolveList` tests move here)

**Interfaces:**
- Produces: `public enum OnEndStage: String, Sendable, Hashable, CaseIterable` in `EarsCore`, with cases `transcribe`, `cleanup`, `summarize` and `public static func resolveList(_ raw: [String]) -> (stages: [OnEndStage], problems: [String])`, unchanged.

- [ ] **Step 1: Write the new file from the fork.**
  ```bash
  git show main:daemon/Sources/EarsCore/Session/OnEndStage.swift > daemon/Sources/EarsCore/Session/OnEndStage.swift
  ```
- [ ] **Step 2: Delete the enum from `OnClosePipelineRunner.swift`.** It runs from the `/// One stage of the on-end pipeline, in chain order.` doc comment through its closing `}`, just before `/// Runs the on-end stage chain against an ended session`. `EarsDaemonKit` already imports `EarsCore`, so every use still resolves.
- [ ] **Step 3: Move the `resolveList` tests.**
  1. Find them: `git grep -n 'resolveList' -- daemon/Tests`. They are in `EarsDaemonKitTests/OnClosePipelineRunnerTests.swift`, titled "resolveList canonicalises order…", "resolveList drops unknown names…" and "resolveList drops LLM stages configured without transcribe…".
  2. Cut those three `@Test` functions into a new `daemon/Tests/EarsCoreTests/OnEndStageTests.swift`:
     ```swift
     import Testing

     @testable import EarsCore

     @Suite("OnEndStage")
     struct OnEndStageTests {
       // the three moved @Test functions, bodies unchanged
     }
     ```
- [ ] **Step 4: Build and test.**
  Run: `cd daemon && swift build && swift test --filter 'OnEndStageTests|OnClosePipelineRunner|DaemonConfigResolution'`
  Expected: PASS. If `earsd` fails to find `OnEndStage`, add `import EarsCore` to `daemon/Sources/earsd/DaemonConfigResolution.swift`.
- [ ] **Step 5: Lint, run the full suite, run the gate, commit.**
  ```bash
  git add -A daemon && git commit -m "refactor(core): move the on-end stage vocabulary into EarsCore

  The pipeline views in \`ears\`, and any other reader, need the stage names to
  say which stages a session asked for, and they should not depend on the
  daemon to get them.

  Claude-Session: https://claude.ai/code/session_01RdkKH69c4dxS5rXwCc8o7A"
  ```

## Task 2: `job.publish` carries the paths a stage wrote

**Files:**
- Modify: `daemon/Sources/EarsCore/Socket/ControlCall.swift` (`JobPublishParams`)
- Modify: `shared/protocol-fixtures/control-v2.json` (add one event fixture)
- Test: `daemon/Tests/EarsCoreTests/JobPublishParamsTests.swift` (new)

**Interfaces:**
- Produces: `JobPublishParams.outputs: [String]?`. The new init parameter `outputs: [String]? = nil` comes last. On the wire it is the key `outputs`, omitted when `nil`.

- [ ] **Step 1: Write the failing test** in `daemon/Tests/EarsCoreTests/JobPublishParamsTests.swift`:
  ```swift
  import Foundation
  import Testing

  @testable import EarsCore

  @Suite("JobPublishParams")
  struct JobPublishParamsTests {
    @Test("a job without outputs encodes no outputs key")
    func omitsAbsentOutputs() throws {
      let params = JobPublishParams(job: "cleanup-1", kind: "cleanup", session: "s", state: .started)
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params))
      let json = try #require(object as? [String: Any])
      #expect(json["outputs"] == nil)
    }

    @Test("outputs round-trip")
    func outputsRoundTrip() throws {
      let params = JobPublishParams(
        job: "summarize-1", kind: "summarize", session: "s", state: .done,
        outputs: ["/notes/a.summary.md", "/notes/a.actions.summary.md"])
      let decoded = try JSONDecoder().decode(
        JobPublishParams.self, from: JSONEncoder().encode(params))
      #expect(decoded == params)
    }

    @Test("a frame without outputs decodes to nil")
    func legacyFrameDecodes() throws {
      let legacy = #"{"job":"j","kind":"transcribe","state":"done"}"#
      let decoded = try JSONDecoder().decode(JobPublishParams.self, from: Data(legacy.utf8))
      #expect(decoded.outputs == nil)
    }
  }
  ```
- [ ] **Step 2: Run it and watch it fail.**
  Run: `cd daemon && swift test --filter JobPublishParamsTests`
  Expected: compile error, "extra argument 'outputs' in call".
- [ ] **Step 3: Implement.** In `JobPublishParams`:
  1. Replace the `kind` doc with:
     `/// \`transcribe\` (self-reported), or \`cleanup\`/\`summarize\` (published by the daemon's on-end chain).`
  2. Add the property after `detail`:
     ```swift
     /// On `done`: the absolute paths the stage wrote — the cleaned transcript
     /// for `cleanup`, each written summary for `summarize`. Lets a subscriber
     /// open exactly what was produced instead of re-deriving it from path
     /// templates. Omitted when there is nothing to report.
     public var outputs: [String]?
     ```
  3. Add `outputs: [String]? = nil` as the last init parameter, with `self.outputs = outputs`.
  4. Add `outputs` to `CodingKeys`: `case job, kind, state, detail, outputs`. The synthesized coding omits a `nil` optional.
- [ ] **Step 4: Add the golden fixture.** Append to the `events` array in `shared/protocol-fixtures/control-v2.json`:
  ```json
  {
    "name": "job-event-summarize-done",
    "frame": {
      "event": "job",
      "params": {
        "job": "summarize-9be04d11",
        "kind": "summarize",
        "session": "0d5e1111-aaaa-bbbb-cccc-222233334444",
        "state": "done",
        "outputs": ["/Users/me/Documents/Transcripts/2026-08-03 standup.summary.md"]
      }
    }
  }
  ```
- [ ] **Step 5: Run the tests.**
  Run: `cd daemon && swift test --filter 'JobPublishParamsTests|ControlProtocolV2FixtureTests' && cd ../browser && bun run test`
  Expected: PASS. The TypeScript tests look fixtures up by name, so the new entry doesn't affect them.
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(protocol): job.publish carries the paths a stage wrote`. Body: a subscriber that wants to open a finished summary should open the file the stage reported, not re-derive its path from config.

## Task 3: `transcribe` accepts the spawner's `--job-id`

This lets the daemon report failures a child dies before reporting, without creating a second job row.

**Files:**
- Modify: `daemon/Sources/transcribe/Transcribe.swift`
- Modify: `daemon/Sources/transcribe/TranscribePipeline.swift`
- Modify: `docs/specs/transcribe.md`

**Interfaces:**
- Produces: the hidden CLI flag `--job-id <id>`, and `TranscribePipeline.Inputs.jobID: String?`. When present, `transcribe` publishes all of its job events under that id; when absent, it mints `transcribe-<8 hex>` as today.

- [ ] **Step 1: Apply the fork's hunks.** Get them with:
  `git show c7894c8 -- daemon/Sources/transcribe/Transcribe.swift daemon/Sources/transcribe/TranscribePipeline.swift`
  - **`Transcribe.swift`:** add the `@Option(name: .customLong("job-id"), help: ArgumentHelp("Job id to report this run's progress under (set by the spawning daemon).", visibility: .hidden)) var jobID: String?`, with the fork's comment reworded so it explains why without history. Pass `jobID: jobID` into `TranscribePipeline.Inputs(...)`, right after `session: session`.
  - **`TranscribePipeline.swift`:** add `var jobID: String? = nil`, with its doc comment, after `var session: String? = nil`. Change the `JobEventPublisher` construction to:
    `jobID: inputs.jobID ?? "transcribe-\(UUID().uuidString.lowercased().prefix(8))",`
- [ ] **Step 2: Add a smoke test** to `daemon/Tests/CLISmokeTests/CLISmokeTests.swift`, next to the `ears sources add` tests. It uses the file's own `binaryURL(_:)` and `run(_:_:environment:)` helpers:
  ```swift
  @Test("transcribe accepts the spawner's --job-id but does not advertise it")
  func transcribeJobIDIsHidden() throws {
    let transcribe = try Self.binaryURL("transcribe")
    let help = try Self.run(transcribe, ["--help"])
    #expect(help.exitCode == 0)
    #expect(!help.stdout.contains("--job-id"))
    let withFlag = try Self.run(transcribe, ["--job-id", "transcribe-test", "--help"])
    #expect(withFlag.exitCode == 0)
  }
  ```
- [ ] **Step 3: Update the docs.** In `docs/specs/transcribe.md`, after the `--session <uuid>` paragraph, add the fork's paragraph from `git show c7894c8 -- docs/specs/transcribe.md`, which begins "A session run reports its lifecycle to the daemon as `job.publish` events".
- [ ] **Step 4: Build and run the transcribe and smoke tests.**
  Run: `cd daemon && swift build && swift test --filter 'TranscribeTests|CLISmokeTests'`
  Expected: PASS.
- [ ] **Step 5: Lint, run the full suite, run the gate, commit.**
  Message: `feat(transcribe): report progress under the spawner's --job-id`.

## Task 4: The on-end chain publishes job events for cleanup and summarize

**Files:**
- Modify: `daemon/Sources/EarsDaemonKit/OnClosePipelineRunner.swift`
- Modify: `daemon/Sources/EarsDaemonKit/EarsDaemon.swift` (pass `publishJob` into the runner)
- Test: `daemon/Tests/EarsDaemonKitTests/OnClosePipelineRunnerTests.swift`
- Test: `daemon/Tests/EarsDaemonKitTests/OnClosePipelineIssueTests.swift`
- Test: `daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift` (only the `--job-id` spawn-line assertion)
- Docs: `docs/specs/control-protocol.md`, `docs/specs/capture-daemon.md`

**Interfaces:**
- Consumes: `JobPublishParams.outputs` (Task 2) and `--job-id` (Task 3).
- Produces: `OnClosePipelineRunner.init(runProcess:log:publishJob:)`, where `publishJob: @escaping JobPublisher = { _ in }` and `public typealias JobPublisher = @Sendable (JobPublishParams) async -> Void`. Job ids have the form `<stage>-<8 hex>`.
- Events published:
  - `cleanup`: `started`, then `done` with `outputs: [cleanPath]`, or `failed`.
  - `summarize`: `started`, then `done` with `outputs` = the written preset paths, or `failed` with `detail: "exit <n>"` or `detail: "invalid result envelope"`.
  - `transcribe`: `failed` only, when the child cannot have reported it itself (`detail: "exit <n>"` or `"invalid result envelope"`).

- [ ] **Step 1: Port the fork's runner.** The fork's final runner is the upstream runner plus exactly these changes, with no detection code. Task 1 already removed the enum, so copying it is safe:
  ```bash
  git show main:daemon/Sources/EarsDaemonKit/OnClosePipelineRunner.swift > daemon/Sources/EarsDaemonKit/OnClosePipelineRunner.swift
  git diff upstream/main -- daemon/Sources/EarsDaemonKit/OnClosePipelineRunner.swift | grep '^[-+]' | grep -ciE 'detect|meeting|app-idle'
  ```
  Expected: `0`.
- [ ] **Step 2: Port the fork's runner tests.**
  ```bash
  git show main:daemon/Tests/EarsDaemonKitTests/OnClosePipelineRunnerTests.swift > daemon/Tests/EarsDaemonKitTests/OnClosePipelineRunnerTests.swift
  git show main:daemon/Tests/EarsDaemonKitTests/OnClosePipelineIssueTests.swift > daemon/Tests/EarsDaemonKitTests/OnClosePipelineIssueTests.swift
  ```
  Then delete the three `resolveList` tests from the ported `OnClosePipelineRunnerTests.swift`; they already live in `OnEndStageTests` from Task 1.
- [ ] **Step 3: Write the failing `outputs` tests.** Append inside `OnClosePipelineRunnerTests`, after `fullChainPublishesJobEvents`:
  ```swift
  @Test("done events carry what each LLM stage wrote; other states carry nothing")
  func doneEventsCarryOutputs() async throws {
    let dir = try Self.makeTempDirectory("onend-outputs")
    defer { try? FileManager.default.removeItem(at: dir) }
    let transcript = try Self.makeFile("t.transcript.md", in: dir)
    let clean = try Self.makeFile("t.clean.md", in: dir)
    let summary = try Self.makeFile("t.summary.md", in: dir)
    let jobs = JobCollector()
    let runner = ScriptedRunner([
      Self.transcribeOutcome(transcript),
      Self.cleanupOutcome(clean),
      SpawnOutcome(
        exitCode: 0,
        stdout: StageEnvelopeFixtures.summarizeSelectedPresetSuccess(
          preset: "meeting-notes", path: summary)),
    ])
    let pipeline = OnClosePipelineRunner(
      runProcess: runner.runner, log: { _ in }, publishJob: { jobs.append($0) })

    _ = await pipeline.runOnEndChain(sessionID: "s1", stages: OnEndStage.allCases, context: "test")

    let done = jobs.snapshot.filter { $0.state == .done }
    #expect(done.map(\.kind) == ["cleanup", "summarize"])
    #expect(done[0].outputs == [clean])
    #expect(done[1].outputs == [summary])
    #expect(jobs.snapshot.filter { $0.state != .done }.allSatisfy { $0.outputs == nil })
  }

  @Test("a summarize that fails after writing some presets reports no outputs")
  func partialSummarizeFailureCarriesNoOutputs() async throws {
    let dir = try Self.makeTempDirectory("onend-partial")
    defer { try? FileManager.default.removeItem(at: dir) }
    let transcript = try Self.makeFile("t.transcript.md", in: dir)
    let clean = try Self.makeFile("t.clean.md", in: dir)
    let brief = try Self.makeFile("t.brief.summary.md", in: dir)
    let decisions = try Self.makeFile("t.decisions.summary.md", in: dir)
    let jobs = JobCollector()
    let runner = ScriptedRunner([
      Self.transcribeOutcome(transcript),
      Self.cleanupOutcome(clean),
      SpawnOutcome(
        exitCode: 4,
        stderr: StageEnvelopeFixtures.summarizePartialFailureError(
          briefPath: brief, decisionsPath: decisions)),
    ])
    let pipeline = OnClosePipelineRunner(
      runProcess: runner.runner, log: { _ in }, publishJob: { jobs.append($0) })

    _ = await pipeline.runOnEndChain(sessionID: "s1", stages: OnEndStage.allCases, context: "test")

    let summarize = jobs.snapshot.filter { $0.kind == "summarize" }
    #expect(summarize.map(\.state) == [.started, .failed])
    #expect(summarize.last?.detail == "exit 4")
    #expect(summarize.last?.outputs == nil)
  }
  ```
- [ ] **Step 4: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter 'OnClosePipelineRunner/doneEventsCarryOutputs'`
  Expected: FAIL (`outputs` is nil).
- [ ] **Step 5: Implement the outputs.** In the ported runner:
  - **Cleanup:** the `done`/`failed` publish becomes
    ```swift
    await publishJob(
      JobPublishParams(
        job: jobID, kind: OnEndStage.cleanup.rawValue, session: sessionID,
        state: cleanPath == nil ? .failed : .done, outputs: cleanPath.map { [$0] }))
    ```
  - **Summarize:** rename `logSummarizeResults(stdout:sessionID:context:issues:) -> Bool` to `summarizeOutputs(stdout:sessionID:context:issues:) -> [String]?`. It returns the written paths, or `nil` when the envelope is unusable:
    ```swift
    /// Logs summarize's per-preset results from its success envelope and
    /// returns the paths it wrote, or `nil` when the envelope is unusable —
    /// which records a failure, so live job events agree with the persisted
    /// issue. Transcription success still governs retention.
    private func summarizeOutputs(
      stdout: String, sessionID: String, context: String, issues: inout [PipelineIssue]
    ) -> [String]? {
      switch StageResultEnvelope.decodeSuccessDocument(
        stdout: stdout, tool: OnEndStage.summarize.rawValue)
      {
      case .success(let envelope):
        let presets = envelope.presetOutputs ?? []
        if !presets.isEmpty {
          log("\(context) on_end: \(Self.presetSummary(presets)) for session '\(sessionID)'")
        }
        let written = presets.compactMap(\.path)
        return written.isEmpty ? envelope.output.map { [$0] } ?? [] : written
      case .failure(let violation):
        log(
          "\(context) on_end: summarize exited 0 but its result envelope is unusable for "
            + "session '\(sessionID)': \(violation.message)")
        issues.append(
          PipelineIssue(
            stage: OnEndStage.summarize.rawValue, kind: .failed, message: violation.message))
        return nil
      }
    }
    ```
    Then update the call site in the summarize block:
    ```swift
    if outcome.exitCode == 0 {
      let written = summarizeOutputs(
        stdout: outcome.stdout, sessionID: sessionID, context: context, issues: &issues)
      await publishJob(
        JobPublishParams(
          job: jobID, kind: OnEndStage.summarize.rawValue, session: sessionID,
          state: written == nil ? .failed : .done,
          detail: written == nil ? "invalid result envelope" : nil,
          outputs: written.flatMap { $0.isEmpty ? nil : $0 }))
    } else {
      await publishJob(
        JobPublishParams(
          job: jobID, kind: OnEndStage.summarize.rawValue, session: sessionID, state: .failed,
          detail: "exit \(outcome.exitCode)"))
    }
    ```
    `envelope.output` is `StageResultEnvelope`'s single-output `String?`; `--select-preset` fills it as well as `outputs`.
- [ ] **Step 6: Wire the daemon.** In `daemon/Sources/EarsDaemonKit/EarsDaemon.swift`, inside `start()` where the on-end hook is built, replace `let pipeline = OnClosePipelineRunner(log: log)` with:
  ```swift
  let pipeline = OnClosePipelineRunner(
    log: log,
    publishJob: { [eventBus] params in await eventBus.publish(.job(params)) })
  ```
  Leave the browser-only guard alone; W2 changes it.
- [ ] **Step 7: Update the smoke test.** In `daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift`, replace the `spawning transcribe --session \(session.id) --json` assertion with the fork's two assertions (see `git show c7894c8 -- daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift`): one for `--job-id transcribe-`, one for `--json for session '<id>'`.
- [ ] **Step 8: Update the docs.**
  - **`docs/specs/control-protocol.md`:** replace the `job.publish` row's params with
    `{job, kind: "transcribe"|"cleanup"|"summarize", session?, state: "started"|"running"|"done"|"failed", detail?, outputs?}`.
    Append to its description: `` `transcribe` reports itself; the daemon's on-end chain reports `cleanup`/`summarize`, and a `transcribe` that died before it could report. `outputs` (on `done`) lists the absolute paths the stage wrote. ``
  - **`docs/specs/capture-daemon.md`:** port the fork's "**The spawner owns each stage's job identity.**" bullet and the `--job-id` wording in the "When a chain does run" bullet, from `git show c7894c8 -- docs/specs/capture-daemon.md`. Add one sentence to the same list: `` The chain publishes `job` events for `cleanup` and `summarize` (`started`, then `done` with the written paths in `outputs`, or `failed`). ``
- [ ] **Step 9: Run the tests.**
  Run: `cd daemon && swift test --filter 'OnClosePipeline|OnEndChainSmokeTests'`
  Expected: PASS.
- [ ] **Step 10: Lint, run the full suite, run the gate, commit.**
  Message: `feat(earsd): publish job events for the on-end LLM stages`. Body: summary-ready was unknowable to any subscriber; the daemon now owns each stage's job id and reports what it wrote.
- [ ] **Step 11: Mark the PR boundary.** Run `git branch pr/w1-job-events`.

---

# PR W2 — a session declares its own on-end chain

## Task 5: `session.start` and `session.toml` carry `on_end_stages`

**Files:**
- Modify: `daemon/Sources/EarsCore/Models/Session.swift`
- Modify: `daemon/Sources/EarsCore/Socket/ControlCall.swift` (`SessionStartParams`)
- Modify: `daemon/Sources/EarsConfig/SessionDescriptorTOML.swift`
- Modify: `daemon/Sources/EarsConfig/TOMLFieldReader.swift`
- Modify: `shared/protocol-fixtures/control-v2.json`
- Test: `daemon/Tests/EarsCoreTests/ControlRequestFrameTests.swift`
- Test: `daemon/Tests/EarsConfigTests/SessionDescriptorTOMLTests.swift`

**Interfaces:**
- Produces:
  - `Session.onEndStages: [String]?`, with init parameter `onEndStages: [String]? = nil` placed after `trigger:`. Its wire key is `on_end_stages`, omitted when `nil`.
  - `SessionStartParams.onEndStages: [String]?`, with init parameter `onEndStages: [String]? = nil` placed last. Same wire key, encoded only when non-nil.
  - `session.toml` key `on_end_stages`. An absent key decodes to `nil`; `[]` decodes to `[]`.

- [ ] **Step 1: Write the failing tests.**
  1. Port `decodesSessionStartOnEndStages` from `git show main:daemon/Tests/EarsCoreTests/ControlRequestFrameTests.swift` into the same file on the branch.
  2. Add to `SessionDescriptorTOMLTests`:
     ```swift
     @Test("on_end_stages keeps its three states through session.toml")
     func onEndStagesRoundTrip() throws {
       var undeclared = Self.referenceSession()
       undeclared.onEndStages = nil
       let undeclaredTable = SessionDescriptorTOML.encode(undeclared)
       guard case .table(let fields) = undeclaredTable else {
         Issue.record("expected a table")
         return
       }
       #expect(fields["on_end_stages"] == nil)
       #expect(try SessionDescriptorTOML.decode(undeclaredTable).onEndStages == nil)

       for declared in [[String](), ["transcribe", "summarize"]] {
         var session = Self.referenceSession()
         session.onEndStages = declared
         let decoded = try SessionDescriptorTOML.decode(SessionDescriptorTOML.encode(session))
         #expect(decoded.onEndStages == declared)
       }
     }
     ```
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter 'ControlRequestFrame|SessionDescriptorTOML'`
  Expected: compile errors on `onEndStages`.
- [ ] **Step 3: Implement.** Apply the fork's hunks, shown by
  `git diff upstream/main main -- daemon/Sources/EarsCore/Models/Session.swift daemon/Sources/EarsCore/Socket/ControlCall.swift daemon/Sources/EarsConfig/SessionDescriptorTOML.swift daemon/Sources/EarsConfig/TOMLFieldReader.swift`.
  - **Take:** every `onEndStages` / `on_end_stages` / `declaredArray` hunk.
  - **Skip:** the `AttendeeOrigin.calendar` case and its doc comment, and the `JobPublishParams` `kind` doc, which Task 2 already covered.
  - The `Session.onEndStages` doc comment should read, without history:
    ```swift
    /// The post-processing chain this session's starter asked for, by stage
    /// name. `nil` means "not declared — apply the daemon's default for
    /// ``trigger``"; `[]` means "run nothing", the opt-out for a client that
    /// runs the stages itself. Names are validated when the session starts.
    ```
- [ ] **Step 4: Add the golden fixtures** to the `requests` array of `shared/protocol-fixtures/control-v2.json`, after `session.start-manual`: the fork's `session.start-declared-chain` and `session.start-no-chain` entries, exactly as in `git diff upstream/main main -- shared/protocol-fixtures/control-v2.json`.
- [ ] **Step 5: Run the tests.**
  Run: `cd daemon && swift test --filter 'ControlRequestFrame|SessionDescriptorTOML|ControlProtocolV2Fixture' && cd ../browser && bun run test`
  Expected: PASS.
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(protocol): let session.start declare its on-end chain`.

## Task 6: `OnEndChainPolicy` — one pure decision point for which stages run

**Files:**
- Create: `daemon/Sources/EarsCore/Session/OnEndChainPolicy.swift`
- Test: `daemon/Tests/EarsCoreTests/OnEndChainPolicyTests.swift`

**Interfaces:**
- Produces:
  - `OnEndChainPolicy.stages(declared: [String]?, trigger: TriggerKind, configured: [OnEndStage]) -> (stages: [OnEndStage], problems: [String])`. A declared chain resolves through `resolveList`. With no declaration, `.browserExtension` inherits `configured` and every other trigger gets `[]`.
  - `OnEndChainPolicy.configured(fromRaw: [String]?) -> [OnEndStage]`. `nil` gives `OnEndStage.allCases`; otherwise `resolveList(raw).stages`.

- [ ] **Step 1: Port the tests without detection.**
  1. `git show main:daemon/Tests/EarsCoreTests/OnEndChainPolicyTests.swift > daemon/Tests/EarsCoreTests/OnEndChainPolicyTests.swift`
  2. Delete the `appDetectedInheritsConfiguredChain` test.
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter OnEndChainPolicyTests`
  Expected: compile error, "cannot find 'OnEndChainPolicy'".
- [ ] **Step 3: Port the implementation without detection.**
  1. `git show main:daemon/Sources/EarsCore/Session/OnEndChainPolicy.swift > daemon/Sources/EarsCore/Session/OnEndChainPolicy.swift`
  2. Replace `let inherits = trigger == .browserExtension || trigger == .appDetected` with `let inherits = trigger == .browserExtension`.
  3. In the type's doc comment, change "browser-extension and app-detected sessions inherit" to "browser-extension sessions inherit".
- [ ] **Step 4: Run the tests.** Same command as Step 2. Expected: PASS.
- [ ] **Step 5: Lint, run the full suite, run the gate, commit.**
  Message: `feat(core): one policy for which on-end stages a session runs`.

## Task 7: The daemon runs the chain a session declared

**Files:**
- Modify: `daemon/Sources/EarsDaemonKit/EarsDaemon.swift`
- Modify: `daemon/Sources/EarsDaemonKit/SessionRegistry.swift`
- Modify: `daemon/Sources/EarsDaemonKit/ControlServer.swift`
- Modify: `daemon/Sources/EarsCore/Config/EarsdConfigSchema.swift` (the `on_end_stages` description only)
- Test: `daemon/Tests/EarsDaemonKitTests/SessionRegistryTests.swift`
- Test: `daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift`
- Docs: `docs/specs/control-protocol.md`, `docs/specs/capture-daemon.md`, `docs/data-formats.md`, `docs/configuration.md`, `README.md`

**Interfaces:**
- Consumes: `OnEndChainPolicy` (Task 6) and `Session.onEndStages` (Task 5).
- Produces:
  - `SessionRegistryError.invalidRequest(String)`, which maps to wire error `invalid_request`.
  - `EarsDaemonConfiguration.onEndStages` defaults to `[]`, so tests stay hermetic. `earsd` always passes the resolved config list.
  - The on-end hook is always installed and resolves through `OnEndChainPolicy`.
  - A re-declare that names a chain replaces the stored one; a re-declare with `nil` keeps it.

- [ ] **Step 1: Port the four registry tests.** From `git show main:daemon/Tests/EarsDaemonKitTests/SessionRegistryTests.swift`, copy these into the branch's `SessionRegistryTests.swift`:
  - `startPersistsDeclaredOnEndStages`
  - `redeclareUpdatesOnEndStages`
  - `redeclareWithoutStagesKeepsDeclaration`
  - `startRejectsUnrunnableOnEndChain`

  If one uses a helper the branch lacks (for example `waitUntil` or `SleepGate`), port `daemon/Tests/EarsDaemonKitTests/SleepGate.swift` from `main` too, then delete any helper in it that mentions app activity.
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter SessionRegistryTests`
  Expected: compile error on `invalidRequest`, or failing expectations.
- [ ] **Step 3: Implement the registry.** Apply only these hunks from `git diff upstream/main main -- daemon/Sources/EarsDaemonKit/SessionRegistry.swift`:
  1. the `case invalidRequest(String)` on `SessionRegistryError`, with its doc;
  2. in `start(_:)`: the leading `try Self.validateOnEndStages(params.onEndStages)`, the `restaged` block in the idempotent branch (including `restaged=\(restaged)` in the log line), and `onEndStages: params.onEndStages` in the new-session `Session(...)`;
  3. the private `validateOnEndStages(_:)`, with its doc cut to the why: *a declared chain arrives on a call whose caller can be told; honour it exactly or refuse it; `[]` is the explicit opt-out.*

  Do **not** take: `appIdle`, `appIdleGraceSeconds`, `activeAppAudio`, `appAudioActivity`, `IdleWatch`, `scheduleIdleExpiry`, or `expireIfStillIdle`. The existing `scheduleGraceExpiry` / `expireIfStillOrphaned` stay as upstream has them.
- [ ] **Step 4: Map the error.** In `ControlServer.swift`, in the registry-error mapping switch, add:
  ```swift
  case .invalidRequest(let message):
    return WireError(code: .invalidRequest, message: message)
  ```
- [ ] **Step 5: Implement the daemon side** in `EarsDaemon.swift`:
  1. Set the `EarsDaemonConfiguration.init` default to `onEndStages: [OnEndStage] = []`.
  2. Replace the property's doc with the fork's (from "`[earsd.sessions].on_end_stages`: the **default** chain…" to "…`OnEndStage.resolveList`."), rewording "Only browser-extension sessions fall back to it" and keeping the hermetic-default reason.
  3. Replace the whole `let onSessionEnded: SessionRegistry.EndedHook?` / `if !configuration.onEndStages.isEmpty { … } else { onSessionEnded = nil }` block with:
     ```swift
     // Always installed: which stages run is a per-session question
     // (``OnEndChainPolicy``), so a session that declares its own chain is
     // honoured even on a daemon whose configured default is empty.
     let pipeline = OnClosePipelineRunner(
       log: log,
       publishJob: { [eventBus] params in await eventBus.publish(.job(params)) })
     let configuredStages = configuration.onEndStages
     let emptiness = configuration.onEndEmptinessPolicy
     let onSessionEnded: SessionRegistry.EndedHook? = { [weak self, log] session in
       let resolved = OnEndChainPolicy.stages(
         declared: session.onEndStages, trigger: session.trigger, configured: configuredStages)
       for problem in resolved.problems {
         log("session.end on_end_stages: session=\(session.id) \(problem)")
       }
       guard !resolved.stages.isEmpty else { return }
       // Spawned in its own task so `session.end` never blocks behind a full
       // transcription-and-LLM run. On transcribe success — and only
       // transcribe: the LLM stages are derived artifacts and never gate
       // retention — stamp the transcript-completion marker, which starts
       // this session's retention clock.
       Task { [weak self] in
         let transcribed = await pipeline.runOnEndChain(
           sessionID: session.id, stages: resolved.stages, emptiness: emptiness,
           context: "session-end",
           recordIssues: { [weak self] issues in
             await self?.recordSessionPipelineIssues(session.id, issues)
           })
         if transcribed {
           await self?.markSessionTranscriptCompleted(session.id)
         }
       }
     }
     ```
  4. Don't take `detection`, `DetectionSettings`, `activityProbe`, `meetingMonitor`, `appIdleGraceSeconds:`, or `import EarsCaptureKit`.
- [ ] **Step 6: Update the schema description.** In `EarsdConfigSchema.swift`, set `on_end_stages`'s description to the fork's text: "Default pipeline stages for a session that declares none of its own, …".
- [ ] **Step 7: Port the smoke tests.**
  1. `git show main:daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift > daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift`
  2. Remove `import EarsMenuKit`.
  3. Remove the block from `// The menu bar app resolves these same paths` to the end of that test function's final `#expect` (the one on `summaries`). Task 14 replaces it.
  4. Confirm `Package.swift`'s `CLISmokeTests` dependencies do **not** include `EarsMenuKit`.
- [ ] **Step 8: Run the tests.**
  Run: `cd daemon && swift test --filter 'SessionRegistryTests|EarsDaemonTests|ControlServerTests|OnEndChainSmokeTests|DaemonConfigResolution'`
  Expected: PASS, including the smoke tests `undeclaredManualSessionSpawnsNothing` and `declaredManualSessionEndPublishesJobEvents`.
- [ ] **Step 9: Update the docs** from `git diff upstream/main main -- docs/ README.md`, taking only hunks about the declared chain:
  - **`control-protocol.md`:** the "**Post-processing is declared at `session.start`, not inferred.**" bullet; the `session.start` row's `on_end_stages?` params and description; and the `session.end` wording change ("It then runs whatever chain the session resolved to").
  - **`capture-daemon.md`:** the bullets "**The session's starter chooses its chain.**" and "**A session that declares nothing falls back per trigger.**"
  - **`data-formats.md`:** the schema-3 paragraph ("declared on-end chain", "`on_end_stages` is the exception"), and the `on_end_stages = ["transcribe"]` line with its comment, in the `session.toml` example. **Not** the `app-detected` or `calendar` values.
  - **`configuration.md`:** the rewritten `on_end_stages` comment block, ending at `opts out whatever this says.` Drop the fork's sentence about the menu bar app reading config. Task 20 adds the right sentence.
  - **`README.md`:** only the on-end-chain sentences from fork commits `201ee04` and `4758e67` (`git show 201ee04 4758e67 -- README.md`).
- [ ] **Step 10: Lint, run the full suite, run the gate, commit.**
  Message: `feat(earsd): run the chain a session declared`. Body: a manual session stays inert unless it asks; a declared chain is honoured exactly or refused at `session.start`.

## Task 8: `ears session start --on-end-stage` / `--no-on-end`

**Files:**
- Modify: `daemon/Sources/ears/Ears.swift`

**Interfaces:**
- Produces:
  - `--on-end-stage <stage>` is repeatable and declares that list.
  - `--no-on-end` declares `[]`.
  - Using both is a `ValidationError`.
  - With neither, `onEndStages` is `nil`.

- [ ] **Step 1: Cherry-pick.** Fork commit `0cb002a` replays cleanly (checked during planning):
  `git cherry-pick -x 0cb002a`
  Then amend the message to end with this plan's `Claude-Session` trailer:
  `git commit --amend`
- [ ] **Step 2: Add a smoke test** to `CLISmokeTests.swift`, next to `earsSourcesAddRejectsUnknownClass`. Validation fails before any connection, so no daemon is needed:
  ```swift
  @Test("ears session start refuses --no-on-end together with --on-end-stage")
  func sessionStartOnEndFlagsAreExclusive() throws {
    let result = try Self.runEars([
      "session", "start", "--no-on-end", "--on-end-stage", "transcribe",
    ])
    #expect(result.exitCode != 0)
    #expect(result.stderr.contains("mutually exclusive"))
  }
  ```
- [ ] **Step 3: Run the smoke tests.**
  Run: `cd daemon && swift test --filter CLISmokeTests`
  Expected: PASS.
- [ ] **Step 4: Lint, run the gate, commit** the test with `git commit --amend`, so it stays one logical change.

## Task 9: The pipeline views read the chain each session asked for

**Files:**
- Modify: `daemon/Sources/EarsCore/CLI/SessionPipeline.swift`
- Create: `daemon/Sources/EarsCore/CLI/SessionPipelineTypes.swift` (split out to stay under 300 lines)
- Modify: `daemon/Sources/EarsCore/CLI/SessionShowRendering.swift`
- Modify: `daemon/Sources/EarsCore/CLI/SessionsListRendering.swift`
- Modify: `daemon/Sources/EarsCore/CLI/StatusDashboardRendering.swift`
- Modify: `daemon/Sources/ears/SessionArtifactScanner.swift`
- Modify: `daemon/Sources/ears/Ears.swift`
- Modify: `daemon/Sources/ears/StatusDashboardAssembly.swift`
- Test: `daemon/Tests/EarsCoreTests/SessionPipelineChainTests.swift` (new, from the fork)
- Test: `SessionPipelineTests.swift`, `SessionShowRenderingTests.swift`, `SessionsListRenderingTests.swift`, `StatusDashboardRenderingTests.swift`

**Interfaces:**
- Consumes: `OnEndChainPolicy` and `OnEndStage`.
- Produces:
  - `SessionPipeline.stages(session:artifacts:now:configuredChain:emptiness:)` and `SessionPipeline.outcome(session:artifacts:now:configuredChain:emptiness:)`, where `configuredChain: [OnEndStage]` comes before `emptiness`.
  - `PipelineStageState.notRequested`, raw value `"not-requested"`, rendered with the glyph `○`.
  - `StatusDashboardInputs.init(status:evidenceBySession:recent:configuredChain:)`.
  - `ScanEnvironment.onEndChain: [OnEndStage]`.

- [ ] **Step 1: Port the tests without detection.**
  ```bash
  for f in SessionPipelineChainTests SessionPipelineTests SessionShowRenderingTests SessionsListRenderingTests StatusDashboardRenderingTests; do
    git show main:daemon/Tests/EarsCoreTests/$f.swift > daemon/Tests/EarsCoreTests/$f.swift
  done
  ```
  Then make these deletions:
  - `SessionPipelineChainTests`: delete `appDetectedSessionInheritsTheConfiguredChain`.
  - `StatusDashboardRenderingTests`: delete `appSourceRendersMeetingLabel` and every `meetingActivity:` argument. Keep `appSourceFallsBackToRawID` only if it passes against upstream's rendering once those arguments are gone; otherwise delete it.
  - Check with `grep -n 'meetingActivity\|appDetected' daemon/Tests/EarsCoreTests/*.swift`. Expected: nothing.
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter 'SessionPipeline|SessionShowRendering|SessionsListRendering|StatusDashboardRendering'`
  Expected: compile errors on `configuredChain:` and `notRequested`.
- [ ] **Step 3: Port the core read-side sources.**
  1. Copy the pipeline files:
     ```bash
     git show main:daemon/Sources/EarsCore/CLI/SessionPipeline.swift > daemon/Sources/EarsCore/CLI/SessionPipeline.swift
     git show main:daemon/Sources/EarsCore/CLI/SessionPipelineTypes.swift > daemon/Sources/EarsCore/CLI/SessionPipelineTypes.swift
     ```
  2. Apply the `configuredChain` hunks to `SessionShowRendering.swift` and `SessionsListRendering.swift` (from `git diff upstream/main main -- daemon/Sources/EarsCore/CLI/`).
  3. In `StatusDashboardRendering.swift`, take only the `configuredChain` hunks: the `StatusDashboardInputs` field, init and doc, and the `outcome(...)` call. Leave out the `meetingActivity` parameter and the `.app` case.
- [ ] **Step 4: Port the `ears` side.**
  - Apply the `onEndChain` hunks to `daemon/Sources/ears/SessionArtifactScanner.swift`: the `ScanEnvironment.onEndChain` field, the `onEndChain(_:)` helper, `stringArray(_:_:)`, and the doc text.
  - Apply the `configuredChain` hunks to `daemon/Sources/ears/Ears.swift`: `runSessionsList` and `SessionShowCommand`.
  - In `StatusDashboardAssembly.swift`:
    1. declare `var onEndChain = OnEndStage.allCases` beside `var recent`;
    2. set `onEndChain = environment.onEndChain` first thing in the `.success` branch;
    3. build the inputs as
       `StatusDashboardInputs(status: status, evidenceBySession: evidence, recent: recent, configuredChain: onEndChain)`.
- [ ] **Step 5: Run the tests.**
  Run: `cd daemon && swift test --filter 'EarsCoreTests|CLISmokeTests'`
  Expected: PASS.
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(ears): pipeline views read the chain each session asked for`. Body: a capture-only manual session reads as recorded, not as missing a note.
- [ ] **Step 7: Mark the PR boundary.** Run `git branch pr/w2-declared-chain`.

---

# PR W3 — `status` reports what the daemon is configured with

## Task 10: `StatusData.configured` on the wire

**Files:**
- Modify: `daemon/Sources/EarsCore/Socket/StatusData.swift`
- Test: `daemon/Tests/EarsCoreTests/ControlResponsePayloadsTests.swift`

**Interfaces:**
- Produces:
  - `public struct StatusData.Configured: Sendable, Hashable, Codable { public var sources: [SourceID]; public var onEndStages: [String] }`, with wire keys `sources` and `on_end_stages`.
  - `StatusData.configured: Configured?`, with init parameter `configured: Configured? = nil` placed last and wire key `configured`, omitted when `nil`.

- [ ] **Step 1: Write the failing tests.** Add to the `StatusDataTests` suite in `ControlResponsePayloadsTests.swift`:
  ```swift
  @Test("configured round-trips and uses the wire's snake_case")
  func configuredRoundTrips() throws {
    let status = StatusData(
      uptimeSeconds: 5, sources: [],
      configured: StatusData.Configured(
        sources: ["mic", "system"], onEndStages: ["transcribe", "cleanup"]))
    let data = try JSONEncoder().encode(status)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let configured = try #require(object?["configured"] as? [String: Any])
    #expect(configured["on_end_stages"] as? [String] == ["transcribe", "cleanup"])
    #expect(try JSONDecoder().decode(StatusData.self, from: data) == status)
  }

  @Test("a status from a daemon without configured decodes to nil and encodes nothing")
  func configuredIsAdditive() throws {
    let legacy = #"{"uptime_s":1,"sources":[],"sessions":[]}"#
    let decoded = try JSONDecoder().decode(StatusData.self, from: Data(legacy.utf8))
    #expect(decoded.configured == nil)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
    #expect((object as? [String: Any])?["configured"] == nil)
  }
  ```
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter StatusDataTests`
  Expected: compile error.
- [ ] **Step 3: Implement** in `StatusData.swift`:
  ```swift
  /// What this daemon was configured with at boot: the capturable
  /// config-declared sources in declaration order, and the resolved
  /// `[earsd.sessions] on_end_stages` chain. A client that starts a manual
  /// session declares these instead of parsing daemon config, so what it
  /// asks for is what this daemon will actually capture and run.
  public var configured: Configured?
  ```
  1. Add `configured: Configured? = nil` to `init` and assign it.
  2. Add `case configured` to `CodingKeys`.
  3. In `init(from:)`: `configured = try container.decodeIfPresent(Configured.self, forKey: .configured)`.
  4. Add, below the struct:
     ```swift
     extension StatusData {
       public struct Configured: Sendable, Hashable, Codable {
         public var sources: [SourceID]
         public var onEndStages: [String]

         public init(sources: [SourceID], onEndStages: [String]) {
           self.sources = sources
           self.onEndStages = onEndStages
         }

         private enum CodingKeys: String, CodingKey {
           case sources
           case onEndStages = "on_end_stages"
         }
       }
     }
     ```
  If `StatusData` has no explicit `encode(to:)`, the synthesized one omits a `nil` `configured`. If it does have one, use `encodeIfPresent`.
- [ ] **Step 4: Run the tests.** Same command as Step 2. Expected: PASS.
- [ ] **Step 5: Lint, run the full suite, run the gate, commit.**
  Message: `feat(protocol): status reports the daemon's configured sources and chain`.

## Task 11: The daemon fills `status.configured`

**Files:**
- Modify: `daemon/Sources/EarsDaemonKit/ControlServer.swift`
- Modify: `daemon/Sources/EarsDaemonKit/EarsDaemon.swift`
- Test: `daemon/Tests/EarsDaemonKitTests/ControlServerTests.swift`
- Test: `daemon/Tests/EarsDaemonKitTests/EarsDaemonTests.swift`
- Docs: `docs/specs/control-protocol.md`

**Interfaces:**
- Consumes: `StatusData.Configured` (Task 10).
- Produces:
  - `ControlServer.init(..., sessions:, configured: StatusData.Configured? = nil)`.
  - `EarsDaemon` passes `StatusData.Configured(sources: configuration.sources.map(\.id), onEndStages: configuration.onEndStages.map(\.rawValue))`.

- [ ] **Step 1: Write the failing socket test.** Add to `EarsDaemonTests`, next to `sessionScopedCaptureOverSocket`, reusing that file's `makeDataRoot()`, `tempSocketPath()`, `makeDescriptor(id:sourceClass:)` and `makeBuffer(seconds:)` helpers:
  ```swift
  @Test("status reports the configured sources in order and the resolved chain, even idle")
  func statusReportsConfigured() async throws {
    let socketPath = tempSocketPath()
    let configuration = EarsDaemonConfiguration(
      sources: [
        makeDescriptor(id: "mic", sourceClass: .mic),
        makeDescriptor(id: "system", sourceClass: .system),
      ],
      dataRoot: try makeDataRoot(),
      socketPath: socketPath,
      onEndStages: [.transcribe, .cleanup]
    )
    let daemon = try EarsDaemon(
      configuration: configuration,
      backendFactory: { descriptor in
        SyntheticCaptureBackend(source: descriptor.id, buffers: [self.makeBuffer(seconds: 0.1)])
      },
      clock: ManualClock(Instant(secondsSinceEpoch: 1_000))
    )
    try await daemon.start()
    let client = try await ControlSocketClient.connect(toPath: socketPath)
    _ = try await client.hello(client: "test/0")

    let status = try await client.send(.status, expecting: StatusData.self)

    #expect(
      status.configured
        == StatusData.Configured(sources: ["mic", "system"], onEndStages: ["transcribe", "cleanup"]))
    await client.close()
    await daemon.stop()
  }
  ```
  Also add to `ControlServerTests`: a `makeServer(...)` without `configured` gives a `status` result with no `"configured"` key. Assert `data["configured"] == nil` using that file's `result(_:)` helper.
- [ ] **Step 2: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter 'EarsDaemonTests/statusReportsConfigured|ControlServerTests'`
  Expected: FAIL (`configured` is nil).
- [ ] **Step 3: Implement.**
  - **`ControlServer`:** store `private let configured: StatusData.Configured?`; add the init parameter; pass `configured: configured` into the `StatusData(...)` built by `status`.
  - **`EarsDaemon.start()`:** pass it where the `ControlServer(...)` is built:
    ```swift
    configured: StatusData.Configured(
      sources: configuration.sources.map(\.id),
      onEndStages: configuration.onEndStages.map(\.rawValue)))
    ```
  `configuration.sources` is the ordered list `DaemonConfigResolution` builds from the capturable `[[earsd.source]]` entries, so declaration order is preserved.
- [ ] **Step 4: Run the tests.** Same command as Step 2. Expected: PASS.
- [ ] **Step 5: Update the docs.** In `docs/specs/control-protocol.md`, set the `status` row to:
  `` → `{uptime_s, sources, sessions, configured?}` — daemon + per-source state, active sessions, and `configured: {sources, on_end_stages}`: the capturable config-declared sources in declaration order and the resolved `[earsd.sessions] on_end_stages`, as loaded at boot. A client starting a manual session declares these rather than reading daemon config. ``
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(earsd): report configured sources and chain in status`.
- [ ] **Step 7: Mark the PR boundary.** Run `git branch pr/w3-status-configured`.

---

# PR R1 — one session scanner

## Task 12: Move the scanner into EarsDataStore, with no behaviour change

**Files:**
- Create: `daemon/Sources/EarsDataStore/SessionScanEnvironment.swift` (the environment, config resolution and error)
- Create: `daemon/Sources/EarsDataStore/SessionArtifactScanner.swift` (the disk scan)
- Delete: `daemon/Sources/ears/SessionArtifactScanner.swift`
- Modify: `daemon/Sources/ears/Ears.swift`, `daemon/Sources/ears/StatusDashboardAssembly.swift` (call sites)

**Interfaces:**
- Produces, in `EarsDataStore`:
  ```swift
  public struct SessionScanEnvironment: Sendable {
    public var dataRoot: URL
    public var cleanupTemplate: PathTemplate
    public var outputRoot: String
    public var weekNumbering: WeekNumbering
    public var onEndChain: [OnEndStage]
    public var emptiness: TranscriptEmptinessPolicy
    public init(dataRoot: URL, cleanupTemplate: PathTemplate, outputRoot: String,
                weekNumbering: WeekNumbering, onEndChain: [OnEndStage],
                emptiness: TranscriptEmptinessPolicy = .defaults)
    public static func resolve(from config: ConfigValue) -> SessionScanEnvironment
    public static func load(configFlag: String?) -> Result<SessionScanEnvironment, SessionScanConfigError>
  }
  public struct SessionScanConfigError: Error, Sendable, CustomStringConvertible {
    public var description: String
  }
  public enum SessionArtifactScanner {
    public static func scan(session: Session, environment: SessionScanEnvironment) -> SessionArtifacts
  }
  ```

- [ ] **Step 1: Split the file.** Move `daemon/Sources/ears/SessionArtifactScanner.swift` into the two new files:
  - **`SessionScanEnvironment.swift`** gets:
    - `ScanEnvironment`, renamed `SessionScanEnvironment` and made `public`, with the explicit `public init` above;
    - the body of `environment(configFlag:)`'s success branch as `public static func resolve(from config: ConfigValue)`;
    - `load(configFlag:)`, which builds `ConfigLoadInputs(configFlag:environment:homeDirectory:)` exactly as before, calls `loadConfig(inputs)`, and maps failure to `SessionScanConfigError(description: "error: could not load config: \(error)")`;
    - the private helpers `onEndChain`, `emptinessPolicy`, `stringValue`, `stringArray` and `nestedValue`.
  - **`SessionArtifactScanner.swift`** gets `public enum SessionArtifactScanner` with `scan`, the three per-area scans, `sidecarText` and `directorySize`.
  - Imports: `EarsConfig`, `EarsCore`, `Foundation`.
  - Rewrite each type's doc to say it's shared by `ears` and the menu bar app. Don't write history.
- [ ] **Step 2: Update the call sites.**
  - `SessionArtifactScanner.environment(configFlag: x)` becomes `SessionScanEnvironment.load(configFlag: x)`.
  - Where a failure branch uses `ConfigResolutionError`, use the error's `.description` the same way.
  - Add `import EarsDataStore` wherever it's missing.
- [ ] **Step 3: Prove nothing changed.**
  Run: `cd daemon && swift build && swift test --filter 'CLISmokeTests|EarsCoreTests'`
  Expected: PASS. The smoke tests pin `ears sessions` and `ears session show` output.
- [ ] **Step 4: Lint, run the full suite, run the gate, commit.**
  Message: `refactor(ears): move the session scanner into EarsDataStore`. Body: the menu bar app needs the same "what happened to session X" answer; one implementation instead of two.

## Task 13: Count only this transcript's summaries

**Files:**
- Create: `daemon/Sources/EarsCore/Path/SummarySiblings.swift`
- Modify: `daemon/Sources/EarsDataStore/SessionArtifactScanner.swift`
- Test: `daemon/Tests/EarsCoreTests/SummarySiblingsTests.swift`

**Interfaces:**
- Produces: `public enum SummarySiblings { public static func select(filenames: [String], stem: String) -> [String] }`. The result is sorted and includes only `<stem>.summary.md` and `<stem>.<preset>.summary.md`.

- [ ] **Step 1: Write the failing test.**
  ```swift
  import Testing

  @testable import EarsCore

  @Suite("SummarySiblings")
  struct SummarySiblingsTests {
    @Test("a lone preset and named presets match; longer stems sharing the prefix do not")
    func selectsOnlyThisStem() {
      let names = [
        "2026-08-03 standup.summary.md",
        "2026-08-03 standup.brief.summary.md",
        "2026-08-03 standup-2.summary.md",
        "2026-08-03 standup.brief.extra.summary.md",
        "2026-08-03 standup.md",
      ]
      #expect(
        SummarySiblings.select(filenames: names, stem: "2026-08-03 standup")
          == ["2026-08-03 standup.brief.summary.md", "2026-08-03 standup.summary.md"])
    }
  }
  ```
- [ ] **Step 2: Run it and watch it fail.**
  Run: `cd daemon && swift test --filter SummarySiblingsTests`
  Expected: compile error.
- [ ] **Step 3: Implement.** Port the body of `siblingSummaries(filenames:stem:)` from `git show main:daemon/Sources/EarsMenuKit/SessionArtifacts.swift`:
  ```swift
  /// The summaries `summarize` writes beside a published transcript:
  /// `<stem>.summary.md` from a lone preset, `<stem>.<preset>.summary.md`
  /// from several. A different session whose stem merely starts with this
  /// one (`standup-2`) is not a match. Sorted, so callers pick the same file
  /// every time.
  public enum SummarySiblings {
    public static func select(filenames: [String], stem: String) -> [String] {
      filenames.filter { name in
        guard !name.contains("/"), name.hasSuffix(".summary.md"), name.hasPrefix(stem) else {
          return false
        }
        let middle = name.dropFirst(stem.count).dropLast(".summary.md".count)
        return middle.isEmpty || (middle.hasPrefix(".") && !middle.dropFirst().contains("."))
      }
      .sorted()
    }
  }
  ```
  In the scanner's `scanTranscriptChain`, replace the `hasPrefix(stem) && hasSuffix(".summary.md")` filter with `SummarySiblings.select(filenames: names, stem: stem).count`.
- [ ] **Step 4: Run the tests.**
  Run: `cd daemon && swift test --filter 'SummarySiblingsTests|CLISmokeTests'`
  Expected: PASS.
- [ ] **Step 5: Lint, run the full suite, run the gate, commit.**
  Message: `fix(ears): count only this transcript's summaries`. Body: a same-day session titled `standup-2` was counted as `standup`'s summary.

## Task 14: The scanner reports summary paths

**Files:**
- Modify: `daemon/Sources/EarsCore/CLI/SessionPipelineTypes.swift` (`SessionArtifacts`)
- Modify: `daemon/Sources/EarsDataStore/SessionArtifactScanner.swift`
- Test: `daemon/Tests/EarsDataStoreTests/SessionArtifactScannerTests.swift` (new)
- Test: `daemon/Tests/CLISmokeTests/OnEndChainSmokeTests.swift` (assert the scanner against a real chain)

**Interfaces:**
- Produces: `SessionArtifacts.summaryPaths: [String]` (absolute, sorted; default `[]`). `summaryCount` stays and always equals `summaryPaths.count`.

- [ ] **Step 1: Write the failing test** in `daemon/Tests/EarsDataStoreTests/SessionArtifactScannerTests.swift`:
  ```swift
  import EarsCore
  import EarsCoreTestSupport
  import Foundation
  import Testing

  @testable import EarsDataStore

  @Suite("SessionArtifactScanner")
  struct SessionArtifactScannerTests {
    /// A store with one ended session whose transcript parses, a published
    /// clean transcript at a fixed template path, and two summaries beside it.
    private static func makeStore() throws -> (SessionScanEnvironment, Session, URL) {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanner-\(UUID().uuidString)")
      let published = root.appendingPathComponent("published")
      try FileManager.default.createDirectory(at: published, withIntermediateDirectories: true)
      let session = Session(
        id: "c08595c8-77fa-48c4-a077-ff5d9f60e522", title: "call", state: .ended,
        started: Instant(secondsSinceEpoch: 1_000), ended: Instant(secondsSinceEpoch: 2_000),
        sources: ["mic"])
      let transcript = DataStoreLayout.sessionTranscriptFile(dataRoot: root, sessionID: session.id)
      try FileManager.default.createDirectory(
        at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(EmptySessionTranscripts.substantive.utf8).write(to: transcript)
      for name in ["notes.md", "notes.summary.md", "notes.brief.summary.md"] {
        try Data("x".utf8).write(to: published.appendingPathComponent(name))
      }
      let environment = SessionScanEnvironment(
        dataRoot: root, cleanupTemplate: PathTemplate(published.path + "/notes.md"),
        outputRoot: published.path, weekNumbering: .us, onEndChain: OnEndStage.allCases)
      return (environment, session, published)
    }

    @Test("summary paths are the published summaries beside the clean transcript, sorted")
    func reportsSummaryPaths() throws {
      let (environment, session, published) = try Self.makeStore()
      defer { try? FileManager.default.removeItem(at: environment.dataRoot) }

      let artifacts = SessionArtifactScanner.scan(session: session, environment: environment)

      #expect(artifacts.cleanupExists)
      #expect(
        artifacts.summaryPaths == [
          published.appendingPathComponent("notes.brief.summary.md").path,
          published.appendingPathComponent("notes.summary.md").path,
        ])
      #expect(artifacts.summaryCount == 2)
    }
  }
  ```
  If `Session`'s memberwise init needs other arguments, copy the argument list of `referenceSession()` in `SessionDescriptorTOMLTests` and adjust.
- [ ] **Step 2: Run it and watch it fail.**
  Run: `cd daemon && swift test --filter SessionArtifactScannerTests`
  Expected: compile error on `summaryPaths`.
- [ ] **Step 3: Implement.**
  1. Add to `SessionArtifacts`:
     ```swift
     /// Absolute paths of the summaries beside the cleaned transcript, sorted.
     public var summaryPaths: [String] = []
     ```
  2. In `scanTranscriptChain`:
     ```swift
     let summaries = SummarySiblings.select(filenames: names, stem: stem)
     artifacts.summaryPaths = summaries.map { directory.appendingPathComponent($0).path }
     artifacts.summaryCount = summaries.count
     ```
- [ ] **Step 4: Add the smoke assertion.** In `OnEndChainSmokeTests`' full-chain test, at the end of the function where Task 7 removed the menu block, add:
  ```swift
  // `ears` and the menu bar app read a session back through this scanner,
  // from config and the transcript's own frontmatter — never from a stage's
  // envelope. It must find exactly what the chain wrote.
  let environment = SessionScanEnvironment(
    dataRoot: URL(fileURLWithPath: dataRoot),
    cleanupTemplate: PathTemplate(LLMStagesConfigSchema.defaultCleanupOutput),
    outputRoot: outputRoot, weekNumbering: .us, onEndChain: OnEndStage.allCases)
  let scanned = SessionArtifactScanner.scan(session: ended, environment: environment)
  #expect(scanned.cleanupExists, "scanner resolved \(scanned.cleanupPath ?? "nil"), which is absent")
  #expect(scanned.summaryPaths.count == 1)
  #expect(scanned.summaryPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
  ```
  Use the test's own names for the data root, output root and ended session. They are `dataRoot`, `outputRoot` and `ended` in the fork's version.
- [ ] **Step 5: Run the tests.**
  Run: `cd daemon && swift test --filter 'SessionArtifactScannerTests|OnEndChainSmokeTests'`
  Expected: PASS.
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(datastore): the session scanner reports summary paths`.

## Task 15: A lighter scan for list views

**Files:**
- Modify: `daemon/Sources/EarsDataStore/SessionArtifactScanner.swift`
- Modify: `daemon/Sources/ears/Ears.swift` (`runSessionsList`)
- Modify: `daemon/Sources/ears/StatusDashboardAssembly.swift` (recent tail)
- Test: `daemon/Tests/EarsDataStoreTests/SessionArtifactScannerTests.swift`

**Interfaces:**
- Produces: `public enum SessionArtifactScanner.Depth: Sendable { case full, outcome }` and `scan(session:environment:depth: Depth = .full)`. `.outcome` skips the source-directory size walk and the attribution parse; `SessionPipeline.outcome` reads neither.

- [ ] **Step 1: Write the failing test.** Add to `SessionArtifactScannerTests`:
  ```swift
  @Test("the outcome depth skips the capture walk and attribution but reads the transcript chain")
  func outcomeDepthIsLighter() throws {
    let (environment, session, _) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: environment.dataRoot) }
    let sources = DataStoreLayout.sessionDirectory(
      dataRoot: environment.dataRoot, sessionID: session.id
    ).appendingPathComponent("sources/mic")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 64).write(to: sources.appendingPathComponent("chunk"))

    let full = SessionArtifactScanner.scan(session: session, environment: environment)
    let light = SessionArtifactScanner.scan(
      session: session, environment: environment, depth: .outcome)

    #expect(!full.captureBytesBySource.isEmpty)
    #expect(light.captureBytesBySource.isEmpty)
    #expect(light.transcriptExists && light.cleanupExists)
    #expect(light.summaryPaths == full.summaryPaths)
  }
  ```
- [ ] **Step 2: Run it and watch it fail.**
  Run: `cd daemon && swift test --filter SessionArtifactScannerTests`
  Expected: compile error on `depth:`.
- [ ] **Step 3: Implement.**
  ```swift
  /// How much of a session to read.
  public enum Depth: Sendable {
    /// Everything `ears session show` renders, including a size walk of every
    /// source directory.
    case full
    /// Only what a one-line outcome reads — the transcript chain. List views
    /// scan many sessions per render, where the size walk is wasted.
    case outcome
  }

  public static func scan(
    session: Session, environment: SessionScanEnvironment, depth: Depth = .full
  ) -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    if depth == .full {
      scanCapture(session: session, environment: environment, into: &artifacts)
      scanAttribution(session: session, environment: environment, into: &artifacts)
    }
    scanTranscriptChain(session: session, environment: environment, into: &artifacts)
    return artifacts
  }
  ```
  Pass `depth: .outcome` in `runSessionsList` and in the status dashboard's recent-tail scan.
- [ ] **Step 4: Run the tests.**
  Run: `cd daemon && swift test --filter 'SessionArtifactScannerTests|CLISmokeTests|StatusDashboard'`
  Expected: PASS.
- [ ] **Step 5: Lint, run the full suite, run the gate, commit.**
  Message: `perf(ears): list views scan only what an outcome reads`.
- [ ] **Step 6: Mark the PR boundary.** Run `git branch pr/r1-shared-scanner`.

---

# PR App — `ears-menubar` stage 1

## Task 16: EarsMenuKit — state, reducer and renderer

**Files:**
- Modify: `daemon/Package.swift` (the `EarsMenuKit` target and the `EarsMenuKitTests` test target)
- Create, ported from `main` and stripped:
  - `daemon/Sources/EarsMenuKit/MenuState.swift`
  - `MenuStateReducer.swift`
  - `MenuContent.swift`
  - `MenuRenderer.swift`
  - `ElapsedFormatter.swift`
  - `ReconnectBackoff.swift`
- Test, ported and stripped: `daemon/Tests/EarsMenuKitTests/MenuStateReducerTests.swift`, `MenuRendererTests.swift`, `ReconnectBackoffTests.swift`

**Interfaces:**
- Produces:
  - `MenuState` with `connection`, `daemon`, `sessions`, `sources`, `jobs` and `lastRev`, plus `activeSession`, `runningJobs` and `failedJobs`.
  - `MenuStateReducer.connected(_:daemon:snapshot:)`, `.disconnected(_:)`, `.resubscribing(_:)`, `.apply(_:_:) -> ReduceOutcome` and `.dismissJob(_:id:)`.
  - `MenuRenderer.render(_:now:) -> MenuContent`, and the module-internal `MenuRenderer.stageLabel(_:)`.
  - `Verb`: `startRecording`, `pause(session:)`, `resume(session:)`, `rename(session:currentTitle:)`, `end(session:)`.
  - `IconVariant`, `PipelineLine` and `MenuContent`, unchanged from the fork.

- [ ] **Step 1: Add the targets** to `daemon/Package.swift`, after `EarsLogging`:
  ```swift
  // The menu bar app's pure core: state reduction, rendering, notification
  // policy. No I/O, so it is tested like EarsCore.
  .target(
    name: "EarsMenuKit",
    dependencies: ["EarsCore"]
  ),
  ```
  And at the end of the test targets:
  ```swift
  .testTarget(
    name: "EarsMenuKitTests",
    dependencies: ["EarsMenuKit", "EarsCoreTestSupport"]
  ),
  ```
- [ ] **Step 2: Port the tests without detection.**
  ```bash
  mkdir -p daemon/Tests/EarsMenuKitTests
  for f in MenuStateReducerTests MenuRendererTests ReconnectBackoffTests; do
    git show main:daemon/Tests/EarsMenuKitTests/$f.swift > daemon/Tests/EarsMenuKitTests/$f.swift
  done
  ```
  Then make these deletions:
  - `MenuStateReducerTests`: delete `meetingActivityUpserts`, `reconnectClearsActivity`, `catchUpFromBeforeAReconnectIsDiscarded` and `liveEdgeDuringCatchUpWins`, plus any helper that builds a `MeetingActivityStatus`.
  - `MenuRendererTests`: delete `detectedMeetingOffersBeforeStart`.
  - Check with `grep -n 'meeting\|Meeting\|startDetected' daemon/Tests/EarsMenuKitTests/*.swift`. Expected: nothing.
- [ ] **Step 3: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter EarsMenuKitTests`
  Expected: compile errors (no sources yet).
- [ ] **Step 4: Port the sources without detection.**
  ```bash
  mkdir -p daemon/Sources/EarsMenuKit
  for f in MenuState MenuStateReducer MenuContent MenuRenderer ElapsedFormatter ReconnectBackoff; do
    git show main:daemon/Sources/EarsMenuKit/$f.swift > daemon/Sources/EarsMenuKit/$f.swift
  done
  ```
  Then make these edits:
  - **`MenuState`:** delete `meetingActivity`, `meetingActivityEdits`, `activeMeetings`, `upsertMeetingActivity(_:)` and their init lines.
  - **`MenuStateReducer`:**
    - in `connected`, delete the two `meetingActivity` statements and their comments;
    - in `apply`, delete `case .meetingActivity`;
    - delete `catchUpMeetingActivity`.
  - **`MenuContent`:** delete `case startDetected(...)` from `Verb`.
  - **`MenuRenderer.verbs(for:)`:** the idle branch becomes `guard let session = state.activeSession else { return [.startRecording] }`.
  - **Comments:** reword any comment that narrates history into a statement of why.
- [ ] **Step 5: Run the tests.** Same command as Step 3. Expected: PASS.
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(menubar): pure menu state, reducer and renderer`.

## Task 17: EarsMenuKit — notifications, starting a recording, recent sessions

**Files:**
- Create in `daemon/Sources/EarsMenuKit/`:
  - `NotificationPolicy.swift` (rewritten)
  - `StartRecording.swift` (new)
  - `SummaryTarget.swift` (new)
  - `RecentSessionItem.swift` (new)
  - `DaemonUptime.swift`, `NotificationAvailability.swift`, `RecentsRefreshPolicy.swift` (ported)
- Test in `daemon/Tests/EarsMenuKitTests/`:
  - `NotificationPolicyTests.swift`, `DaemonUptimeTests.swift`, `NotificationAvailabilityTests.swift`, `RecentsRefreshPolicyTests.swift` (ported)
  - `StartRecordingTests.swift`, `SummaryTargetTests.swift`, `RecentSessionItemTests.swift` (new)

**Interfaces:**
- Consumes: `StatusData.Configured` (Task 10), `JobPublishParams.outputs` (Task 2), `SessionArtifacts.summaryPaths` (Task 14), and `MenuState` / `MenuRenderer.stageLabel` (Task 16).
- Produces:
  - `NotificationRequest { title, body, action }` with `Action`: `.openSummary(session: String, path: String?)`, `.revealSession(session: String)`, `.none`.
  - `NotificationPolicy.onEvent(_ frame: EventFrame, state: MenuState) -> NotificationRequest?` and `NotificationPolicy.onDisconnect(state:warnedSessions:) -> NotificationRequest?`.
  - `StartRecording.params(from: StatusData) -> Result<SessionStartParams, StartRecording.Refusal>`, where `Refusal` has cases `.daemonTooOld` and `.noSources` and conforms to `CustomStringConvertible`.
  - `SummaryTarget.written(_ path: String?, exists: (String) -> Bool) -> URL?`.
  - `RecentSessionItem(session:artifacts:outcome:)` with `session`, `transcript: URL?`, `clean: URL?`, `summaries: [URL]`, `outcome: PipelineOutcome`, and `id` (the session id).
  - `RecentSessions.select(from: [Session], limit: Int = 7) -> [Session]`.
  - `DaemonUptime`, `NotificationAvailability`, and `RecentsRefreshPolicy.shouldRefresh(for:)`.

- [ ] **Step 1: Write the new failing tests.**

  `StartRecordingTests.swift`:
  ```swift
  import EarsCore
  import Testing

  @testable import EarsMenuKit

  @Suite("StartRecording")
  struct StartRecordingTests {
    private func status(_ configured: StatusData.Configured?) -> StatusData {
      StatusData(uptimeSeconds: 1, sources: [], configured: configured)
    }

    @Test("declares exactly the daemon's configured sources and chain, and no title")
    func declaresConfigured() throws {
      let params = try StartRecording.params(
        from: status(.init(sources: ["mic", "system"], onEndStages: ["transcribe", "cleanup"]))
      ).get()
      #expect(params.sources == ["mic", "system"])
      #expect(params.onEndStages == ["transcribe", "cleanup"])
      #expect(params.title == nil)
      #expect(params.trigger == nil)
    }

    @Test("an empty configured chain is declared as [] — run nothing — not omitted")
    func emptyChainIsDeclared() throws {
      let params = try StartRecording.params(
        from: status(.init(sources: ["mic"], onEndStages: []))
      ).get()
      #expect(params.onEndStages == [])
    }

    @Test("a daemon whose status has no configured block is refused as too old")
    func olderDaemonIsRefused() {
      #expect(StartRecording.params(from: status(nil)) == .failure(.daemonTooOld))
    }

    @Test("no configured sources is refused rather than recording nothing")
    func noSourcesIsRefused() {
      #expect(
        StartRecording.params(from: status(.init(sources: [], onEndStages: ["transcribe"])))
          == .failure(.noSources))
    }
  }
  ```

  `SummaryTargetTests.swift`:
  ```swift
  import Foundation
  import Testing

  @testable import EarsMenuKit

  @Suite("SummaryTarget")
  struct SummaryTargetTests {
    @Test("the reported file opens while it exists")
    func writtenFileOpens() {
      #expect(
        SummaryTarget.written("/n/a.summary.md", exists: { _ in true })
          == URL(fileURLWithPath: "/n/a.summary.md"))
    }

    @Test("a moved or deleted file, or no reported path, falls back to the caller's scan")
    func missingWrittenFileFallsBack() {
      #expect(SummaryTarget.written("/n/a.summary.md", exists: { _ in false }) == nil)
      #expect(SummaryTarget.written(nil, exists: { _ in true }) == nil)
    }
  }
  ```

  `RecentSessionItemTests.swift`:
  ```swift
  import EarsCore
  import Foundation
  import Testing

  @testable import EarsMenuKit

  @Suite("RecentSessionItem")
  struct RecentSessionItemTests {
    private let session = Session(
      id: "s1", title: "call", state: .ended, started: Instant(secondsSinceEpoch: 0),
      ended: Instant(secondsSinceEpoch: 60))

    @Test("paths come from what the scan found on disk; an absent clean copy is nil")
    func mapsArtifacts() {
      var artifacts = SessionArtifacts()
      artifacts.transcriptExists = true
      artifacts.transcriptPath = "/d/sessions/s1/transcript.md"
      artifacts.cleanupPath = "/p/call.md"
      artifacts.cleanupExists = false
      artifacts.summaryPaths = ["/p/call.summary.md"]
      let item = RecentSessionItem(
        session: session, artifacts: artifacts, outcome: PipelineOutcome(glyph: "·", text: "x"))
      #expect(item.transcript == URL(fileURLWithPath: "/d/sessions/s1/transcript.md"))
      #expect(item.clean == nil)
      #expect(item.summaries == [URL(fileURLWithPath: "/p/call.summary.md")])
      #expect(item.id == "s1")
    }

    @Test("recent sessions are ended ones, most recently ended first")
    func selectsByEnd() {
      let long = Session(
        id: "long", title: "l", state: .ended, started: Instant(secondsSinceEpoch: 0),
        ended: Instant(secondsSinceEpoch: 500))
      let short = Session(
        id: "short", title: "s", state: .ended, started: Instant(secondsSinceEpoch: 100),
        ended: Instant(secondsSinceEpoch: 200))
      let live = Session(
        id: "live", title: "v", state: .active, started: Instant(secondsSinceEpoch: 600))
      #expect(RecentSessions.select(from: [short, live, long]).map(\.id) == ["long", "short"])
    }
  }
  ```
  If `Session`'s init needs more arguments, copy them from `referenceSession()` in `SessionDescriptorTOMLTests`.
- [ ] **Step 2: Port the existing tests.**
  ```bash
  for f in NotificationPolicyTests DaemonUptimeTests NotificationAvailabilityTests RecentsRefreshPolicyTests; do
    git show main:daemon/Tests/EarsMenuKitTests/$f.swift > daemon/Tests/EarsMenuKitTests/$f.swift
  done
  ```
  Then make these edits:
  - **`NotificationPolicyTests`:**
    - replace every `.openSummary(session: X)` with `.openSummary(session: X, path: nil)`;
    - delete any test about `startDetected` or notification categories;
    - add the test below.
  - **`RecentsRefreshPolicyTests`:** delete any `meetingActivity` case.

  The new `NotificationPolicyTests` test:
  ```swift
  @Test("summary ready carries the path the daemon reported writing")
  func summaryCarriesWrittenPath() {
    var state = MenuState()
    state.sessions = [
      Session(id: "s1", title: "Weekly sync", state: .ended, started: Instant(secondsSinceEpoch: 0))
    ]
    let frame = EventFrame(
      event: .job(
        JobPublishParams(
          job: "summarize-1", kind: "summarize", session: "s1", state: .done,
          outputs: ["/n/sync.summary.md"])))
    let request = NotificationPolicy.onEvent(frame, state: state)
    #expect(request?.title == "Summary ready")
    #expect(request?.action == .openSummary(session: "s1", path: "/n/sync.summary.md"))
  }
  ```
  If `EventFrame` has no `init(event:)`, build it the way the other tests in the ported file do.
- [ ] **Step 3: Run them and watch them fail.**
  Run: `cd daemon && swift test --filter EarsMenuKitTests`
  Expected: compile errors.
- [ ] **Step 4: Implement.**
  1. Port `DaemonUptime`, `NotificationAvailability` and `RecentsRefreshPolicy` from `main`. In `RecentsRefreshPolicy`, the last case becomes `case .source, .vad, .segment: return false`.
  2. Write `StartRecording.swift`:
     ```swift
     import EarsCore

     /// What Start Recording asks the daemon for: exactly the sources and chain
     /// the running daemon reports in `status.configured`. The app never reads
     /// daemon config, so what it asks for cannot drift from what the daemon on
     /// the other end of the socket will capture and run.
     public enum StartRecording {
       public enum Refusal: Error, Sendable, Hashable, CustomStringConvertible {
         /// `status` carried no `configured` block: a daemon older than this app.
         case daemonTooOld
         /// The daemon captures no configured source; a session would record nothing.
         case noSources

         public var description: String {
           switch self {
           case .daemonTooOld:
             return "earsd is older than this menu bar app — reinstall with `make install`."
           case .noSources:
             return "No capture sources are configured — see [[earsd.source]] in your config."
           }
         }
       }

       /// No title: the daemon names an unnamed manual session itself, and a
       /// title sent here would read as one the user chose.
       public static func params(from status: StatusData) -> Result<SessionStartParams, Refusal> {
         guard let configured = status.configured else { return .failure(.daemonTooOld) }
         guard !configured.sources.isEmpty else { return .failure(.noSources) }
         return .success(
           SessionStartParams(sources: configured.sources, onEndStages: configured.onEndStages))
       }
     }
     ```
  3. Write `SummaryTarget.swift`:
     ```swift
     import Foundation

     /// Where a "Summary ready" click lands: the file the daemon reported
     /// writing, while it is still there. `nil` sends the caller to its scan —
     /// the file may have been moved or renamed since.
     public enum SummaryTarget {
       public static func written(_ path: String?, exists: (String) -> Bool) -> URL? {
         guard let path, exists(path) else { return nil }
         return URL(fileURLWithPath: path)
       }
     }
     ```
  4. Write `RecentSessionItem.swift`:
     ```swift
     import EarsCore
     import Foundation

     /// One Recent Sessions row: an ended session plus what its scan found on
     /// disk. `nil`/empty means not there, and the menu disables the verb rather
     /// than offering a path that opens nothing.
     public struct RecentSessionItem: Identifiable, Sendable, Equatable {
       public var session: Session
       /// The raw transcript in the data store — an intermediate, offered last.
       public var transcript: URL?
       /// The published, cleaned transcript: the file you actually read.
       public var clean: URL?
       public var summaries: [URL]
       public var outcome: PipelineOutcome
       public var id: String { session.id }

       public init(session: Session, artifacts: SessionArtifacts, outcome: PipelineOutcome) {
         self.session = session
         transcript = artifacts.transcriptExists
           ? artifacts.transcriptPath.map { URL(fileURLWithPath: $0) } : nil
         clean = artifacts.cleanupExists ? artifacts.cleanupPath.map { URL(fileURLWithPath: $0) } : nil
         summaries = artifacts.summaryPaths.map { URL(fileURLWithPath: $0) }
         self.outcome = outcome
       }
     }

     public enum RecentSessions {
       /// Ended sessions, most recently *ended* first — the order `ears status`'s
       /// recent tail uses. A record with no end instant sorts on its start.
       public static func select(from sessions: [Session], limit: Int = 7) -> [Session] {
         Array(
           sessions.filter { $0.state == .ended }
             .sorted { ($0.ended ?? $0.started) > ($1.ended ?? $1.started) }
             .prefix(limit))
       }
     }
     ```
  5. Write `NotificationPolicy.swift`. Port `git show main:daemon/Sources/EarsMenuKit/NotificationPolicy.swift` with these changes:
     - `Action` becomes exactly:
       ```swift
       public enum Action: Sendable, Hashable {
         /// Open the session's summary. `path` is the file the daemon reported
         /// writing, when it reported one.
         case openSummary(session: String, path: String?)
         case revealSession(session: String)
         case none
       }
       ```
       Delete `notificationCategory` and `notificationIdentifier`.
     - The summarize-done action becomes `job.session.map { .openSummary(session: $0, path: job.outputs?.first) } ?? .none`.
     - Keep `onDisconnect` and the warnings body as they are. Trim the `onDisconnect` doc to the why: it's edge-triggered, it's armed from `.connecting` too, and it warns once per at-risk session.
- [ ] **Step 5: Run the tests.** Same command as Step 3. Expected: PASS.
- [ ] **Step 6: Lint, run the full suite, run the gate, commit.**
  Message: `feat(menubar): notification, start-recording and recent-session policies`.

## Task 18: The menu bar shell

This task is the SwiftUI shell. There are no unit tests here: the pure parts are covered by Tasks 16–17, and the shell gets the manual checklist in Task 21.

**Files:**
- Modify: `daemon/Package.swift`:
  - add the product `.executable(name: "ears-menubar", targets: ["ears-menubar"])`;
  - add the target `.executableTarget(name: "ears-menubar", dependencies: ["EarsMenuKit", "EarsCore", "EarsConfig", "EarsIPC", "EarsDataStore"])`.
- Create in `daemon/Sources/ears-menubar/`:
  - `MenuBarApp.swift`, `AppModel.swift`, `AppClock.swift`, `ClientConfig.swift`, `DaemonConnection.swift`, `SessionControls.swift`, `RecentsStore.swift`, `SessionNotifications.swift`, `Notifier.swift`, `SystemActions.swift`, `RenamePrompt.swift`, `MenuContentView.swift`, `LaunchAtLoginToggle.swift`

**Interfaces:**
- Consumes: everything in `EarsMenuKit`, plus `SessionScanEnvironment`, `SessionArtifactScanner`, `SessionStore`, `DataStoreLayout`, `ControlSocketClient` and `DefaultSocketPath`.

- [ ] **Step 1: Write the small files.**

  `AppClock.swift`:
  ```swift
  import EarsCore
  import Foundation

  /// The app's one wall-clock read, kept out of `EarsMenuKit` so the pure core
  /// only ever sees injected instants.
  enum AppClock {
    static func now() -> Instant { Instant(secondsSinceEpoch: Date().timeIntervalSince1970) }
  }
  ```

  `ClientConfig.swift`:
  ```swift
  import EarsConfig
  import EarsCore
  import EarsDataStore
  import Foundation

  struct ClientConfigError: Error, Sendable, CustomStringConvertible {
    var description: String
  }

  /// Where the daemon is and how to read its sessions back — the only config
  /// this app reads. What a session records and runs comes from the daemon
  /// itself (`status.configured`), never from here.
  struct ClientConfig: Sendable {
    var socketPath: String
    var environment: SessionScanEnvironment

    static func resolve() -> Result<ClientConfig, ClientConfigError> {
      let inputs = ConfigLoadInputs(
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
      switch loadConfig(inputs) {
      case .failure(let error):
        return .failure(ClientConfigError(description: "config load failed: \(error)"))
      case .success(let loaded):
        let environment = SessionScanEnvironment.resolve(from: loaded.value)
        var configured = ""
        if case .table(let root) = loaded.value, case .string(let value)? = root["socket_path"] {
          configured = value
        }
        let socketPath =
          configured.isEmpty
          ? DefaultSocketPath.resolve(dataRoot: environment.dataRoot.path) : configured
        if let message = DefaultSocketPath.lengthError(forPath: socketPath) {
          return .failure(ClientConfigError(description: message))
        }
        return .success(ClientConfig(socketPath: socketPath, environment: environment))
      }
    }
  }
  ```

  `DaemonConnection.swift`: port `git show main:daemon/Sources/ears-menubar/DaemonConnection.swift` with these changes:
  1. `Event.ready` becomes `case ready(daemon: String, snapshot: SnapshotData)`; yield `.ready(daemon: hello.daemon, snapshot: snapshot)`.
  2. `hello(client: "menubar/\(Self.version)")`, with
     `private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"`. Add `import Foundation`.
  3. Subscribe with `SubscribeParams(events: [.job])`.
  4. Delete `startSession(_:)`.
  5. Trim comments to the why. Keep the ones on closing sockets that were dialled but never adopted, on the silent bounce, and on clearing `client` before awaiting `close()`.

  Port `SystemActions.swift` and `RenamePrompt.swift` from `main` unchanged, apart from trimming comments to the why.

  `LaunchAtLoginToggle.swift`: move the `LaunchAtLoginToggle` struct out of the fork's `MenuContentView.swift` unchanged, with `import ServiceManagement` and `import SwiftUI`.
- [ ] **Step 2: Write `SessionControls.swift`.**
  ```swift
  import EarsCore
  import EarsMenuKit

  /// The session verbs, as control calls. Each returns why it failed, or `nil`:
  /// the caller surfaces every failure, because a verb that silently does
  /// nothing leaves the user believing a recording stopped when it did not.
  struct SessionControls: Sendable {
    let connection: DaemonConnection

    /// Asks the daemon what it is configured to record, then starts exactly
    /// that — see ``StartRecording``.
    func startRecording() async -> String? {
      guard let status = await connection.status() else { return "not connected to earsd" }
      switch StartRecording.params(from: status) {
      case .failure(let refusal): return refusal.description
      case .success(let params): return await connection.perform(.sessionStart(params))?.message
      }
    }

    func pause(_ session: String) async -> String? {
      await connection.perform(.sessionPause(session: session))?.message
    }

    func resume(_ session: String) async -> String? {
      await connection.perform(.sessionResume(session: session))?.message
    }

    func end(_ session: String) async -> String? {
      await connection.perform(.sessionEnd(session: session))?.message
    }

    func rename(_ session: String, to title: String) async -> String? {
      await connection.perform(.sessionRename(SessionRenameParams(session: session, title: title)))?
        .message
    }
  }
  ```
- [ ] **Step 3: Write `RecentsStore.swift`.**
  ```swift
  import EarsCore
  import EarsDataStore
  import EarsMenuKit
  import Foundation
  import Observation

  /// Reads recent sessions back from disk through the scanner `ears` uses.
  /// Never writes: earsd stays the only writer.
  struct RecentsLoader: Sendable {
    var environment: SessionScanEnvironment

    func load(limit: Int = 7, now: Instant) -> [RecentSessionItem] {
      let all = SessionStore.readAll(dataRoot: environment.dataRoot)
      return RecentSessions.select(from: all, limit: limit).map { item(for: $0, now: now) }
    }

    /// The first summary on disk for one session — a notification click's
    /// fallback when the daemon reported no path, or the file has moved.
    func summary(forSession id: String, now: Instant) -> URL? {
      guard let session = try? SessionStore.read(sessionID: id, dataRoot: environment.dataRoot)
      else { return nil }
      return item(for: session, now: now).summaries.first
    }

    private func item(for session: Session, now: Instant) -> RecentSessionItem {
      let artifacts = SessionArtifactScanner.scan(
        session: session, environment: environment, depth: .outcome)
      let outcome = SessionPipeline.outcome(
        session: session, artifacts: artifacts, now: now,
        configuredChain: environment.onEndChain, emptiness: environment.emptiness)
      return RecentSessionItem(session: session, artifacts: artifacts, outcome: outcome)
    }
  }

  /// The Recent Sessions submenu's rows, refreshed off the main actor so a
  /// large store never stalls the menu bar.
  @MainActor @Observable final class RecentsStore {
    private(set) var items: [RecentSessionItem] = []
    let loader: RecentsLoader?

    init(loader: RecentsLoader?) {
      self.loader = loader
    }

    func refresh() {
      guard let loader else { return }
      Task.detached { [weak self] in
        let items = loader.load(now: AppClock.now())
        await MainActor.run { self?.items = items }
      }
    }
  }
  ```
- [ ] **Step 4: Write `Notifier.swift` and `SessionNotifications.swift`.**
  - **`Notifier.swift`:** port from `main` and remove:
    - the `startDetected` property and parameter;
    - `meetingPromptCategory` and the `setNotificationCategories` call;
    - `withdrawMeetingPrompts`;
    - the `startDetected` branches in `encode`, `decode` and `didReceive`.

    Then make these changes:
    - Post with `identifier: UUID().uuidString`, and don't set `categoryIdentifier`.
    - Keep `content.sound = .default` and `.banner, .list, .sound` in `willPresent`.
    - In `didReceive`, act only on `UNNotificationDefaultActionIdentifier`; every other identifier just completes.
    - `encode` / `decode`: `openSummary` writes `["action": "openSummary", "session": s]`, plus `"path": p` when `p` is non-nil. Decode reads `userInfo["path"] as? String`.
  - **`SessionNotifications.swift`:** port from `main`. Delete `announceMeetingPrompts`, `withdrawMeetingPrompts` and the `startDetected` parameter. `bootstrap` becomes:
    ```swift
    func bootstrap(
      dataRoot: String, loader: RecentsLoader?,
      report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
    ) {
      notifier.bootstrap { action in
        switch action {
        case .openSummary(let session, let path):
          if let written = SummaryTarget.written(path, exists: FileManager.default.fileExists(atPath:)) {
            return written
          }
          return loader?.summary(forSession: session, now: AppClock.now())
        case .revealSession(let session):
          return DataStoreLayout.sessionDirectory(
            dataRoot: URL(fileURLWithPath: dataRoot), sessionID: session)
        case .none:
          return nil
        }
      } report: { availability in
        report(availability)
      }
    }
    ```
- [ ] **Step 5: Write `AppModel.swift`.**
  ```swift
  import AppKit
  import EarsCore
  import EarsMenuKit
  import Foundation
  import Observation
  import os

  /// The menu's observable state and the loop that keeps it in step with the
  /// daemon: socket frames → ``MenuStateReducer`` → ``MenuRenderer``. Verbs go
  /// through ``SessionControls``, recent sessions through ``RecentsStore``, and
  /// notifications through ``SessionNotifications``.
  @MainActor @Observable final class AppModel {
    private(set) var state = MenuState()
    private(set) var content = MenuContent(
      icon: .idle, header: "Connecting to earsd…", verbs: [], pipeline: [])
    private(set) var uptime: DaemonUptime?
    /// The last control call that failed, shown in the menu where the user who
    /// clicked is looking.
    private(set) var actionError: String?
    /// Starts `.authorized` so a launch does not flash a warning while the grant
    /// is still resolving.
    private(set) var notifications: NotificationAvailability = .authorized
    let recents: RecentsStore
    let dataRoot: String
    private let configError: String?
    private let connection: DaemonConnection?
    private let announcements = SessionNotifications()
    private let log = Logger(subsystem: "net.tomelliot.ears.menubar", category: "app")

    init(config: ClientConfig) {
      dataRoot = config.environment.dataRoot.path
      connection = DaemonConnection(socketPath: config.socketPath)
      recents = RecentsStore(loader: RecentsLoader(environment: config.environment))
      configError = nil
    }

    init(configError message: String) {
      dataRoot = ""
      connection = nil
      recents = RecentsStore(loader: nil)
      configError = message
      content = MenuContent(icon: .attention, header: "⚠ \(message)", verbs: [], pipeline: [])
    }

    func start() {
      guard let connection else { return }
      announcements.bootstrap(dataRoot: dataRoot, loader: recents.loader) { [weak self] in
        self?.notifications = $0
      }
      observeMenuTracking()
      Task { await connection.run() }
      Task { await pump(connection) }
    }

    var daemonLine: String {
      DaemonUptime.line(daemon: state.daemon, uptime: uptime, now: AppClock.now())
    }

    func perform(_ verb: Verb) {
      guard let connection else { return }
      let controls = SessionControls(connection: connection)
      let call: @Sendable () async -> String?
      switch verb {
      case .startRecording: call = { await controls.startRecording() }
      case .pause(let session): call = { await controls.pause(session) }
      case .resume(let session): call = { await controls.resume(session) }
      case .end(let session): call = { await controls.end(session) }
      case .rename(let session, let currentTitle):
        guard let title = RenamePrompt.run(currentTitle: currentTitle) else { return }
        call = { await controls.rename(session, to: title) }
      }
      Task {
        if let message = await call() { report(message) } else { actionError = nil }
      }
    }

    func dismiss(jobID: String) {
      MenuStateReducer.dismissJob(&state, id: jobID)
      rerender()
    }

    /// `bounce()` yields no `.down`, so the state transition is this caller's:
    /// without it the menu keeps offering Pause/End over a socket that is gone.
    func restartDaemon() {
      guard let connection else { return }
      MenuStateReducer.resubscribing(&state)
      uptime = nil
      rerender()
      Task { [weak self] in
        if let error = await SystemActions.restartDaemon() { self?.report(error) }
        await connection.bounce()
      }
    }

    private func pump(_ connection: DaemonConnection) async {
      for await event in connection.events {
        switch event {
        case .ready(let daemon, let snapshot):
          MenuStateReducer.connected(&state, daemon: daemon, snapshot: snapshot)
          actionError = nil
          anchorUptime(connection)
          recents.refresh()
        case .event(let frame):
          switch MenuStateReducer.apply(&state, frame) {
          case .gap:
            // Only the first gap bounces: frames queued behind it are from the
            // same dead stream and reduce to `.gap` too.
            if state.connection == .connected {
              MenuStateReducer.resubscribing(&state)
              await connection.bounce()
            }
          case .applied:
            announcements.announce(frame, state: state)
            if RecentsRefreshPolicy.shouldRefresh(for: frame) { recents.refresh() }
          case .ignoredStale:
            break
          }
        case .down:
          // Before reducing: the warning is edge-triggered off the state it drops from.
          announcements.warnAtRisk(state: state)
          MenuStateReducer.disconnected(&state)
          uptime = nil
        }
        rerender()
      }
    }

    /// Re-anchors uptime against the process now on the socket. A failed
    /// `status` leaves no anchor rather than the previous process's.
    private func anchorUptime(_ connection: DaemonConnection) {
      Task { [weak self] in
        let status = await connection.status()
        self?.uptime = status.map {
          DaemonUptime(reported: Double($0.uptimeSeconds), anchor: AppClock.now())
        }
      }
    }

    private func report(_ message: String) {
      log.error("control call failed: \(message, privacy: .public)")
      actionError = message
    }

    private func rerender() {
      // The config-error model's content *is* the error; rendering the empty
      // state over it would replace it with a wait that never ends.
      guard configError == nil else { return }
      content = MenuRenderer.render(state, now: AppClock.now())
    }

    private func menuWillOpen() {
      rerender()
      recents.refresh()
      announcements.refreshAvailability { [weak self] in self?.notifications = $0 }
    }

    /// The menu-style `MenuBarExtra` gives its content no per-open hook;
    /// AppKit still posts `didBeginTracking` for the status item's menu, and
    /// this `LSUIElement` app has exactly one menu.
    private func observeMenuTracking() {
      Task { [weak self] in
        let opens = NotificationCenter.default.notifications(
          named: NSMenu.didBeginTrackingNotification)
        for await _ in opens {
          guard let self else { return }
          self.menuWillOpen()
        }
      }
    }
  }
  ```
- [ ] **Step 6: Write `MenuBarApp.swift` and `MenuContentView.swift`.**
  - **`MenuBarApp.swift`:** port from `main` with these changes: `ClientConfig.resolve()` now fails with `ClientConfigError`; remove `.onAppear { model.menuWillOpen() }`, because the tracking observer covers every open. Keep `AppDelegate`'s `.accessory` activation policy.
  - **`MenuContentView.swift`:** port from `main` with these changes:
    - move `LaunchAtLoginToggle` out (Step 1);
    - `model.recents` becomes `model.recents.items`;
    - delete the `.startDetected` label case;
    - keep the `IconVariant.systemImage` mapping and `MenuBarLabel`;
    - trim comments to the why.
- [ ] **Step 7: Build and check the gates.**
  Run: `cd daemon && swift build --product ears-menubar && swift format lint --recursive --strict Sources/ Tests/ && wc -l Sources/ears-menubar/*.swift | sort -n | tail -3`
  Expected: the build succeeds, lint is clean, and every file is ≤ 300 lines.
- [ ] **Step 8: Smoke-run it unbundled.**
  Run: `swift run ears-menubar &` against a running `earsd`, then `kill %1`.
  Expected: an ear glyph appears in the menu bar; the menu shows "Idle" and Start Recording. Notifications are no-ops without a bundle, as designed.
- [ ] **Step 9: Run the full suite and the gate, then commit.**
  Message: `feat(menubar): the menu bar app shell`. Body: a thin SwiftUI client that learns what to record from `status.configured` and reads sessions back through the shared scanner; no daemon config parsing.

## Task 19: Package All Ears.app

**Files:**
- Modify: `Makefile`
- Create: `packaging/ears-menubar.Info.plist`

**Interfaces:**
- Produces: `make menubar` (build, assemble, sign, install to `~/Applications/All Ears.app`, relaunch) and `make uninstall-menubar`. `make uninstall` also runs `uninstall-menubar`. `make install` is unchanged.

- [ ] **Step 1: Write the Info.plist.**
  1. `git show main:packaging/ears-menubar.Info.plist > packaging/ears-menubar.Info.plist`
  2. Delete the alert-style comment, the `NSUserNotificationAlertStyle` key/value, and the `NSCalendarsFullAccessUsageDescription` key/value.
  3. Check with `plutil -lint packaging/ears-menubar.Info.plist`. Expected: `OK`.
- [ ] **Step 2: Update the Makefile.** Apply the fork's Makefile diff (`git diff upstream/main main -- Makefile`) with **one** change: keep upstream's line `install: guard-user build sign install-bin install-agent`, without `menubar`. So take:
  - the `MENUBAR_BIN` … `ICON_SRC` variables;
  - the `RESOLVE_IDENTITY` macro and its use in `sign`;
  - `menubar` and `uninstall-menubar` in `.PHONY`;
  - the `help` line;
  - `uninstall-menubar` in `uninstall`;
  - the `menubar` and `uninstall-menubar` recipes.

  Trim the recipe comments to the why.
- [ ] **Step 3: Verify.**
  Run: `make -n install | grep -c menubar`
  Expected: `0`.
  Run: `make menubar`
  Expected: `All Ears.app` is in `~/Applications` and launches. `codesign -dv ~/Applications/All\ Ears.app` shows the identity.
- [ ] **Step 4: Run the gate and commit.**
  Message: `build(menubar): package All Ears.app via make menubar`. Body: opt-in, so `make install` is unchanged for everyone else.

## Task 20: Docs for the menu bar app

**Files:**
- Modify: `docs/architecture.md`, `docs/overview.md`, `docs/distribution.md`, `docs/configuration.md`, `docs/specs/control-protocol.md`, `README.md`
- Create: `docs/plans/menubar-app.md`

- [ ] **Step 1: Port the fork's doc hunks** that mention `ears-menubar` or the menu bar app, from `git diff upstream/main main -- docs/architecture.md docs/overview.md docs/distribution.md README.md docs/specs/control-protocol.md`. That covers the executable list, the tools table, the `make menubar` note, the README section, and "the menu-bar app (`ears-menubar`)" in the protocol intro. Drop every sentence about detection, prompts or calendar.
- [ ] **Step 2: Add a sentence to `docs/configuration.md`,** after the `on_end_stages` comment block Task 7 ported: `The menu bar app starts sessions with the sources and chain the running daemon reports in \`status.configured\`, so this setting reaches menu-started recordings too.`
- [ ] **Step 3: Write `docs/plans/menubar-app.md`** from the spec's "App — ears-menubar stage 1", "Packaging and docs" and "Testing" sections, in the shape of the fork's `docs/plans/menubar-app.md` (One job / Decisions / Architecture / UX / Packaging / Testing). It must describe this design:
  - `status.configured` and the shared scanner;
  - no config parsing;
  - banner notifications;
  - no detection;
  - no "Upstream" section, and no history.
- [ ] **Step 4: Run the gate** and check the doc links: `grep -o '](\.\{0,2\}/[^)]*)' docs/plans/menubar-app.md`. Each target must exist.
- [ ] **Step 5: Commit.**
  Message: `docs: the menu bar app`.

## Task 21: Final verification and PR pointers

- [ ] **Step 1: Run the full gates from a clean build.**
  ```bash
  cd daemon && rm -rf .build && swift format lint --recursive --strict Sources/ Tests/ && swift build && swift test 2>&1 | tail -3
  cd ../browser && bun run test 2>&1 | tail -3
  ```
  Expected: all green. The test count is above the Task 0 baseline.
- [ ] **Step 2: Run the detection gate and the fork-files check.**
  ```bash
  git diff --name-only upstream/main | grep -E '^CLAUDE\.md$|^docs/superpowers/'
  ```
  Expected: no output from either.
- [ ] **Step 3: Check that every PR boundary builds.**
  ```bash
  for b in pr/w1-job-events pr/w2-declared-chain pr/w3-status-configured pr/r1-shared-scanner; do
    git checkout -q $b && (cd daemon && swift build && swift test) || echo "RED at $b"
  done
  git checkout -q upstream-menubar
  ```
  Expected: nothing prints "RED".
- [ ] **Step 4: Point the app PR branch.** Run `git branch pr/app-menubar upstream-menubar`.
- [ ] **Step 5: Run the manual checklist** with `make install && make menubar` and a real daemon. Record the results in the final report:
  1. Start Recording → the icon shows recording and the header shows the default title. Pause → paused icon. Resume. Rename… → the new title shows. End.
  2. After End, with the default chain: a "Summary ready" notification. Clicking it opens exactly the summary file.
  3. Move that summary file, then click an older "Summary ready" notification → it opens via the scan, or opens nothing. It never errors.
  4. Stop `earsd` mid-recording (`launchctl kill TERM gui/$UID/net.tomelliot.ears.earsd`) → "Recording at risk" appears once, and the icon shows attention.
  5. Restart Daemon from the menu → it reconnects, and the uptime restarts.
  6. Launch at Login: toggle it on and off, and check the Login Items state.
  7. Deny notifications in System Settings, then open the menu → the "Notifications are off" line appears with a Settings shortcut.
  8. Recent Sessions shows the ended session with its outcome glyph. Open Summary, Open Transcript and Show in Finder each work.
- [ ] **Step 6: Report to the user:** the branch names, the commits per PR, and the checklist results. Do not push.
