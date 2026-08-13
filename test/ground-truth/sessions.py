# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2"]
# ///
"""Read `earsd`'s audio store the way every other tool does — straight off disk.

`docs/architecture.md` makes the on-disk layout the read API: the daemon owns
writes and is never in the read path, so a scorer needs no daemon running, no
socket, and no cooperation from the capture side. That is what makes an archived
run re-scorable against a new algorithm months later — the property this whole
harness exists to buy.

Everything here is therefore a pure function of a `sessions/<uuid>/` directory:

- `session.toml` (schema 3) — roster, reconciled speaker map, and source list
- `events.jsonl` — attendee_joined / attendee_left, directly scorable against a
  scenario manifest
- `sources/<id>/chunks.jsonl` + `chunks/` — the structural index and the
  native-rate audio it names
- `sources/<id>/vad/*.jsonl` — speech/silence spans
"""

from __future__ import annotations

import json
import os
import subprocess
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

#: Where to read the audio store from. Overridable with `GT_DATA_ROOT` so a run
#: against an isolated daemon (its own data_root, so a synthetic call can never
#: reach the user's real store or publishing config) is still readable by the
#: runner and the scorer.
DEFAULT_ROOT = Path(
    os.environ.get("GT_DATA_ROOT")
    or Path.home() / "Library" / "Application Support" / "ears"
)
SAMPLE_RATE = 48_000


def parse_time(value: str) -> datetime | None:
    """Parse the store's timestamps, which appear in two spellings: ISO-8601
    with colons inside files, and colon-for-dash in file *names*."""
    if not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        pass
    # 2026-07-17T10-30-00Z — the filename spelling
    try:
        date, _, clock = value.rstrip("Z").partition("T")
        return datetime.fromisoformat(f"{date}T{clock.replace('-', ':')}+00:00")
    except ValueError:
        return None


@dataclass
class Chunk:
    start: datetime
    end: datetime
    file: Path
    frames: int


@dataclass
class Gap:
    start: datetime
    end: datetime
    reason: str


@dataclass
class Span:
    state: str
    start: datetime
    end: datetime


@dataclass
class Source:
    id: str
    directory: Path
    chunks: list[Chunk] = field(default_factory=list)
    gaps: list[Gap] = field(default_factory=list)
    spans: list[Span] = field(default_factory=list)
    meta: dict = field(default_factory=dict)

    @property
    def speech(self) -> list[Span]:
        return [s for s in self.spans if s.state == "speech"]

    @property
    def first_audio(self) -> datetime | None:
        return self.chunks[0].start if self.chunks else None

    def decode(self, feed: str = "chunks") -> tuple[np.ndarray, datetime]:
        """Reconstruct this source's audio on one continuous timeline.

        Chunks are laid down at their indexed start instants, not concatenated:
        a pushed browser stream goes quiet whenever its speaker does, and the
        daemon records the quiet as a `gap` rather than as audio. Concatenating
        would squeeze those silences out and slide every later slot earlier —
        which is precisely the misattribution the timing score is looking for.
        """
        if not self.chunks:
            return np.zeros(0, dtype=np.float32), datetime.now(timezone.utc)
        origin = self.chunks[0].start
        end = max(c.end for c in self.chunks)
        total = int((end - origin).total_seconds() * SAMPLE_RATE) + SAMPLE_RATE
        buf = np.zeros(total, dtype=np.float32)
        for chunk in self.chunks:
            path = chunk.file
            if feed == "asr":
                candidate = self.directory / "asr" / chunk.file.name
                if candidate.exists():
                    path = candidate
            if not path.exists():
                continue
            samples = _decode_file(path)
            at = int((chunk.start - origin).total_seconds() * SAMPLE_RATE)
            stop = min(at + samples.size, buf.size)
            if stop > at:
                buf[at:stop] = samples[: stop - at]
        return buf, origin


def _decode_file(path: Path) -> np.ndarray:
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1",
         "-ar", str(SAMPLE_RATE), "-"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return np.zeros(0, dtype=np.float32)
    return np.frombuffer(proc.stdout, dtype="<i2").astype(np.float32) / 32768.0


@dataclass
class Attendee:
    id: str
    display_name: str
    joined: datetime | None
    left: datetime | None
    source: str
    #: "platform" | "synthetic" | "" (unknown — files from before the field
    #: existed). Synthetic rows are capture track handles (`t3`), not people.
    origin: str = ""


