# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2"]
# ///
"""Shared model for the ground-truth harness: the slot grid, the scenarios, and
the small amount of audio I/O everything else is built on.

Three ideas carry the whole harness and are worth stating once:

1. **The audio file is the clock.** Chrome's ``--use-file-for-fake-audio-capture``
   starts a participant's WAV when the page acquires the mic and (with
   ``%noloop``) never repeats it. So a participant's speaking schedule is baked
   into its own file; the runner only decides *when* to start each browser. Every
   offset in a manifest is therefore stated twice: once on the shared **grid**
   clock (what the scenario means) and once relative to **that participant's own
   audio start** (what its WAV actually contains).

2. **Disjoint slots are the scorable property.** Speaker *k* of *N* speaks in
   grid slots *k, k+N, k+2N…* and is digitally silent everywhere else, so
   attribution can be scored from energy and timing with no ASR at all. A slot is
   ``SLOT_SECONDS`` long and holds a head tone, a short gap, one passage, then
   silence to the boundary — the silence is the guard band that absorbs
   launch-time drift between browsers. ``guard_seconds()`` reports how much there
   is; the runner flags a run whose measured drift eats it.

3. **Everything is derived from ``raw/manifest.json``.** The renders are pinned
   by SHA-256 there along with the voice, model and seed that produced them. This
   module re-checks those hashes before it will assemble anything, so a corpus
   can never drift out from under a scenario manifest silently.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import struct
import subprocess
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
RAW = HERE / "raw"
RAW_MANIFEST = RAW / "manifest.json"
BUILD = HERE / "build"
MANIFESTS = HERE / "manifests"
RUNS = HERE / "runs"

# ---------------------------------------------------------------------------
# The slot grid
# ---------------------------------------------------------------------------

SCHEMA_VERSION = 1

SAMPLE_RATE = 48_000  # Chrome's fake device wants 16-bit PCM; 48 kHz mono is the
#                       native rate earsd stores at, so nothing resamples twice.
SLOT_SECONDS = 12.0
TONE_SECONDS = 0.5
TONE_GAP_SECONDS = 0.3
TONE_AMPLITUDE = 0.25  # ≈ -12 dBFS: audible to an FFT, well under the passage peak
PASSAGE_PEAK_DBFS = -3.0  # every passage normalised to the same peak, so a
#                           per-slot energy threshold means the same thing for
#                           every speaker and Meet's AGC has less to chew on.

# Silence at the head of every participant's WAV, covering browser launch → page
# load → name entry → admission. A guest not yet admitted when its preroll
# expires has lost the front of its schedule; the runner checks for that rather
# than letting it score as a miss.
PREROLL_SECONDS = 30.0
TAIL_SECONDS = 3.0

# Silence appended after the scored tail, so the file cannot reach its end and
# start over inside a run.
#
# `%noloop` does not work. Measured on Chromium 150.0.7871.46 and Brave
# 151.1.93.129 (macOS 15, arm64): a 5 s file passed as `file.wav%noloop` was
# still delivering full-level audio at 16 s, identically to the same file with
# no suffix. The suffix *is* parsed — `file.wav%bogus` produces no capture at
# all — but `noloop` has no effect on either build. The flag is still passed
# (harmless, and correct if a future build honours it), but nothing here depends
# on it: the file is simply made longer than any run can be, and the runner
# stops the call well before the loop point. `check_loop_margin` is what makes
# that an assertion rather than an assumption.
LOOP_GUARD_SECONDS = 120.0

# Primes with no small-integer ratios between them, so no tone can be mistaken
# for another's harmonic.
HEAD_TONES_HZ = {"host": 383, "alpha": 521, "bravo": 673, "charlie": 947}

DISPLAY_NAMES = {
    "host": "GT-Host",
    "alpha": "GT-Alpha",
    "bravo": "GT-Bravo",
    "charlie": "GT-Charlie",
}

SPEAKER_ORDER = ["host", "alpha", "bravo", "charlie"]


def guard_seconds(longest_passage: float) -> float:
    """Silence left in the tightest slot — the drift budget between browsers."""
    return SLOT_SECONDS - (TONE_SECONDS + TONE_GAP_SECONDS + longest_passage)


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Turn:
    """One speaking slot, stated on both clocks."""

    slot: int  # index into the shared grid
    speaker: str
    passage: str  # "p1".."p4" or "ov"
    grid_start: float  # seconds from grid t=0
    grid_end: float
    audio_start: float  # seconds from THIS speaker's audio start
    audio_end: float
    text: str
    overlap: bool = False


@dataclass(frozen=True)
class Participant:
    """A participant and the WAV that defines what it says and when."""

    label: str  # host | alpha | bravo | charlie
    display_name: str  # typed at join; the ground-truth label, by construction
    local: bool  # True = the instrumented browser + earsd mic source
    join_grid: float  # intended join, seconds from grid t=0 (negative = before)
    leave_grid: float | None  # None = stays to the end
    audio_start_grid: float  # when its WAV begins, seconds from grid t=0
    head_tone_hz: int
    turns: list[Turn] = field(default_factory=list)

    @property
    def wav_name(self) -> str:
        return f"{self.label}.wav"


@dataclass(frozen=True)
class Scenario:
    id: str
    shape: str
    speakers: list[str]  # in grid order; index is k
    rounds: int
    overlap_pair: tuple[str, str] | None
    # label -> (join_grid, leave_grid or None). Absent = present from the start
    # and stays to the end.
    schedule: dict[str, tuple[float, float | None]] = field(default_factory=dict)
    # labels that skip the first round entirely (late admission)
    skip_rounds: dict[str, int] = field(default_factory=dict)


# `s4` is the one that matters: guests admitted late change the track timeline,
# which is what produced the anomalous track-5 in the 2026-08-06 call. Its
# stagger is chosen so every arrival and departure lands in a slot nobody is
# speaking in — a join is a change to the *timeline*, and mixing it with a
# collision would make a failure ambiguous.
SCENARIOS: dict[str, Scenario] = {
    "s1-solo": Scenario(
        id="s1-solo",
        shape="1 local participant (host only)",
        speakers=["host"],
        rounds=3,
        overlap_pair=None,
    ),
    "s2-one-guest": Scenario(
        id="s2-one-guest",
        shape="1 local participant + 1 guest",
        speakers=["host", "alpha"],
        rounds=3,
        overlap_pair=("host", "alpha"),
    ),
    "s3-three-guests": Scenario(
        id="s3-three-guests",
        shape="1 local participant + 3 guests, all joined before speech starts",
        speakers=["host", "alpha", "bravo", "charlie"],
        rounds=3,
        overlap_pair=("bravo", "charlie"),
    ),
    "s4-staggered": Scenario(
        id="s4-staggered",
        shape="1 local participant + 3 guests, joining and leaving at staggered times",
        speakers=["host", "alpha", "bravo", "charlie"],
        rounds=4,
        overlap_pair=("bravo", "charlie"),
        # charlie arrives in the silent slot 3 (36-48 s) and still gets three
        # turns; alpha leaves at 130 s, inside slot 10 which it does not own,
        # having taken its three.
        schedule={"charlie": (36.0, None), "alpha": (-PREROLL_SECONDS, 130.0)},
        skip_rounds={"charlie": 1},
    ),
}


def _passage_text(raw_manifest: dict, speaker: str, label: str) -> str:
    return raw_manifest["passages"][f"{speaker}-{label}.mp3"]["text"]


def build_scenario(scenario: Scenario, raw_manifest: dict) -> list[Participant]:
    """Resolve a scenario into participants with fully-stated turn schedules."""
    n = len(scenario.speakers)
    participants: list[Participant] = []

    for k, label in enumerate(scenario.speakers):
        skip = scenario.skip_rounds.get(label, 0)
        join, leave = scenario.schedule.get(label, (-PREROLL_SECONDS, None))
        # A participant's WAV begins PREROLL_SECONDS before its first grid
        # obligation, so admission has somewhere to happen.
        audio_start = join if join < 0 else max(0.0, join - 6.0)

        turns: list[Turn] = []
        my_rounds = [r for r in range(scenario.rounds) if r >= skip]
        for turn_index, r in enumerate(my_rounds):
            slot = r * n + k
            start = slot * SLOT_SECONDS
            end = start + SLOT_SECONDS
            if leave is not None and start >= leave:
                continue
            passage = f"p{turn_index + 1}"
            turns.append(
                Turn(
                    slot=slot,
                    speaker=label,
                    passage=passage,
                    grid_start=start,
                    grid_end=end,
                    audio_start=start - audio_start,
                    audio_end=end - audio_start,
                    text=_passage_text(raw_manifest, label, passage),
                )
            )

        if scenario.overlap_pair and label in scenario.overlap_pair:
            slot = scenario.rounds * n
            start = slot * SLOT_SECONDS
            turns.append(
                Turn(
                    slot=slot,
                    speaker=label,
                    passage="ov",
                    grid_start=start,
                    grid_end=start + SLOT_SECONDS,
                    audio_start=start - audio_start,
                    audio_end=start + SLOT_SECONDS - audio_start,
                    text=_passage_text(raw_manifest, label, "ov"),
                    overlap=True,
                )
            )

        participants.append(
            Participant(
                label=label,
                display_name=DISPLAY_NAMES[label],
                local=(label == "host"),
                join_grid=join,
                leave_grid=leave,
                audio_start_grid=audio_start,
                head_tone_hz=HEAD_TONES_HZ[label],
                turns=turns,
            )
        )
    return participants


def grid_end_seconds(scenario: Scenario) -> float:
    n = len(scenario.speakers)
    slots = scenario.rounds * n + (1 if scenario.overlap_pair else 0)
    return slots * SLOT_SECONDS


# ---------------------------------------------------------------------------
# Audio I/O — ffmpeg decodes, numpy computes, stdlib `wave` writes.
# Deliberately no soundfile/librosa: one binary dependency (ffmpeg), which the
# assembly step needs anyway.
# ---------------------------------------------------------------------------


class AudioError(RuntimeError):
    pass


def require_ffmpeg() -> None:
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            raise AudioError(f"{tool} not found on PATH — the assembler needs it")


def decode(path: Path, rate: int = SAMPLE_RATE) -> np.ndarray:
    """Decode any ffmpeg-readable file to mono float32 in [-1, 1] at `rate`."""
    proc = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(path),
            "-f", "s16le", "-acodec", "pcm_s16le",
            "-ac", "1", "-ar", str(rate), "-",
        ],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise AudioError(f"ffmpeg could not decode {path.name}: {proc.stderr.decode().strip()}")
    return np.frombuffer(proc.stdout, dtype="<i2").astype(np.float32) / 32768.0


def write_wav(path: Path, samples: np.ndarray, rate: int = SAMPLE_RATE) -> None:
    """Write mono 16-bit PCM. Chrome's fake device accepts nothing else."""
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm.tobytes())


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as src:
        if src.getsampwidth() != 2 or src.getnchannels() != 1:
            raise AudioError(
                f"{path.name}: expected mono 16-bit PCM, got "
                f"{src.getnchannels()}ch/{src.getsampwidth() * 8}-bit"
            )
        raw = src.readframes(src.getnframes())
        rate = src.getframerate()
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0, rate


