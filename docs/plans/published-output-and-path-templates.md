# Plan: intermediates in the data store, published output via path templates

Implementation prompt for a coding agent. Read `docs/engineering-practices.md`
first and follow it; match the existing test patterns (pure path logic tested
without disk, pipelines tested with injected fakes). Backwards compatibility is
explicitly **not** required — delete superseded layouts and heuristics rather
than preserving them.

## Goal

Split the pipeline's artifacts into two tiers:

- **Intermediates** — raw `.transcript.md` + JSON sidecar — live in the hidden
  per-session data store (`data_root`, default
  `~/Library/Application Support/ears`), addressed by session, with no
  user-facing layout.
- **Published output** — the cleaned transcript and summaries — lands in a
  smart-default or user-configured location, resolved through a shared path
  template with date/week/title tokens.

Motivating configuration (the acceptance scenario, real paths):

```toml
# data_root stays at its default: ~/Library/Application Support/ears

[cleanup]
output = "/Users/tom/obsidian/Everything/Transcripts/{year}/{month}/{day}/{date} - {title}.md"

[[summarize.preset]]
name = "meeting-notes"
prompt_file = "/Users/tom/obsidian/Everything/Business/AI/coscope/prompts/Clean up call & meeting notes from jotted notes & transcript.md"
notes = "/Users/tom/obsidian/Everything/daily-notes/{year}/{month}/{week}/{date}/{date} - {title}.md"
out = "{notes}"
frontmatter = false
```

End state for a Meet call named "Kevin Weekly" on 2026-08-05: the raw
transcript sits in the session's data-store directory; the cleaned transcript
is at `…/Transcripts/2026/08/05/2026-08-05 - Kevin Weekly.md`; the
`meeting-notes` preset reads the jotted daily note at
`…/daily-notes/2026/08/32/2026-08-05/2026-08-05 - Kevin Weekly.md` alongside
the cleaned transcript and writes the result back over that same note
(atomically, no ears frontmatter). `32` is the week number.

## 1. `PathTemplate` in `EarsCore`

A pure token-expansion type (no filesystem I/O; unit-tested like the current
`OutputPathResolution`).

Tokens: `{output_root}`, `{year}`, `{month}`, `{day}` (zero-padded), `{date}`
(`YYYY-MM-DD`), `{time}` (`HH-MM-SS`), `{week}` (zero-padded week-of-year),
`{session}` (session id), `{slug}` (path-safe source list, the current
filename slug), `{title}` (path-sanitized session title), and — in
`[[summarize.preset]] out` only — `{notes}` (the preset's expanded notes
path).

- Date/time tokens derive from the **session start**, not wall-clock at run
  time: a call ending after midnight files under the day it started.
