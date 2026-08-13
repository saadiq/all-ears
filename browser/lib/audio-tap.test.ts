import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { initCapture } from "./audio-tap";
import { claimEpoch } from "./epoch";
import type { PlatformAdapter } from "./identity/adapter";
import { liveTracks } from "./rtc-hook";

// ── Track-scoped source handles (R3) ────────────────────────────────────────
//
// A source id is a stable per-track handle (`t<n>`), minted once at admission
// and never changed for the track's life. Identity never rides the source id:
// a platform id — known at admission or confirmed mid-call — flows as a
// `participant-identified` attendee upsert linking the handle's source, and
// the pipeline is never restarted for it.

interface PostedEnvelope {
  __ears?: boolean;
  msg?: { kind: string } & Record<string, unknown>;
}

class FakeMediaTrack {
  muted = false;
  readyState: "live" | "ended" = "live";
  private readonly listeners = new Map<string, Set<() => void>>();
  constructor(readonly id: string) {}
  addEventListener(kind: string, fn: () => void): void {
    if (!this.listeners.has(kind)) this.listeners.set(kind, new Set());
    this.listeners.get(kind)!.add(fn);
  }
  removeEventListener(kind: string, fn: () => void): void {
    this.listeners.get(kind)?.delete(fn);
  }
}

/** WebCodecs breakout-box fake: exposes each track's stream controller so a
 * test can push decoded frames through the real capture pipeline. */
class FakeTrackProcessor {
  static controllers = new Map<string, ReadableStreamDefaultController<unknown>>();
  readable: ReadableStream<unknown>;
  constructor(init: { track: { id: string } }) {
    this.readable = new ReadableStream({
      start(controller) {
        FakeTrackProcessor.controllers.set(init.track.id, controller);
      },
    });
  }
}

/** One decoded frame: 3200 samples of 16 kHz audio at peak 0.1 — enough for
 * the accumulator to emit at least one full 100 ms pcm frame per push. */
function decodedFrame(): unknown {
  return {
    sampleRate: 16000,
    numberOfFrames: 3200,
    numberOfChannels: 1,
    format: "f32",
    copyTo(dest: Float32Array) {
      dest.fill(0.1);
    },
    close() {},
  };
}