@dataclass
class Speaker:
    """One `[[speaker]]` row: the reconciled source → name map transcription
    labels turns with. Source ids are opaque track handles, so this map — not
    the label — is where attribution lives (docs/data-formats.md)."""

    source: str
    name: str
    confidence: str


@dataclass
class Session:
    id: str
    directory: Path
    record: dict
    attendees: list[Attendee]
    speakers: list[Speaker]
    events: list[dict]
    sources: dict[str, Source]

    @property
    def started(self) -> datetime | None:
        return parse_time(self.record.get("started", ""))

    @property
    def ended(self) -> datetime | None:
        return parse_time(self.record.get("ended", ""))

    @property
    def title(self) -> str:
        return self.record.get("title", "")

    @property
    def external_id(self) -> str:
        return self.record.get("external_id", "")

    def browser_sources(self) -> dict[str, Source]:
        return {k: v for k, v in self.sources.items() if k.startswith("browser:")}


def load_session(directory: Path) -> Session:
    record = tomllib.loads((directory / "session.toml").read_text())
    if record.get("schema") != 3:
        raise ValueError(
            f"{directory}: session.toml schema {record.get('schema')}, expected 3 — "
            "refusing to guess (docs/data-formats.md)"
        )

    attendees = [
        Attendee(
            id=a.get("id", ""),
            display_name=a.get("display_name", ""),
            joined=parse_time(a.get("joined", "")),
            left=parse_time(a.get("left", "")),
            source=a.get("source", ""),
            origin=a.get("origin", ""),
        )
        for a in record.get("attendee", [])
    ]

    speakers = [
        Speaker(
            source=s.get("source", ""),
            name=s.get("name", ""),
            confidence=s.get("confidence", ""),
        )
        for s in record.get("speaker", [])
    ]

    events = []
    events_path = directory / "events.jsonl"
    if events_path.exists():
        for line in events_path.read_text().splitlines():
            if line.strip():
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

    sources: dict[str, Source] = {}
    source_root = directory / "sources"
    if source_root.exists():
        for path in sorted(source_root.iterdir()):
            if path.is_dir():
                source = _load_source(path)
                sources[source.id] = source
    return Session(directory.name, directory, record, attendees, speakers, events, sources)


def _load_source(directory: Path) -> Source:
    meta = {}
    meta_path = directory / "meta.toml"
    if meta_path.exists():
        meta = tomllib.loads(meta_path.read_text())
    # The directory name has path-unsafe characters replaced by `_`; meta.toml
    # keeps the id in its natural form, so prefer it.
    source = Source(id=meta.get("id", directory.name), directory=directory, meta=meta)

    index = directory / "chunks.jsonl"
    if index.exists():
        for line in index.read_text().splitlines():
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            start, end = parse_time(event.get("start", "")), parse_time(event.get("end", ""))
            if start is None or end is None:
                continue
            if event.get("t") == "chunk":
                source.chunks.append(
                    Chunk(start, end, directory / event["file"], int(event.get("frames", 0)))
                )
            elif event.get("t") == "gap":
                source.gaps.append(Gap(start, end, event.get("reason", "")))

    vad_dir = directory / "vad"
    if vad_dir.exists():
        for path in sorted(vad_dir.glob("*.jsonl")):
            for line in path.read_text().splitlines():
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                start, end = parse_time(event.get("start", "")), parse_time(event.get("end", ""))
                if event.get("t") == "vad" and start and end:
                    source.spans.append(Span(event.get("state", ""), start, end))
    source.chunks.sort(key=lambda c: c.start)
    source.spans.sort(key=lambda s: s.start)
    return source


def sessions_since(moment: datetime, root: Path = DEFAULT_ROOT) -> list[Session]:
    """Every session that started at or after `moment`, oldest first.

    How a run finds its own session: the runner stamps the instant before it
    launches anything, and the extension declares the session when the
    instrumented host joins. Matching on time rather than on a meeting code
    keeps it working when the daemon titles the session from a scraped name.
    """
    found = []
    root = root / "sessions"
    if not root.exists():
        return found
    for directory in sorted(root.iterdir()):
        if not (directory / "session.toml").exists():
            continue
        try:
            session = load_session(directory)
        except Exception:
            continue
        started = session.started
        if started and started >= moment:
            found.append(session)
    return sorted(found, key=lambda s: s.started or datetime.min.replace(tzinfo=timezone.utc))
