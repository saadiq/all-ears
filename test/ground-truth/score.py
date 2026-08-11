# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""Score a recorded run against its ground-truth manifest.

    uv run score.py runs/<timestamp>-<scenario>            # score, print, exit non-zero on regression
    uv run score.py runs/<...> --session <uuid>            # re-score an archived run
    uv run score.py runs/<...> --baseline runs/<older>     # compare against a previous report

Three independent scores, reported separately because they fail differently:

1. **Roster** — the display names typed at join versus `session.toml`'s attendees
   and the `browser:<platform>:<participant>` source ids, and join/leave instants
   versus `events.jsonl`.
2. **Timing/energy** — each captured source's energy envelope cross-correlated
   against each reference WAV, zero-lag. Needs no ASR, and is the path that
   caught the mic duplication.
3. **Text** — bag-of-words Jaccard between each source's transcript segments and
   each participant's known passages. The corpus's speakers own disjoint
   semantic domains, so after stopword removal this discriminates cleanly.

What the report says beyond pass/fail:

- the **confusion matrix**: which reference each captured source actually
  matched, not just whether it was right;
- **disagreement** between paths 2 and 3, flagged and never averaged away. If
  timing says a source is Bravo and text says Alpha, that is itself the finding;
- **duplication**: two captured sources matching one reference is the
  mic-duplication signature and must not score as a pass.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import click
import numpy as np

import gtlib as gt
import sessions as store

HOP = 0.1
# Correlation below this means "this reference does not explain this stream".
MATCH_FLOOR = 0.30
# ...but a floor alone does not discriminate, because every participant's file
# shares the same slot grid, so their envelopes are structurally similar whatever
# the speech is. Measured on the s1-solo daemon-only run: `mic` fed host.wav
# scored 0.946 against host and 0.27/0.42/0.47 against alpha/bravo/charlie — the
# wrong answers clear a 0.30 floor comfortably. What separates them is the
# *margin* over the runner-up, so a match must also win by this much or it is
# reported as ambiguous rather than silently assigned.
MATCH_MARGIN = 0.15
JACCARD_FLOOR = 0.15

STOPWORDS = {
    "a", "about", "after", "again", "all", "already", "an", "and", "any", "anything",
    "are", "around", "as", "at", "back", "be", "because", "been", "before", "best",
    "better", "brief", "but", "by", "can", "could", "cost", "did", "do", "does",
    "down", "during", "each", "early", "else", "end", "ends", "enough", "even",
    "every", "far", "faster", "few", "fine", "finally", "for", "from", "gave",
    "give", "go", "goes", "going", "good", "got", "had", "has", "have", "held",
    "her", "here", "high", "him", "his", "hold", "how", "i", "if", "in", "instead",
    "into", "is", "it", "its", "just", "keep", "kept", "last", "late", "later",
    "left", "less", "like", "long", "lost", "made", "make", "many", "matters",
    "may", "me", "means", "might", "more", "most", "much", "must", "my", "near",
    "nearer", "need", "needs", "never", "next", "night", "no", "not", "nothing",
    "now", "of", "off", "old", "on", "once", "only", "onto", "or", "other", "our",
    "out", "outside", "over", "own", "poor", "put", "right", "same", "seems",
    "session", "shorter", "should", "since", "so", "some", "start", "still",
    "switched", "than", "that", "the", "their", "them", "then", "there", "these",
    "they", "this", "those", "though", "through", "time", "to", "too", "turned",
    "twice", "under", "until", "up", "us", "use", "used", "very", "was", "we",
    "well", "were", "what", "when", "where", "which", "while", "who", "why",
    "will", "with", "would", "year", "you", "your",
}


def bag(text: str) -> set[str]:
    words = re.findall(r"[a-z]+", text.lower())
    return {w for w in words if w not in STOPWORDS and len(w) > 2}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


# ---------------------------------------------------------------------------


