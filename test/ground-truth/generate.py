# /// script
# requires-python = ">=3.11"
# dependencies = ["elevenlabs>=2", "click>=8", "python-dotenv>=1"]
# ///
"""Render the ground-truth corpus passages to MP3 via the ElevenLabs API.

One file per passage, not per speaker: the harness places each passage at a slot
boundary itself, and per-passage files remove any dependence on the TTS honouring
paragraph breaks.
"""

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path

import click
from dotenv import find_dotenv, load_dotenv
from elevenlabs import VoiceSettings
from elevenlabs.client import ElevenLabs

HERE = Path(__file__).parent
SCRIPTS = HERE / "scripts"
RAW = HERE / "raw"
VOICES_FILE = HERE / "voices.json"
MANIFEST = HERE / "raw" / "manifest.json"

SPEAKERS = ["host", "alpha", "bravo", "charlie"]
LABELS = ["p1", "p2", "p3", "p4", "ov"]

# Alpha and Bravo deliberately share one voice: separation must come from the
# per-participant source, not from the audio sounding different. Host and Charlie
# stay distinct, so a run that fails only on the shared pair localises the fault.
# They are also not the overlap pair — see gt-scripts.md — so a shared voice and
# simultaneous speech are never tested in the same block.
SHARED_PAIR = ("alpha", "bravo")
MODEL = "eleven_multilingual_v2"
OUTPUT_FORMAT = "mp3_44100_128"
SEED = 20260806

# Pinned so a re-render is byte-comparable. Style stays at 0 — style exaggeration
# is the least reproducible knob in the API.
SETTINGS = VoiceSettings(stability=0.5, similarity_boost=0.75, style=0.0, use_speaker_boost=True)


@dataclass(frozen=True)
class Passage:
    speaker: str
    label: str
    text: str

    @property
    def name(self) -> str:
        return f"{self.speaker}-{self.label}.mp3"


def load_passages() -> list[Passage]:
    passages = []
    for speaker in SPEAKERS:
        blocks = [b.strip() for b in (SCRIPTS / f"{speaker}.txt").read_text().split("\n\n") if b.strip()]
        if len(blocks) != len(LABELS):
            raise click.ClickException(
                f"{speaker}.txt has {len(blocks)} passages, expected {len(LABELS)} "
                f"(blank line between each)"
            )
        passages.extend(Passage(speaker, label, text) for label, text in zip(LABELS, blocks))
    return passages


def fingerprint(passage: Passage, voice_id: str) -> str:
    """Everything that changes the audio. A mismatch means re-render."""
    payload = json.dumps(
        {
            "text": passage.text,
            "voice_id": voice_id,
            "model": MODEL,
            "output_format": OUTPUT_FORMAT,
            "seed": SEED,
            "settings": SETTINGS.dict(),
        },
        sort_keys=True,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def client() -> ElevenLabs:
    key = (os.environ.get("ELEVENLABS_API_KEY") or "").strip()
    if not key:
        raise click.ClickException("ELEVENLABS_API_KEY is not set — see --env-file")
    return ElevenLabs(api_key=key)


@click.group()
@click.option(
    "--env-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Read ELEVENLABS_API_KEY from here. Default: .env beside this script, then upward from cwd.",
)
def cli(env_file):
    load_dotenv(env_file or HERE / ".env")
    load_dotenv(find_dotenv(usecwd=True))


@cli.command()
def voices():
    """List the account's voices, so you can pick four and write voices.json."""
    for voice in client().voices.search().voices:
        labels = ", ".join(f"{k}={v}" for k, v in (voice.labels or {}).items())
        click.echo(f"{voice.voice_id}  {voice.name:<24} {labels}")
    a, b = SHARED_PAIR
    click.echo(f"\nWrite three ids to {VOICES_FILE} — {a} and {b} share one on purpose:")
    click.echo(json.dumps({s: f"VOICE_ID_{'SHARED' if s in SHARED_PAIR else s.upper()}" for s in SPEAKERS}, indent=2))


@cli.command()
@click.option("--force", is_flag=True, help="Re-render passages that are already current.")
def render(force):
    """Render every passage that is missing or out of date."""
    if not VOICES_FILE.exists():
        raise click.ClickException(f"{VOICES_FILE} not found — run `voices` first")
    voice_ids = json.loads(VOICES_FILE.read_text())
    missing = [s for s in SPEAKERS if s not in voice_ids]
    if missing:
        raise click.ClickException(f"voices.json is missing: {', '.join(missing)}")
    a, b = SHARED_PAIR
    if voice_ids[a] != voice_ids[b]:
        raise click.ClickException(f"{a} and {b} must share one voice id — that pairing is the test")
    if len(set(voice_ids.values())) != 3:
        raise click.ClickException(
            f"expected 3 distinct voice ids across 4 speakers ({a}/{b} shared), "
            f"got {len(set(voice_ids.values()))}"
        )

    RAW.mkdir(exist_ok=True)
    previous = json.loads(MANIFEST.read_text()).get("passages", {}) if MANIFEST.exists() else {}
    api = client()
    manifest = {}

    for passage in load_passages():
        voice_id = voice_ids[passage.speaker]
        want = fingerprint(passage, voice_id)
        out = RAW / passage.name
        entry = previous.get(passage.name)

        if not force and out.exists() and entry and entry["fingerprint"] == want:
            manifest[passage.name] = entry
            click.echo(f"  cached  {passage.name}")
        else:
            audio = api.text_to_speech.convert(
                text=passage.text,
                voice_id=voice_id,
                model_id=MODEL,
                output_format=OUTPUT_FORMAT,
                voice_settings=SETTINGS,
                seed=SEED,
            )
            out.write_bytes(b"".join(audio))
            manifest[passage.name] = {
                "speaker": passage.speaker,
                "label": passage.label,
                "text": passage.text,
                "voice_id": voice_id,
                "fingerprint": want,
                "sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
            }
            click.echo(f"  wrote   {passage.name}  ({out.stat().st_size:,} bytes)")

    MANIFEST.write_text(
        json.dumps(
            {
                "model": MODEL,
                "output_format": OUTPUT_FORMAT,
                "seed": SEED,
                "voice_settings": SETTINGS.dict(),
                "voices": voice_ids,
                "passages": manifest,
            },
            indent=2,
        )
        + "\n"
    )
    click.echo(f"\n{len(manifest)} passages → {RAW}\nmanifest → {MANIFEST}")


if __name__ == "__main__":
    cli()
