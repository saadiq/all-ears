# Spec: `cleanup` + `summarize` (LLM stages)

Two separate tools, each one job, built on a shared LLM backend interface.

## Shared LLM backend

- The backend interface is prompt-in → completion-out; prompt construction, chunking, and output writing belong to the tools.
- One implementation exists: a **subprocess backend** that runs a command with the prompt on stdin and reads the completion from stdout, with a timeout. Both config spellings resolve to it: `backend = "llm-cli"` runs `llm -m <model>` (the [`llm` CLI](https://llm.datasette.io) brings model selection, key management, and local-model support for free); `backend = "command"` runs an arbitrary `[llm].command` line, which is also how a local model runs as a sidecar.
- A native SDK backend (streaming, caching, retries) can be added behind the same interface later.
- Logging: request/response metadata only (model, latency, sizes) — never prompt/response bodies above `debug`. Failures are loud and non-zero.
- Long transcripts are chunked with overlap and stitched; parameters are configurable and logged. Prompts keep a stable prefix (system prompt + vocabulary + instructions) ahead of the dynamic transcript so caching backends can reuse it.

## `cleanup`

### One job
Turn a raw transcript into a clean, readable one, correcting mis-transcriptions and formatting with an LLM, guided by the known-word list.

### Behaviour
1. Read a `.transcript.md`.
2. Build the prompt: the built-in cleanup prompt (or `[cleanup].prompt_file`), plus the merged vocabulary (global + session) as an explicit correction list.
3. Correct homophones/mis-hearings against the vocabulary and fix punctuation/casing, **without** altering meaning, timestamps, or speaker turns.
4. Write `<...>.clean.md` atomically, frontmatter `kind: clean` with `derived_from` naming the source transcript.

### Guardrails
Cleanup must improve readability without hallucinating or over-editing:

- **Accept/fallback validation:** if a cleaned segment diverges from the source beyond bounds (length ratio, structural drift), reject it and keep the original rather than shipping a hallucination.
- **Minimal-change prompting:** the smallest edit that fixes errors; filler words are kept unless removal is configured.
- Timestamps and segment/turn structure are preserved; cleanup never invents or drops turns. Frontmatter records model + settings for reproducibility.

### CLI
```
cleanup <transcript.md> [--out <clean.md>] [--prompt <file>] [--vocab <path>] [--model <name>] [--no-vocab]
```

## `summarize`

### One job
Produce one or more summaries of one or more transcripts from configurable prompt presets.

### Behaviour
1. Read one or more transcripts (cleaned preferred if both exist).
2. For each selected preset (`[[summarize.preset]]`), run its prompt over the transcript(s).
3. Write `<...>.summary.md` (or `<...>.<preset>.summary.md` when multiple), frontmatter `kind: summary` with `preset` and `derived_from`.

Presets are named prompt files, so summary styles (brief, decisions, action items) are user configuration, not code.

### CLI
```
summarize <transcript.md> [more...] [--preset brief] [--preset actions] [--all-presets] [--out <path>] [--model <name>]
```

## Composition

The stages chain but never depend on each other at runtime — each reads and writes files:

```sh
transcribe --session "$SESSION_ID" \
  && cleanup "$OUT/…standup.transcript.md" \
  && summarize "$OUT/…standup.clean.md" --preset brief --preset actions
```

The daemon runs this chain itself when a browser session ends (`[earsd.sessions] on_end_stages`, default all three stages — see [capture-daemon](capture-daemon.md)). Any stage can still be run alone against an existing file.

### Output-path contract (stdout)

The daemon chains stages without re-deriving each stage's output-path logic: a path-producing stage prints its primary output path as the **final non-empty line of stdout** on success. `transcribe` (batch mode) prints the `.transcript.md` path; `cleanup` prints the `.clean.md` path; `summarize` writes one file per preset and prints no path (its result surface is deferred to the `--json` issue). Batch stdout carries nothing else, so the contract is also script-friendly: `` cleanup "$(transcribe --session "$SESSION_ID")" ``. A stage that exits 0 without printing a path is treated by the daemon as a failure.

**The promise, frozen (issue #62):** On exit 0 in default mode, stdout is exactly one line: the absolute path of the primary output. All other output goes to stderr. This will not change.

Failure ⇒ empty stdout: a run that exits non-zero writes **nothing** to stdout, in default and `--verbose` mode alike. `--verbose` (shorthand for `--log-level debug`) only widens what reaches stderr and the log file — it never changes stdout. Enforced structurally by `EarsCLISupport.ResultChannel`'s fd swap, stated verbatim in each stage binary's `--help`, and pinned end to end by `Tests/CLISmokeTests/PlainModeContractSmokeTests.swift`.

Rejected alternatives, recorded so they stay rejected:

- **No second stdout line, ever.** It would break every `$(…)` consumer and the daemon's strict one-line parse in the same release.
- **No TTY detection for the data format.** Stdout is the same one line piped or interactive; a format that changes shape depending on who is watching cannot be scripted against.
- **No `key=value` mode.** Anything richer than the one path line is the `--json` surface's job, on its own flag — never a mutation of plain mode.
