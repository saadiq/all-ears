# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""Replay tier: re-score an ARCHIVED run through the daemon's real reconciler.

    uv run replay.py runs/<timestamp>-<scenario>          # replay + score, offline
    uv run replay.py fixtures/replay-demo                 # the committed fixture
    uv run replay.py runs/<...> --asr                     # real ASR, so text re-scores too

This is the standing regression harness for the daemon's binding logic: take a
run recorded months ago, re-run speaker reconciliation over its archived store
with TODAY's reconciler, and score the result against the run's ground truth.
No live call, no daemon, no browser.

The reconciler is not reimplemented here. The archived session store is copied
into a scratch data root (the archive stays byte-identical), and the real
`transcribe` binary runs `--session <id> --rereconcile --json` against the
copy — the same Swift code path the daemon itself uses, consuming the same
evidence: the roster in `session.toml` plus the binding hints in
`attribution.jsonl` (the R1 flight recorder). The re-derived speaker map comes
back in the replayed transcript's JSON sidecar (`"speakers"`), and the
existing scorers in `score.py` judge it against the run's manifest.

What a replay needs from the archive, and what happens when it is missing:

- `session.toml` at schema 3 — a pre-R3 store (schema 1/2, or the old
  participant-labelled source ids without an attribution log) cannot be
  replayed and fails with a clear message rather than a wrong score.
- `attribution.jsonl` — the recorded evidence. A session from before the
  flight recorder existed fails by default; `--roster-only` replays it from
  the roster alone (still the real reconciler, just hint-less).
- `sources/` audio — optional. Evicted audio (the retention default, 2 h
  after transcript completion) leaves the timing score `unscored`, exactly as
  the README warns; roster/attribution still score fully.

By default the ASR model is swapped for the daemon's own null test backend
(`ALLEARS_TRANSCRIBE_BACKEND=null`), so a replay is fast and hermetic — the
text score reports `unscored`. Pass `--asr` to run the real model over
archived audio and re-score text as well.

The archived run directory is never written to. The replay's own record —
`replay.json`, the same three scores plus a `replay` block saying exactly what
was replayed with which binary — lands in a new `runs/<stamp>-replay-<name>/`
directory (or `--out`).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
from datetime import datetime, timezone
from pathlib import Path

import click

import gtlib as gt
import score
import sessions as store