def load_run(run_dir: Path) -> dict:
    path = run_dir / "run.json"
    if not path.exists():
        raise click.ClickException(f"{path} not found — this is not a scenario run directory")
    return json.loads(path.read_text())


def resolve_session(manifest: dict, override: str | None) -> store.Session:
    session_id = override or (manifest.get("run") or {}).get("session_id")
    if not session_id:
        raise click.ClickException(
            "this run has no session id. The manifest and the session id must travel "
            "together for a run to be re-scorable; pass --session to supply it by hand."
        )
    directory = (
        Path(session_id) if "/" in session_id
        else store.DEFAULT_ROOT / "sessions" / session_id
    )
    if not directory.exists():
        raise click.ClickException(f"{directory} not found")
    return store.load_session(directory)


# ---------------------------------------------------------------------------
# 1. roster
# ---------------------------------------------------------------------------


def score_roster(manifest: dict, session: store.Session) -> dict:
    declared = {p["display_name"]: p for p in manifest["participants"]}
    guests = {n: p for n, p in declared.items() if p["role"] != "local"}
    # The signed-in convener has to stay in the call for anonymous guests to be
    # admitted at all (see run.py's note_observers), so it is a real attendee.
    # Expected, but never scored — and anything that is neither declared nor a
    # recorded observer still fails, so a stray joiner stays visible.
    observers = set((manifest.get("run") or {}).get("observers") or [])

    seen = {a.display_name: a for a in session.attendees}
    matched, missing, unexpected = [], [], []

    recorded = ((manifest.get("run") or {}).get("participants") or {})
    for name, spec in guests.items():
        # A signed-in participant's roster label is its Google account name,
        # recorded by the runner at join. Fall back to the declared name for an
        # anonymous participant, which types its own label.
        expected = recorded.get(spec["label"], {}).get("observed_display_name") or name
        attendee = seen.get(expected)
        if attendee is None:
            missing.append(name)
            continue
        matched.append(
            {
                "display_name": name,
                "matched_on": expected,
                "label": spec["label"],
                "attendee_id": attendee.id,
                # Whether the roster entry carries a per-participant source is
                # the whole point of the identity path.
                "source": attendee.source or None,
                "joined": attendee.joined.isoformat() if attendee.joined else None,
                "left": attendee.left.isoformat() if attendee.left else None,
                "anonymous_device_id": bool(re.match(r"spaces/[^/]+/devices/\d+", attendee.id)),
            }
        )
    # The local participant's own roster entry is expected. Match it by the
    # display name the runner observed at join — matching on "looks like a
    # device id" would sweep in every REMOTE participant too, which is the
    # opposite of the intent.
    local_name = (
        ((manifest.get("run") or {}).get("participants") or {})
        .get(next((p["label"] for p in manifest["participants"] if p["role"] == "local"), ""), {})
        .get("observed_display_name")
    )
    local_ids = {a.id for a in session.attendees if local_name and a.display_name == local_name}
    # Provisional ids the extension assigns when identity resolution returns
    # null (`speaker-<n>`, the universal fallback). One per unresolved track is
    # normal mid-call; a set of them in a call with no remote participants is a
    # phantom roster, and is reported as its own failure rather than lumped in
    # with "unexpected", because the two have completely different causes.
    # A provisional id WITH a source behind it is not a phantom: it is a real
    # captured participant whose identity had not resolved yet. Meet exposes no
    # synchronous identity mechanism, so a track legitimately starts under
    # `speaker-<n>` and is upgraded once speaking-onset correlation names it —
    # which starts a fresh source rather than renaming in place. Only a
    # provisional id with NO source is a phantom.
    provisional = re.compile(r"^(speaker|graphtap|graphgen|webaudio-track)-\d+$")
    phantom = [
        {"id": a.id, "source": a.source or None,
         "joined": a.joined.isoformat() if a.joined else None}
        for a in session.attendees
        if provisional.match(a.id) and not a.source
    ]
    upgraded = [
        {"id": a.id, "source": a.source}
        for a in session.attendees
        if provisional.match(a.id) and a.source
    ]
    matched_names = {m["matched_on"] for m in matched}
    for attendee in session.attendees:
        name = attendee.display_name
        if name in matched_names:
            continue
        if attendee.id in local_ids or any(p["id"] == attendee.id for p in phantom):
            continue
        if name not in declared and name not in observers:
            unexpected.append(name)

    events = [e for e in session.events if e.get("t") in ("attendee_joined", "attendee_left")]
    return {
        "declared_guests": list(guests),
        "matched": matched,
        "missing": missing,
        "unexpected": unexpected,
        "observers": sorted(observers),
        "local_device_ids": sorted(local_ids),
        "phantom_attendees": phantom,
        "provisional_with_source": upgraded,
        "named_sources": sum(1 for m in matched if m["source"]),
        "attendee_events": len(events),
        "pass": not missing and not unexpected and not phantom,
    }


