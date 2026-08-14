# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""Verify an assembled corpus against its own manifest, before any browser runs.

    uv run verify.py check                      # every scenario
    uv run verify.py check --scenario s4-staggered

A corpus that silently drifted is worse than no corpus: every downstream score
would read as an algorithm regression. So this asserts, per scenario:

- **format** — mono, 16-bit, 48 kHz, matching the manifest's own `wav_sha256`;
- **duration** — long enough to hold the last scheduled turn, and not longer
  than the schedule plus its tail;
- **energy envelope** — loud exactly inside the scheduled turns and at digital
  silence outside them. This is the check that catches a misplaced passage, and
  it is the same measurement the scorer later makes against captured audio;
- **head tone** — the right frequency dominates the first 0.5 s of every turn,
  by FFT. A tone at the wrong frequency means two speakers' files were crossed;
- **disjointness** — no two participants are scheduled loud at once outside the
  declared overlap block.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
import numpy as np

import gtlib as gt

SILENCE_CEILING = 1e-4  # digital silence, allowing for dither in the 16-bit round-trip
SPEECH_FLOOR = 0.02  # a normalised passage sits far above this


class Failures(list):
    def add(self, scope: str, message: str) -> None:
        self.append(f"{scope}: {message}")


def dominant_frequency(samples: np.ndarray, rate: int) -> float:
    if samples.size < 64:
        return 0.0
    windowed = samples * np.hanning(samples.size)
    spectrum = np.abs(np.fft.rfft(windowed))
    return float(np.fft.rfftfreq(samples.size, 1 / rate)[int(np.argmax(spectrum))])


def check_scenario(path: Path, failures: Failures) -> dict:
    manifest = json.loads(path.read_text())
    scope = manifest["scenario"]
    rate = manifest["grid"]["sample_rate"]
    slot = manifest["grid"]["slot_seconds"]
    tone_s = manifest["grid"]["tone_seconds"]
    loud_windows: list[tuple[str, float, float, bool]] = []

    for participant in manifest["participants"]:
        label = participant["label"]
        wav = gt.HERE / participant["wav"]
        if not wav.exists():
            failures.add(f"{scope}/{label}", f"{wav} missing — run assemble.py build")
            continue

        digest = gt.sha256_file(wav)
        if digest != participant["wav_sha256"]:
            failures.add(
                f"{scope}/{label}",
                f"{wav.name} SHA-256 {digest[:16]} does not match the manifest's "
                f"{participant['wav_sha256'][:16]}",
            )

        try:
            samples, actual_rate = gt.read_wav(wav)
        except gt.AudioError as exc:
            failures.add(f"{scope}/{label}", str(exc))
            continue
        if actual_rate != rate:
            failures.add(f"{scope}/{label}", f"{wav.name} is {actual_rate} Hz, manifest says {rate}")
            continue

        duration = samples.size / rate
        turns = participant["turns"]
        if turns:
            needed = max(t["audio_start_seconds"] for t in turns) + slot
            if duration + 1e-6 < needed:
                failures.add(
                    f"{scope}/{label}",
                    f"{wav.name} is {duration:.2f}s but the last turn needs {needed:.2f}s — "
                    "the file is short and the tail of the schedule is missing",
                )

        loud = _loud_regions(samples, rate)
        for turn in turns:
            start = turn["audio_start_seconds"]
            _check_turn(scope, label, participant, turn, samples, rate, tone_s, failures)
            loud_windows.append(
                (
                    label,
                    start + participant["audio_start_grid_seconds"],
                    start + participant["audio_start_grid_seconds"] + slot,
                    turn["overlap"],
                )
            )

        # Anything loud outside a scheduled slot breaks the property the whole
        # timing score rests on.
        scheduled = [(t["audio_start_seconds"], t["audio_start_seconds"] + slot) for t in turns]
        for begin, end in loud:
            if not any(begin >= s - 0.05 and end <= e + 0.05 for s, e in scheduled):
                failures.add(
                    f"{scope}/{label}",
                    f"audio at {begin:.2f}-{end:.2f}s falls outside every scheduled slot",
                )

    _check_disjoint(scope, manifest, loud_windows, failures)
    return manifest