DAEMON = gt.HERE.parent.parent / "daemon"
SESSION_COPY_DIRNAME = "session"


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def find_transcribe(explicit: str | None) -> Path:
    """The daemon's own binary — a debug build from this checkout by default,
    so the replay exercises exactly the reconciler on this branch."""
    candidates = (
        [Path(explicit)]
        if explicit
        else [
            DAEMON / ".build" / "debug" / "transcribe",
            DAEMON / ".build" / "release" / "transcribe",
            Path.home() / ".local" / "bin" / "transcribe",
        ]
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    found = shutil.which("transcribe")
    if found:
        return Path(found)
    raise click.ClickException(
        "no transcribe binary found — build one with `swift build` in daemon/ "
        "(or pass --transcribe). The replay runs the REAL Swift reconciler; "
        "there is deliberately no Python fallback."
    )


def resolve_archived_session(run_dir: Path, manifest: dict, override: str | None) -> Path:
    """Where the archived session store lives, in preference order: a copy
    archived inside the run directory itself (`runs/<...>/session/` — the
    convention that makes a run re-scorable on any machine), an explicit
    `--session-dir`, the path the runner recorded, then the live store."""
    if override:
        return Path(override)
    bundled = run_dir / SESSION_COPY_DIRNAME
    if (bundled / "session.toml").exists():
        return bundled
    run = manifest.get("run") or {}
    session_id = run.get("session_id")
    if not session_id:
        raise click.ClickException(
            "this run has no session id and no archived session/ copy — there is "
            "nothing to replay. Pass --session-dir to supply the store by hand."
        )
    recorded = run.get("session_dir")
    if recorded and (Path(recorded) / "session.toml").exists():
        return Path(recorded)
    return store.DEFAULT_ROOT / "sessions" / session_id


def preflight(session_dir: Path, roster_only: bool) -> dict:
    """Refuse the stores the replay tier cannot honestly re-score, with the
    reason spelled out — a wrong score is worse than no score."""
    descriptor = session_dir / "session.toml"
    if not descriptor.exists():
        raise click.ClickException(f"{descriptor} not found — this is not a session store")
    record = tomllib.loads(descriptor.read_text())
    schema = record.get("schema")
    if schema != 3:
        raise click.ClickException(
            f"pre-R3 store: {descriptor} is session.toml schema {schema}, and the "
            "replay tier needs a schema-3 store (roster + [[speaker]] map + opaque "
            "track-handle source ids). Runs archived before R3 cannot be replayed "
            "through the current reconciler."
        )
    attribution = session_dir / "attribution.jsonl"
    if not attribution.exists() and not roster_only:
        raise click.ClickException(
            f"no attribution log recorded: {attribution} does not exist. This "
            "session predates the R1 flight recorder (or was not captured by the "
            "browser extension), so there is no recorded binding evidence to "
            "replay. Pass --roster-only to re-reconcile from the roster alone."
        )
    return {
        "session_id": record.get("id", session_dir.name),
        "attribution_log_lines": (
            sum(1 for line in attribution.read_text().splitlines() if line.strip())
            if attribution.exists()
            else 0
        ),
        "stored_reconciler_version": record.get("reconciler_version", 0),
        "stored_speaker_map": record.get("speaker", []),
    }


def run_transcribe(
    binary: Path, data_root: Path, session_id: str, use_asr: bool
) -> tuple[dict, list[str]]:
    """`transcribe --session <id> --rereconcile --json` against the scratch
    copy, fully isolated from the user's real config and store."""
    config = data_root.parent / "config.toml"
    # An isolated config: only this data root, and a short socket path —
    # sun_path caps at 104 bytes and a scratch-dir default blows past it. The
    # socket is never connected by a batch run; it only has to resolve.
    socket = Path(tempfile.gettempdir()) / f"ears-replay-{os.getpid()}.sock"
    config.write_text(f'data_root = "{data_root}"\nsocket_path = "{socket}"\n')

    argv = [
        str(binary),
        "--config", str(config),
        "--session", session_id,
        "--rereconcile",
        "--json",
    ]
    env = dict(os.environ)
    if not use_asr:
        # The daemon's own test seam: a real, successful transcribe run with
        # the ASR model swapped for a no-op. The reconciler, the store reads,
        # and the output contract are all production code.
        env["ALLEARS_TRANSCRIBE_BACKEND"] = "null"
    proc = subprocess.run(argv, capture_output=True, text=True, env=env, check=False)
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.strip().splitlines()[-3:])
        raise click.ClickException(
            f"transcribe exited {proc.returncode} — the replay produced no result.\n{tail}"
        )
    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise click.ClickException(
            f"transcribe --json emitted no parseable envelope:\n{proc.stdout[:400]}"
        )
    return envelope, argv


def replayed_speaker_map(envelope: dict) -> list[dict]:
    """The re-derived map, read back off disk from the replayed transcript's
    JSON sidecar — the run's one durable record of the conclusion it was
    labelled with (`session.toml` never sees a re-derivation)."""
    sidecar = Path(envelope["output"]).with_suffix("").with_suffix(".json")
    if not sidecar.exists():
        raise click.ClickException(f"replayed sidecar {sidecar} was not written")
    return json.loads(sidecar.read_text()).get("speakers", [])