# ---------------------------------------------------------------------------
# 2. timing / energy
# ---------------------------------------------------------------------------


def score_timing(manifest: dict, session: store.Session) -> dict:
    references = {}
    for p in manifest["participants"]:
        wav = gt.HERE / p["wav"]
        if wav.exists():
            samples, _ = gt.read_wav(wav)
            references[p["label"]] = gt.rms_envelope(samples, HOP)

    captured = {}
    for source_id, source in session.sources.items():
        samples, origin = source.decode()
        if samples.size:
            captured[source_id] = (gt.rms_envelope(samples, HOP), origin, samples)

    matrix: dict[str, dict[str, dict]] = {}
    for source_id, (envelope, _origin, _samples) in captured.items():
        row = {}
        for label, reference in references.items():
            lag, correlation = gt.align_lag(envelope, reference, HOP)
            row[label] = {"correlation": round(correlation, 4), "lag_seconds": round(lag, 2)}
        matrix[source_id] = row

    assignment = {}
    for source_id, row in matrix.items():
        ranked = sorted(row.items(), key=lambda kv: kv[1]["correlation"], reverse=True)
        best = ranked[0]
        runner_up = ranked[1][1]["correlation"] if len(ranked) > 1 else 0.0
        margin = best[1]["correlation"] - runner_up
        confident = best[1]["correlation"] >= MATCH_FLOOR and margin >= MATCH_MARGIN
        assignment[source_id] = {
            "label": best[0] if confident else None,
            "correlation": best[1]["correlation"],
            "lag_seconds": best[1]["lag_seconds"],
            "runner_up": ranked[1][0] if len(ranked) > 1 else None,
            "margin": round(margin, 4),
            "reason": None if confident else (
                "below the correlation floor" if best[1]["correlation"] < MATCH_FLOOR
                else f"ambiguous: only {margin:.3f} ahead of {ranked[1][0]}"
            ),
        }

    # Two captured sources explained by one reference is the mic-duplication
    # signature (journal #117: one call transcribed the user four times).
    by_label: dict[str, list[str]] = {}
    for source_id, best in assignment.items():
        if best["label"]:
            by_label.setdefault(best["label"], []).append(source_id)
    duplication = {label: ids for label, ids in by_label.items() if len(ids) > 1}

    expected = {p["label"] for p in manifest["participants"]}
    unmatched_refs = sorted(expected - set(by_label))
    return {
        "confusion_matrix": matrix,
        "assignment": assignment,
        "duplication": duplication,
        "references_with_no_source": unmatched_refs,
        "sources_below_floor": [s for s, b in assignment.items() if b["label"] is None],
        "match_floor": MATCH_FLOOR,
        "match_margin": MATCH_MARGIN,
        "ambiguous": {s: b["reason"] for s, b in assignment.items()
                      if b["label"] is None and b["reason"]},
        "pass": not duplication and not unmatched_refs,
    }


# ---------------------------------------------------------------------------
# 3. text
# ---------------------------------------------------------------------------


