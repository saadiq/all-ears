# Spec: transport (extension ↔ `earsd`)

## One job

Stream per-participant PCM from the extension to `earsd`'s loopback WebSocket ingest endpoint, mapping each participant to a distinct `browser:<label>` source and its `stream_id`. One WebSocket, held in the background context, with one piece of state: the participant → `stream_id` table.

The extension's control traffic (the session lifecycle verbs, status) rides the separate `/control` WebSocket via `lib/control-transport.ts`, which speaks the same v2 protocol as the Unix socket — see the [capture-daemon spec](../capture-daemon.md#transports). This document covers the audio leg (`lib/transport.ts`).

### Why a WebSocket, not native messaging

No native-messaging host manifest, no extension-id-coupled install, and PCM ships as binary frames. MV3 service workers hold WebSockets, and WebSocket activity resets the worker idle timer (Chrome 116+), so the connection lives in the background context on both browsers with no offscreen document.

### Responsibilities

- Open one WebSocket to `ws://127.0.0.1:<port>/ingest`; reconnect with backoff on drop.
- Lazily `ingest.open` a source on the first PCM for a new participant; stream binary frames; `ingest.close` on leave.
- Maintain the participant → `stream_id` table; discard it on disconnect and re-open lazily as new frames arrive.
- Ship attribution flight-recorder batches (`ingest.attribution`) when the session tag is known; drop them otherwise — the in-page ring keeps the events exportable.
- Apply backpressure; never buffer unbounded.

It does **not** capture, resample, or inspect audio (it receives finished 16 kHz `pcm_s16le`), and does **not** resolve identity (it receives an already-stable id).

## Endpoint & connection

- URL: `ws://127.0.0.1:<port>/ingest`; port from extension options (default `47811`, matching `[earsd.ingest_ws].port`).
- **Loopback only.** The extension refuses any non-`127.0.0.1` URL — a remote URL is a bug, not a configuration.
- The browser sets `Origin` (`chrome-extension://<id>` / `moz-extension://<uuid>`) truthfully on the handshake; `earsd` allowlists it.

## Wire protocol

Control is text frames, reusing `earsd`'s `ControlRequest`/`ControlResponse` types:

```jsonc
// text --> declare a per-participant stream (first PCM for a new participant).
// `id` (optional) is a correlation id, an opaque string the daemon echoes
// verbatim on the reply — see "Correlation ids" below. `session` (optional) is
// the membership tag: the session identity (platform + the platform's own
// meeting id) this source belongs to, when the background's tracker knows it
// at open time. The daemon uses it to link the source into the session
// server-side, keeping the ingest-idle grace sound across service-worker
// respawns.
{"cmd":"ingest.open","id":"1","source":"browser:meet:jane-a1b2","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"},"session":{"platform":"meet","external_id":"abc-defg-hij"}}
// text <-- {"ok":true,"id":"1","data":{"stream_id":"s7"}}

// text --> end the stream (participant left / track ended)
{"cmd":"ingest.close","id":"2","stream_id":"s7"}
// text <-- {"ok":true,"id":"2","data":{}}

// text --> a batch of attribution flight-recorder events. `events` is an array
// of opaque, pre-encoded JSONL lines (browser/lib/attribution-log.ts, one
// schema-versioned JSON object each) the daemon appends VERBATIM to the tagged
// session's attribution.jsonl beside events.jsonl — see docs/data-formats.md.
// The session tag is mandatory here: a batch with no session has no directory
// to land in, so the extension only sends once the tag is known. Best-effort
// both ways: the daemon always acks {"ok":true} (a tag naming no live session
// drops the batch with a daemon-side log line), and the extension never
// retries — the in-page ring still holds the events for on-demand export
// (window.__earsExportAttribution()).
{"cmd":"ingest.attribution","id":"3","session":{"platform":"meet","external_id":"abc-defg-hij"},"events":["{\"schema\":1,\"type\":\"dom-burst\",\"t\":1723500000000,\"deviceId\":\"spaces/x/devices/1\"}"]}
// text <-- {"ok":true,"id":"3","data":{}}
```

### Correlation ids

