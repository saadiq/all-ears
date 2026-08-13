import { beforeEach, describe, expect, it } from "vitest";
import {
  DECODER_HEALTHY_FRAMES,
  DECODER_MAX_RESTARTS,
  DECODER_RESTART_COOLDOWN_MS,
  MeetDecodeSource,
  unwrapRedPayload,
  type MeetDecodeDeps,
} from "./meet-decode";
import type { EncodedAudioListener } from "./rtc-hook";

// ── Meet decoder recovery (restart-in-place, bounded budget) ────────────────

// A fake WebCodecs AudioDecoder whose `error` callback the test drives on
// demand. Every construction (including a post-error rebuild) records itself.
// decode() synchronously fires the output callback, modelling a real decoder
// that emits a decoded frame per chunk — so the source's health counter (frames
// decoded since rebuild) advances the way it does in production.
class FakeDecoder {
  static instances: FakeDecoder[] = [];
  readonly output: (frame: unknown) => void;
  readonly error: (err: Error) => void;
  configured = false;
  closed = false;
  decoded: unknown[] = [];
  constructor(init: { output: (frame: unknown) => void; error: (err: Error) => void }) {
    this.output = init.output;
    this.error = init.error;
    FakeDecoder.instances.push(this);
  }
  configure(): void {
    this.configured = true;
  }
  decode(chunk: unknown): void {
    this.decoded.push(chunk);
    this.output({}); // a real decoder emits a decoded frame here
  }
  close(): void {
    this.closed = true;
  }
}

class FakeChunk {
  constructor(readonly init: { type: string; timestamp: number; data: ArrayBuffer }) {}
}

const DECODING_ERROR = new Error("Decoding error.");
const aFrame = () => ({ data: new ArrayBuffer(2), timestamp: 0 });

describe("unwrapRedPayload", () => {
  const PT = 111; // Meet's Opus payload type — RED headers carry 0x80|111 = 0xEF

  /** Build an RFC 2198 RED payload: redundant blocks (4-byte headers), one
   * primary (1-byte header), blocks in header order. */
  function redPayload(redundantBlocks: number[][], primary: number[]): ArrayBuffer {
    const bytes: number[] = [];
    for (const block of redundantBlocks) {
      const tsOffset = 960; // arbitrary 14-bit value
      bytes.push(0x80 | PT, (tsOffset >> 6) & 0xff, ((tsOffset & 0x3f) << 2) | ((block.length >> 8) & 0x03), block.length & 0xff);
    }
    bytes.push(PT); // primary header, F clear
    for (const block of redundantBlocks) bytes.push(...block);
    bytes.push(...primary);
    return new Uint8Array(bytes).buffer;
  }

  it("extracts the primary block from a one-redundancy payload (the live 0xEF shape)", () => {
    const redundant = [1, 2, 3, 4, 5];
    const primary = [0x78, 9, 8, 7]; // 0x78 = a plausible mono Opus TOC
    const payload = redPayload([redundant], primary);
    expect(new Uint8Array(payload)[0]).toBe(0xef); // matches every captured failing frame
    expect([...new Uint8Array(unwrapRedPayload(payload)!)]).toEqual(primary);
  });

  it("extracts the primary block past multiple redundant blocks", () => {
    const primary = [0x78, 42];
    const payload = redPayload([[1, 1, 1], [2, 2]], primary);
    expect([...new Uint8Array(unwrapRedPayload(payload)!)]).toEqual(primary);
  });

  it("returns null for a plain Opus payload whose TOC has the high bit set", () => {
    // A genuine CELT TOC (e.g. 0xFB) is not a RED chain: read as a RED header
    // its declared lengths won't fit the payload exactly.
    const opus = new Uint8Array([0xfb, 1, 2, 3, 4, 5]).buffer;
    expect(unwrapRedPayload(opus)).toBeNull();
  });

  it("returns null when header PTs disagree (not a RED chain)", () => {
    const bytes = [0x80 | PT, 0, 0, 2, 0x80 | 96, 0, 0, 1, PT, 9, 9, 8, 7];
    expect(unwrapRedPayload(new Uint8Array(bytes).buffer)).toBeNull();
  });

  it("returns null for a redundancy-free payload (F clear on the first byte)", () => {
    const opus = new Uint8Array([0x78, 1, 2, 3]).buffer; // ordinary mono TOC
    expect(unwrapRedPayload(opus)).toBeNull();
  });

  it("returns null when declared redundant lengths overrun the payload", () => {
    const bytes = [0x80 | PT, 0, 0, 200, PT, 1, 2, 3]; // claims 200B redundant, has 3
    expect(unwrapRedPayload(new Uint8Array(bytes).buffer)).toBeNull();
  });

  it("returns null for a truncated header chain", () => {
    const bytes = [0x80 | PT, 0]; // 4-byte header cut short
    expect(unwrapRedPayload(new Uint8Array(bytes).buffer)).toBeNull();
  });
});

