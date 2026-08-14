# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""Analyse a tone-viability probe run and answer its three questions.

    uv run probe_report.py runs/<timestamp>-probe

For every window in the probe schedule — eight tone windows across the four
head frequencies, three speech control windows — it reports:

1. **audio-reaches-host** — captured RMS on the guest's `browser:` source,
   plus, for tone windows, the in-band/out-of-band ratio at the expected
   frequency. A tone that arrives is a narrow spectral peak, not just energy.
2. **speaking-ring** — Meet's per-tile mutation-burst activity for that guest
   inside the window. This is the signal `SpeakingCorrelator` runs on, so a dark
   ring means the identity correlator cannot be exercised at all.
3. **daemon-vad** — whether `earsd` emitted a speech span overlapping the
   window.

The verdict is a comparison, not an absolute: the speech control windows are
the positive control. Tones dark and speech lit is a verdict about tones;
everything dark is a verdict about the rig.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
import numpy as np

import gtlib as gt
import sessions as store

HOP = 0.1
TONE_SNR_PASS = 6.0  # in-band peak this many times the out-of-band median
RMS_PASS = 2e-3


def load(run_dir: Path) -> dict:
    path = run_dir / "probe.json"
    if not path.exists():
        raise click.ClickException(f"{path} not found")
    return json.loads(path.read_text())


def guest_source(session: store.Session, report: dict) -> store.Source | None:
    """The captured source carrying the probe guest's audio.

    Picked by energy rather than by name: the whole point of the probe is that
    identity resolution may not have worked, and a source labelled `speaker-2`
    still answers the question.
    """
    candidates = list(session.browser_sources().values())
    if not candidates:
        return None
    best, best_rms = None, -1.0
    for source in candidates:
        samples, _ = source.decode()
        value = gt.rms(samples)
        report.setdefault("browser_sources", []).append(
            {"id": source.id, "rms": value, "chunks": len(source.chunks),
             "speech_spans": len(source.speech)}
        )
        if value > best_rms:
            best, best_rms = source, value
    return best


def ring_activity(ring: dict | None) -> dict[str, list[tuple[float, int]]]:
    """Ring bursts as (epoch seconds, mutation count) per participant tile."""
    if not ring:
        return {}
    t0 = ring["t0"] / 1000.0
    out = {}
    for participant in ring.get("participants", []):
        key = participant.get("name") or participant["id"]
        out[key] = [(t0 + bucket * 0.1, count) for bucket, count in participant["activity"]]
    return out