def timing_scorable(manifest: dict, session: store.Session) -> str | None:
    """Why the timing score cannot run, or None if it can. Split out so an
    evicted-audio archive reports `unscored` instead of a false FAIL — the
    replay tier's subject is the binding logic, which needs no audio."""
    if not any(
        chunk.file.exists()
        for source in session.sources.values()
        for chunk in source.chunks
    ):
        return (
            "the archived store holds no audio (evicted by retention, or never "
            "archived) — see the README on archiving sources/ beside a run"
        )
    if not any((gt.HERE / p["wav"]).exists() for p in manifest["participants"]):
        return "no reference WAVs on this machine (run `uv run assemble.py build`)"
    return None


@click.command()
@click.argument("run_dir", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option("--session-dir", default=None,
              help="The archived session store, when it is not runs/<...>/session/ "
                   "or in the live store.")
@click.option("--transcribe", "transcribe_path", default=None,
              help="The transcribe binary to replay through (default: this checkout's "
                   "debug build).")
@click.option("--asr", is_flag=True,
              help="Run the real ASR model instead of the null backend, so the text "
                   "score re-runs too (needs the archived audio, downloads the model).")
@click.option("--roster-only", is_flag=True,
              help="Replay a session that has no attribution.jsonl from its roster alone.")
@click.option("--out", "out_dir", default=None, type=click.Path(path_type=Path),
              help="Where to write the replay record (default: runs/<stamp>-replay-<name>).")
@click.option("--keep-work", is_flag=True,
              help="Keep the scratch copy of the session store for inspection.")
@click.option("--json", "as_json", is_flag=True)
def main(run_dir: Path, session_dir: str | None, transcribe_path: str | None,
         asr: bool, roster_only: bool, out_dir: Path | None, keep_work: bool,
         as_json: bool) -> None:
    manifest = score.load_run(run_dir)
    archived = resolve_archived_session(run_dir, manifest, session_dir)
    if not archived.exists():
        raise click.ClickException(
            f"{archived} not found — the archived session store is gone. Archive "
            f"the session tree as runs/<...>/{SESSION_COPY_DIRNAME}/ to keep a run "
            "replayable after the live store is cleaned up."
        )
    flight = preflight(archived, roster_only)
    session_id = flight["session_id"]
    binary = find_transcribe(transcribe_path)

    # Work on a copy: the archive stays byte-identical, and the replayed
    # transcript (which overwrites sessions/<id>/transcript.{md,json}) lands
    # in scratch, never in the archive.
    work = Path(tempfile.mkdtemp(prefix="gt-replay-"))
    data_root = work / "data"
    session_copy = data_root / "sessions" / session_id
    session_copy.parent.mkdir(parents=True)
    shutil.copytree(archived, session_copy)

    try:
        envelope, argv = run_transcribe(binary, data_root, session_id, use_asr=asr)
        speakers = replayed_speaker_map(envelope)

        # The same scorers as a live run, over the copied store — with the
        # session's speaker map REPLACED by the re-derivation just computed.
        # That substitution is the entire point: the roster score judges
        # attribution on the map, so it now judges the current reconciler.
        session = store.load_session(session_copy)
        session.speakers = [
            store.Speaker(source=s["source"], name=s["name"], confidence=s["confidence"])
            for s in speakers
        ]
        roster = score.score_roster(manifest, session)
        unscorable = timing_scorable(manifest, session)
        if unscorable is None:
            timing = score.score_timing(manifest, session)
        else:
            timing = {"available": False, "note": unscorable, "pass": None}
        text = score.score_text(manifest, session)
        if text["pass"] is None and not asr:
            text["note"] = (
                "replayed with the null ASR backend, so there is no transcript "
                "text — the text path is unscored, not failed. Re-run with --asr "
                "to score it."
            )
        conflicts = (
            score.disagreements(timing, text) if unscorable is None else []
        )
    finally:
        if keep_work:
            click.echo(f"scratch store kept at {work}", err=True)
        else:
            shutil.rmtree(work, ignore_errors=True)

    report = {
        "schema": gt.SCHEMA_VERSION,
        "kind": "replay",
        "run": str(run_dir),
        "scenario": manifest["scenario"],
        "corpus_fingerprint": manifest["corpus_fingerprint"],
        "session_id": session_id,
        "replay": {
            "archived_session": str(archived),
            "transcribe": str(binary),
            "argv": argv,
            "asr": asr,
            "roster_only": roster_only,
            "attribution_log_lines": flight["attribution_log_lines"],
            "stored_reconciler_version": flight["stored_reconciler_version"],
            "stored_speaker_map": flight["stored_speaker_map"],
            "replayed_speaker_map": speakers,
            "replayed_at": datetime.now(timezone.utc).isoformat(),
        },
        "roster": roster,
        "timing": timing,
        "text": text,
        "disagreements": conflicts,
    }
    report["pass"] = (
        bool(roster["pass"])
        and timing["pass"] is not False
        and text["pass"] is not False
    )

    out = out_dir or gt.RUNS / f"{stamp()}-replay-{run_dir.name}"
    out.mkdir(parents=True, exist_ok=True)
    (out / "replay.json").write_text(json.dumps(report, indent=2) + "\n")
    if as_json:
        click.echo(json.dumps(report, indent=2))
    else:
        _print(report)
    click.echo(f"\nreplay record → {out}")
    sys.exit(0 if report["pass"] else 1)


def _print(report: dict) -> None:
    replay = report["replay"]
    click.echo(f"replay of {report['run']}  (scenario {report['scenario']})")
    click.echo(f"session  {report['session_id']}")
    click.echo(f"binary   {replay['transcribe']}")
    click.echo(
        f"evidence {replay['attribution_log_lines']} attribution-log lines"
        + ("  [roster-only]" if replay["roster_only"] else "")
    )

    stored = {s["source"]: s["name"] for s in replay["stored_speaker_map"]}
    click.echo("\nreplayed speaker map (the current reconciler's verdict):")
    if not replay["replayed_speaker_map"]:
        click.echo("   (empty — nothing was bound)")
    for entry in replay["replayed_speaker_map"]:
        was = stored.get(entry["source"])
        suffix = "" if was in (None, entry["name"]) else f"   (stored map said {was})"
        click.echo(
            f"   {entry['source']:<32} -> {entry['name']} ({entry['confidence']}){suffix}"
        )
    for source, was in stored.items():
        if not any(e["source"] == source for e in replay["replayed_speaker_map"]):
            click.echo(f"   {source:<32} -> (unbound)   (stored map said {was})")

    roster = report["roster"]
    click.echo(f"\n1. ROSTER  {'pass' if roster['pass'] else 'FAIL'}")
    for m in roster["matched"]:
        sources = ", ".join(m["sources"]) if m["sources"] else "—"
        click.echo(f"   {m['display_name']:<12} {m['attendee_id']:<34} sources={sources}")
    if roster["missing"]:
        click.echo(f"   missing from the roster: {roster['missing']}")
    if roster["unexpected"]:
        click.echo(f"   unexpected attendees:    {roster['unexpected']}")
    if roster.get("phantom_attendees"):
        click.echo(f"   PHANTOM ATTENDEES: {roster['phantom_attendees']}")

    for name, block in (("2. TIMING/ENERGY", report["timing"]), ("3. TEXT", report["text"])):
        state = (
            "unscored" if block["pass"] is None
            else "pass" if block["pass"] else "FAIL"
        )
        click.echo(f"\n{name}  {state}")
        if block.get("note"):
            click.echo(f"   {block['note']}")
        for source_id, best in (block.get("assignment") or {}).items():
            click.echo(f"   {source_id:<32} -> {best.get('label') or 'NO MATCH'}")

    if report["disagreements"]:
        click.echo("\nDISAGREEMENT between timing and text — reported, not averaged:")
        for d in report["disagreements"]:
            click.echo(f"   {d['source']}: timing says {d['timing_says']}, "
                       f"text says {d['text_says']}")

    click.echo(f"\n{'PASS' if report['pass'] else 'FAIL'}")


if __name__ == "__main__":
    main()
