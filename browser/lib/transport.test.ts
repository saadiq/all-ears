import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EarsSocket } from "./transport";
import { INGEST_FORMAT, sourceLabel } from "./protocol";

// EarsSocket reaches out to the global WebSocket constructor at call time
// (inside open()), not at module-load time, so swapping globalThis.WebSocket
// before each test is enough — no need to mock the module itself.

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  binaryType = "";
  bufferedAmount = 0;
  url: string;
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: unknown[] = [];

  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
  }

  send(data: unknown): void {
    this.sent.push(data);
  }

  close(): void {
    this.onclose?.();
  }

  respond(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) });
  }
}

function textSent(ws: FakeWebSocket): unknown[] {
  return ws.sent.filter((s) => typeof s === "string").map((s) => JSON.parse(s as string));
}

function opens(ws: FakeWebSocket): unknown[] {
  return textSent(ws).filter((m) => (m as { cmd?: string }).cmd === "ingest.open");
}

function binarySent(ws: FakeWebSocket): ArrayBuffer[] {
  return ws.sent.filter((s) => s instanceof ArrayBuffer) as ArrayBuffer[];
}

function decodeFrame(buf: ArrayBuffer): { streamId: string; pcm: Uint8Array } {
  const bytes = new Uint8Array(buf);
  const idLen = bytes[0]!;
  const streamId = new TextDecoder().decode(bytes.slice(1, 1 + idLen));
  return { streamId, pcm: bytes.slice(1 + idLen) };
}

/** Connects and drives the socket through to "connected", returning the ws. */
function connectAndOpen(socket: EarsSocket): FakeWebSocket {
  socket.connect();
  const ws = FakeWebSocket.instances.at(-1)!;
  ws.onopen?.();
  return ws;
}