Every command may carry an optional `id`: an opaque string, unique among the sender's in-flight requests (the extension stamps a per-socket counter on every `ingest.open`/`ingest.close`/`ingest.attribution`). The daemon echoes it verbatim at the top level of the reply, beside `ok`/`data`/`error`; a request without an `id` gets a reply without one, byte-identical to the pre-id shape.

The field converts a protocol assumption into a checked contract. Without it, replies are matched to requests by arrival order, and one unsolicited, duplicated, or reordered daemon response desynchronises every subsequent open — handing each participant the previous participant's `stream_id` for the rest of the connection. With it, the extension matches a reply that echoes an `id` to exactly that request, and drops (with a log line) any response whose `id` matches nothing in flight.

Both directions stay compatible across versions. An old daemon never echoes, so a new extension falls back to FIFO matching — exactly the pre-id behaviour. An old extension never sends ids, so a new daemon's replies carry none and the old FIFO matching is unperturbed. Mixing matched and FIFO responses on one connection cannot happen: a daemon either echoes ids (all replies to id-carrying requests have them) or predates the field (none do).

Audio is one binary frame per PCM chunk, multiplexed by `stream_id`. Two shapes, discriminated by the first byte (a zero first byte is impossible in the legacy shape, since stream ids are never empty):

```
legacy:   [ u8 idLen>0 ][ stream_id : idLen ASCII ][ pcm_s16le (mono, LE) ]
extended: [ 0x00 ][ u8 ver=1 ][ u8 idLen ][ stream_id ][ u32le seq ][ f64le sentAt ][ pcm_s16le ]
```

The extension always sends the extended shape. `seq` is per-stream monotonic (wrapping at 2^32) and `sentAt` is epoch ms stamped in the MAIN world when the frame left the capture path — not for ordering (WebSocket rides TCP), but so the daemon can compute one-way delay and tell a silent speaker from a stalled capture path. Frames queued while an `ingest.open` is in flight keep their original stamp, not their replay time. `earsd` accepts both shapes.

At ~10 frames/s/participant (~3 KB each), message size is never a concern.

### Source labeling

One participant → `browser:<platform>:<participant>` → one `stream_id` → one independently-recorded, independently-transcribed `earsd` source. `<platform>` is `meet` | `zoom` | `teams`; `<participant>` is the sanitized id from the [extension spec](./extension.md#platform-adapters). Fallback ids become e.g. `browser:teams:speaker-3` — stable within the call, honest about provenance.

## State & lifecycle

- **participant → stream_id table:** populate on `ingest.open` success; drop on `ingest.close`. On an `{"ok":false}` open, log and drop that participant's frames (no per-frame retry).
- **Reconnect:** on close/error, discard the table (stream ids are per-connection), buffer nothing, reconnect with backoff, and re-open lazily as new frames arrive. Surface a `disconnected` status to the popup.
- **Backpressure:** if the socket's `bufferedAmount` exceeds its threshold, drop frames and count them in a logged `dropped` counter — never grow an unbounded queue.

### Per-browser lifetime

- **Chrome (MV3 service worker):** continuous PCM keeps the worker alive, but silence produces no traffic, so a `chrome.alarms` keepalive is armed while a capture session is active and cleared when the last participant leaves. On worker respawn, the module top level reconnects, streams re-open lazily, and persisted `storage.session` state re-arms the alarm.
- **Firefox (MV3 event page):** Firefox can also suspend its background context after idle, so the same keepalive + lazy-reconnect hardening applies; the code path is identical.

## Security

Both sides enforce the boundary; neither trusts the other to.

**`earsd` (server):** binds `127.0.0.1` only; validates `Origin` against `[earsd.ingest_ws].allowed_origins` before completing the upgrade (empty allowlist rejects all — fail closed); accepts nothing but `ingest.open`/`ingest.close`/`ingest.attribution` and binary audio, so even an allowed origin cannot drive the daemon from this endpoint.

**Extension (client):** connects to loopback only; the WebSocket lives in the background context, never the page realm, so no meeting-page CSP applies and no endpoint or state is exposed to page scripts.

Residual risk on a shared machine: another **local** process can present an allowed `Origin` and connect. Loopback + Origin allowlist is the specified control; the threat model is a single-user machine. A user-configured bearer token is a documented future option.

The extension is testable without a daemon against `browser/dev/stub-server.ts`, which speaks this same wire protocol.