describe("track-scoped source handles (R3)", () => {
  let posted: Array<{ kind: string } & Record<string, unknown>>;

  function stubWindow(): void {
    posted = [];
    (globalThis as { window?: unknown }).window = {
      postMessage: (envelope: PostedEnvelope) => {
        if (envelope?.msg) posted.push(envelope.msg);
      },
    };
    (globalThis as { MediaStreamTrackProcessor?: unknown }).MediaStreamTrackProcessor =
      FakeTrackProcessor;
    FakeTrackProcessor.controllers.clear();
  }

  function registerLive(track: FakeMediaTrack): void {
    liveTracks().set(track as unknown as MediaStreamTrack, {
      stream: { id: `stream-${track.id}` } as unknown as MediaStream,
    });
  }

  const ofKind = (kind: string) => posted.filter((m) => m.kind === kind);

  async function pushFrame(trackId: string): Promise<void> {
    FakeTrackProcessor.controllers.get(trackId)!.enqueue(decodedFrame());
    // The processor loop consumes asynchronously; yield until it has.
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  beforeEach(stubWindow);

  afterEach(() => {
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    liveTracks().clear();
    delete (globalThis as { MediaStreamTrackProcessor?: unknown }).MediaStreamTrackProcessor;
    delete (globalThis as { window?: unknown }).window;
  });

  it("mints a short opaque handle per admitted track; a platform id becomes an identity upsert, never the source id", () => {
    const trackA = new FakeMediaTrack("zoom-track-a");
    const trackB = new FakeMediaTrack("zoom-track-b");
    registerLive(trackA);
    registerLive(trackB);
    const adapter = {
      platform: "zoom",
      // The platform knows track A's owner at admission; track B resolves to
      // nothing — its handle carries the audio just the same.
      identify: (track: MediaStreamTrack) => (track.id === "zoom-track-a" ? "zoom-1024" : null),
    } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter });

    const joined = ofKind("participant-joined");
    expect(joined).toHaveLength(2);
    const ids = joined.map((m) => (m.participant as { kind: string; id: string }).id);
    // Handles are track-scoped and identity-free for every track — platform-
    // identified or not — and distinct per track.
    for (const id of ids) expect(id).toMatch(/^t\d+$/);
    expect(new Set(ids).size).toBe(2);
    for (const m of joined) expect((m.participant as { kind: string }).kind).toBe("synthetic");

    // The known identity arrived as an attendee upsert linking the source.
    const identified = ofKind("participant-identified");
    expect(identified).toHaveLength(1);
    expect(identified[0]).toMatchObject({ participantId: "zoom-1024", platform: "zoom" });
    const capturedUnder = identified[0]!.captureId as string;
    expect(ids).toContain(capturedUnder);
  });

  it("keeps the handle, the pipeline, and the frame stream across a mid-call identity upgrade", async () => {
    const track = new FakeMediaTrack("meet-track");
    registerLive(track);
    let identityCb: ((trackId: string, id: string) => void) | undefined;
    const adapter = {
      platform: "meet",
      identify: () => null,
      displayName: (id: string) => (id === "spaces/s/devices/9" ? "Jane Doe" : undefined),
      onIdentity: (cb: (trackId: string, id: string) => void) => {
        identityCb = cb;
      },
    } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "meet", adapter });

    const joined = ofKind("participant-joined");
    expect(joined).toHaveLength(1);
    const handle = (joined[0]!.participant as { id: string }).id;
    expect(handle).toMatch(/^t\d+$/);

    await pushFrame("meet-track");
    const before = ofKind("pcm");
    expect(before.length).toBeGreaterThan(0);
    expect(before.at(-1)).toMatchObject({ participantId: handle, seq: before.length });

    // The engine confirms the track's owner mid-call.
    identityCb!("meet-track", "spaces/s/devices/9");

    // No restart: nothing left, nothing re-joined, the handle unchanged —
    // the identity is a metadata upsert.
    expect(ofKind("participant-left")).toHaveLength(0);
    expect(ofKind("participant-joined")).toHaveLength(1);
    expect(ofKind("participant-identified")).toEqual([
      {
        kind: "participant-identified",
        platform: "meet",
        participantId: "spaces/s/devices/9",
        captureId: handle,
        displayName: "Jane Doe",
      },
    ]);

    // Frames continue across the upgrade on the same pipeline: same handle,
    // seq unbroken (a restart would reset the counter and lose frames).
    await pushFrame("meet-track");
    const after = ofKind("pcm");
    expect(after.length).toBeGreaterThan(before.length);
    expect(after.at(-1)).toMatchObject({ participantId: handle, seq: after.length });
  });

  it("a late identity for an already-dead track still resolves to the source that recorded it", () => {
    const track = new FakeMediaTrack("meet-track-2");
    registerLive(track);
    let identityCb: ((trackId: string, id: string) => void) | undefined;
    const adapter = {
      platform: "meet",
      identify: () => null,
      onIdentity: (cb: (trackId: string, id: string) => void) => {
        identityCb = cb;
      },
    } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "meet", adapter });
    const handle = (ofKind("participant-joined")[0]!.participant as { id: string }).id;

    // The track ends before the correlation confirms (the Etel case)…
    track.readyState = "ended";
    liveTracks().clear();
    // …and the identity still lands as the same upsert, keyed by track id.
    identityCb!("meet-track-2", "spaces/s/devices/14");

    expect(ofKind("participant-identified")).toEqual([
      {
        kind: "participant-identified",
        platform: "meet",
        participantId: "spaces/s/devices/14",
        captureId: handle,
      },
    ]);
  });

  it("re-adoption across an epoch handoff keeps the track's handle (a new generation, not a new source)", () => {
    const track = new FakeMediaTrack("stable-track");
    registerLive(track);
    const adapter = { platform: "zoom", identify: () => null } as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter });
    const first = ofKind("participant-joined");
    expect(first).toHaveLength(1);
    const handle = (first[0]!.participant as { id: string }).id;
    expect(first[0]).toMatchObject({ generation: 1 });

    // A re-inject supersedes the epoch and replays the live registry.
    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter });
    const joined = ofKind("participant-joined");
    expect(joined).toHaveLength(2);
    expect(joined[1]).toMatchObject({ generation: 2 });
    expect((joined[1]!.participant as { id: string }).id).toBe(handle);
  });
});

describe("initCapture epoch teardown", () => {
  beforeEach(() => {
    // initCapture touches only postMessage on window (status messages); the
    // epoch counter and track registry live as window globals and start clean
    // on a fresh stub.
    (globalThis as { window?: unknown }).window = { postMessage: () => {} };
  });

  afterEach(() => {
    delete (globalThis as { window?: unknown }).window;
  });

  it("disposes each epoch's adapter when the epoch is superseded or stopped (B10)", () => {
    const disposed: string[] = [];
    const makeAdapter = (name: string): PlatformAdapter =>
      ({
        platform: "meet",
        identify: () => null,
        dispose: () => disposed.push(name),
      }) as unknown as PlatformAdapter;

    initCapture({ epoch: claimEpoch(), platform: "meet", adapter: makeAdapter("first") });
    expect(disposed).toEqual([]); // the live epoch's adapter stays alive

    // A new epoch (re-inject / toggle cycle) supersedes: the old epoch's
    // teardown chain must dispose the old adapter, never the new one.
    initCapture({ epoch: claimEpoch(), platform: "meet", adapter: makeAdapter("second") });
    expect(disposed).toEqual(["first"]);

    // Toggling capture off tears down the final epoch via __earsTeardown.
    (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.();
    expect(disposed).toEqual(["first", "second"]);
  });

  it("survives an adapter without dispose, and a dispose that throws", () => {
    const noDispose = { platform: "zoom", identify: () => null } as unknown as PlatformAdapter;
    initCapture({ epoch: claimEpoch(), platform: "zoom", adapter: noDispose });

    const throwing = {
      platform: "meet",
      identify: () => null,
      dispose: () => {
        throw new Error("identity teardown must never break capture teardown");
      },
    } as unknown as PlatformAdapter;
    initCapture({ epoch: claimEpoch(), platform: "meet", adapter: throwing });

    expect(() =>
      (window as unknown as { __earsTeardown?: () => void }).__earsTeardown?.(),
    ).not.toThrow();
  });
});