describe("EarsSocket", () => {
  beforeEach(() => {
    FakeWebSocket.instances = [];
    (globalThis as unknown as { WebSocket: unknown }).WebSocket = FakeWebSocket;
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("refuses to open a non-loopback URL and never constructs a WebSocket", () => {
    class NonLoopbackSocket extends EarsSocket {
      override get url(): string {
        return "ws://example.com:47811/ingest";
      }
    }
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const socket = new NonLoopbackSocket(47811);
    socket.connect();
    expect(FakeWebSocket.instances).toHaveLength(0);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("non-loopback"));
    errorSpy.mockRestore();
  });

  it("reaches connected status once the socket opens, and reconnects with growing backoff on drop", () => {
    const statuses: string[] = [];
    const socket = new EarsSocket(47811, (s) => statuses.push(s));

    const ws1 = connectAndOpen(socket);
    expect(statuses).toEqual(["connecting", "connected"]);

    ws1.onclose?.();
    expect(statuses).toEqual(["connecting", "connected", "disconnected"]);
    expect(FakeWebSocket.instances).toHaveLength(1); // reconnect not yet fired

    vi.advanceTimersByTime(500); // BASE_BACKOFF_MS
    expect(FakeWebSocket.instances).toHaveLength(2);

    const ws2 = FakeWebSocket.instances[1]!;
    ws2.onclose?.(); // a second consecutive drop before ever reconnecting successfully
    vi.advanceTimersByTime(999);
    expect(FakeWebSocket.instances).toHaveLength(2); // not yet — backoff doubled to 1000ms
    vi.advanceTimersByTime(1);
    expect(FakeWebSocket.instances).toHaveLength(3);
  });

  it("ingest.open is sent once per participant; a stream_id is reused for later frames", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane-a1b2", "meet", new Uint8Array([1, 2]));
    expect(textSent(ws)).toEqual([
      { cmd: "ingest.open", id: "1", source: sourceLabel("meet", "jane-a1b2"), format: INGEST_FORMAT },
    ]);
    expect(binarySent(ws)).toHaveLength(0); // queued until ingest.open resolves

    ws.respond({ ok: true, data: { stream_id: "s1" } });
    const firstBatch = binarySent(ws);
    expect(firstBatch).toHaveLength(1); // the queued frame flushes on open
    expect(decodeFrame(firstBatch[0]!).streamId).toBe("s1");

    socket.sendPcm("jane-a1b2", "meet", new Uint8Array([3, 4]));
    expect(textSent(ws)).toHaveLength(1); // still just the one ingest.open
    expect(binarySent(ws)).toHaveLength(2);
    expect(decodeFrame(binarySent(ws)[1]!).streamId).toBe("s1");
  });

  it("ingest.open carries the session membership tag when the caller knows it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane-a1b2", "meet", new Uint8Array([1, 2]), "kQ0DRVtDaekB");
    expect(textSent(ws)).toEqual([
      {
        cmd: "ingest.open",
        id: "1",
        source: sourceLabel("meet", "jane-a1b2"),
        format: INGEST_FORMAT,
        session: { platform: "meet", external_id: "kQ0DRVtDaekB" },
      },
    ]);
  });

  it("re-opens a rejected participant as soon as a session tag arrives, and the held audio lands", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const opened: string[] = [];
    const socket = new EarsSocket(47811);
    socket.onStreamOpened = (id) => opened.push(id);
    const ws = connectAndOpen(socket);

    // The first frame beats session.start, so there is no tag to stamp and the
    // daemon refuses the open ("no live session for its identity tag").
    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    ws.respond({ ok: false, error: "no live session for its identity tag" });
    expect(binarySent(ws)).toHaveLength(0);

    // The tracker resolves the meeting id; the next frame carries it. That
    // absent→present transition is the retry trigger — no waiting on a clock.
    socket.sendPcm("jane", "meet", new Uint8Array([2]), "kQ0DRVtDaekB");
    expect(opens(ws)).toEqual([
      { cmd: "ingest.open", id: "1", source: sourceLabel("meet", "jane"), format: INGEST_FORMAT },
      {
        cmd: "ingest.open",
        id: "2",
        source: sourceLabel("meet", "jane"),
        format: INGEST_FORMAT,
        session: { platform: "meet", external_id: "kQ0DRVtDaekB" },
      },
    ]);

    ws.respond({ ok: true, data: { stream_id: "s1" } });
    const frames = binarySent(ws);
    expect(frames).toHaveLength(2); // both held frames flush — nothing was thrown away
    expect(decodeFrame(frames[0]!).pcm).toEqual(new Uint8Array([1]));
    expect(decodeFrame(frames[1]!).streamId).toBe("s1");
    expect(opened).toEqual(["jane"]); // the session layer hears about it exactly once
    warnSpy.mockRestore();
  });

  it("bounds the retries when no session tag ever arrives, then gives up out loud", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    // 60s of a participant talking into a session that is never declared:
    // 100 ms frames, so ~600 of them. A per-frame retry would be 600 opens.
    for (let i = 0; i < 600; i++) {
      const before = opens(ws).length;
      socket.sendPcm("jane", "meet", new Uint8Array([i & 0xff]));
      if (opens(ws).length > before) ws.respond({ ok: false, error: "no live session" });
      vi.advanceTimersByTime(100);
    }
    expect(opens(ws).length).toBeLessThanOrEqual(5); // MAX_OPEN_ATTEMPTS
    expect(opens(ws).length).toBeGreaterThan(1); // but it did retry
    expect(errorSpy).not.toHaveBeenCalled(); // still inside the hold window

    // Past the hold window the drop is real, so it is reported rather than
    // left to look like a quiet speaker.
    vi.advanceTimersByTime(60_000);
    socket.sendPcm("jane", "meet", new Uint8Array([9]));
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("giving up on jane"));
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("NOT being recorded"));

    // And it stays given up: no further sockets traffic for this participant.
    const after = ws.sent.length;
    for (let i = 0; i < 20; i++) socket.sendPcm("jane", "meet", new Uint8Array([i]), "late-tag");
    expect(ws.sent).toHaveLength(after);
    expect(errorSpy).toHaveBeenCalledTimes(1); // reported once, not per frame
    warnSpy.mockRestore();
    errorSpy.mockRestore();
  });

  it("holds at most OPENING_QUEUE_LIMIT frames while a rejected participant waits to recover", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([0]));
    ws.respond({ ok: false, error: "no live session" });
    // Waiting is not an excuse to grow: the queue stays drop-oldest so a long
    // refusal can't turn into unbounded memory in the service worker.
    for (let i = 1; i < 200; i++) socket.sendPcm("jane", "meet", new Uint8Array([i & 0xff]));

    socket.sendPcm("jane", "meet", new Uint8Array([200]), "kQ0DRVtDaekB");
    ws.respond({ ok: true, data: { stream_id: "s1" } });
    const frames = binarySent(ws);
    expect(frames).toHaveLength(50); // OPENING_QUEUE_LIMIT — the newest 50, oldest dropped
    expect(decodeFrame(frames.at(-1)!).pcm).toEqual(new Uint8Array([200]));
    warnSpy.mockRestore();
  });

  it("participantLeft sends ingest.close for the open stream and forgets it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    ws.respond({ ok: true, data: { stream_id: "s7" } });

    socket.participantLeft("jane");
    expect(textSent(ws).at(-1)).toEqual({ cmd: "ingest.close", id: "2", stream_id: "s7" });

    // A later frame for the same id is treated as a brand-new participant.
    socket.sendPcm("jane", "meet", new Uint8Array([2]));
    const opens = textSent(ws).filter((m) => (m as { cmd: string }).cmd === "ingest.open");
    expect(opens).toHaveLength(2);
  });

  it("drops the newest-over-limit frame under back-pressure rather than growing an unbounded queue", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    ws.respond({ ok: true, data: { stream_id: "s1" } });
    expect(binarySent(ws)).toHaveLength(1);

    ws.bufferedAmount = (1 << 20) + 1; // over BUFFERED_AMOUNT_LIMIT
    socket.sendPcm("jane", "meet", new Uint8Array([2]));
    expect(binarySent(ws)).toHaveLength(1); // the new frame was dropped, not queued or sent

    ws.bufferedAmount = 0;
    socket.sendPcm("jane", "meet", new Uint8Array([3]));
    expect(binarySent(ws)).toHaveLength(2); // back to normal once drained
    warnSpy.mockRestore();
  });

  it("disconnect() is terminal — no reconnect is scheduled after it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);
    socket.disconnect();
    expect(FakeWebSocket.instances).toHaveLength(1);
    vi.advanceTimersByTime(60_000);
    expect(FakeWebSocket.instances).toHaveLength(1);
    void ws;
  });

  it("ships an attribution batch as ingest.attribution with the session tag, lines verbatim", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    const lines = ['{"schema":1,"type":"track-ended","t":1,"trackId":"trk-1"}'];
    socket.sendAttribution(lines, "meet", "kQ0DRVtDaekB");
    expect(textSent(ws)).toEqual([
      {
        cmd: "ingest.attribution",
        id: "1",
        session: { platform: "meet", external_id: "kQ0DRVtDaekB" },
        events: lines,
      },
    ]);
  });

  it("drops an attribution batch with no session tag — there is nowhere to file it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);
    socket.sendAttribution(['{"schema":1,"type":"track-ended","t":1}'], "meet", undefined);
    expect(textSent(ws)).toEqual([]);
  });

  it("ships a capture-failed report as ingest.capture_failed with source and session tag", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);

    socket.sendCaptureFailed("t3", "meet", "decoder gave up", "kQ0DRVtDaekB");
    expect(textSent(ws)).toEqual([
      {
        cmd: "ingest.capture_failed",
        id: "1",
        source: sourceLabel("meet", "t3"),
        session: { platform: "meet", external_id: "kQ0DRVtDaekB" },
        reason: "decoder gave up",
      },
    ]);
  });

  it("drops a capture-failed report with no session tag — there is nowhere to file it", () => {
    const socket = new EarsSocket(47811);
    const ws = connectAndOpen(socket);
    socket.sendCaptureFailed("t3", "meet", "decoder gave up", undefined);
    expect(textSent(ws)).toEqual([]);
  });

  it("matches replies by correlation id, so reordered daemon responses still land on the right open", () => {
    const opened: string[] = [];
    const socket = new EarsSocket(47811);
    socket.onStreamOpened = (id) => opened.push(id);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    socket.sendPcm("kim", "meet", new Uint8Array([2]));
    const [janeOpen, kimOpen] = opens(ws) as Array<{ id: string }>;

    // The daemon answers the SECOND open first. FIFO matching would hand
    // kim's stream to jane and desynchronise everything after; id matching
    // routes each reply to its own request.
    ws.respond({ ok: true, id: kimOpen!.id, data: { stream_id: "s-kim" } });
    ws.respond({ ok: true, id: janeOpen!.id, data: { stream_id: "s-jane" } });

    expect(opened).toEqual(["kim", "jane"]);
    const frames = binarySent(ws).map(decodeFrame);
    expect(frames.find((f) => f.pcm[0] === 1)!.streamId).toBe("s-jane");
    expect(frames.find((f) => f.pcm[0] === 2)!.streamId).toBe("s-kim");
  });

  it("ignores a response with an unknown id without desynchronising the pending queue", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const opened: string[] = [];
    const socket = new EarsSocket(47811);
    socket.onStreamOpened = (id) => opened.push(id);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    // Unsolicited or duplicated daemon reply: its id matches nothing pending.
    // Under FIFO it would consume jane's slot; with ids it is logged and dropped.
    ws.respond({ ok: true, id: "9999", data: { stream_id: "s-ghost" } });
    expect(opened).toEqual([]);

    ws.respond({ ok: true, id: (opens(ws)[0] as { id: string }).id, data: { stream_id: "s1" } });
    expect(opened).toEqual(["jane"]);
    expect(decodeFrame(binarySent(ws)[0]!).streamId).toBe("s1");
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining("unknown correlation id"),
      expect.anything(),
    );
    warnSpy.mockRestore();
  });

  it("falls back to FIFO matching against a daemon that does not echo ids", () => {
    // An older earsd replies in request order with no id field. Two opens in
    // flight must still resolve, first reply to first request.
    const opened: string[] = [];
    const socket = new EarsSocket(47811);
    socket.onStreamOpened = (id) => opened.push(id);
    const ws = connectAndOpen(socket);

    socket.sendPcm("jane", "meet", new Uint8Array([1]));
    socket.sendPcm("kim", "meet", new Uint8Array([2]));
    ws.respond({ ok: true, data: { stream_id: "s1" } });
    ws.respond({ ok: true, data: { stream_id: "s2" } });

    expect(opened).toEqual(["jane", "kim"]);
    const frames = binarySent(ws).map(decodeFrame);
    expect(frames.find((f) => f.pcm[0] === 1)!.streamId).toBe("s1");
    expect(frames.find((f) => f.pcm[0] === 2)!.streamId).toBe("s2");
  });

  it("keeps the FIFO response matching straight when attribution acks interleave with opens", () => {
    const opened: string[] = [];
    const socket = new EarsSocket(47811);
    socket.onStreamOpened = (id) => opened.push(id);
    const ws = connectAndOpen(socket);

    socket.sendAttribution(['{"schema":1,"type":"dom-burst","t":1,"deviceId":"d"}'], "meet", "kQ0");
    socket.sendPcm("jane", "meet", new Uint8Array([1]), "kQ0");
    ws.respond({ ok: true, data: {} }); // the attribution ack, first in FIFO order
    ws.respond({ ok: true, data: { stream_id: "s1" } }); // then the open's reply
    expect(opened).toEqual(["jane"]); // the open's reply reached the open, not the ack
    expect(decodeFrame(binarySent(ws)[0]!).streamId).toBe("s1");
  });
});
