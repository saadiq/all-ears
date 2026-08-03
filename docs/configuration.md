# Configuration

## Model

Layered, highest wins:

1. **Built-in defaults** — every setting has one; the suite runs with no config file.
2. **Config file** — TOML at a standard path.
3. **Environment variables** — prefix `EARS_`, nested keys joined by `__` (e.g. `EARS_LOG__LEVEL`).
4. **CLI flags** — per-invocation overrides: the typed flags (`--log-level`, `--log-file`), then the generic `--set`/`--set-string` on top.

Example for the data root: default `~/Library/Application Support/ears` → `data_root` in TOML → `EARS_DATA_ROOT` → `--set data_root=/path`.

## Overriding any setting from the CLI

Every tool accepts `--set <dotted.key>=<value>` (repeatable) to override any config setting for one invocation, without a dedicated flag per key — the CLI-side twin of the `EARS_*` environment variables, and the highest-precedence layer:

```
transcribe --set transcribe.backend=parakeet --set diarize.backend=sortformer
earsd --set earsd.vad.min_silence_ms=500 --set log.level=debug
cleanup notes.transcript.md --set llm.model=claude-opus-4-8
```

- **Typed values.** `true`/`false`, integers, and floats are coerced to their type, matching the `EARS_*` layer. Use `--set-string <key>=<value>` to force a literal string (a version like `1.0`, a numeric id).
- **The value may contain `=`.** Only the first `=` splits key from value, so `--set llm.command='llm -m gpt'` works.
- **Validated.** An override is merged then checked against the schema, so a typo'd key or a wrong-typed value is rejected with a precise message, never silently dropped. A malformed `--set` (no `=`) fails the invocation.
- **Arrays replace wholesale.** Setting an array-valued key replaces the whole array; there is no element-wise patch.

