import type { Platform } from "./protocol";

// The seam-agnostic frame pipeline (refactor R7): everything between "a frame
// source produced decoded audio" and "16 kHz mono Int16 frames left for the
// isolated relay" — resampler, ring buffer, the MediaStreamTrackProcessor
// frame source, and the silent-capture watchdog. No module state: each
// pipeline owns its instances, and the orchestration layer (audio-tap.ts)
// wires them together.

export const TARGET_SAMPLE_RATE = 16000;
// Bounded per-participant ring buffer. ~10 frames/s; 50 frames ≈ 5 s of slack
// before we drop the oldest frame (back-pressure toward the transport).
export const RING_CAPACITY = 50;

export const FRAME_SAMPLES = 1600; // 100 ms @ 16 kHz → ~10 frames/s

// WebCodecs AudioData surface we use (avoids ambient-declaration conflicts).
export interface AudioDataLike {
  readonly sampleRate: number;
  readonly numberOfFrames: number;
  readonly numberOfChannels: number;
  readonly format: string | null;
  copyTo(dest: Float32Array, options: { planeIndex: number; format?: string }): void;
  close(): void;
}

export interface FrameSource {
  /** Begin producing frames. Called at most once. */
  start(): void;
  /** Stop producing frames and release resources. Idempotent. */
  stop(): void;
}

export type FrameSourceFactory = (
  onFrame: (frame: AudioDataLike) => void,
  onFatalError: (reason: string) => void,
) => FrameSource;

// A track that unmutes but never yields a decoded frame is the silent-capture
// failure (journal #72): on Meet the encoded-audio tee may never wrap the
// receiver, so the decoder is fed nothing and the whole call records silence
// while +track/unmute/identity all still look healthy. The grace window covers
// the ~1-frame latency between an unmute and the first decoded frame with wide
// margin, so a brief blip never false-positives.
export const SILENT_CAPTURE_GRACE_MS = 4_000;

/**
 * Decide how to surface a track that unmuted but produced no decoded frame.
 * Meet delivers no audio for an unmuted-but-silent participant (DTX / noise
 * suppression), so "no frames" alone is NOT proof of breakage. Escalate to a
 * loud warning only when nothing has decoded anywhere on the call
 * (`anyAudioThisCall === false`) — the same condition the call-level tee
 * watchdog flags. If other participants are being captured, this one is simply
 * quiet: a benign info note, never a scary ⚠ (journal #67: quiet ≠ broken).
 */
export function silentReport(
  participantId: string,
  platform: Platform | undefined,
  anyAudioThisCall: boolean,
  graceMs: number,
): { level: "warn" | "info"; text: string } {
  const secs = Math.round(graceMs / 1000);
  if (anyAudioThisCall) {
    return {
      level: "info",
      text:
        `${participantId} unmuted but no audio decoded in ${secs}s` +
        " — likely silent or noise-suppressed (other participants are being captured)",
    };
  }
  const hint =
    platform === "meet"
      ? " — Meet exposes no decodable track audio, so no encoded frames reached the decoder" +
        " (createEncodedStreams not intercepted, or Meet changed its audio pipeline)." +
        " Reload the tab to re-arm."
      : "";
  return {
    level: "warn",
    text: `⚠ ${participantId} unmuted but no audio decoded in ${secs}s — capture is SILENT for this participant${hint}`,
  };
}

/**
 * Per-track detector for the silent-capture failure. `armOnUnmute()` starts a
 * one-shot timer; unless `noteFrame()` lands before it fires, `onSilent` runs
 * once (latched for the track's life). Kept free of TrackCapture's
 * window/postMessage wiring so it unit-tests under fake timers.
 */
export class SilentCaptureWatchdog {
  private firstFrameSeen = false;
  private reported = false;
  private timer?: ReturnType<typeof setTimeout>;

  constructor(
    private readonly onSilent: (graceMs: number) => void,
    private readonly graceMs: number = SILENT_CAPTURE_GRACE_MS,
  ) {}

  /** The track unmuted — a decoded frame must follow. Arm once; ignore repeat
   * unmutes and any unmute after a frame already proved capture live. */
  armOnUnmute(): void {
    if (this.firstFrameSeen || this.reported || this.timer !== undefined) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (this.firstFrameSeen || this.reported) return;
      this.reported = true;
      this.onSilent(this.graceMs);
    }, this.graceMs);
  }

  /** A decoded frame arrived — capture is live; cancel the watchdog for good. */
  noteFrame(): void {
    if (this.firstFrameSeen) return;
    this.firstFrameSeen = true;
    this.clearTimer();
  }

  stop(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }
}