def _loud_regions(samples: np.ndarray, rate: int, window_s: float = 0.05) -> list[tuple[float, float]]:
    env = gt.rms_envelope(samples, window_s, rate)
    hot = env > SILENCE_CEILING
    regions: list[tuple[float, float]] = []
    start: int | None = None
    for i, on in enumerate(hot):
        if on and start is None:
            start = i
        elif not on and start is not None:
            regions.append((start * window_s, i * window_s))
            start = None
    if start is not None:
        regions.append((start * window_s, len(hot) * window_s))
    # Merge regions separated by less than the tone gap — a passage's own pauses
    # are not separate regions.
    merged: list[tuple[float, float]] = []
    for begin, end in regions:
        if merged and begin - merged[-1][1] < 1.0:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((begin, end))
    return merged


def _check_turn(scope, label, participant, turn, samples, rate, tone_s, failures) -> None:
    start = turn["audio_start_seconds"]
    begin = int(round(start * rate))
    tone_end = begin + int(round(tone_s * rate))
    head = samples[begin:tone_end]
    if head.size == 0:
        failures.add(f"{scope}/{label}", f"slot {turn['slot']}: no audio at {start:.2f}s")
        return

    want = participant["head_tone_hz"]
    got = dominant_frequency(head, rate)
    # ±3% covers FFT bin width at a 0.5 s window; a crossed file would be tens of
    # percent out, since the tone table has no small-integer ratios in it.
    if abs(got - want) > want * 0.03:
        failures.add(
            f"{scope}/{label}",
            f"slot {turn['slot']}: head tone is {got:.0f} Hz, expected {want} Hz "
            "— two speakers' files may be crossed",
        )

    body = samples[tone_end : begin + int(round(gt.SLOT_SECONDS * rate))]
    if gt.rms(body) < SPEECH_FLOOR:
        failures.add(
            f"{scope}/{label}",
            f"slot {turn['slot']} ({turn['passage']}): passage RMS {gt.rms(body):.4f} "
            f"is below the speech floor — the passage did not land",
        )


def _check_disjoint(scope, manifest, windows, failures) -> None:
    declared = set(manifest["overlap"]["slots"])
    slot = manifest["grid"]["slot_seconds"]
    for i, (label_a, a0, a1, ov_a) in enumerate(windows):
        for label_b, b0, b1, ov_b in windows[i + 1 :]:
            if label_a == label_b or a0 >= b1 or b0 >= a1:
                continue
            grid_slot = int(round(a0 / slot))
            if ov_a and ov_b and grid_slot in declared:
                continue
            failures.add(
                scope,
                f"{label_a} and {label_b} are both scheduled loud at grid "
                f"{a0:.0f}-{a1:.0f}s, outside the declared overlap block",
            )


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.option("--scenario", "only", multiple=True)
def check(only: tuple[str, ...]) -> None:
    """Assert every assembled WAV matches the schedule it claims to carry."""
    raw = gt.load_raw_manifest()
    gt.verify_raw(raw)

    paths = sorted(gt.MANIFESTS.glob("*.json"))
    if only:
        paths = [p for p in paths if p.stem in only]
    if not paths:
        raise click.ClickException(f"no manifests in {gt.MANIFESTS} — run assemble.py build")

    failures = Failures()
    for path in paths:
        manifest = check_scenario(path, failures)
        turns = sum(len(p["turns"]) for p in manifest["participants"])
        click.echo(
            f"  {manifest['scenario']:<16} {len(manifest['participants'])} wav, {turns} turns, "
            f"overlap slots {manifest['overlap']['slots'] or 'none'}"
        )

    if failures:
        for line in failures:
            click.echo(f"FAIL {line}", err=True)
        raise click.ClickException(f"{len(failures)} corpus check(s) failed")
    click.echo(f"\nOK — {len(paths)} scenario(s) match their manifests")


if __name__ == "__main__":
    cli()
