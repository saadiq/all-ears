# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

All Ears is a macOS suite that records each audio source of a session as its own
stream and turns it into clean, summarised text. Two codebases live here:

- `daemon/` — one Swift 6 package (macOS 15+, Apple Silicon) producing five
  binaries: `earsd`, `ears`, `transcribe`, `cleanup`, `summarize`.
- `browser/` — a WXT/TypeScript Chrome+Firefox extension that isolates each
  meeting participant's audio and pushes it to the daemon.

`docs/` is a first-class part of the repo, not an afterthought: `docs/architecture.md`,
`docs/data-formats.md`, and `docs/specs/*` are the contracts the code implements.
**When code and a doc disagree, that is a bug in one of them — fix it, don't let it stand.**

## Commands

### Daemon (Swift) — run from `daemon/`

```sh
swift build                                   # debug build
swift build -c release                        # what `make install` builds
swift test                                    # full suite (hermetic by default)
swift test --filter TranscribeTests           # one target
swift test --filter SessionRegistryTests      # one suite
swift format lint --recursive --strict Sources/ Tests/   # exactly what CI runs
swift format --recursive -i Sources/ Tests/              # fix formatting
```

Tests use **swift-testing** (`import Testing`, `@Test`/`#expect`), not XCTest.

Live model/audio tests are opt-in so the default suite stays hermetic:

```sh
EARS_LIVE_MODEL_TEST=1 swift test --filter AMIDiarizationLiveTests
EARS_LIVE_SYSTEM_AUDIO_TEST=1 swift test --filter ...   # needs real hardware + TCC grants
```

Audio fixtures are never committed — they are fetched on demand, pinned by SHA-256,
and cached under `~/Library/Caches` (see `Tests/TranscribeTests/IntegrationFixture.swift`).

### Install / run the daemon

```sh
make install     # build + sign + install to ~/.local/bin + load the LaunchAgent
make status      # LaunchAgent state + `ears status`
make uninstall   # removes agent and binaries; leaves data untouched
launchctl kickstart -k gui/$UID/net.tomelliot.ears.earsd   # restart after a config change
```

Never run `make install` under `sudo` — the LaunchAgent must load into your GUI
session. macOS ties the mic/system-audio grant to the code-signing identity, so
pass `SIGN_IDENTITY="Developer ID Application: ..."` to keep the grant across rebuilds.

### Browser extension — run from `browser/`

```sh
bun install
bun run test        # vitest, unit tests over lib/**/*.test.ts (node env, no DOM)
bunx vitest run lib/identity/meet.test.ts     # one file
bun run compile     # tsc --noEmit
bun run dev         # WXT dev server (Chrome)
bun run build       # → .output/chrome-mv3  (NB: also bumps package.json patch version)
bun run build:firefox
```

`browser/dev/stub-server.ts` speaks the daemon's wire protocol, so the extension
is testable end-to-end with no daemon running. `WXT_DEV_LOCALHOST=1` adds a
localhost match so the synthetic WebRTC harness in `dev/` exercises the real
content-script injection path.

**CI (`.github/workflows/ci.yml`) only covers the daemon** — format lint, build,
test. Browser tests must be run locally.

### Hooks

`git config core.hooksPath .githooks` once per clone — the pre-commit hook runs
`swift format lint --strict` on staged Swift files.

## Architecture

### Disk is the API

`earsd` is the **only writer** to the audio store under `~/Library/Application Support/ears`;
every other tool reads files directly. The on-disk layout in `docs/data-formats.md`
is a versioned public interface. Consequences to preserve when changing things:

- A daemon crash never makes captured audio unreadable or untranscribable.
- Tools are developed and tested against fixture stores with no daemon running.
- Never add a tool→tool dependency; they compose through files and exit codes only.

Audio is **session-scoped**: `sessions/<uuid>/sources/<source-id>/{chunks,asr,vad}`.
`session.toml` (schema 3) and `events.jsonl` are kept forever; `sources/` is deleted
wholesale by transcript-driven retention. Descriptors with `schema != 3` and the old
`meetings/` tree are ignored, never migrated.

### Control plane

`earsd` serves the same command set on a Unix domain socket (for `ears` and the
pipeline tools) and an optional loopback control WebSocket (for the extension,
fail-closed `Origin` allowlist). Binary PCM ingestion is a *separate* loopback
WebSocket that accepts nothing but `ingest.open`/`ingest.close` and audio frames.
Sockets carry control and notifications; results always land on disk.

### Module layout (`daemon/Sources/`)

- `EarsCore` — **pure, no I/O**: index reading, range reconstruction, segment
  merging, streaming deltas, transcript rendering, socket message types, config
  layering. This is where new logic belongs by default; it is what makes TDD cheap.
