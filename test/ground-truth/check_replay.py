# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Prove the replay tier works, hermetically — no call, no operator, no model.

    uv run check_replay.py

Drives `replay.py` over the committed `fixtures/replay-demo/` archive and
asserts the properties the tier exists to provide:

1. the REAL Swift reconciler ran and consumed the recorded binding hints —
   the replayed map names GT-Alpha `correlated` (elimination alone would say
   `inferred`, and the archive's deliberately stale stored map says GT-Stale);
2. the archived fixture is byte-identical afterwards;
3. the two stores the tier must refuse are refused with their reasons said
   out loud: a store with no attribution log, and a pre-R3 (schema != 3) one.

Needs a built daemon (`swift build` in daemon/) — the whole point is running
the real binary.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixtures" / "replay-demo"


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def run_replay(run_dir: Path, out: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["uv", "run", "replay.py", str(run_dir), "--out", str(out), *extra],
        cwd=HERE, capture_output=True, text=True, check=False,
    )


def check(condition: bool, label: str, detail: str = "") -> None:
    if not condition:
        print(f"FAIL  {label}" + (f"\n      {detail}" if detail else ""), file=sys.stderr)
        sys.exit(1)
    print(f"  ok  {label}")


def main() -> None:
    if not (HERE.parent.parent / "daemon" / ".build").exists():
        print(
            "no daemon build found — run `swift build` in daemon/ first "
            "(the check replays through the real transcribe binary)",
            file=sys.stderr,
        )
        sys.exit(1)

    scratch = Path(tempfile.mkdtemp(prefix="gt-check-replay-"))
    try:
        before = tree_digest(FIXTURE)

        # ── the happy path ────────────────────────────────────────────────
        proc = run_replay(FIXTURE, scratch / "happy")
        check(proc.returncode == 0, "replay exits 0", proc.stderr.strip()[-300:])
        report = json.loads((scratch / "happy" / "replay.json").read_text())
        replayed = report["replay"]["replayed_speaker_map"]
        check(
            replayed == [
                {"source": "browser:meet:t1", "name": "GT-Alpha", "confidence": "correlated"}
            ],
            "the real reconciler re-derived GT-Alpha from the binding hint",
            f"got {replayed}",
        )
        check(
            report["replay"]["stored_speaker_map"][0]["name"] == "GT-Stale",
            "the stale stored map was reported, not trusted",
        )
        check(report["roster"]["pass"] is True, "roster scores pass on the replayed map")
        check(report["timing"]["pass"] is None, "timing is unscored (audio evicted), not failed")
        check(report["text"]["pass"] is None, "text is unscored (null ASR), not failed")
        check(tree_digest(FIXTURE) == before, "the archived fixture is byte-identical")

        # ── refusal: no attribution log ───────────────────────────────────
        no_log = scratch / "no-attribution"
        shutil.copytree(FIXTURE, no_log)
        (no_log / "session" / "attribution.jsonl").unlink()
        proc = run_replay(no_log, scratch / "no-attribution-out")
        check(
            proc.returncode != 0 and "no attribution log recorded" in proc.stderr,
            "a store without attribution.jsonl is refused with the reason",
            proc.stderr.strip()[-300:],
        )
        proc = run_replay(no_log, scratch / "no-attribution-roster", "--roster-only")
        check(
            proc.returncode == 0,
            "--roster-only replays the same store from the roster alone",
            proc.stderr.strip()[-300:],
        )
        roster_report = json.loads(
            (scratch / "no-attribution-roster" / "replay.json").read_text())
        check(
            roster_report["replay"]["replayed_speaker_map"][0]["confidence"] == "inferred",
            "hint-less, the binding falls back to elimination (inferred)",
        )

        # ── refusal: pre-R3 store ─────────────────────────────────────────
        pre_r3 = scratch / "pre-r3"
        shutil.copytree(FIXTURE, pre_r3)
        descriptor = pre_r3 / "session" / "session.toml"
        descriptor.write_text(descriptor.read_text().replace("schema = 3", "schema = 1", 1))
        proc = run_replay(pre_r3, scratch / "pre-r3-out")
        check(
            proc.returncode != 0 and "pre-R3 store" in proc.stderr,
            "a pre-R3 store is refused with the reason",
            proc.stderr.strip()[-300:],
        )

        print("PASS")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