The typed convenience flags (`--log-level`, `--log-file`, and `cleanup`'s `--model`/`--prompt`/`--vocab`/`--no-vocab`) remain; `--set` reaches everything else.

## Discovering settings

`ears config describe` lists every setting across all tools — dotted key, type, default, and a one-line description — rendered from the schema itself, so it never drifts from the code:

```
ears config describe
```

Two companions show the resolved values rather than the reference: `ears config show` (or any tool's `--print-config`) prints the merged config as TOML, and `ears config path` (or `--config-path`) reports which file was loaded.

## File location

Resolved in order:

1. `--config <path>` flag.
2. `EARS_CONFIG` env var.
3. `$XDG_CONFIG_HOME/ears/config.toml` if set.
4. `~/.config/ears/config.toml`.

All tools read the same file. Tool-specific settings live in their own tables.

## Reference

```toml
schema = 1

# --- Shared paths ---
data_root   = "~/Library/Application Support/ears"  # sessions (records + audio), vocab, runtime
output_root = "~/Documents/Transcripts"             # transcripts, summaries
socket_path = ""   # empty => <data_root>/runtime/earsd.sock

# --- Logging (see logging.md) ---
[log]
level     = "info"        # debug | info | notice | error
file      = ""            # JSON Lines sink (primary); empty => <data_root>/logs/<tool>.jsonl
format    = "auto"        # auto | json | pretty  (auto: pretty on a TTY, json otherwise)
oslog     = true          # also mirror events into Apple unified logging
subsystem = "net.tomelliot.ears"
rotate_max_bytes = 52428800   # rotate the JSON log at ~50MB
rotate_max_files = 5

# --- Capture daemon ---
[earsd]
chunk_seconds            = 30     # bounds live-transcription latency; use ~10 for `transcribe --follow`
codec                    = "aac"  # aac | opus
bitrate                  = 64000
native_sample_rate       = 48000  # listenable chunks/ feed
asr_sample_rate          = 16000  # derived asr/ feed for transcription
store_native             = true   # keep the listenable copy alongside the ASR feed
channels                 = 1

# Transcript-driven retention. A session's audio (sessions/<id>/sources/) is
# deleted once its transcript has been complete for evict_after_transcript_seconds;
# a session whose transcript never completed keeps its audio until
# max_audio_age_seconds after it ended (so a failed run can be retried), then
# it is deleted regardless. session.toml/events.jsonl and transcripts are
# never deleted.
[earsd.retention]
evict_after_transcript_seconds = 7200    # 2h after a successful transcript
max_audio_age_seconds          = 604800  # 7d hard cap for never-transcribed sessions

[earsd.vad]
backend        = "silero"  # currently ignored: an energy-threshold VAD is always used
speech_pad_ms  = 300       # pad around detected speech spans
min_silence_ms = 700       # gap before declaring silence

[earsd.sessions]
# How long a browser session's last ingest stream may stay closed before the
# daemon ends the session on its own (events.jsonl reason "ingest-idle").
# Manual sessions are never auto-ended.
ingest_close_grace_s = 120
# Locally-captured sources folded into every browser session, so your own side
# is transcribed alongside the extension's per-participant streams. Each id is
# included only if the daemon is actually capturing it. Set to [] to disable.
local_sources = ["mic"]
# Pipeline stages auto-run when a browser session ends, in chain order:
# transcribe writes the transcript, cleanup corrects it with the [llm] backend,
# summarize renders every [[summarize.preset]]. cleanup/summarize require
# transcribe (they consume its output); an invalid entry is dropped with a
# logged warning. Set to ["transcribe"] to skip the LLM stages, [] to disable
# the chain entirely.
on_end_stages = ["transcribe", "cleanup", "summarize"]

# Audio ingestion from the browser extension (binary PCM). Off by default.
[earsd.ingest_ws]
enabled         = false
port            = 47811   # loopback only
allowed_origins = []      # e.g. ["chrome-extension://<id>", "moz-extension://<uuid>"];
                          # empty rejects every connection (fail closed)

# Control plane for the browser extension (session lifecycle, status). Off by default.
[earsd.control_ws]
enabled         = false
port            = 47812   # loopback only
allowed_origins = []      # same fail-closed allowlist as ingest_ws

# Sources enabled at startup. Each may override capture params.
[[earsd.source]]
id    = "mic"
class = "mic"
device_uid = ""           # empty => default input

[[earsd.source]]
id    = "system"
class = "system"
enabled = false           # opt-in: needs the system-audio-recording permission

[[earsd.source]]
id    = "app:us.zoom.xos"
class = "app"
label = "Zoom"

# --- LLM stages ---
[llm]
backend = "llm-cli"           # llm-cli | command — both run a subprocess:
model   = "claude-sonnet-5"   #   llm-cli runs `llm -m <model>`; command runs the line below
# command = "my-llm-wrapper --fast"   # prompt on stdin, completion on stdout

[cleanup]
prompt_file = ""              # empty => built-in cleanup prompt
use_vocab   = true

[[summarize.preset]]
name = "brief"
prompt_file = "prompts/brief.md"
[[summarize.preset]]
name = "actions"
prompt_file = "prompts/action-items.md"

# --- Vocabulary ---
[vocab]
global = ""   # relative to data_root; empty (the default) => no global list. e.g. "vocab/global.txt"
```

Transcription uses Parakeet via FluidAudio on the Apple Neural Engine, with VAD silence-skipping on. The `[transcribe]` table selects the backend/model/compute (all optional — the defaults above are assumed):

```toml
# --- Transcription ---
[transcribe]
backend = "fluidaudio"   # ASR backend
model = ""               # optional model id (e.g. "parakeet-tdt-v3"); empty = backend default
compute = "automatic"    # "ane" | "gpu" | "cpu" | "automatic"
```

**Diarization** (splitting a multi-speaker far-end source into `Speaker N`) is a separate, opt-in stage — off by default, since it downloads a model and costs ANE time:

```toml
# --- Diarization ---
[diarize]
backend = "none"         # "none" (default) | "sortformer"
model = ""               # optional model id override; empty = backend default
compute = "automatic"    # "ane" | "gpu" | "cpu" | "automatic"
```

With `backend = "sortformer"`, `transcribe` runs NVIDIA Sortformer (via FluidAudio) as an offline pass and refines multi-speaker turns into `<source> · Speaker N`. Source-of-origin stays the primary label; the diarizer only adds the within-source split. A diarizer that fails to load or run is non-fatal: the transcript falls back to source-only labels. The Sortformer model downloads automatically on first use.

- **Captured audio** (`--last`/`--from`/`--to`, `--session`): only multi-speaker far-end sources are diarized — `system`, `app:*`, `device:*` — never the `mic` or per-participant `browser:*` streams (each already a single speaker).
- **Standalone files** (`--file`): the whole file is treated as one multi-speaker source and always diarized when a backend is configured, since a file carries no source-of-origin separation. Example: `transcribe --file memo.m4a`.

## Conventions

- **Paths** support `~` expansion and resolve relative to `data_root` when not absolute (except `data_root`/`output_root` themselves).
- **Zero-config:** with no file present, the daemon captures `mic` with the defaults above and the LLM stages use the `llm` CLI.
- **Validation:** each tool validates its config at startup and exits non-zero with a precise message (key path + reason) on any unknown key or invalid value. No silent fallback.
- **Discovery:** every tool prints the resolved, merged config and reports which file was loaded. The single-purpose tools spell it `--print-config` / `--config-path`; `ears` spells it `ears config show` / `ears config path`. `ears config describe` lists every setting with its type, default, and description (see "Discovering settings").
- **Overrides:** every setting can be overridden per-invocation with `--set <dotted.key>=<value>` (typed) or `--set-string` (literal), the highest-precedence layer (see "Overriding any setting from the CLI").