- Protocol seams at every hardware/model boundary: `CaptureBackend`, `Transcriber`,
  `StreamingTranscriber`, `Diarizer`, `VAD`, `PermissionProviding`.
- Thin shims behind those seams — `EarsCaptureKit` (Core Audio/process taps),
  `EarsTranscribeKit` (FluidAudio/Parakeet), `EarsDiarizeKit` (Sortformer),
  `EarsDataStore` (chunk + session I/O), `EarsIPC` (sockets), `EarsLLMKit`
  (LLM subprocess), `EarsConfig`, `EarsLogging`, `EarsCLISupport`.
- `EarsDaemonKit` holds `earsd`'s real orchestration (`CaptureActor`,
  `ControlServer`, `SessionRegistry`) as a *library* so it is `@testable import`-able
  without spawning a process. The executable targets wire libraries together and
  own no business logic — keep it that way.

Only `EarsTranscribeKit`/`EarsDiarizeKit` may touch FluidAudio; only `EarsCaptureKit`
may touch Core Audio.

### Concurrency

Headless and actor-based, enforced by Swift 6 strict concurrency. **No `@MainActor`
anywhere in the core.** One `CaptureActor` per source, built when a session names it
and torn down when the session ends. Every IO-proc/tap callback is gated by a
**generation counter**; any `await` in a capture path must re-check ownership before
acting on the result. The one accepted exception to actors is a realtime type where
an actor would add latency — there, a lock plus `@unchecked Sendable`, deliberately
and locally.

Two buffers exist and conflating them is a known bug source: the in-RAM lock-free
SPSC jitter buffer (drops loud, milliseconds-deep) and the on-disk audio store.

### Browser extension

Four contexts, one direction of audio flow: `hook.content.ts` (MAIN world,
`document_start`, patches `RTCPeerConnection`) → `content.ts` (isolated-world relay
via `postMessage`) → `background.ts` (MV3 service worker, owns both WebSockets) →
`earsd`. Only `lib/identity/` branches on platform; the capture spine never does.
The hook is passive — never mutate SDP or transceiver direction, and never discover
tracks via `getReceivers()`/`getTransceivers()` (use the `track` event).

## Conventions that are easy to violate

- **TDD is mandatory** for pure/`EarsCore` logic (tier 0) and tool-vs-fixture-store
  contracts (tier 1). Test-first is relaxed only at hardware/model shims (tier 2).
  Every bug fix ships a regression test. See `docs/engineering-practices.md`.
- **No wall-clock time in tests** — inject clocks; never call `Date()` or real timers
  in a test path.
- **Small, green, Conventional Commits**: `type(scope): summary`, scope = tool or
  package (`fix(transcribe): pad trailing silence before TDT decode`). One logical
  change per commit; every commit builds and passes. No dead code, no `_old`/`_v2`
  parallel implementations, no unwired capability presented as shipped.
- **stdout is a guarded result channel.** Batch stages call
  `ResultChannel.activate()`, which `dup2`s fd 1 to stderr so stray `print`s (or a
  chatty dependency) physically cannot pollute the result line. Emit results only
  via `emitResult`.
- **Exit codes carry a failure class, never data states** (`EarsCLISupport/ExitClass`):
  0 success, 3 input-missing, 4 stage-failed, 5 retryable-upstream, 64 usage.
- **`--json` envelopes are schema'd** in `shared/stage-envelopes/*.schema.json`; the
  `.examples.json` fixtures are round-tripped by the Swift suite, so drift fails the
  build. Additive keys are non-breaking; removals bump the major in `schema`.
- **Config is layered**: defaults → TOML → `EARS_*` env (nested keys via `__`) →
  typed flags → `--set key=value`. Every tool accepts `--set`/`--print-config`/
  `--config-path`; `ears config describe` renders the whole schema. Adding a setting
  means adding it to the schema, not just reading an env var.
- **Fail loud, log always**: non-zero exits, structured JSON Lines logs mirrored to
  Apple unified logging, outputs written atomically (temp + rename).

Test-only escape hatches, gated behind env vars normal invocations never set:
`EARS_CAPTURE_BACKEND=synthetic`, `ALLEARS_TRANSCRIBE_BACKEND=null`,
`EARS_SOCKET_PATH`, `EARS_CONFIG`, `EARS_DATA_ROOT`.

## Not built yet (don't describe these as shipped)

Within-stream diarization (labels come from the source alone: `mic` → `You`),
vocabulary biasing at the ASR decoder (vocabulary applies at `cleanup` only),
configurable VAD/ASR backends, signed+notarized builds, and live-verified Firefox
support for the extension.