def load_transcript(session: store.Session) -> dict[str, str]:
    """Text per source, from the session's canonical JSON sidecar if there is one,
    else from the Markdown transcript's speaker headings."""
    sidecar = session.directory / "transcript.json"
    per_source: dict[str, list[str]] = {}
    if sidecar.exists():
        try:
            data = json.loads(sidecar.read_text())
            for segment in data.get("segments", []):
                per_source.setdefault(segment.get("source", "?"), []).append(segment.get("text", ""))
            return {k: " ".join(v) for k, v in per_source.items()}
        except json.JSONDecodeError:
            pass

    markdown = session.directory / "transcript.md"
    if markdown.exists():
        current = None
        for line in markdown.read_text().splitlines():
            heading = re.match(r"^##\s+\[[\d:]+\]\s+(.+?)\s*$", line)
            if heading:
                current = heading.group(1)
                # `mic` renders as `You` (docs/data-formats.md)
                if current == "You":
                    current = "mic"
                per_source.setdefault(current, [])
            elif current and line.strip():
                per_source[current].append(line.strip())
    return {k: " ".join(v) for k, v in per_source.items()}


def score_text(manifest: dict, session: store.Session) -> dict:
    transcripts = load_transcript(session)
    if not transcripts:
        return {
            "available": False,
            "note": "no transcript in the session directory — the text path is unscored, "
                    "not failed. Run `transcribe --session <id>` and re-score.",
            "pass": None,
        }

    references = {
        p["label"]: bag(" ".join(t["text"] for t in p["turns"]))
        for p in manifest["participants"]
    }
    matrix: dict[str, dict[str, float]] = {}
    assignment = {}
    for source_id, text in transcripts.items():
        observed = bag(text)
        row = {label: round(jaccard(observed, ref), 4) for label, ref in references.items()}
        matrix[source_id] = row
        best = max(row.items(), key=lambda kv: kv[1])
        assignment[source_id] = {
            "label": best[0] if best[1] >= JACCARD_FLOOR else None,
            "jaccard": best[1],
            "words": len(observed),
        }
    return {
        "available": True,
        "confusion_matrix": matrix,
        "assignment": assignment,
        "jaccard_floor": JACCARD_FLOOR,
        "pass": all(a["label"] for a in assignment.values()),
    }


# ---------------------------------------------------------------------------


def disagreements(timing: dict, text: dict) -> list[dict]:
    """Where the two independent paths name different participants for one
    source. Surfaced, never averaged: a disagreement is a finding about the
    pipeline, and averaging it away destroys exactly the information that makes
    two paths worth having."""
    if not text.get("available"):
        return []
    out = []
    for source_id, timed in timing["assignment"].items():
        texted = text["assignment"].get(source_id)
        if not texted:
            continue
        if timed["label"] != texted["label"]:
            out.append(
                {
                    "source": source_id,
                    "timing_says": timed["label"],
                    "timing_correlation": timed["correlation"],
                    "text_says": texted["label"],
                    "text_jaccard": texted["jaccard"],
                }
            )
    return out