def tone(freq_hz: float, seconds: float, amplitude: float = TONE_AMPLITUDE) -> np.ndarray:
    """A head tone, with 10 ms raised-cosine edges so the onset is a tone rather
    than a click — a click is broadband and would smear across every band the
    scorer looks in."""
    n = int(round(seconds * SAMPLE_RATE))
    t = np.arange(n, dtype=np.float64) / SAMPLE_RATE
    wave_ = np.sin(2 * np.pi * freq_hz * t) * amplitude
    edge = min(int(0.010 * SAMPLE_RATE), n // 2)
    if edge:
        ramp = 0.5 * (1 - np.cos(np.pi * np.arange(edge) / edge))
        wave_[:edge] *= ramp
        wave_[-edge:] *= ramp[::-1]
    return wave_.astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(round(seconds * SAMPLE_RATE)), dtype=np.float32)


def normalise_peak(samples: np.ndarray, dbfs: float = PASSAGE_PEAK_DBFS) -> np.ndarray:
    peak = float(np.max(np.abs(samples))) if samples.size else 0.0
    if peak <= 0:
        return samples
    return samples * (10 ** (dbfs / 20.0) / peak)


def rms(samples: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(samples)))) if samples.size else 0.0


def rms_envelope(samples: np.ndarray, window_s: float = 0.1, rate: int = SAMPLE_RATE) -> np.ndarray:
    win = max(1, int(round(window_s * rate)))
    usable = (samples.size // win) * win
    if usable == 0:
        return np.zeros(0, dtype=np.float32)
    return np.sqrt(np.mean(np.square(samples[:usable].reshape(-1, win)), axis=1))


def band_energy(samples: np.ndarray, freq_hz: float, rate: int = SAMPLE_RATE) -> tuple[float, float]:
    """Energy at `freq_hz` and the median energy elsewhere, by FFT.

    Returns `(in_band, out_of_band)`; their ratio is the tone's SNR. This is the
    ASR-free identification channel: a head tone is a fixed frequency per
    participant, and the frequencies are primes with no small-integer ratios
    between them, so no tone can be read as another's harmonic.
    """
    if samples.size < 1024:
        return 0.0, 0.0
    spectrum = np.abs(np.fft.rfft(samples * np.hanning(samples.size)))
    freqs = np.fft.rfftfreq(samples.size, 1 / rate)
    # ±2% window: wide enough for FFT leakage and codec warble, far narrower
    # than the gap to the next tone in the table.
    mask = np.abs(freqs - freq_hz) <= freq_hz * 0.02
    if not mask.any():
        return 0.0, 0.0
    speech_band = (freqs > 80) & (freqs < 4000) & ~mask
    out = float(np.median(spectrum[speech_band])) if speech_band.any() else 0.0
    return float(np.max(spectrum[mask])), out


def align_lag(
    captured: np.ndarray,
    reference: np.ndarray,
    hop_s: float = 0.1,
    max_lag_s: float = 180.0,
) -> tuple[float, float]:
    """Recover the fixed offset between a captured stream and its reference, by
    zero-lag cross-correlation of their RMS envelopes.

    Envelopes rather than raw samples on purpose: the captured copy has been
    through Opus and a jitter buffer, so it is nowhere near sample-identical to
    the file that produced it, but *when it is loud* survives all of that
    untouched. This is the measurement that caught the mic duplication, and it
    needs no ASR.

    Returns `(lag_seconds, normalised_peak)`. The peak is a correlation
    coefficient in [-1, 1]: near 1 means this reference explains this stream.
    """
    a = captured - captured.mean() if captured.size else captured
    b = reference - reference.mean() if reference.size else reference
    if a.size < 4 or b.size < 4:
        return 0.0, 0.0
    n = 1 << int(np.ceil(np.log2(a.size + b.size)))
    corr = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    corr = np.concatenate([corr[-(b.size - 1):], corr[: a.size]])
    lags = np.arange(-(b.size - 1), a.size) * hop_s
    keep = np.abs(lags) <= max_lag_s
    if not keep.any():
        return 0.0, 0.0
    corr, lags = corr[keep], lags[keep]
    norm = float(np.sqrt(np.sum(a**2) * np.sum(b**2)))
    if norm <= 0:
        return 0.0, 0.0
    best = int(np.argmax(corr))
    return float(lags[best]), float(corr[best] / norm)


# ---------------------------------------------------------------------------
# raw/ integrity
# ---------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load_raw_manifest() -> dict:
    if not RAW_MANIFEST.exists():
        raise AudioError(f"{RAW_MANIFEST} not found — run generate.py render first")
    return json.loads(RAW_MANIFEST.read_text())


def verify_raw(manifest: dict) -> None:
    """Fail loudly, by file name, on a missing or altered render.

    The corpus is only worth anything if a run recorded today can be re-scored
    against a new algorithm next month, and that needs the bytes to be the bytes
    the manifest describes. A silent mismatch would produce a short or
    misaligned WAV and score as an algorithm regression.
    """
    problems = []
    for name, entry in sorted(manifest["passages"].items()):
        path = RAW / name
        if not path.exists():
            problems.append(f"{name}: missing from {RAW}")
            continue
        actual = sha256_file(path)
        if actual != entry["sha256"]:
            problems.append(
                f"{name}: SHA-256 mismatch\n"
                f"    manifest {entry['sha256']}\n"
                f"    on disk  {actual}"
            )
    if problems:
        raise AudioError(
            "raw/ does not match raw/manifest.json:\n  " + "\n  ".join(problems)
        )


def corpus_fingerprint(manifest: dict) -> str:
    """Content hash of everything that changes an assembled WAV: the renders, the
    slot grid, the tone table and the scenario definitions. The assembler caches
    on this, so reassembly is free when nothing changed and impossible to skip
    when something did."""
    payload = {
        "schema": SCHEMA_VERSION,
        "passages": {k: v["sha256"] for k, v in sorted(manifest["passages"].items())},
        "grid": {
            "sample_rate": SAMPLE_RATE,
            "slot_seconds": SLOT_SECONDS,
            "tone_seconds": TONE_SECONDS,
            "tone_gap_seconds": TONE_GAP_SECONDS,
            "tone_amplitude": TONE_AMPLITUDE,
            "passage_peak_dbfs": PASSAGE_PEAK_DBFS,
            "preroll_seconds": PREROLL_SECONDS,
            "tail_seconds": TAIL_SECONDS,
            "loop_guard_seconds": LOOP_GUARD_SECONDS,
        },
        "tones": HEAD_TONES_HZ,
        "scenarios": {
            s.id: {
                "speakers": s.speakers,
                "rounds": s.rounds,
                "overlap_pair": list(s.overlap_pair) if s.overlap_pair else None,
                "schedule": {k: list(v) for k, v in sorted(s.schedule.items())},
                "skip_rounds": s.skip_rounds,
            }
            for s in SCENARIOS.values()
        },
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
