# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""Assemble the ground-truth corpus: `raw/` renders → one 16-bit PCM WAV per
scenario per speaker, plus the scenario manifest that says what is in them.

    uv run assemble.py build              # all four scenarios
    uv run assemble.py build --scenario s1-solo
    uv run assemble.py build --force      # ignore the cache

Every WAV is the full call length with the speaker's passages at their slot
offsets and digital silence everywhere else, so all of a scenario's files are
the same shape and only differ in *when* they are loud. That is what makes
attribution scorable from energy alone.

Caching is on a content hash of the `raw/` SHA-256s plus the slot grid, the tone
table and the scenario definitions (``gtlib.corpus_fingerprint``). Reassembly is
free when nothing changed; when something did, the fingerprint moves and every
WAV is rebuilt. There is no path where a changed input yields a stale WAV.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import click
import numpy as np

import gtlib as gt


def assemble_participant(participant: gt.Participant, total_seconds: float) -> np.ndarray:
    """Lay one speaker's turns onto a silent bed of the full call length."""
    buf = gt.silence(total_seconds)
    for turn in participant.turns:
        head = gt.tone(participant.head_tone_hz, gt.TONE_SECONDS)
        passage = gt.normalise_peak(gt.decode(gt.RAW / f"{turn.speaker}-{turn.passage}.mp3"))

        at = int(round(turn.audio_start * gt.SAMPLE_RATE))
        if at < 0:
            raise gt.AudioError(
                f"{participant.label}: turn in slot {turn.slot} starts "
                f"{-turn.audio_start:.1f}s before its own audio does"
            )
        _place(buf, head, at)
        _place(buf, passage, at + int(round((gt.TONE_SECONDS + gt.TONE_GAP_SECONDS) * gt.SAMPLE_RATE)))

        used = gt.TONE_SECONDS + gt.TONE_GAP_SECONDS + passage.size / gt.SAMPLE_RATE
        if used > gt.SLOT_SECONDS:
            raise gt.AudioError(
                f"{participant.label}-{turn.passage}: {used:.2f}s of content does not fit a "
                f"{gt.SLOT_SECONDS:.0f}s slot — the grid guard band is gone"
            )
    return buf


def _place(buf: np.ndarray, chunk: np.ndarray, at: int) -> None:
    end = min(at + chunk.size, buf.size)
    if end <= at:
        raise gt.AudioError("a passage landed entirely past the end of the call")
    buf[at:end] += chunk[: end - at]


def manifest_for(
    scenario: gt.Scenario,
    participants: list[gt.Participant],
    raw_manifest: dict,
    fingerprint: str,
    wav_dir: Path,
) -> dict:
    """The ground truth, in the form a scorer six weeks from now can read with no
    access to this conversation."""
    voices = raw_manifest["voices"]
    return {
        "schema": gt.SCHEMA_VERSION,
        "scenario": scenario.id,
        "shape": scenario.shape,
        "corpus_fingerprint": fingerprint,
        "grid": {
            "sample_rate": gt.SAMPLE_RATE,
            "slot_seconds": gt.SLOT_SECONDS,
            "tone_seconds": gt.TONE_SECONDS,
            "tone_gap_seconds": gt.TONE_GAP_SECONDS,
            "tone_amplitude": gt.TONE_AMPLITUDE,
            "passage_peak_dbfs": gt.PASSAGE_PEAK_DBFS,
            "preroll_seconds": gt.PREROLL_SECONDS,
            "rounds": scenario.rounds,
            "slots": int(gt.grid_end_seconds(scenario) / gt.SLOT_SECONDS),
            "grid_end_seconds": gt.grid_end_seconds(scenario),
            "guard_seconds": round(gt.guard_seconds(_longest_passage(participants)), 3),
        },
        "tts": {
            "model": raw_manifest["model"],
            "output_format": raw_manifest["output_format"],
            "seed": raw_manifest["seed"],
            "voice_settings": raw_manifest["voice_settings"],
        },
        "overlap": {
            "pair": list(scenario.overlap_pair) if scenario.overlap_pair else None,
            "slots": sorted(
                {t.slot for p in participants for t in p.turns if t.overlap}
            ),
        },
        "participants": [
            {
                "label": p.label,
                "display_name": p.display_name,
                "role": "local" if p.local else "guest",
                "wav": str((wav_dir / p.wav_name).relative_to(gt.HERE)),
                "wav_sha256": gt.sha256_file(wav_dir / p.wav_name),
                "wav_duration_seconds": round(
                    gt.read_wav(wav_dir / p.wav_name)[0].size / gt.SAMPLE_RATE, 3
                ),
                # Everything after this is loop-guard silence. A run that is
                # still going here has outlasted its own ground truth.
                "scored_end_seconds": round(
                    gt.read_wav(wav_dir / p.wav_name)[0].size / gt.SAMPLE_RATE
                    - gt.LOOP_GUARD_SECONDS,
                    3,
                ),
                "head_tone_hz": p.head_tone_hz,
                "voice_id": voices[p.label],
                "tts_model": raw_manifest["model"],
                "audio_start_grid_seconds": p.audio_start_grid,
                "intended_join_grid_seconds": p.join_grid,
                "intended_leave_grid_seconds": p.leave_grid,
                "expected_source_id": (
                    "mic" if p.local else f"browser:meet:<resolved-at-run-time>"
                ),
                "turns": [
                    {
                        "slot": t.slot,
                        "passage": t.passage,
                        "overlap": t.overlap,
                        "grid_start_seconds": t.grid_start,
                        "grid_end_seconds": t.grid_end,
                        "audio_start_seconds": round(t.audio_start, 3),
                        "audio_end_seconds": round(t.audio_end, 3),
                        "text": t.text,
                        "raw_sha256": raw_manifest["passages"][
                            f"{t.speaker}-{t.passage}.mp3"
                        ]["sha256"],
                    }
                    for t in p.turns
                ],
            }
            for p in participants
        ],
        # Filled in by the runner. Kept in the same document as the schedule on
        # purpose: an archived run is only re-scorable if the WAVs, the slot
        # schedule and the resulting session id travel together.
        "run": None,
    }