@click.command()
@click.argument("run_dir", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option("--json", "as_json", is_flag=True, help="Emit the structured report only.")
def main(run_dir: Path, as_json: bool) -> None:
    report = load(run_dir)
    schedule = report["schedule"]
    result: dict = {"run": str(run_dir), "windows": [], "verdict": {}}

    if not report.get("session"):
        raise click.ClickException("this run recorded no session — nothing to analyse")
    session = store.load_session(Path(report["session"]["directory"]))

    source = guest_source(session, result)
    if source is None or not source.chunks:
        raise click.ClickException(
            "no browser: source with audio in the session — the extension captured nothing, "
            "which is a rig failure and says nothing about tones"
        )
    result["source_id"] = source.id

    captured, origin = source.decode()
    origin_epoch = origin.timestamp()
    reference, _ = gt.read_wav(gt.HERE / schedule["wav"])

    lag, score = gt.align_lag(
        gt.rms_envelope(captured, HOP), gt.rms_envelope(reference, HOP), HOP
    )
    result["alignment"] = {"lag_seconds": lag, "correlation": score}

    rings = ring_activity(report.get("ring"))
    # Ring tiles are keyed by whatever text the tile carried; the probe guest is
    # the one whose declared name we typed ourselves.
    guest_name = schedule["display_name"]
    guest_ring = next(
        (v for k, v in rings.items() if k and guest_name.lower() in k.lower()), None
    )
    result["ring_tiles"] = list(rings)
    result["ring_matched_tile"] = guest_ring is not None

    spans = [(s.start.timestamp(), s.end.timestamp()) for s in source.speech]
    result["vad_span_count"] = len(spans)

    for window in schedule["windows"]:
        begin = window["start_seconds"] + lag
        end = window["end_seconds"] + lag
        a, b = int(begin / HOP * HOP * gt.SAMPLE_RATE), int(end * gt.SAMPLE_RATE)
        a = max(0, int(begin * gt.SAMPLE_RATE))
        segment = captured[a:b] if b > a else np.zeros(0, dtype=np.float32)

        entry = {
            "kind": window["kind"],
            "detail": window["detail"],
            "reference_start": window["start_seconds"],
            "captured_rms": round(gt.rms(segment), 6),
            "audio_reaches_host": gt.rms(segment) > RMS_PASS,
        }
        if window["kind"] == "tone":
            in_band, out_band = gt.band_energy(segment, window["detail"]["hz"])
            snr = in_band / out_band if out_band > 0 else 0.0
            entry["tone_hz"] = window["detail"]["hz"]
            entry["tone_snr"] = round(snr, 2)
            entry["tone_survives"] = snr >= TONE_SNR_PASS and entry["audio_reaches_host"]

        w0, w1 = origin_epoch + begin, origin_epoch + end
        entry["vad_speech"] = any(s < w1 and e > w0 for s, e in spans)
        if guest_ring is not None:
            entry["ring_bursts"] = sum(c for t, c in guest_ring if w0 <= t <= w1)
            entry["ring_lit"] = entry["ring_bursts"] > 0
        else:
            entry["ring_bursts"] = None
            entry["ring_lit"] = None
        result["windows"].append(entry)

    tones = [w for w in result["windows"] if w["kind"] == "tone"]
    speech = [w for w in result["windows"] if w["kind"] == "speech"]
    result["verdict"] = {
        "tone_audio_reaches_host": _fraction(tones, "audio_reaches_host"),
        "tone_survives_spectrally": _fraction(tones, "tone_survives"),
        "tone_ring_lit": _fraction(tones, "ring_lit"),
        "tone_vad_speech": _fraction(tones, "vad_speech"),
        "speech_audio_reaches_host": _fraction(speech, "audio_reaches_host"),
        "speech_ring_lit": _fraction(speech, "ring_lit"),
        "speech_vad_speech": _fraction(speech, "vad_speech"),
    }
    result["conclusion"] = _conclude(result["verdict"])

    (run_dir / "probe-report.json").write_text(json.dumps(result, indent=2) + "\n")
    if as_json:
        click.echo(json.dumps(result, indent=2))
        return
    _print(result)


def _fraction(windows: list[dict], key: str) -> str | None:
    values = [w[key] for w in windows if w.get(key) is not None]
    if not values:
        return None
    return f"{sum(1 for v in values if v)}/{len(values)}"


def _pass(fraction: str | None) -> bool:
    if not fraction:
        return False
    got, total = fraction.split("/")
    return int(total) > 0 and int(got) == int(total)


def _conclude(verdict: dict) -> str:
    rig_ok = _pass(verdict["speech_audio_reaches_host"]) and _pass(verdict["speech_vad_speech"])
    if not rig_ok:
        return (
            "INCONCLUSIVE — the speech control did not make it through either, so this run "
            "measures the rig, not tones. Fix the rig and re-run before drawing any "
            "conclusion about the head tones."
        )
    all_tone = (
        _pass(verdict["tone_audio_reaches_host"])
        and _pass(verdict["tone_survives_spectrally"])
        and _pass(verdict["tone_ring_lit"])
        and _pass(verdict["tone_vad_speech"])
    )
    if all_tone:
        return (
            "TONES VIABLE — audio arrives, the tone survives spectrally, Meet's speaking ring "
            "lights, and the daemon's VAD emits spans. A tones-only corpus is a legitimate "
            "cheap mode for capture-layer regression runs, and the head tones in the speech "
            "corpus are safe."
        )
    if _pass(verdict["tone_audio_reaches_host"]) and not _pass(verdict["tone_ring_lit"]):
        return (
            "TONES ARRIVE BUT THE RING STAYS DARK — Meet's local speaking analyzer does not "
            "count a sine as speech. Decisive for the corpus being speech: the identity "
            "correlator runs on the ring, so a tones-only corpus would silently skip it. The "
            "head tones still work as an ASR-free channel in the captured audio, but nothing "
            "may depend on them lighting the ring."
        )
    return (
        "TONES DO NOT SURVIVE — the speech control got through and the tones did not. The "
        "corpus must be speech, and the per-turn head tones need rethinking."
    )


def _print(result: dict) -> None:
    click.echo(f"probe run {result['run']}")
    click.echo(f"source {result['source_id']}  lag {result['alignment']['lag_seconds']:+.2f}s  "
               f"correlation {result['alignment']['correlation']:.3f}")
    click.echo(f"ring tiles seen: {result['ring_tiles']}  matched guest: {result['ring_matched_tile']}")
    click.echo("")
    click.echo(f"{'window':<26}{'rms':>10}{'snr':>8}{'ring':>7}{'vad':>6}")
    for w in result["windows"]:
        if w["kind"] == "tone":
            name = f"tone {w['tone_hz']} Hz"
            snr = f"{w['tone_snr']:.1f}"
        else:
            name = f"speech {w['detail']['passage']}"
            snr = "-"
        ring = "-" if w["ring_bursts"] is None else str(w["ring_bursts"])
        click.echo(f"{name:<26}{w['captured_rms']:>10.5f}{snr:>8}{ring:>7}{str(w['vad_speech']):>6}")
    click.echo("")
    for key, value in result["verdict"].items():
        click.echo(f"  {key:<32} {value}")
    click.echo(f"\n{result['conclusion']}")


if __name__ == "__main__":
    main()
