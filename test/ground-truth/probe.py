# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""The tone-viability probe: does a sine tone survive the path from a fake mic,
through Meet, to a captured source and the daemon's VAD?

    uv run probe.py wav        # build probe/tone-probe.wav + its schedule

Why this runs before anything else. The corpus is speech because four things
between the fake mic and the transcript may treat a steady sine as non-speech —
WebRTC noise suppression, Opus voice mode plus DTX, Meet's own local speaking
analyzer (the one driving the speaking-ring DOM that `SpeakingCorrelator` feeds
on), and the daemon's energy VAD. That is a testable assumption, not a settled
one, and the head tones already in the corpus design carry exactly the same
risk.

The probe WAV is deliberately **tones and speech in one file**. A tones-only
probe cannot tell "Meet discarded the tone" from "the rig is broken": both look
like silence at the far end. Interleaving a known speech control means every
check has a positive control in the same recording, from the same participant,
over the same connection. A dark ring during the tone blocks and a lit ring
during the speech block is a verdict about tones; a dark ring throughout is a
verdict about the rig.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
import numpy as np

import gtlib as gt

PROBE = gt.HERE / "probe"
WAV = PROBE / "tone-probe.wav"
SCHEDULE = PROBE / "tone-probe.json"

PREROLL = 30.0  # launch → load → name → admit
TONE_ON = 3.0
TONE_OFF = 1.5
BLOCK_GAP = 3.0
SPEECH_GAP = 1.5
TAIL = 3.0
# The speech control uses Alpha's passages: a voice already in the corpus, and
# one that is not the local participant's, so nothing in the probe depends on
# the file-backed capture provider being finished.
CONTROL_PASSAGES = ["alpha-p1", "alpha-p2", "alpha-p3"]


def build() -> dict:
    gt.require_ffmpeg()
    raw = gt.load_raw_manifest()
    gt.verify_raw(raw)

    parts: list[np.ndarray] = [gt.silence(PREROLL)]
    windows: list[dict] = []
    at = PREROLL

    def emit(chunk: np.ndarray, kind: str, detail) -> None:
        nonlocal at
        seconds = chunk.size / gt.SAMPLE_RATE
        windows.append(
            {
                "kind": kind,
                "detail": detail,
                "start_seconds": round(at, 3),
                "end_seconds": round(at + seconds, 3),
            }
        )
        parts.append(chunk)
        at += seconds

    def gap(seconds: float) -> None:
        nonlocal at
        parts.append(gt.silence(seconds))
        at += seconds

    # Two passes over the four head frequencies. Two, not one, so a single
    # dropout cannot be mistaken for a frequency that never survives.
    for pass_index in range(2):
        for speaker, hz in gt.HEAD_TONES_HZ.items():
            emit(gt.tone(hz, TONE_ON), "tone", {"hz": hz, "speaker": speaker, "pass": pass_index})
            gap(TONE_OFF)
        gap(BLOCK_GAP)

    gap(BLOCK_GAP)

    for name in CONTROL_PASSAGES:
        passage = gt.normalise_peak(gt.decode(gt.RAW / f"{name}.mp3"))
        emit(passage, "speech", {"passage": name, "text": raw["passages"][f"{name}.mp3"]["text"]})
        gap(SPEECH_GAP)

    parts.append(gt.silence(TAIL))
    samples = np.concatenate(parts)
    gt.write_wav(WAV, samples)

    schedule = {
        "schema": gt.SCHEMA_VERSION,
        "wav": str(WAV.relative_to(gt.HERE)),
        "wav_sha256": gt.sha256_file(WAV),
        "sample_rate": gt.SAMPLE_RATE,
        "duration_seconds": round(samples.size / gt.SAMPLE_RATE, 3),
        "preroll_seconds": PREROLL,
        "display_name": "GT-Probe",
        "tone_amplitude": gt.TONE_AMPLITUDE,
        "passage_peak_dbfs": gt.PASSAGE_PEAK_DBFS,
        "windows": windows,
        "checks": [
            "audio-reaches-host: a captured browser: source carries energy in the window",
            "speaking-ring: Meet's per-participant speaking ring lights in the window",
            "daemon-vad: earsd emits a speech span overlapping the window",
        ],
    }
    SCHEDULE.write_text(json.dumps(schedule, indent=2) + "\n")
    return schedule


@click.group()
def cli() -> None:
    pass


@cli.command()
def wav() -> None:
    """Build the probe WAV and its window schedule."""
    schedule = build()
    tones = sum(1 for w in schedule["windows"] if w["kind"] == "tone")
    speech = sum(1 for w in schedule["windows"] if w["kind"] == "speech")
    click.echo(
        f"{WAV.relative_to(gt.HERE)}  {schedule['duration_seconds']:.1f}s  "
        f"{tones} tone windows, {speech} speech windows\n"
        f"{SCHEDULE.relative_to(gt.HERE)}  sha256 {schedule['wav_sha256'][:16]}"
    )


if __name__ == "__main__":
    cli()
