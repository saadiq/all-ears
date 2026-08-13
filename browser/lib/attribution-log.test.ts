import { describe, expect, it } from "vitest";
import {
  ATTRIBUTION_RING_CAPACITY,
  ATTRIBUTION_SCHEMA,
  AttributionRing,
  bytesToBase64,
  decodeAttributionLine,
  encodeAttributionEvent,
  type AttributionEvent,
} from "./attribution-log";

// Pure tier-0 unit: every timestamp is injected, nothing reads the clock.
const T0 = 1_723_500_000_000;

// One representative event per variant of the vocabulary, with SANITIZED,
// synthetic values only (per the flight-recorder privacy rule: real device-id
// paths and display names never enter the repo).
const fixtures: AttributionEvent[] = [
  {
    type: "track-appeared",
    t: T0,
    trackId: "trk-1",
    seam: "receiver-track",
    muted: true,
    origin: "remote",
    rootId: "trk-1",
  },
  { type: "track-unmuted", t: T0 + 1, trackId: "trk-1" },
  { type: "track-muted", t: T0 + 2, trackId: "trk-1" },
  { type: "track-ended", t: T0 + 3, trackId: "trk-1" },
  {
    type: "admitted",
    t: T0 + 4,
    trackId: "trk-1",
    seam: "receiver-track",
    participantId: "speaker-1",
    generation: 1,
  },
  { type: "deferred", t: T0 + 5, trackId: "trk-2", seam: "receiver-track", reason: "muted at dispatch" },
  {
    type: "adopted",
    t: T0 + 6,
    trackId: "trk-3",
    seam: "webaudio-track",
    reason: "unknown via=createMediaStreamSource",
  },
  { type: "retired", t: T0 + 7, trackId: "trk-3", reason: "local via=sender root=trk-0" },
  {
    type: "escalated",
    t: T0 + 8,
    from: "receiver-track",
    to: "webaudio-track",
    reason: "no frame decoded within the unmute grace window",
  },
  {
    type: "collections-edge",
    t: T0 + 9,
    deviceId: "spaces/demo/devices/1",
    micOpen: true,
    rawB64: bytesToBase64(new Uint8Array([0x1f, 0x8b, 0x08, 0x00])),
  },
  { type: "dom-burst", t: T0 + 10, deviceId: "spaces/demo/devices/2" },
  {
    type: "audio-onset",
    t: T0 + 11,
    participantId: "speaker-1",
    trackId: "trk-1",
    state: "start",
    framePeak: 0.0421,
  },
  {
    type: "roster-delta",
    t: T0 + 12,
    entries: [
      { participantId: "spaces/demo/devices/1", displayName: "Ada Fixture" },
      { participantId: "spaces/demo/devices/2", displayName: "Ben Fixture", isLocal: true },
    ],
  },
  {
    type: "provisional-binding",
    t: T0 + 13,
    trackId: "trk-1",
    deviceId: "spaces/demo/devices/1",
    correlator: "dom",
    confirmations: 2,
    outcome: "bound",
  },
  {
    type: "identity-link",
    t: T0 + 14,
    trackId: "trk-1",
    captureId: "t3",
    participantId: "spaces/demo/devices/1",
  },
];

describe("encodeAttributionEvent / decodeAttributionLine", () => {
  it("round-trips every event variant losslessly", () => {
    for (const event of fixtures) {
      expect(decodeAttributionLine(encodeAttributionEvent(event))).toEqual(event);
    }
  });

  it("encodes one JSON object per line, versioned with the schema field", () => {
    for (const event of fixtures) {
      const line = encodeAttributionEvent(event);
      expect(line).not.toContain("\n");
      const parsed = JSON.parse(line) as Record<string, unknown>;
      expect(parsed.schema).toBe(ATTRIBUTION_SCHEMA);
      expect(parsed.type).toBe(event.type);
      expect(parsed.t).toBe(event.t);
    }
  });

  it("golden: the encoded wire shape is stable field-for-field", () => {
    const line = encodeAttributionEvent({
      type: "provisional-binding",
      t: T0,
      trackId: "trk-1",
      deviceId: "spaces/demo/devices/1",
      correlator: "unmute",
      confirmations: 2,
      outcome: "refused-rebind",
    });
    expect(JSON.parse(line)).toEqual({
      schema: 1,
      type: "provisional-binding",
      t: T0,
      trackId: "trk-1",
      deviceId: "spaces/demo/devices/1",
      correlator: "unmute",
      confirmations: 2,
      outcome: "refused-rebind",
    });
  });

  it("rejects lines that are not attribution events", () => {
    expect(decodeAttributionLine("not json")).toBeNull();
    expect(decodeAttributionLine("[]")).toBeNull(); // an array is not an event object
    expect(decodeAttributionLine('{"type":"track-ended","t":1}')).toBeNull(); // no schema
    expect(decodeAttributionLine('{"schema":999,"type":"track-ended","t":1}')).toBeNull(); // unknown schema
    expect(decodeAttributionLine('{"schema":1,"type":"mystery","t":1}')).toBeNull(); // unknown type
    expect(decodeAttributionLine('{"schema":1,"type":"track-ended"}')).toBeNull(); // no timestamp
  });
});

describe("AttributionRing", () => {
  it("keeps events in order and snapshots without draining", () => {
    const ring = new AttributionRing(4);
    ring.push("a");
    ring.push("b");
    expect(ring.size).toBe(2);
    expect(ring.snapshot()).toEqual(["a", "b"]);
    expect(ring.size).toBe(2); // snapshot is a copy, not a drain
  });

  it("bounds itself by dropping the oldest and counting the drops", () => {
    const ring = new AttributionRing(3);
    for (const line of ["a", "b", "c", "d", "e"]) ring.push(line);
    expect(ring.size).toBe(3);
    expect(ring.snapshot()).toEqual(["c", "d", "e"]);
    expect(ring.dropped).toBe(2);
  });

  it("drains everything and starts empty again", () => {
    const ring = new AttributionRing(3);
    ring.push("a");
    ring.push("b");
    expect(ring.drain()).toEqual(["a", "b"]);
    expect(ring.size).toBe(0);
    expect(ring.drain()).toEqual([]);
  });

  it("defaults to the documented capacity", () => {
    const ring = new AttributionRing();
    for (let i = 0; i < ATTRIBUTION_RING_CAPACITY + 5; i++) ring.push(`line-${i}`);
    expect(ring.size).toBe(ATTRIBUTION_RING_CAPACITY);
    expect(ring.dropped).toBe(5);
  });
});

describe("bytesToBase64", () => {
  it("encodes raw payload bytes for the collections-edge event", () => {
    expect(bytesToBase64(new Uint8Array([]))).toBe("");
    expect(bytesToBase64(new Uint8Array([0x1f, 0x8b, 0x08, 0x00]))).toBe("H4sIAA==");
    // Longer than one chunk boundary's worth still round-trips.
    const big = new Uint8Array(70_000).map((_, i) => i % 251);
    const decoded = Uint8Array.from(atob(bytesToBase64(big)), (c) => c.charCodeAt(0));
    expect(decoded).toEqual(big);
  });
});
