#!/usr/bin/env python3
"""Catch probe dumps POSTed from a meeting tab and write them to disk.

DevTools' copy() has silently failed mid-call before (journal #168) — the
clipboard kept its previous contents and the operator's "done" was
indistinguishable from success, costing two round-trips of live meeting time.
POSTing removes the operator from the loop entirely.

    python3 browser/dev/probes/probe-receiver.py [--port 8899] [--out DIR]

Then, in the meeting tab's console:  __earsTeams.post()

Each POST is written to DIR/<name>-<timestamp>.json and its arrival printed.
Binds 127.0.0.1 only. The probe posts with mode:"no-cors" and
Content-Type:text/plain, which is a CORS-simple request: no preflight to
answer, and the opaque response the tab gets back is irrelevant to it.
"""

import argparse
import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Receiver(BaseHTTPRequestHandler):
    out_dir = Path(".")

    def do_POST(self):  # noqa: N802 — BaseHTTPRequestHandler's spelling
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        name = (self.path.strip("/") or "probe").replace("/", "-")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        path = self.out_dir / f"{name}-{stamp}.json"

        try:
            parsed = json.loads(body)
            path.write_text(json.dumps(parsed, indent=2))
            summary = describe(parsed)
        except json.JSONDecodeError:
            # A probe that failed reports itself by POSTing its stack trace, so
            # a non-JSON body is a result too, not an error to drop.
            path = path.with_suffix(".txt")
            path.write_text(body.decode("utf-8", "replace"))
            summary = "NOT JSON — probably a probe stack trace"

        print(f"{stamp}  {len(body):>9,} bytes  {path}  {summary}", flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_args):
        pass  # the POST line above is the only log worth having


def describe(dump):
    """One line of what landed, so a bad capture is obvious immediately."""
    if not isinstance(dump, dict):
        return ""
    census = dump.get("census") or {}
    rows = (dump.get("latest") or {}).get("rows") or []
    attrs = ",".join(census.get("rowAttrs") or []) or "NONE"
    return f"probe={dump.get('probe')} rows={len(rows)} rowAttrs={attrs} changes={len(dump.get('changes') or [])}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--out", default=".", help="directory for received dumps")
    args = ap.parse_args()

    Receiver.out_dir = Path(args.out).expanduser().resolve()
    Receiver.out_dir.mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Receiver)
    print(f"listening on http://127.0.0.1:{args.port}/ → {Receiver.out_dir}")
    print("in the meeting tab console:  __earsTeams.post()")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