// ── Standard path: MediaStreamTrackProcessor (Zoom, Teams) ─────────────────
//
// Read decoded audio frames straight off the MediaStreamTrack (WebCodecs
// breakout box). Unlike a WebAudio MediaStreamAudioSourceNode, this needs no
// AudioContext and no playing media element, so it doesn't hit the remote-track
// silence bug (verified: on real Meet the WebAudio tap read digital silence
// even with a playing mirror; the breakout box reads the true audio — though
// on Meet even this reads nothing at all, see MeetDecodeSource in
// meet-decode.ts).

type TrackProcessorCtor = new (init: { track: MediaStreamTrack }) => {
  readable: ReadableStream<AudioDataLike>;
};

export class TrackProcessorSource implements FrameSource {
  private stopped = false;
  private reader?: ReadableStreamDefaultReader<AudioDataLike>;
  private unmuteHandler?: () => void;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
  ) {}

  start(): void {
    if (this.track.muted) {
      // A MediaStreamTrackProcessor constructed on a MUTED track never delivers
      // frames — even after the track unmutes — and a track allows only one
      // processor ever. So defer construction until the track's first unmute.
      const onUnmute = () => {
        this.track.removeEventListener("unmute", onUnmute);
        this.unmuteHandler = undefined;
        if (!this.stopped) this.begin();
      };
      this.unmuteHandler = onUnmute;
      this.track.addEventListener("unmute", onUnmute);
      return;
    }
    this.begin();
  }

  stop(): void {
    this.stopped = true;
    if (this.unmuteHandler) {
      this.track.removeEventListener("unmute", this.unmuteHandler);
      this.unmuteHandler = undefined;
    }
    this.reader?.cancel().catch(() => {});
  }

  private begin(): void {
    const Ctor = (globalThis as unknown as { MediaStreamTrackProcessor?: TrackProcessorCtor })
      .MediaStreamTrackProcessor;
    if (!Ctor) {
      this.onFatalError("MediaStreamTrackProcessor unavailable");
      return;
    }
    try {
      this.reader = new Ctor({ track: this.track }).readable.getReader();
    } catch (err) {
      this.onFatalError(`failed to construct processor: ${String(err)}`);
      return;
    }
    void this.loop();
  }

  private async loop(): Promise<void> {
    const reader = this.reader!;
    while (!this.stopped) {
      let done = false;
      let value: AudioDataLike | undefined;
      try {
        ({ done, value } = await reader.read());
      } catch (err) {
        if (!this.stopped) this.onFatalError(`reader.read() threw: ${String(err)}`);
        return;
      }
      if (done) {
        if (!this.stopped) this.onFatalError("track reader closed");
        return;
      }
      if (!value) continue;
      try {
        this.onFrame(value);
      } finally {
        value.close();
      }
    }
  }
}

export function trackProcessorSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new TrackProcessorSource(track, onFrame, onFatalError);
}

/**
 * Streaming linear resampler (inRate → outRate), phase-continuous across chunks.
 * Linear interpolation is adequate for speech at these rates. Shared unmodified
 * by every frame source — TrackCapture doesn't know or care where a frame came from.
 */
export class LinearResampler {
  private readonly step: number; // input samples advanced per output sample
  private cursor = 0; // fractional read position within the pending buffer
  private buf = new Float32Array(0);

  constructor(inRate: number, outRate: number) {
    this.step = inRate / outRate;
  }

  process(input: Float32Array): Float32Array {
    const merged = new Float32Array(this.buf.length + input.length);
    merged.set(this.buf);
    merged.set(input, this.buf.length);

    const out: number[] = [];
    let pos = this.cursor;
    while (Math.floor(pos) + 1 < merged.length) {
      const i = Math.floor(pos);
      const frac = pos - i;
      out.push(merged[i]! * (1 - frac) + merged[i + 1]! * frac);
      pos += this.step;
    }
    const keep = Math.floor(pos);
    this.buf = merged.slice(keep);
    this.cursor = pos - keep;
    return Float32Array.from(out);
  }
}

// Bounded ring buffer, drop-oldest, with a logged dropped counter — never grows
// unbounded. Drop-oldest keeps the freshest audio when the consumer stalls.
export class RingBuffer {
  private q: Int16Array[] = [];
  private dropped = 0;
  constructor(
    private readonly capacity: number,
    private readonly label: string,
  ) {}

  push(frame: Int16Array): void {
    if (this.q.length >= this.capacity) {
      this.q.shift();
      this.dropped++;
      if (this.dropped % 50 === 1) {
        console.warn(`[ears][capture] ring overflow for ${this.label}: dropped ${this.dropped} frame(s)`);
      }
    }
    this.q.push(frame);
  }

  drain(): Int16Array[] {
    const out = this.q;
    this.q = [];
    return out;
  }
}