def _longest_passage(participants: list[gt.Participant]) -> float:
    longest = 0.0
    for p in participants:
        for t in p.turns:
            src = gt.RAW / f"{t.speaker}-{t.passage}.mp3"
            longest = max(longest, gt.decode(src).size / gt.SAMPLE_RATE)
    return longest


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.option("--scenario", "only", multiple=True, help="Build just these scenarios.")
@click.option("--force", is_flag=True, help="Rebuild even when the fingerprint matches.")
def build(only: tuple[str, ...], force: bool) -> None:
    """Verify raw/, then assemble every scenario's WAVs and manifest."""
    gt.require_ffmpeg()
    raw = gt.load_raw_manifest()
    gt.verify_raw(raw)
    click.echo(f"raw/ verified: {len(raw['passages'])} renders match manifest SHA-256")

    fingerprint = gt.corpus_fingerprint(raw)
    click.echo(f"corpus fingerprint {fingerprint[:16]}")

    wanted = list(only) or list(gt.SCENARIOS)
    for name in wanted:
        if name not in gt.SCENARIOS:
            raise click.ClickException(
                f"unknown scenario {name!r} — have {', '.join(gt.SCENARIOS)}"
            )
        _build_one(gt.SCENARIOS[name], raw, fingerprint, force)


def _build_one(scenario: gt.Scenario, raw: dict, fingerprint: str, force: bool) -> None:
    out = gt.BUILD / scenario.id
    stamp = out / ".fingerprint"
    participants = gt.build_scenario(scenario, raw)
    wavs = [out / p.wav_name for p in participants]

    if not force and stamp.exists() and stamp.read_text().strip() == fingerprint:
        if all(w.exists() for w in wavs):
            click.echo(f"  cached  {scenario.id}")
            return

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    grid_end = gt.grid_end_seconds(scenario)
    for p in participants:
        total = grid_end - p.audio_start_grid + gt.TAIL_SECONDS
        if p.leave_grid is not None:
            # A participant that leaves stops producing audio then; giving its
            # file the full length would make Meet transmit silence from an
            # absent participant, which is not what the manifest says happened.
            total = min(total, p.leave_grid - p.audio_start_grid + gt.TAIL_SECONDS)
        # Loop-guard silence: `%noloop` is a no-op on the browsers here, so the
        # file is made longer than the run instead of asking Chrome to stop it.
        gt.write_wav(out / p.wav_name, assemble_participant(p, total + gt.LOOP_GUARD_SECONDS))

    gt.MANIFESTS.mkdir(parents=True, exist_ok=True)
    manifest = manifest_for(scenario, participants, raw, fingerprint, out)
    (gt.MANIFESTS / f"{scenario.id}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    stamp.write_text(fingerprint + "\n")

    turns = sum(len(p.turns) for p in participants)
    click.echo(
        f"  built   {scenario.id}: {len(participants)} wav, {turns} turns, "
        f"{grid_end:.0f}s grid, guard {manifest['grid']['guard_seconds']:.2f}s"
    )


if __name__ == "__main__":
    cli()