- `{week}`: implement both US-locale weeks (Sunday-start, week 1 contains
  Jan 1 — moment.js/Obsidian `ww` default) and ISO-8601 weeks, selected by a
  new top-level config key `week_numbering = "us" | "iso"` (default `"us"`,
  matching Obsidian's default locale).
- `{title}` sanitization: strip path separators and filesystem-hostile
  characters, following the existing `SourceID.pathSafe` idiom.
- Missing context degrades, never fails: no title → fall back to `{slug}`,
  no slug → the input file's basename. An *unknown* token in a configured
  template is a config validation error, reported through the existing
  lenient validate-and-report machinery.
- Expansion happens in the tool that writes the file; parent directories are
  created as needed.

Template context travels **in the transcript frontmatter**, not via new CLI
flags: `transcribe` stamps the session title and session start into the
`.transcript.md` frontmatter; `cleanup` preserves frontmatter; each stage
reads its token context from its input document. Manual reruns then behave
identically to daemon-spawned runs.

## 2. `transcribe`: write intermediates into the data store

- Session runs (`--session <id>`) write `transcript.md` + `transcript.json`
  into the session's own data-store directory (`sessions/<uuid>/`), via
  `EarsDataStore`'s layout type.
- Range runs (`--last` / `--source`) have no session directory; write to
  `<data_root>/runs/<range-run-id>.transcript.md` (+ sidecar), where
  `<range-run-id>` is the existing `rangeRunIdentifier` shape.
- `--out` still overrides verbatim; `--file` mode is unchanged (output next to
  the input file).
- Delete `OutputPathResolution`'s `<output_root>/<date>/<time>_<slug>` layout
  and its tests; replace with the store-path logic above (keep it pure and
  unit-tested).
- Stamp `title` (session title) and the session/range start into the
  transcript frontmatter (extend `TranscriptFrontmatter`; update
  `docs/data-formats.md`).
- The `--json` result envelope still names the written path — the daemon
  chain (`OnClosePipelineRunner`) needs **no changes**.

## 3. `cleanup`: the publishing stage

- New config key `[cleanup] output` — a full path template for the cleaned
  transcript. Default (the smart default, in `LLMStagesConfigSchema`):
  `"{output_root}/{year}/{month}/{day}/{date} - {title}.md"`.
- `output_root` keeps its `~/Documents/Transcripts` default and becomes
  exclusively the *published*-artifact root.
- `--out` still overrides. The JSON sidecar stays an extension-swapped
  sibling of wherever the markdown lands. Writes remain atomic
  (`AtomicFileIO`).
- Add `cleanup --session <id>`: resolve the session's intermediate transcript
  from the data store and run on it — the one-command rerun path now that
  intermediates are hidden.

## 4. `summarize`: notes ingestion, per-preset destinations, frontmatter opt-out

Extend the `[[summarize.preset]]` element schema:

- `notes` (string, optional): path template for a companion notes file. Read
  as **plain markdown** — no `TranscriptParser`, no sidecar. Assemble the LLM
  input with labelled sections (`## Jotted notes`, `## Transcript`) so
  prompts can address each. If the expanded path doesn't exist, that preset
  is reported failed with a clear `inputMissing`-class message (existing
  per-preset result reporting; other presets still run; the daemon chain
  already tolerates summarize failure).
- `out` (string, optional): path template for this preset's output,
  overriding the default sibling naming. May reference `{notes}` to write
  back over the notes file — safe because all inputs are read before any
  write, and writes are atomic. Overwrite is the intended semantics; the
  prompt is responsible for carrying the jotted notes forward into its
  output.
- `frontmatter` (bool, default `true`): when `false`, emit the summary body
  with no YAML frontmatter block (for output into an Obsidian vault, where
  the ears `kind:`/`preset:` stamp would collide with vault frontmatter).
- Also expose `--notes <path>` on the CLI for ad-hoc runs (single-preset runs
  only, like `--out`).
- Add `summarize --session <id>`: resolve the session's *cleaned* transcript
  path (falling back to the raw transcript if no clean exists) from the
  session store / envelope-recorded paths.
- **Delete** `preferCleanedSibling` — the clean file no longer lives next to
  the raw transcript, and the daemon chain passes explicit paths.

Update `shared/stage-envelopes/summarize.v1.schema.json` only if the
per-preset result shape needs a skipped/missing distinction; otherwise leave
the envelope contract alone.

## 5. Browser extension: Meet meeting title

- Scrape the meeting name from the Meet UI (calendar-created meetings expose
  it — e.g. the document title / in-call details header). Treat a
  meeting-code-shaped string (`xxx-yyyy-zzz`) as "no name found".
- When known at declare time, pass it as `title` on `session.start` (the
  daemon already accepts it — `ControlCall.swift`).
- Calendar names often resolve after join: watch for late arrival and call
  `session.rename` with `if_rev` compare-and-set so a manual rename is never
  clobbered. Send at most one rename per discovered name.
- No name found → send no title; the daemon's existing default (identity →
  Meet ID) is the fallback. Zoom/Teams: out of scope, same fallback.
- Test the scrape/rename logic in the extension's existing vitest suites
  (`session-tracker`, `identity/meet`).

## 6. Retention: explicitly unchanged, plus one clarification

- Audio eviction still keys on transcribe success (`transcriptCompleted`).
- Raw transcripts in the data store are **not** swept: once audio is evicted
  they are the only route to re-running cleanup/summarize with a different
  prompt or model. Update `docs/specs/capture-daemon.md`'s retention section
  to say so.

## 7. Docs

Update to match: `docs/configuration.md` (new keys, new reference config,
`week_numbering`), `docs/data-formats.md` (intermediate store layout, new
frontmatter fields, published layout now template-driven),
`docs/overview.md` and `README.md` (the two-tier artifact story),
`docs/specs/llm-stages.md`, `docs/specs/transcribe.md`, and the browser spec
for the title scrape.

## Non-goals

- No changes to `OnClosePipelineRunner`, the `--json` envelope contract
  (beyond §4's possible preset-result note), the control protocol, or capture.
- No append/section-merge mode for notes output — overwrite only, for now.
- No migration of existing `~/Documents/Transcripts` content.

## Acceptance

1. With an empty config, an ended session produces: raw transcript in
   `sessions/<uuid>/`, cleaned transcript at
   `~/Documents/Transcripts/<year>/<month>/<day>/<date> - <title>.md`, and
   summaries beside it (only if presets are configured).
2. With the motivating configuration above, the end state described under
   "Goal" holds, and re-running
   `summarize --session <id>` reproduces the daily-note write.
3. A session with no scraped title publishes under the Meet-ID-derived title;
   a `--file` cleanup with no session context falls back to the input
   basename in place of `{title}`.
4. `week_numbering = "iso"` changes `{week}` accordingly (test a date where
   US and ISO diverge, e.g. early January).
5. All existing suites pass; deleted logic (`OutputPathResolution` layout,
   `preferCleanedSibling`) has no remaining references.