describe("MeetDecodeSource decoder recovery", () => {
  let clock = 0;
  let listener: EncodedAudioListener | null;
  let subscribeCalls: Array<EncodedAudioListener | null>;
  let fatals: string[];
  let src: MeetDecodeSource;

  function makeSource(): MeetDecodeSource {
    const deps: MeetDecodeDeps = {
      decoderCtor: FakeDecoder as unknown as MeetDecodeDeps["decoderCtor"],
      chunkCtor: FakeChunk as unknown as MeetDecodeDeps["chunkCtor"],
      subscribe: (_track, l) => {
        listener = l;
        subscribeCalls.push(l);
      },
      now: () => clock,
    };
    const track = { id: "track-x" } as unknown as MediaStreamTrack;
    // Mirror TrackCapture.fail's wiring: a fatal error stops the source.
    const s = new MeetDecodeSource(track, () => {}, (reason) => {
      fatals.push(reason);
      s.stop();
    }, deps);
    return s;
  }

  /** Feed n live encoded frames to the current listener. */
  function feed(n: number): void {
    for (let i = 0; i < n; i++) listener!(aFrame());
  }

  beforeEach(() => {
    FakeDecoder.instances = [];
    clock = 0;
    listener = null;
    subscribeCalls = [];
    fatals = [];
    src = makeSource();
  });

  it("rebuilds immediately when a healthy decoder hits an isolated error — capture continues, not fatal", () => {
    src.start();
    expect(FakeDecoder.instances).toHaveLength(1);
    const first = FakeDecoder.instances[0]!;
    feed(DECODER_HEALTHY_FRAMES); // decoder proves healthy

    first.error(DECODING_ERROR);

    expect(fatals).toEqual([]); // recovered, no participant-left/joined churn
    expect(first.closed).toBe(true); // old decoder torn down
    expect(FakeDecoder.instances).toHaveLength(2); // fresh one built at once
    expect(FakeDecoder.instances[1]!.configured).toBe(true);

    // The same encoded-audio listener keeps feeding the fresh decoder.
    feed(1);
    expect(FakeDecoder.instances[1]!.decoded).toHaveLength(1);
    expect(subscribeCalls).toEqual([expect.any(Function)]); // never re-subscribed
  });

  it("a poisoned burst cannot exhaust the restart budget in under a second", () => {
    src.start();
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // barren → cooldown, no rebuild yet
    expect(FakeDecoder.instances).toHaveLength(1);

    // Meet floods poisoned frames every 20ms; all land inside the first second.
    for (clock = 20; clock < 1000; clock += 20) feed(1);

    expect(fatals).toEqual([]); // did NOT give up in <1s …
    expect(FakeDecoder.instances).toHaveLength(1); // … because the frames were dropped, not re-fed
  });

  it("resumes at the next decodable frame after the cooldown elapses", () => {
    src.start();
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // barren → cooldown
    feed(1); // within cooldown → dropped
    expect(FakeDecoder.instances).toHaveLength(1);

    clock = DECODER_RESTART_COOLDOWN_MS; // cooldown elapsed
    feed(1); // rebuilds and decodes on the fresh decoder
    expect(FakeDecoder.instances).toHaveLength(2);
    expect(FakeDecoder.instances[1]!.decoded).toHaveLength(1);
    expect(fatals).toEqual([]);
  });

  it("treats a decode() throw the same as a decoder error (barren → cooldown → rebuild)", () => {
    class ThrowOnceDecoder extends FakeDecoder {
      override decode(chunk: unknown): void {
        // Throw only on the first instance; rebuilt ones decode fine.
        if (FakeDecoder.instances[0] === this) throw new Error("bad state");
        super.decode(chunk);
      }
    }
    const deps: MeetDecodeDeps = {
      decoderCtor: ThrowOnceDecoder as unknown as MeetDecodeDeps["decoderCtor"],
      chunkCtor: FakeChunk as unknown as MeetDecodeDeps["chunkCtor"],
      subscribe: (_t, l) => {
        listener = l;
      },
      now: () => clock,
    };
    const s = new MeetDecodeSource({ id: "t" } as unknown as MediaStreamTrack, () => {}, (r) => fatals.push(r), deps);
    s.start();
    listener!(aFrame()); // decode throws → barren → cooldown, not fatal
    expect(fatals).toEqual([]);
    expect(FakeDecoder.instances).toHaveLength(1);

    clock = DECODER_RESTART_COOLDOWN_MS;
    listener!(aFrame()); // rebuild → decodes fine
    expect(fatals).toEqual([]);
    expect(FakeDecoder.instances).toHaveLength(2);
  });

  it("gives up (fatal exactly once) only after sustained barren restarts across seconds", () => {
    src.start();
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // first barren → cooldown

    // Each cooldown boundary yields exactly one restart that immediately dies barren.
    for (let i = 0; i <= DECODER_MAX_RESTARTS; i++) {
      clock += DECODER_RESTART_COOLDOWN_MS;
      feed(1); // rebuild attempt (or the final give-up)
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // dies barren again
    }

    expect(fatals).toHaveLength(1);
    expect(fatals[0]).toContain("giving up");
    // Budget was time-gated: give-up took at least MAX cooldowns of wall time.
    expect(clock).toBeGreaterThanOrEqual(DECODER_MAX_RESTARTS * DECODER_RESTART_COOLDOWN_MS);
    // 1 initial + exactly MAX restarts, then fatal (no further rebuilds).
    expect(FakeDecoder.instances).toHaveLength(DECODER_MAX_RESTARTS + 1);
    // Fatal path stopped the source: the tee was unsubscribed.
    expect(subscribeCalls.at(-1)).toBeNull();
  });

  it("resets the restart budget after a recovery — distinct incidents don't accumulate", () => {
    src.start();
    // Eight separate incidents (far more than the budget). The first death is
    // barren (spends/clears a restart slot, which a full recovery then wipes);
    // every later death lands on a decoder that recovered to full health, so it
    // rebuilds immediately without spending the budget. None of them add up to a
    // give-up.
    for (let incident = 0; incident < 8; incident++) {
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
      clock += DECODER_RESTART_COOLDOWN_MS;
      feed(1); // rebuild path (immediate for a healthy decoder; post-cooldown for the barren one)
      feed(DECODER_HEALTHY_FRAMES); // decoder proves healthy → budget resets
    }
    expect(fatals).toEqual([]);
  });

  it("resets the restart budget once the sliding window passes", () => {
    src.start();
    // Five barren restarts, each spaced a cooldown apart, all within the window.
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    for (let i = 0; i < DECODER_MAX_RESTARTS - 1; i++) {
      clock += DECODER_RESTART_COOLDOWN_MS;
      feed(1);
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    }
    expect(fatals).toEqual([]); // at budget, not over

    clock += 31_000; // advance past the 30s window before the next restart
    feed(1); // window pruned → restarts, not fatal
    expect(fatals).toEqual([]);
  });

  it("stays fatal when the decoder constructor is unavailable", () => {
    const deps: MeetDecodeDeps = {
      decoderCtor: undefined,
      chunkCtor: undefined,
      subscribe: () => {},
      now: () => 0,
    };
    const s = new MeetDecodeSource({ id: "t" } as unknown as MediaStreamTrack, () => {}, (r) => fatals.push(r), deps);
    s.start();
    expect(fatals).toEqual(["AudioDecoder/EncodedAudioChunk unavailable — cannot decode Meet audio"]);
    expect(FakeDecoder.instances).toHaveLength(0);
  });
});

