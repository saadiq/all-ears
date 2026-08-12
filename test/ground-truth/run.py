# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "click>=8"]
# ///
"""Phase-1 runner: drive a ground-truth call on this machine, no container.

    uv run run.py probe --meet-url https://meet.google.com/xxx-yyyy-zzz
    uv run run.py scenario s1-solo --meet-url https://meet.google.com/xxx-yyyy-zzz

The convener (the user's own Brave, driven separately through Claude in Chrome)
creates the meeting and opens access. This runner launches only throwaway
browsers: the guests, and the instrumented participant carrying the extension.
It never touches the user's profile.

What a run produces, under `runs/<timestamp>-<scenario>/`:

- `run.json` — the scenario manifest with its `run` block filled in: actual join
  and leave instants, the resolved session id, browser and extension versions.
  The manifest and the session id travel together on purpose; an archived run is
  only re-scorable if they do.
- `ring.json` — Meet's per-tile speaking-ring activity as seen from the host
- `roster.json` — the host page's tile roster
- `*-browser.log`, `*-launch.json` — one per launched browser, argv included
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path

import click
import numpy as np

import browsers
import gtlib as gt
import sessions as store

WORK = gt.HERE / ".work"
EARSD_CONFIG = Path.home() / ".config" / "ears" / "config.toml"
BASE_PORT = 9310


def now() -> float:
    return time.time()


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def silent_wav(path: Path, seconds: float = 900.0) -> Path:
    """A long silent WAV for a participant that must be present but must not
    speak. Long enough that looping is impossible (see gtlib on `%noloop`)."""
    if not path.exists():
        gt.write_wav(path, gt.silence(seconds))
    return path


def extension_id(host: browsers.Browser) -> str | None:
    """The unpacked extension's id, as the browser assigned it.

    Worth asserting rather than assuming: `earsd`'s ingest and control sockets
    validate `Origin` against an allowlist and fail closed, so an id that does
    not match the config means the extension is running and recording nothing,
    which looks exactly like a capture bug.
    """
    targets = host.rodney("js", "1", check=False)  # ensure a session exists
    del targets
    raw = subprocess.run(
        ["curl", "-s", f"http://127.0.0.1:{host.port}/json/list"],
        capture_output=True, text=True, check=False,
    ).stdout
    try:
        for target in json.loads(raw):
            url = target.get("url", "")
            if url.startswith("chrome-extension://"):
                return url.split("/")[2]
    except (json.JSONDecodeError, IndexError):
        pass
    return None


def allowed_origins() -> list[str]:
    if not EARSD_CONFIG.exists():
        return []
    config = tomllib.loads(EARSD_CONFIG.read_text())
    out = []
    for key in ("ingest_ws", "control_ws"):
        out.extend(config.get("earsd", {}).get(key, {}).get("allowed_origins", []))
    return out


def check_extension_origin(host: browsers.Browser, report: dict) -> None:
    ident = extension_id(host)
    origins = allowed_origins()
    report["extension_id"] = ident
    report["earsd_allowed_origins"] = origins
    if ident is None:
        report["extension_origin_ok"] = None
        click.echo("  ! could not read the extension id from the browser", err=True)
        return
    ok = any(ident in origin for origin in origins)
    report["extension_origin_ok"] = ok
    if not ok:
        raise browsers.BrowserError(
            f"extension id chrome-extension://{ident} is not in earsd's allowlist "
            f"{origins}. earsd fails closed on Origin, so this run would record no "
            "browser audio at all while looking like a capture bug. Add it to "
            f"{EARSD_CONFIG} under [earsd.ingest_ws] and [earsd.control_ws]."
        )



def note_observers(
    host: browsers.Browser, declared: set[str], convener_name: str | None
) -> list[str]:
    """Record every tile in the call that is not one of ours.

    **A signed-in participant must stay in the call.** Measured 2026-08-06 on a
    call whose access type is Open: an anonymous guest is admitted instantly
    while the signed-in convener is present, and is redirected to
    `workspace.google.com/products/meet/` when the only participants are
    anonymous — including when the instrumented host is already in. So the
    brief's "create the meeting, enable Quick access, and leave" does not hold:
    the convener has to sit in the call for the whole run.

    That makes the convener a real participant, so it is declared rather than
    ignored. The scorer treats a recorded observer as expected-but-not-scored,
    while still failing on an attendee that is neither declared nor recorded
    here — which is what keeps a genuinely unexpected joiner visible.

    **Have the convener join in Companion mode** ("Other ways to join" → "Use
    Companion mode"). Meet then reports "your speakers and mic are unavailable
    to avoid echo": it holds the call open and satisfies the signed-in-presence
    requirement while contributing no audio at all, which is exactly the
    property the corpus needs from it. A plain muted join works too, but leaves
    a live mic one stray click away from the ground truth.
    """
    roster = host.js(browsers.ROSTER_JS)
    observers = []
    if isinstance(roster, list):
        for tile in roster:
            name = (tile.get("text") or [""])[0]
            if name and name not in declared:
                observers.append(name)
    if convener_name and convener_name not in observers:
        observers.append(convener_name)
    if not observers:
        click.echo(
            "  ! no signed-in participant is in the call — anonymous guests will be "
            "refused. Have the convener join before continuing.",
            err=True,
        )
    else:
        click.echo(f"  observers holding the call open: {observers}")
    return observers


def _tile_names(browser: browsers.Browser) -> list[str]:
    """Display names currently on the host page's participant tiles."""
    roster = browser.js(browsers.ROSTER_JS)
    names = []
    if isinstance(roster, list):
        for tile in roster:
            text = tile.get("text") or []
            if text and text[0]:
                names.append(text[0])
    return names


def wait_for_session(since: datetime, timeout: float = 180.0) -> store.Session | None:
    """Poll the store for the session the extension declared for this call."""
    deadline = now() + timeout
    while now() < deadline:
        found = store.sessions_since(since)
        if found:
            return found[-1]
        time.sleep(2.0)
    return None


def wait_for_session_end(session_id: str, timeout: float = 300.0) -> store.Session | None:
    """Wait for the daemon to close the session, so `sources/` is flushed and
    indexed before anything reads it."""
    directory = store.DEFAULT_ROOT / "sessions" / session_id
    deadline = now() + timeout
    latest = None
    while now() < deadline:
        try:
            latest = store.load_session(directory)
        except Exception:
            time.sleep(2.0)
            continue
        if latest.record.get("state") == "ended":
            return latest
        time.sleep(3.0)
    return latest


# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.option("--meet-url", required=True, help="Meeting the convener created.")
@click.option("--host-browser", default="auto-host", help="chrome | brave | chromium")
@click.option("--guest-browser", default="auto-guest")
@click.option("--keep-open", is_flag=True, help="Leave the browsers running afterwards.")
@click.option("--convener", "convener_name", default=None,
              help="Display name of the signed-in participant holding the call open.")
def probe(meet_url: str, host_browser: str, guest_browser: str, keep_open: bool,
          convener_name: str | None) -> None:
    """Tone-viability probe: one guest, tones plus a speech control, three checks.

    Runs before any scenario because its result can change the corpus design:
    if a sine tone does not survive Meet, the head tones in the corpus need
    rethinking and a tones-only cheap mode is off the table.
    """
    schedule = json.loads((gt.HERE / "probe" / "tone-probe.json").read_text())
    wav = gt.HERE / schedule["wav"]
    if not wav.exists():
        raise click.ClickException(f"{wav} missing — run `uv run probe.py wav` first")
    if gt.sha256_file(wav) != schedule["wav_sha256"]:
        raise click.ClickException(f"{wav} does not match its schedule's SHA-256")

    out = gt.RUNS / f"{stamp()}-probe"
    out.mkdir(parents=True)
    WORK.mkdir(exist_ok=True)
    report: dict = {
        "kind": "tone-viability-probe",
        "schema": gt.SCHEMA_VERSION,
        "meet_url": meet_url,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "schedule": schedule,
    }

    click.echo("preflight: proving the fake device reads its file at all")
    report["preflight"] = browsers.preflight(WORK)
    click.echo(f"  ok — {report['preflight']['observed_hz']} Hz at RMS {report['preflight']['peak_rms']:.4f}")

    since = datetime.now(timezone.utc)
    host = guest = None
    try:
        click.echo("launching the instrumented participant (extension + earsd behind it)")
        host, joined = browsers.launch_and_join(
            "host", WORK, BASE_PORT, meet_url, "GT-Host",
            wav=silent_wav(WORK / "silence.wav"),
            binary=browsers.resolve_binary(host_browser),
            extension=browsers.EXTENSION,
        )
        report["host_browser"] = str(host.binary)
        report["host_join"] = joined
        report["host_admitted"] = joined
        check_extension_origin(host, report)
        click.echo(f"  extension {report['extension_id']} — origin allowed")
        click.echo(f"  host is in the call (attempt {joined['join_attempts']})")
        report["observers"] = note_observers(host, {"GT-Host"}, convener_name)
        host.js(browsers.RING_OBSERVER_JS)

        click.echo("launching the probe guest")
        guest, guest_joined = browsers.launch_and_join(
            "probe-guest", WORK, BASE_PORT + 1, meet_url, schedule["display_name"],
            wav=wav, binary=browsers.resolve_binary(guest_browser),
        )
        # The fake file starts at the page's first getUserMedia, i.e. this
        # browser's launch — and a retry relaunches, so read it off the browser
        # that actually got in rather than off the first one tried.
        guest_audio_start = guest.launched_at
        report["guest_browser"] = str(guest.binary)
        report["guest_join"] = guest_joined
        report["guest_admitted"] = guest_joined
        report["guest_audio_start_epoch"] = guest_audio_start
        click.echo(f"  guest admitted {report['guest_admitted']['admitted_at'] - guest_audio_start:.1f}s "
                   f"after its audio started (preroll {schedule['preroll_seconds']:.0f}s)")

        duration = schedule["duration_seconds"]
        remaining = guest_audio_start + duration + 5 - now()
        click.echo(f"  holding the call for {remaining:.0f}s while the probe WAV plays")
        _hold(host, remaining)

        report["ring"] = host.js(browsers.RING_DUMP_JS)
        report["roster"] = host.js(browsers.ROSTER_JS)
        (out / "ring.json").write_text(json.dumps(report["ring"], indent=2) + "\n")
        (out / "roster.json").write_text(json.dumps(report["roster"], indent=2) + "\n")

        report["guest_left_at"] = browsers.leave_meet(guest)
        time.sleep(2)
        report["host_left_at"] = browsers.leave_meet(host)
    finally:
        if not keep_open:
            for browser in (guest, host):
                if browser is not None:
                    browser.close()
        for name in ("host", "probe-guest", "preflight"):
            log = WORK / f"{name}-browser.log"
            if log.exists():
                shutil.copy(log, out / log.name)
            launch_record = WORK / f"{name}-launch.json"
            if launch_record.exists():
                shutil.copy(launch_record, out / launch_record.name)

    click.echo("waiting for earsd to close the session")
    session = wait_for_session(since)
    if session is None:
        report["session"] = None
        click.echo("  ! no session appeared — the extension never declared one", err=True)
    else:
        ended = wait_for_session_end(session.id) or session
        report["session"] = {
            "id": ended.id,
            "directory": str(ended.directory),
            "title": ended.title,
            "external_id": ended.external_id,
            "state": ended.record.get("state"),
            "sources": ended.record.get("sources", []),
            "attendees": [
                {"id": a.id, "display_name": a.display_name,
                 "joined": a.joined.isoformat() if a.joined else None,
                 "left": a.left.isoformat() if a.left else None,
                 "source": a.source}
                for a in ended.attendees
            ],
        }
        click.echo(f"  session {ended.id} — sources {ended.record.get('sources', [])}")

    (out / "probe.json").write_text(json.dumps(report, indent=2, default=str) + "\n")
    click.echo(f"\nrun record → {out}")
    click.echo(f"analyse with: uv run probe_report.py {out}")


def _hold(browser: browsers.Browser, seconds: float) -> None:
    """Sleep, keeping the page alive and noticing if it dies."""
    deadline = now() + seconds
    while now() < deadline:
        time.sleep(min(15.0, max(0.0, deadline - now())))
        if not browser.alive():
            raise browsers.BrowserError(f"{browser.label} exited mid-call")


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------


@cli.command()
@click.argument("scenario_id")
@click.option("--meet-url", required=True)
@click.option("--host-browser", default="auto-host")
@click.option("--guest-browser", default="auto-guest")
@click.option("--keep-open", is_flag=True)
@click.option("--convener", "convener_name", default=None,
              help="Deprecated: no longer needed now participants sign in.")
@click.option("--profile", "profile_map", multiple=True, metavar="LABEL=DIR",
              help="Run this participant from a signed-in profile under .profiles/.")
def scenario(scenario_id: str, meet_url: str, host_browser: str, guest_browser: str,
             keep_open: bool, convener_name: str | None,
             profile_map: tuple[str, ...]) -> None:
    """Run one scenario end to end and write its run record."""
    manifest_path = gt.MANIFESTS / f"{scenario_id}.json"
    if not manifest_path.exists():
        raise click.ClickException(f"{manifest_path} missing — run `uv run assemble.py build`")
    manifest = json.loads(manifest_path.read_text())
    # label -> signed-in profile directory. Anonymous join is no longer
    # available, so a participant without a profile here can only join a call
    # that still permits anonymous guests.
    profiles = dict(entry.split("=", 1) for entry in profile_map)

    out = gt.RUNS / f"{stamp()}-{scenario_id}"
    out.mkdir(parents=True)
    WORK.mkdir(exist_ok=True)

    run: dict = {
        "meet_url": meet_url,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "host_machine": subprocess.run(["uname", "-mrs"], capture_output=True, text=True).stdout.strip(),
        "extension_version": json.loads(
            (browsers.EXTENSION / "manifest.json").read_text()
        ).get("version"),
        "participants": {},
        "notes": [],
    }

    click.echo("preflight")
    run["preflight"] = browsers.preflight(WORK)

    since = datetime.now(timezone.utc)
    launched: dict[str, browsers.Browser] = {}
    grid_zero: float | None = None

    try:
        # The instrumented participant first: it must be in the call before any
        # guest, so the extension is capturing from the first remote track.
        local = next(p for p in manifest["participants"] if p["role"] == "local")
        host_profile = profiles.get(local["label"])
        host, joined = browsers.launch_and_join(
            local["label"], WORK, BASE_PORT, meet_url,
            # A signed-in profile has no name field: Meet supplies the name, so
            # the ground-truth label moves from "the name we typed" to "which
            # profile played which WAV". The runner owns that mapping, so the
            # truth is still by construction — it just has to be recorded.
            "" if host_profile else local["display_name"],
            wav=gt.HERE / local["wav"],
            binary=browsers.resolve_binary(host_browser),
            extension=browsers.EXTENSION,
            profile=browsers.PROFILES / host_profile if host_profile else None,
        )
        launched[local["label"]] = host
        host_audio_start = host.launched_at
        run["host_browser"] = str(host.binary)
        check_extension_origin(host, run)
        run["participants"][local["label"]] = {
            "display_name": local["display_name"],
            "signed_in_profile": host_profile,
            "audio_start_epoch": host_audio_start,
            "join": joined,
            "admitted_at_epoch": joined["admitted_at"],
        }
        admitted = joined
        # The convener role is gone (a signed-in participant revives a dormant
        # call by itself), so there is nothing to declare as an observer. What
        # is worth recording is the host's OWN tile name: a signed-in profile
        # shows its Google account name rather than the label we declared, and
        # the scorer needs to know which is which. It lands only in run.json,
        # which is gitignored.
        run["observers"] = []
        # Read the roster while the host is alone: whatever name is here is the
        # host's own, which is what makes a later new name attributable.
        known_names = set(_tile_names(host))
        if known_names:
            run["participants"][local["label"]]["observed_display_name"] = sorted(known_names)[0]
        host.js(browsers.RING_OBSERVER_JS)

        # Grid t=0 is the host's audio start plus its preroll: everything in the
        # manifest is stated against that instant.
        grid_zero = host_audio_start + gt.PREROLL_SECONDS
        run["grid_zero_epoch"] = grid_zero
        click.echo(f"  grid t=0 in {grid_zero - now():.0f}s")

        guests = [p for p in manifest["participants"] if p["role"] != "local"]
        port = BASE_PORT + 1
        pending = sorted(guests, key=lambda p: p["audio_start_grid_seconds"])
        leaves = [
            (p["label"], p["intended_leave_grid_seconds"])
            for p in guests
            if p["intended_leave_grid_seconds"] is not None
        ]

        # One event loop: launch each guest when its own audio is due to start,
        # and hang up each departure when the grid says so. Every actual instant
        # is recorded — the intended times are the scenario, the actual ones are
        # what happened, and s4 exists to make the difference visible.
        deadline = grid_zero + manifest["grid"]["grid_end_seconds"] + gt.TAIL_SECONDS
        while now() < deadline:
            elapsed = now() - grid_zero
            while pending and elapsed >= pending[0]["audio_start_grid_seconds"]:
                spec = pending.pop(0)
                click.echo(f"  [{elapsed:6.1f}s] launching {spec['display_name']}")
                guest_profile = profiles.get(spec["label"])
                guest, state = browsers.launch_and_join(
                    spec["label"], WORK, port, meet_url,
                    "" if guest_profile else spec["display_name"],
                    wav=gt.HERE / spec["wav"],
                    binary=browsers.resolve_binary(guest_browser),
                    profile=browsers.PROFILES / guest_profile if guest_profile else None,
                )
                port += 1
                launched[spec["label"]] = guest
                entry = {
                    "display_name": spec["display_name"],
                    "signed_in_profile": guest_profile,
                    "audio_start_epoch": guest.launched_at,
                    "audio_start_grid_seconds": guest.launched_at - grid_zero,
                    "join": state,
                }
                entry["admitted_at_epoch"] = state["admitted_at"]
                entry["admitted_grid_seconds"] = state["admitted_at"] - grid_zero
                # A signed-in guest shows its Google account name, not the label
                # we declared, so the expected roster name has to be OBSERVED.
                # The newly-appeared tile is this guest's: the mapping stays
                # ground truth because the runner owns which profile plays which
                # WAV, it is just recorded rather than declared.
                if guest_profile:
                    seen_now = _tile_names(host)
                    fresh = [n for n in seen_now if n not in known_names]
                    if fresh:
                        entry["observed_display_name"] = fresh[0]
                        known_names.update(fresh)
                late = entry["admitted_grid_seconds"] - spec["intended_join_grid_seconds"]
                entry["admission_lateness_seconds"] = late
                if state["admitted_at"] > guest.launched_at + gt.PREROLL_SECONDS:
                    run["notes"].append(
                        f"{spec['label']}: admitted after its {gt.PREROLL_SECONDS:.0f}s preroll "
                        "expired — the front of its schedule was spoken to an empty room"
                    )
                run["participants"][spec["label"]] = entry

            for label, at in list(leaves):
                if elapsed >= at:
                    leaves.remove((label, at))
                    click.echo(f"  [{elapsed:6.1f}s] {label} leaving")
                    left = browsers.leave_meet(launched[label])
                    run["participants"][label]["left_at_epoch"] = left
                    run["participants"][label]["left_grid_seconds"] = left - grid_zero
            time.sleep(1.0)

        run["ring"] = host.js(browsers.RING_DUMP_JS)
        run["roster"] = host.js(browsers.ROSTER_JS)
        (out / "ring.json").write_text(json.dumps(run["ring"], indent=2) + "\n")
        (out / "roster.json").write_text(json.dumps(run["roster"], indent=2) + "\n")

        for label, browser in launched.items():
            if "left_at_epoch" not in run["participants"].get(label, {}):
                run["participants"].setdefault(label, {})["left_at_epoch"] = browsers.leave_meet(browser)
            time.sleep(0.5)
    finally:
        if not keep_open:
            for browser in launched.values():
                browser.close()
        for path in WORK.glob("*-browser.log"):
            shutil.copy(path, out / path.name)
        for path in WORK.glob("*-launch.json"):
            shutil.copy(path, out / path.name)

    click.echo("waiting for earsd to close the session")
    session = wait_for_session(since)
    if session is not None:
        ended = wait_for_session_end(session.id) or session
        run["session_id"] = ended.id
        run["session_dir"] = str(ended.directory)
        run["session_state"] = ended.record.get("state")
        run["session_sources"] = ended.record.get("sources", [])
        click.echo(f"  session {ended.id} — sources {run['session_sources']}")
    else:
        run["session_id"] = None
        run["notes"].append("no session appeared: the extension never declared one")
        click.echo("  ! no session appeared", err=True)

    # Drift check: the guard band is what keeps slots disjoint when browsers
    # start at slightly different moments. Past it, the corpus's core property
    # is gone and the scores would be measuring the runner, not the pipeline.
    starts = [
        p["audio_start_epoch"] - grid_zero - _declared_audio_start(manifest, label)
        for label, p in run["participants"].items()
        if "audio_start_epoch" in p
    ]
    if starts:
        drift = max(starts) - min(starts)
        run["audio_start_drift_seconds"] = drift
        guard = manifest["grid"]["guard_seconds"]
        if drift > guard:
            run["notes"].append(
                f"audio-start drift {drift:.2f}s exceeds the {guard:.2f}s guard band — "
                "scheduled slots may have collided; treat timing scores with suspicion"
            )
        click.echo(f"  audio-start drift {drift:.2f}s (guard {guard:.2f}s)")

    manifest["run"] = run
    (out / "run.json").write_text(json.dumps(manifest, indent=2, default=str) + "\n")
    click.echo(f"\nrun record → {out}")
    click.echo(f"score with:  uv run score.py {out}")


def _declared_audio_start(manifest: dict, label: str) -> float:
    for p in manifest["participants"]:
        if p["label"] == label:
            return p["audio_start_grid_seconds"]
    return 0.0


if __name__ == "__main__":
    cli()
