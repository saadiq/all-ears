# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8"]
# ///
"""Launching and driving the harness's browsers.

Two roles, deliberately split (see README):

- **Convener** — the user's own Brave, attached to through the Claude in Chrome
  extension, only to create the meeting and open access. Nothing here touches
  it: this module never launches, flags, or reads that profile.
- **Launched participants** — guests and the instrumented host, each on a
  throwaway ``--user-data-dir`` with the fake-device flags. Driven through
  ``rodney connect`` against the debugging port we opened ourselves, each with
  its own ``RODNEY_HOME`` so concurrent sessions cannot collide and the user's
  global ``~/.rodney`` is never touched.

Three environment facts this module encodes, all measured rather than assumed
(macOS 15.5 arm64, 2026-08-06):

1. **Google Chrome is not installed on this machine**, and Brave cannot join a
   Meet call anonymously at all. Chromium 150.0.7871.46 and Brave 151.1.93.129
   are installed, both native arm64; only Chromium can be a participant, so both
   roles use it. See ``resolve_binary`` for the evidence. Brave Shields, which
   the brief flags as the risk in a Brave run, never came into it.

2. **The fake audio file is not read unless the audio-service sandbox is
   off.** Without ``--disable-features=AudioServiceSandbox`` the fake device
   appears, delivers frames at the right rate, and every sample is digital
   zero — it fails *silently*, which is the exact failure mode the corpus
   verification exists to prevent. ``preflight`` asserts against it before a
   run rather than discovering it in the scores.

3. **``%noloop`` has no effect** on either build (see ``gtlib``). The flag is
   still passed; nothing depends on it.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import click

CHROMIUM = Path("/Applications/Chromium.app/Contents/MacOS/Chromium")
BRAVE = Path("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

EXTENSION = Path(__file__).resolve().parents[2] / "browser" / ".output" / "chrome-mv3"

#: Persistent, manually-signed-in browser profiles — the brief's stated fallback
#: for when anonymous join is unavailable. Never wiped by ``launch``, never
#: committed (they hold live Google session cookies), and never written to by
#: anything here: a human signs in once, by hand, in a browser launched with no
#: debugging port and no automation flags.
#:
#: **What this costs.** An anonymous guest types its own display name, so the
#: roster label is ground truth by construction. A signed-in guest shows its
#: Google account name instead, which we neither control nor should change. The
#: ground truth therefore moves from "the name typed at join" to "which profile
#: played which WAV" — still by construction, since the runner owns that
#: mapping, but the runner must now RECORD the observed display name rather than
#: declare it.
PROFILES = Path(__file__).resolve().parent / ".profiles"

# Meet gates anonymous join on the user agent, and neither browser here passes.
# Measured 2026-08-06 against a call whose access type is Open ("This call is
# open to anyone"):
#
#   Chromium 150, own UA   → redirected to workspace.google.com marketing
#   Brave 151, own UA      → "You can't join this video call" +
#                            "This browser version is no longer supported"
#   Chromium 150, this UA  → the anonymous pre-join screen: "What's your name?"
#
# So the anonymous-guest design in the brief works — it just needs a UA Meet
# recognises. This is a presentation-layer override only: the engine, the media
# stack and the extension are untouched, and nothing in the capture path reads
# `navigator.userAgent`. It is also arguably *more* faithful than the default,
# since it gets the same Meet build a stock Chrome user is served.
CHROME_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
)


class BrowserError(RuntimeError):
    pass


def force_english(url: str) -> str:
    """Pin Meet's UI language to English.

    Every selector here matches on visible button text ("Join now", "Leave
    call", "Allow microphone"), which makes the whole join path silently
    locale-dependent. A second Google account whose locale is German rendered
    "Jetzt teilnehmen" instead, so the pre-join detector found neither a name
    field nor a join button and sat in `waiting` until it timed out — a failure
    that looks exactly like Meet refusing the join.

    Pinning `hl=en` is the fix rather than translating the selectors: the set of
    languages is unbounded, and matching obfuscated class tokens instead is
    exactly what journal #118 warns against.
    """
    if "meet.google.com" not in url:
        return url
    parsed = urlparse(url)
    query = dict(parse_qsl(parsed.query))
    query["hl"] = "en"
    return urlunparse(parsed._replace(query=urlencode(query)))


def resolve_binary(name: str) -> Path:
    """Pick a browser binary by role name, preferring Chrome when it exists."""
    table = {"chrome": CHROME, "brave": BRAVE, "chromium": CHROMIUM}
    # Brave is deliberately last for both roles, Chrome first for both.
    #
    # Brave cannot join a Meet call anonymously at all (measured 2026-08-06,
    # Brave 151.1.93.129): its own UA gets "You can't join this video call" plus
    # "This browser version is no longer supported", and overriding
    # `--user-agent` to a stock Chrome string does not help — the flag does not
    # touch `navigator.userAgentData`, which still reports Brave. So the brief's
    # preference order (Chrome, then Brave, then Chromium) inverts here on
    # evidence: with no Chrome installed, Chromium is the only browser that can
    # be an anonymous participant. Brave Shields never even came into it.
    if name in ("auto-guest", "auto-host"):
        candidates = [CHROME, CHROMIUM, BRAVE]
    else:
        candidates = [table[name]]
    for path in candidates:
        if path.exists():
            return path
    raise BrowserError(f"no browser found for role {name!r} (looked for {candidates})")


# Brave Shields can perturb exactly the audio path seam arbitration observes, so
# a Brave instrumented participant runs with Shields down for Meet. Written into
# the throwaway profile before first launch — never into the user's own profile.
BRAVE_PREFS = {
    "profile": {
        "content_settings": {
            "exceptions": {
                # Brave's own content setting. BLOCK (2) means "shields down".
                "braveShields": {"https://meet.google.com,*": {"setting": 2}},
                # Fingerprinting protection re-mints media device metadata,
                # which is what `looksLikeCaptureDevice` reads. ALLOW (1) = off.
                "fingerprintingV2": {"*,*": {"setting": 1}},
            }
        }
    },
    "brave": {
        "webrtc_ip_handling_policy": "default",
        "shields": {"advanced_view_enabled": False},
    },
}


@dataclass
class Browser:
    """One launched browser instance and the rodney session bound to it."""

    label: str
    binary: Path
    profile: Path
    rodney_home: Path
    port: int
    wav: Path | None
    process: subprocess.Popen
    launched_at: float
    with_extension: bool = False

    # -- rodney -------------------------------------------------------------

    def _env(self) -> dict[str, str]:
        return {**os.environ, "RODNEY_HOME": str(self.rodney_home)}

    def rodney(self, *args: str, timeout: int = 60, check: bool = True) -> str:
        proc = subprocess.run(
            ["rodney", *args], env=self._env(), capture_output=True, text=True, timeout=timeout
        )
        if check and proc.returncode != 0:
            raise BrowserError(
                f"{self.label}: rodney {' '.join(args[:2])} failed "
                f"({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}"
            )
        return proc.stdout.strip()

    def connect(self, attempts: int = 20) -> None:
        for i in range(attempts):
            try:
                self.rodney("connect", f"127.0.0.1:{self.port}", timeout=20)
                return
            except (BrowserError, subprocess.TimeoutExpired):
                if i == attempts - 1:
                    raise
                time.sleep(1.0)

    def js(self, expression: str) -> object:
        """Evaluate and JSON-decode. Everything the harness reads out of a page
        goes through here, so a page-side error surfaces as a Python error
        rather than as a quietly missing measurement."""
        raw = self.rodney("js", expression)
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw

    def open(self, url: str) -> None:
        self.rodney("open", url, timeout=90)

    # -- lifecycle ----------------------------------------------------------

    def alive(self) -> bool:
        return self.process.poll() is None

    def close(self) -> None:
        if self.alive():
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()


def launch(
    label: str,
    workdir: Path,
    port: int,
    url: str = "about:blank",
    wav: Path | None = None,
    binary: Path | None = None,
    extension: Path | None = None,
    profile: Path | None = None,
) -> Browser:
    """Launch one participant browser with the fake-device flags.

    `profile` names a persistent (signed-in) profile to reuse; omit it for the
    usual throwaway profile, which is wiped on every launch.
    """
    binary = binary or resolve_binary("auto-guest")
    persistent = profile is not None
    profile = profile or (workdir / f"profile-{label}")
    rodney_home = workdir / f"rodney-{label}"
    if profile.exists() and not persistent:
        shutil.rmtree(profile)
    profile.mkdir(parents=True, exist_ok=True)
    rodney_home.mkdir(parents=True, exist_ok=True)

    if "Brave" in binary.name and not persistent:
        default = profile / "Default"
        default.mkdir(parents=True, exist_ok=True)
        (default / "Preferences").write_text(json.dumps(BRAVE_PREFS))

    args = [
        str(binary),
        f"--user-data-dir={profile}",
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream",
        "--autoplay-policy=no-user-gesture-required",
        # Without this the fake file is never read and every sample is zero.
        "--disable-features=AudioServiceSandbox",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-search-engine-choice-screen",
        "--disable-session-crashed-bubble",
        f"--user-agent={CHROME_UA}",
        f"--remote-debugging-port={port}",
        f"--remote-allow-origins=http://127.0.0.1:{port}",
    ]
    url = force_english(url)
    if wav is not None:
        if not wav.exists():
            raise BrowserError(f"{label}: {wav} does not exist")
        args.append(f"--use-file-for-fake-audio-capture={wav}%noloop")
    if extension is not None:
        args.append(f"--disable-extensions-except={extension}")
        args.append(f"--load-extension={extension}")
    args.append(url)

    log = (workdir / f"{label}-browser.log").open("wb")
    launched_at = time.time()
    process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)

    browser = Browser(
        label=label,
        binary=binary,
        profile=profile,
        rodney_home=rodney_home,
        port=port,
        wav=wav,
        process=process,
        launched_at=launched_at,
        with_extension=extension is not None,
    )
    (workdir / f"{label}-launch.json").write_text(
        json.dumps(
            {
                "label": label,
                "binary": str(binary),
                "argv": args,
                "launched_at": launched_at,
                "wav": str(wav) if wav else None,
            },
            indent=2,
        )
        + "\n"
    )
    browser.connect()
    return browser


# ---------------------------------------------------------------------------
# Page-side helpers
# ---------------------------------------------------------------------------

# Reads the fake mic straight off a MediaStreamTrackProcessor — the same frame
# source the extension's receiver/webaudio seams use, and no AudioContext to be
# left suspended by autoplay policy (which reads as silence and would be
# mistaken for the sandbox problem).
MIC_CHECK_JS = r"""
(() => {
  if (window.__gtMic) return "already";
  window.__gtMic = {status: "starting", samples: []};
  (async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {echoCancellation: false, noiseSuppression: false, autoGainControl: false}});
      const track = stream.getAudioTracks()[0];
      window.__gtMic.label = track.label;
      window.__gtMic.settings = track.getSettings();
      const reader = new MediaStreamTrackProcessor({track: track.clone()}).readable.getReader();
      window.__gtMic.status = "running";
      let acc = [], frames = 0, rate = 48000;
      const t0 = performance.now();
      for (;;) {
        const {value, done} = await reader.read();
        if (done) break;
        rate = value.sampleRate;
        const buf = new Float32Array(value.numberOfFrames);
        value.copyTo(buf, {planeIndex: 0, format: "f32-planar"});
        value.close();
        acc.push(buf); frames += buf.length;
        if (frames >= rate / 10) {
          const all = new Float32Array(frames); let o = 0;
          for (const b of acc) { all.set(b, o); o += b.length; }
          let s = 0, zc = 0;
          for (let i = 0; i < all.length; i++) {
            s += all[i] * all[i];
            if (i && (all[i - 1] < 0) !== (all[i] < 0)) zc++;
          }
          window.__gtMic.samples.push({
            t: +((performance.now() - t0) / 1000).toFixed(2),
            rms: +Math.sqrt(s / all.length).toFixed(5),
            hz: Math.round((zc * rate) / (2 * all.length)),
          });
          acc = []; frames = 0;
        }
      }
      window.__gtMic.status = "ended";
    } catch (e) { window.__gtMic = {status: "error", error: String(e)}; }
  })();
  return "started";
})()
"""

# Meet's per-tile speaking ring, the only confirmed per-turn per-device signal
# (journal #111, #118). Anchored on [data-participant-id] subtrees and keyed on
# mutation burst shape, never on obfuscated class tokens — the classes change
# between builds, the burst does not.
RING_OBSERVER_JS = r"""
(() => {
  if (window.__gtRing) return "already";
  const buckets = new Map();          // participantId -> Map(bucket -> count)
  const names = new Map();
  const t0 = Date.now();
  window.__gtRing = {t0, buckets, names};
  const bump = (node) => {
    const tile = node.nodeType === 1 ? node.closest("[data-participant-id]")
                                     : node.parentElement?.closest("[data-participant-id]");
    if (!tile) return;
    const id = tile.getAttribute("data-participant-id");
    if (!names.has(id)) {
      const text = (tile.innerText || "").split("\n").map(s => s.trim()).filter(Boolean);
      if (text.length) names.set(id, text[0]);
    }
    const bucket = Math.floor((Date.now() - t0) / 100);
    if (!buckets.has(id)) buckets.set(id, new Map());
    const b = buckets.get(id);
    b.set(bucket, (b.get(bucket) || 0) + 1);
  };
  new MutationObserver((records) => {
    for (const r of records) {
      bump(r.target);
      for (const n of r.addedNodes) bump(n);
    }
  }).observe(document.body, {subtree: true, childList: true, attributes: true});
  return "started";
})()
"""

RING_DUMP_JS = r"""
JSON.stringify((() => {
  if (!window.__gtRing) return null;
  const out = {t0: window.__gtRing.t0, participants: []};
  for (const [id, buckets] of window.__gtRing.buckets) {
    out.participants.push({
      id,
      name: window.__gtRing.names.get(id) || null,
      // [bucket index (100 ms), mutation count] — burst shape, not class tokens
      activity: [...buckets.entries()].sort((a, b) => a[0] - b[0]),
    });
  }
  return out;
})())
"""

# Roster + extension state, read from the host page. Names here are the
# harness's own synthetic GT-* labels by construction.
ROSTER_JS = r"""
JSON.stringify([...document.querySelectorAll("[data-participant-id]")].map(el => ({
  id: el.getAttribute("data-participant-id"),
  text: (el.innerText || "").split("\n").map(s => s.trim()).filter(Boolean).slice(0, 2),
})))
"""


def join_meet(browser: Browser, url: str, display_name: str, timeout: float = 180.0) -> dict:
    """Get an anonymous guest from the pre-join screen into the call.

    Anonymous guest join is what makes the display name the ground-truth label:
    it is typed here, so the roster join is declared rather than inferred. No
    account, no login automation.

    **One loop, re-asserting until the call UI appears**, rather than
    type-then-click-then-wait. Meet enables "Join now" a beat after it renders,
    and `HTMLElement.click()` on a disabled button silently does nothing — so a
    click-once-then-wait shape reports success, waits out its whole timeout on
    the pre-join screen, and looks exactly like an admission refusal. That cost
    two runs before it was spotted; the fix is to keep re-checking the name and
    re-clicking an *enabled* button until the tiles appear.

    **Launch straight at the meeting URL.** Measured 2026-08-06: a browser
    started on `about:blank` and then navigated to the meeting is redirected to
    `workspace.google.com/products/meet/` and never sees the name field, while
    the identical browser started with the meeting URL as its startup argument
    reaches the anonymous pre-join screen every time.
    """
    url = force_english(url)
    # Compare on the meeting path, not the whole URL: the query carries hl=en.
    if urlparse(url).path not in str(browser.js("location.href") or ""):
        browser.open(url)

    deadline = time.time() + timeout
    result: dict = {"url": url, "display_name": display_name, "clicks": 0}
    named = False
    while time.time() < deadline:
        state = browser.js(IN_CALL_JS)
        if isinstance(state, dict) and state.get("inCall"):
            result.update(state)
            result["name_field_found"] = named
            result["admitted_at"] = time.time()
            return result

        if any(marker in str(browser.js("location.href") or "") for marker in REFUSAL_MARKERS):
            raise BrowserError(f"{browser.label}: Meet refused the join (redirected away)")

        dismissed = browser.js(_ALLOW_MEDIA_JS)
        if isinstance(dismissed, str) and dismissed.startswith("clicked:"):
            result.setdefault("permission_modal", []).append(dismissed.split(":", 1)[1])

        outcome = browser.js(_SET_NAME_JS.replace("__NAME__", json.dumps(display_name)))
        if outcome == "set":
            named = True
        clicked = browser.js(_CLICK_JOIN_JS)
        if isinstance(clicked, str) and clicked.startswith("clicked:"):
            result["clicks"] += 1
            result["join_button"] = clicked.split(":", 1)[1]
        time.sleep(2.0)

    raise BrowserError(
        f"{browser.label}: never entered the call within {timeout:.0f}s "
        f"(name set: {named}, join clicks: {result['clicks']})"
    )


# Meet intermittently interposes a "Do you want people to see and hear you?"
# modal before the pre-join screen, even with `--use-fake-ui-for-media-stream`
# auto-granting permission. While it is up there is no name field and no "Join
# now", so the join loop sees a page it does not recognise and times out.
#
# **Only ever click Allow.** The modal's other option is "Use without microphone
# and camera", and taking it joins a participant that transmits nothing — a
# guest present in the roster, emitting silence, with the manifest still claiming
# it spoke. That is the silently-wrong-corpus failure this harness exists to
# prevent, so the "without" wording is explicitly excluded rather than merely
# not preferred.
_JOIN_BUTTON_PRESENT_JS = r"""
(() => {
  const want = /^(ask to join|join now|join anyway|switch here)$/i;
  return [...document.querySelectorAll("button, [role=button]")]
    .some(el => el.offsetParent !== null && want.test((el.innerText || "").trim()));
})()
"""

_ALLOW_MEDIA_JS = r"""
(() => {
  const deny = /without|dismiss|not now|cancel/i;
  const allow = /allow (microphone|mic|camera)|allow (and )?continue|^allow$|use (microphone|mic)/i;
  const button = [...document.querySelectorAll("button, [role=button]")]
    .filter(el => el.offsetParent !== null)
    .find(el => {
      const text = ((el.innerText || "") + " " + (el.getAttribute("aria-label") || "")).trim();
      return allow.test(text) && !deny.test(text);
    });
  if (!button) return "no-modal";
  if (button.disabled || button.getAttribute("aria-disabled") === "true") return "disabled";
  button.click();
  return "clicked:" + (button.innerText || "").trim();
})()
"""

_SET_NAME_JS = r"""
(() => {
  const field = [...document.querySelectorAll("input[type=text], input:not([type])")]
    .find(el => el.offsetParent !== null &&
      /name/i.test((el.getAttribute("aria-label") || "") + (el.placeholder || "")));
  if (!field) return "no-field";
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
  setter.call(field, __NAME__);
  field.dispatchEvent(new Event("input", {bubbles: true}));
  field.dispatchEvent(new Event("change", {bubbles: true}));
  return field.value === __NAME__ ? "set" : "rejected";
})()
"""

_CLICK_JOIN_JS = r"""
(() => {
  const want = /^(ask to join|join now|join anyway|switch here)$/i;
  const button = [...document.querySelectorAll("button, [role=button]")]
    .find(el => el.offsetParent !== null && want.test((el.innerText || "").trim()));
  if (!button) return "no-button";
  // Meet enables this a beat after rendering it, and .click() on a disabled
  // button is a silent no-op — reporting that as a click is what made a failed
  // join look like a refused one.
  if (button.disabled || button.getAttribute("aria-disabled") === "true") return "disabled";
  button.click();
  return "clicked:" + button.innerText.trim();
})()
"""

IN_CALL_JS = r"""
JSON.stringify({
  inCall: !!document.querySelector("[data-participant-id]"),
  tiles: document.querySelectorAll("[data-participant-id]").length,
  url: location.href,
  title: document.title,
})
"""


#: How Meet says no. Both are transient in practice — the same browser, same
#: flags and same call succeeds a minute later — so they are retried rather than
#: treated as fatal.
REFUSAL_MARKERS = ("workspace.google.com/products/meet", "can't join this video call")


def _prejoin_state(browser: Browser) -> str:
    url = str(browser.js("location.href") or "")
    if any(marker in url for marker in REFUSAL_MARKERS):
        return "refused"
    text = str(browser.js("JSON.stringify(document.body.innerText.slice(0,400))") or "")
    if "can't join this video call" in text:
        return "refused"
    # A signed-in profile has no name field — Meet already knows who it is — so
    # readiness cannot key on that alone. An enabled join affordance is the
    # common signal across both anonymous and signed-in pre-join screens.
    if browser.js(_SET_NAME_JS.replace("__NAME__", '""')) != "no-field":
        return "ready"
    if browser.js(_JOIN_BUTTON_PRESENT_JS) is True:
        return "ready"
    return "waiting"


def launch_and_join(
    label: str,
    workdir: Path,
    port: int,
    meet_url: str,
    display_name: str,
    wav: Path | None = None,
    binary: Path | None = None,
    extension: Path | None = None,
    profile: Path | None = None,
    attempts: int = 3,
) -> tuple[Browser, dict]:
    """Launch a participant browser and get it into the call, retrying refusals.

    Meet refuses anonymous joins intermittently — observed on a call that was
    open, live, and had its signed-in convener present, from a browser that had
    just joined the same call successfully. Both refusal shapes (the
    marketing-page redirect and "You can't join this video call") cleared on a
    retry a minute later.

    A retry **relaunches** the browser rather than reloading it, because the
    fake-audio file starts at the page's first `getUserMedia` and a reload would
    leave the participant's clock somewhere undefined. Relaunching restarts that
    clock cleanly, and the caller records the actual instant — which is why
    every offset in a manifest is stated relative to the participant's own audio
    start rather than to a wall clock.
    """
    last = "no attempt made"
    for attempt in range(attempts):
        browser = launch(
            label, workdir, port, url=force_english(meet_url), wav=wav, binary=binary,
            extension=extension, profile=profile,
        )
        try:
            deadline = time.time() + 60
            state = "waiting"
            while time.time() < deadline:
                state = _prejoin_state(browser)
                if state in ("ready", "refused"):
                    break
                time.sleep(1.0)
            if state != "ready":
                last = f"pre-join state {state!r}"
                raise BrowserError(f"{label}: {last}")
            result = join_meet(browser, meet_url, display_name)
            return browser, {**result, "join_attempts": attempt + 1}
        except BrowserError as error:
            last = str(error)
            browser.close()
            if attempt < attempts - 1:
                time.sleep(15.0)
    raise BrowserError(f"{label}: could not join after {attempts} attempts — last: {last}")


def wait_admitted(browser: Browser, timeout: float = 180.0) -> dict:
    """Block until the call UI appears, i.e. the guest was admitted."""
    deadline = time.time() + timeout
    last: dict = {}
    while time.time() < deadline:
        state = browser.js(IN_CALL_JS)
        if isinstance(state, dict):
            last = state
            if state.get("inCall"):
                state["admitted_at"] = time.time()
                return state
        time.sleep(1.0)
    raise BrowserError(f"{browser.label}: not admitted within {timeout:.0f}s (last state {last})")


def leave_meet(browser: Browser) -> float:
    """Hang up, so the departure is a real leave rather than a dead tab."""
    browser.js(
        r"""
        (() => {
          const b = [...document.querySelectorAll("button, [role=button]")]
            .find(el => /leave call|hang up|end call/i.test(
              (el.getAttribute("aria-label") || "") + (el.innerText || "")));
          if (b) { b.click(); return "clicked"; }
          return "no-button";
        })()
        """
    )
    return time.time()


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------


def serve(directory: Path, port: int = 8731):
    """A loopback HTTP server for the preflight page.

    `getUserMedia` needs a secure context and `file://` is not one — a
    file-served preflight page fails with `NotAllowedError` and reads exactly
    like the sandbox problem it is meant to detect. `http://127.0.0.1` is
    potentially-trustworthy, so it is.
    """
    import functools
    import http.server
    import threading

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    handler.log_message = lambda *a, **k: None  # type: ignore[method-assign]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


PREFLIGHT_HZ = 1_111  # not a head-tone frequency, so a stale probe WAV cannot pass this


def preflight(workdir: Path, port: int = 9399, seconds: float = 4.0) -> dict:
    """Prove the fake device is actually reading its file, in a throwaway
    browser, before any participant's schedule starts.

    Uses its own generated tone rather than a corpus WAV for two reasons: a
    participant WAV opens with preroll silence, which would read as a failure;
    and asserting the *frequency* comes back proves the device is reading the
    file we named rather than merely producing something.

    Deliberately not run inside a participant's own browser — the fake file
    starts at the first ``getUserMedia``, so a preflight there would consume the
    preroll it exists to protect.
    """
    (workdir / "preflight.html").write_text(
        "<!doctype html><meta charset=utf-8><title>gt preflight</title>"
    )
    wav = workdir / "preflight-tone.wav"
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-y", "-f", "lavfi",
            "-i", f"sine=frequency={PREFLIGHT_HZ}:duration=60:sample_rate=48000",
            "-ac", "1", "-c:a", "pcm_s16le", str(wav),
        ],
        check=True,
    )
    server = serve(workdir)
    browser = launch(
        "preflight", workdir, port, url="http://127.0.0.1:8731/preflight.html", wav=wav
    )
    try:
        started = browser.js(MIC_CHECK_JS)
        time.sleep(seconds)
        mic = browser.js("JSON.stringify(window.__gtMic)")
        if isinstance(mic, dict) and mic.get("status") == "error":
            raise BrowserError(f"preflight page could not open the fake mic: {mic.get('error')}")
        samples = (mic or {}).get("samples", []) if isinstance(mic, dict) else []
        loud = [s for s in samples if s["rms"] > 1e-3]
        peak = max((s["rms"] for s in samples), default=0.0)
        median_hz = sorted(s["hz"] for s in loud)[len(loud) // 2] if loud else 0
        result = {
            "wav": str(wav),
            "browser": str(browser.binary),
            "windows": len(samples),
            "peak_rms": peak,
            "expected_hz": PREFLIGHT_HZ,
            "observed_hz": median_hz,
            "track_label": (mic or {}).get("label") if isinstance(mic, dict) else None,
            "settings": (mic or {}).get("settings") if isinstance(mic, dict) else None,
            "ok": peak > 1e-3 and abs(median_hz - PREFLIGHT_HZ) < PREFLIGHT_HZ * 0.05,
        }
        if not samples:
            raise BrowserError(
                "preflight read no audio frames at all — the fake device did not start"
            )
        if peak <= 1e-3:
            raise BrowserError(
                f"preflight: fake device delivered {len(samples)} windows at peak RMS "
                f"{peak:.6f}, i.e. digital silence. On macOS this is the audio-service "
                "sandbox refusing to read the WAV; the launcher passes "
                "--disable-features=AudioServiceSandbox for exactly this, so a failure "
                "here means the flag stopped working, not that the file is wrong."
            )
        if not result["ok"]:
            raise BrowserError(
                f"preflight: fake device is loud (peak RMS {peak:.4f}) but at "
                f"{median_hz} Hz, not the {PREFLIGHT_HZ} Hz the file carries — it is "
                "reading something other than the WAV it was given."
            )
        return result
    finally:
        browser.close()
        server.shutdown()


@click.group()
def cli() -> None:
    pass


@cli.command("preflight")
@click.option("--workdir", type=click.Path(path_type=Path), default=Path(".work"))
def preflight_cmd(workdir: Path) -> None:
    """Check the fake-device path end to end without joining anything."""
    workdir.mkdir(parents=True, exist_ok=True)
    click.echo(json.dumps(preflight(workdir), indent=2))


if __name__ == "__main__":
    cli()