@click.command()
@click.argument("run_dir", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option("--session", "session_override", default=None, help="Score against this session id.")
@click.option("--json", "as_json", is_flag=True)
def main(run_dir: Path, session_override: str | None, as_json: bool) -> None:
    manifest = load_run(run_dir)
    session = resolve_session(manifest, session_override)

    roster = score_roster(manifest, session)
    timing = score_timing(manifest, session)
    text = score_text(manifest, session)
    conflicts = disagreements(timing, text)

    report = {
        "schema": gt.SCHEMA_VERSION,
        "run": str(run_dir),
        "scenario": manifest["scenario"],
        "corpus_fingerprint": manifest["corpus_fingerprint"],
        "session_id": session.id,
        "session_sources": list(session.sources),
        "roster": roster,
        "timing": timing,
        "text": text,
        "disagreements": conflicts,
    }
    # A disagreement is not itself a failure — it is a finding. The run fails on
    # a score failing, and reports the disagreement either way.
    report["pass"] = bool(roster["pass"]) and bool(timing["pass"]) and text["pass"] is not False

    (run_dir / "score.json").write_text(json.dumps(report, indent=2) + "\n")
    if as_json:
        click.echo(json.dumps(report, indent=2))
    else:
        _print(report)
    sys.exit(0 if report["pass"] else 1)


def _print(report: dict) -> None:
    click.echo(f"scenario {report['scenario']}  session {report['session_id']}")
    click.echo(f"corpus   {report['corpus_fingerprint'][:16]}")

    roster = report["roster"]
    click.echo(f"\n1. ROSTER  {'pass' if roster['pass'] else 'FAIL'}")
    for m in roster["matched"]:
        click.echo(f"   {m['display_name']:<12} {m['attendee_id']:<34} source={m['source'] or '—'}")
    if roster["missing"]:
        click.echo(f"   missing from the roster: {roster['missing']}")
    if roster["unexpected"]:
        click.echo(f"   unexpected attendees:    {roster['unexpected']}")
    if roster.get("local_device_ids"):
        click.echo(f"   local device ids:        {roster['local_device_ids']}")
    if roster.get("provisional_with_source"):
        click.echo(
            f"   pre-upgrade sources ({len(roster['provisional_with_source'])}): captured under a "
            "provisional id before identity resolved — expected, not duplication")
        for up in roster["provisional_with_source"]:
            click.echo(f"      {up['id']:<14} -> {up['source']}")
    if roster.get("phantom_attendees"):
        click.echo(
            f"   PHANTOM ATTENDEES ({len(roster['phantom_attendees'])}): provisional ids in the "
            "roster with no source behind them")
        for ph in roster["phantom_attendees"]:
            click.echo(f"      {ph['id']:<14} source={ph['source'] or '—'} joined={ph['joined']}")

    timing = report["timing"]
    click.echo(f"\n2. TIMING/ENERGY  {'pass' if timing['pass'] else 'FAIL'}   "
               f"(zero-lag cross-correlation, floor {timing['match_floor']})")
    labels = sorted({label for row in timing["confusion_matrix"].values() for label in row})
    if labels:
        click.echo("   " + " " * 34 + "".join(f"{label:>10}" for label in labels))
        for source_id, row in timing["confusion_matrix"].items():
            cells = "".join(f"{row[label]['correlation']:>10.3f}" for label in labels)
            click.echo(f"   {source_id:<32}{cells}")
    for source_id, best in timing["assignment"].items():
        click.echo(f"   {source_id:<32} -> {best['label'] or 'NO MATCH':<10} "
                   f"lag {best['lag_seconds']:+7.2f}s  margin {best['margin']:+.3f}"
                   + (f"  ({best['reason']})" if best["reason"] else ""))
    if timing["duplication"]:
        click.echo(f"   DUPLICATION: {timing['duplication']} — two sources carry one participant")
    if timing["references_with_no_source"]:
        click.echo(f"   NO SOURCE FOR: {timing['references_with_no_source']}")

    text = report["text"]
    click.echo(f"\n3. TEXT  {'pass' if text['pass'] else ('unscored' if text['pass'] is None else 'FAIL')}")
    if not text.get("available"):
        click.echo(f"   {text['note']}")
    else:
        for source_id, best in text["assignment"].items():
            click.echo(f"   {source_id:<32} -> {best['label'] or 'NO MATCH':<10} "
                       f"jaccard {best['jaccard']:.3f} ({best['words']} words)")

    if report["disagreements"]:
        click.echo("\nDISAGREEMENT between timing and text — reported, not averaged:")
        for d in report["disagreements"]:
            click.echo(f"   {d['source']}: timing says {d['timing_says']} "
                       f"({d['timing_correlation']:.3f}), text says {d['text_says']} "
                       f"({d['text_jaccard']:.3f})")

    click.echo(f"\n{'PASS' if report['pass'] else 'FAIL'}")


if __name__ == "__main__":
    main()
