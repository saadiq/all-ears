import {
  setEncodedAudioListener,
  type EncodedAudioFrameLike,
  type EncodedAudioListener,
} from "./rtc-hook";
import { captureMetrics, DEBUG_AUDIO_NOW } from "./capture-instrumentation";
import { perfEnabled } from "./perf-main";
import type { AudioDataLike, FrameSource, FrameSourceFactory } from "./frame-pipeline";

// ── Meet path: AudioDecoder fed by rtc-hook.ts's encoded-audio tee ─────────
//
// Standard path never works on Meet (confirmed empirically — see rtc-hook.ts
// and specs/extension.md §Audio extraction). Readiness here is "rtc-hook.ts
// has a tee'd branch for this track and is willing to dispatch frames to us",
// not track-mute state: once createEncodedStreams() is in play, Meet's own
// decode pipeline owns track.muted and it stops reflecting anything
// meaningful for our purposes.

interface EncodedAudioChunkInit {
  type: "key" | "delta";
  timestamp: number;
  data: ArrayBuffer;
}
type EncodedAudioChunkCtor = new (init: EncodedAudioChunkInit) => unknown;

interface AudioDecoderLike {
  configure(config: { codec: string; sampleRate: number; numberOfChannels: number }): void;
  decode(chunk: unknown): void;
  close(): void;
}
type AudioDecoderCtor = new (init: {
  output: (frame: AudioDataLike) => void;
  error: (err: Error) => void;
}) => AudioDecoderLike;

// A single transient bad frame puts the whole AudioDecoder into a permanent
// error state (WebCodecs gives no per-frame recovery, and the error callback
// carries no chunk reference). Killing the participant's capture over one such
// frame is wrong: live evidence shows the *same* track decodes cleanly on a
// fresh decoder immediately afterwards (a decoder that died mid-call went on
// to decode ~9.8k subsequent frames with zero errors once reconstructed). So
// MeetDecodeSource restarts its decoder in place — the encoded-audio tee keeps
// feeding this track for its whole life, so a rebuilt decoder resumes with no
// participant-left/joined churn and no daemon-source close.
//
// The spiral issue #22 fixes: Meet changes the Opus stream mid-call (bitrate /
// DTX as speakers pause) and a short burst of frames won't decode from a cold
// decoder. The old budget counted every rebuild equally, so a poisoned burst
// re-fed into a fresh decoder frame-by-frame exhausted all 5 restarts in under
// a second and dropped the track. Two changes break that, distinguishing "same
// frame fails repeatedly" (skip it) from "decoder broken" (rebuild):
//
//   1. A rebuilt decoder that dies before decoding anything (a *barren*
//      restart) does NOT re-feed the frames that just failed. It cools down for
//      DECODER_RESTART_COOLDOWN_MS — dropping the poisoned window — then
//      rebuilds on the next live frame: "resume at the next decodable
//      boundary", not "replay the recent frame window". That paces barren
//      restarts at most one per cooldown, so one bad burst can't burn the whole
//      budget in <1s.
//   2. A decoder that WAS decoding cleanly (>= DECODER_HEALTHY_FRAMES) before an
//      error is a distinct incident, not a spiral: it rebuilds immediately
//      (near-zero audio loss) and its recovery resets the restart budget. Only
//      barren restarts count toward giving up.
//
// Past DECODER_MAX_RESTARTS barren restarts within a sliding
// DECODER_RESTART_WINDOW_MS we stop and fall through to the fatal path (stops
// the pipeline once; TrackCapture then emits a capture-failed event so the
// daemon can attribute the gap instead of just seeing the source go quiet).
const DECODER_RESTART_WINDOW_MS = 30_000;
export const DECODER_MAX_RESTARTS = 5;
// A rebuilt decoder that decodes this many frames (~200ms of Opus at 20ms /
// frame) has proven it can decode from a cold start — the poisoned boundary is
// behind it. Reaching it resets the restart budget; an error after it rebuilds
// immediately instead of counting toward give-up.
export const DECODER_HEALTHY_FRAMES = 10;
// After a barren restart, drop incoming frames for this long before spending the
// next restart. Long enough for a mid-stream Opus parameter change to finish so
// the rebuilt decoder lands on a decodable boundary; short enough that recovery
// costs ~1s of audio, not the whole speaking turn.
export const DECODER_RESTART_COOLDOWN_MS = 1_000;

/** Injection seam for MeetDecodeSource — production reads globals + rtc-hook;
 * tests supply fakes and a controllable clock. All optional. */
export interface MeetDecodeDeps {
  decoderCtor?: AudioDecoderCtor;
  chunkCtor?: EncodedAudioChunkCtor;
  /** Subscribe to (listener) / unsubscribe from (null) this track's encoded-audio tee. */
  subscribe?: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  /** ms clock for the restart sliding window. */
  now?: () => number;
}

/** One recently-fed encoded frame, kept for post-hoc error forensics. */
interface FrameForensic {
  byteLength: number;
  timestamp: number;
  /** Opus TOC byte (config / stereo / frame-count code). A mid-stream bitrate
   * or DTX change — the suspected poison — shows up here as a changed config. */
  toc: number;
}

/**
 * Unwrap an RFC 2198 RED payload to its primary (current) block, or return
 * null when `data` doesn't parse as RED.
 *
 * Meet wraps its Opus stream in RED adaptively (redundancy kicks in under
 * packet loss), and those packets reach the encoded-audio tee as-is: the
 * 2026-07-24 live captures show every "AudioDecoder error: Decoding error"
 * frame starting 0xEF — not an Opus TOC but the RED block header
 * `F=1 | PT=111` (111 is Meet's Opus payload type). Feeding RED to a plain
 * Opus decoder fails per-packet, which is journal #45's entire error class.
 *
 * Wire shape (RFC 2198): N redundant-block headers (4 bytes each, F bit set:
 * F|PT, 14-bit timestamp offset, 10-bit block length), one primary header
 * (1 byte, F bit clear), then the blocks in header order — redundant blocks
 * first at their declared lengths, primary block last taking the remainder.
 * The primary block is the current frame; redundant blocks re-carry earlier
 * frames the decoder has usually already seen, so only the primary is fed.
 *
 * Defensive by contract: a genuine Opus TOC can also carry the high bit, so
 * a payload is only treated as RED when the full header chain parses — every
 * header PT identical and the declared redundant lengths fitting exactly
 * inside the payload. Anything else returns null and is fed to the decoder
 * unchanged.
 */
export function unwrapRedPayload(data: ArrayBuffer): ArrayBuffer | null {
  const bytes = new Uint8Array(data);
  let offset = 0;
  let redundantBytes = 0;
  let redundantHeaders = 0;
  let primaryPT = -1;
  while (offset < bytes.length) {
    const first = bytes[offset]!;
    const pt = first & 0x7f;
    if (primaryPT === -1) primaryPT = pt;
    else if (pt !== primaryPT) return null; // mixed PTs — not a RED chain
    if ((first & 0x80) === 0) {
      // Primary header (1 byte) — blocks follow.
      if (redundantHeaders === 0) return null; // no redundancy → plain payload
      const blocksStart = offset + 1;
      const primaryStart = blocksStart + redundantBytes;
      if (primaryStart >= bytes.length) return null; // lengths don't fit
      return bytes.slice(primaryStart).buffer;
    }
    if (offset + 4 > bytes.length) return null; // truncated header
    redundantBytes += ((bytes[offset + 2]! & 0x03) << 8) | bytes[offset + 3]!;
    redundantHeaders += 1;
    offset += 4;
  }
  return null; // ran out of bytes before a primary header
}

export class MeetDecodeSource implements FrameSource {
  private stopped = false;
  private decoder?: AudioDecoderLike;
  private decoderCtor?: AudioDecoderCtor;
  private chunkCtor?: EncodedAudioChunkCtor;
  private readonly subscribe: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  private readonly now: () => number;
  /** ms timestamps of barren restarts still inside the sliding window. */
  private restarts: number[] = [];
  /** Successful decodes since the current decoder was built. 0 = barren so far;
   * >= DECODER_HEALTHY_FRAMES = the decoder has recovered. */
  private framesSinceBuild = 0;
  /** Set when the decoder has died and is cooling down before its next rebuild;
   * frames arriving before now() reaches it + COOLDOWN are dropped (skipping the
   * poisoned window). undefined while a decoder is live. */
  private coolingSince?: number;
  // AudioDecoder's error callback gives a generic DOMException with no reference
  // to which chunk failed, so keep a small rolling window of what we recently
  // fed it. Always populated (small, cheap) — you can't arm the debug flag after
  // the error already happened, and issue #22 needs this for every error.
  private recentFrames: FrameForensic[] = [];
  // Per-track give-up summary (logged when we stop restarting).
  private readonly startedAt: number;
  private totalFramesDecoded = 0;
  private totalErrors = 0;
  private framesDroppedRecovering = 0;
  /** RED payloads unwrapped to their primary block (see unwrapRedPayload). */
  private redFramesUnwrapped = 0;
  private firstErrorReason?: string;
  private lastErrorReason?: string;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
    private readonly deps: MeetDecodeDeps = {},
  ) {
    this.subscribe = deps.subscribe ?? setEncodedAudioListener;
    this.now = deps.now ?? (() => Date.now());
    this.startedAt = this.now();
  }

  start(): void {
    const DecoderCtor = this.deps.decoderCtor ?? (globalThis as unknown as { AudioDecoder?: AudioDecoderCtor }).AudioDecoder;
    const ChunkCtor = this.deps.chunkCtor ?? (globalThis as unknown as { EncodedAudioChunk?: EncodedAudioChunkCtor }).EncodedAudioChunk;
    if (!DecoderCtor || !ChunkCtor) {
      // Not expected to trigger (AudioDecoder opus support confirmed on-build),
      // but fall back cleanly: skip this participant, don't crash the hook.
      this.onFatalError("AudioDecoder/EncodedAudioChunk unavailable — cannot decode Meet audio");
      return;
    }
    this.decoderCtor = DecoderCtor;
    this.chunkCtor = ChunkCtor;
    if (!this.buildDecoder()) return; // construction failed — fatal already reported
    this.subscribe(this.track, (frame) => this.onEncodedFrame(frame));
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.subscribe(this.track, null);
    this.closeDecoder();
  }

  /** Construct + configure a fresh decoder. Returns false (after reporting a
   * fatal error) if construction itself fails — that's not recoverable. */
  private buildDecoder(): boolean {
    try {
      this.decoder = new this.decoderCtor!({
        output: (frame) => this.onDecodedFrame(frame),
        error: (err) => this.onDecoderError(`AudioDecoder error: ${err.message ?? String(err)}`),
      });
      // Stereo, not mono: every "Decoding error" frame captured live carries
      // TOC 0xef — Opus config 29 with the STEREO flag set. Meet switches its
      // per-speaker stream between mono and stereo packets mid-call, and a
      // mono-configured decoder dies on each stereo packet (journal #45's
      // whole error class, root-caused 2026-07-24 during the drift capture —
      // dev/captures/2026-07-24-meet-collections-drift.md). An Opus decoder
      // configured stereo decodes BOTH: mono packets upmix to two identical
      // channels, and consume()'s downmix folds either shape back to mono.
      this.decoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 2 });
      this.framesSinceBuild = 0;
      this.coolingSince = undefined;
      return true;
    } catch (err) {
      this.onFatalError(`failed to construct AudioDecoder: ${String(err)}`);
      return false;
    }
  }

  private closeDecoder(): void {
    try {
      this.decoder?.close();
    } catch {
      // already closed (an errored decoder self-closes)
    }
    this.decoder = undefined;
  }

  /** A frame decoded successfully. Track health so a decoder that gets going
   * again resets the restart budget (its failure was a distinct incident, not a
   * spiral). */
  private onDecodedFrame(frame: AudioDataLike): void {
    this.framesSinceBuild++;
    this.totalFramesDecoded++;
    if (this.framesSinceBuild === DECODER_HEALTHY_FRAMES && this.restarts.length > 0) {
      console.debug(
        `[ears][capture] ${this.track.id} decoder recovered — ` +
          `${DECODER_HEALTHY_FRAMES} frames decoded since rebuild; restart budget reset`,
      );
      this.restarts = [];
    }
    this.onFrame(frame);
  }

  /** Decoder-level failure (error callback or decode() throw). A decoder that
   * was healthy rebuilds immediately; a barren one cools down (see the class
   * comment) so a poisoned burst can't spiral through the budget. */
  private onDecoderError(reason: string): void {
    if (this.stopped) return;
    const now = this.now();
    this.totalErrors++;
    this.firstErrorReason ??= reason;
    this.lastErrorReason = reason;

    const decodedThisLife = this.framesSinceBuild;
    const healthy = decodedThisLife >= DECODER_HEALTHY_FRAMES;
    this.logDecoderError(reason, decodedThisLife, healthy);
    this.closeDecoder();

    if (healthy) {
      // Isolated error after a clean run — a distinct incident, not the spiral.
      // Rebuild immediately (near-zero audio loss) and clear the barren budget.
      this.restarts = [];
      console.warn(`[ears][capture] ${this.track.id} decoder rebuilt in place after a healthy run — ${reason}`);
      this.buildDecoder();
      return;
    }

    // Barren: the decoder died before proving it could decode from here. Don't
    // re-feed the same frames — cool down, dropping them, and rebuild on the
    // next live frame past the cooldown (see onEncodedFrame). Budget is spent at
    // that rebuild, so barren restarts can't accumulate faster than one per
    // cooldown.
    this.coolingSince = now;
    const pending = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS).length;
    console.warn(
      `[ears][capture] ${this.track.id} decoder died barren (${decodedThisLife} frame(s) since rebuild) — ` +
        `cooling down ${DECODER_RESTART_COOLDOWN_MS}ms before restart ${pending + 1}/${DECODER_MAX_RESTARTS}`,
    );
  }

  /** Rebuild after a barren restart's cooldown. Spends a budget slot; gives up
   * (fatal, exactly once) if the budget is exhausted. Returns false on give-up. */
  private restartDecoder(): boolean {
    const now = this.now();
    this.restarts = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS);
    if (this.restarts.length >= DECODER_MAX_RESTARTS) {
      this.giveUp(now);
      return false;
    }
    this.restarts.push(now);
    console.warn(
      `[ears][capture] ${this.track.id} decoder restart ${this.restarts.length}/${DECODER_MAX_RESTARTS} ` +
        `(resuming at a fresh frame; ${this.framesDroppedRecovering} frame(s) dropped while recovering)`,
    );
    return this.buildDecoder();
  }

  /** Restart budget exhausted: log a per-track summary and go fatal once. */
  private giveUp(now: number): void {
    const seconds = ((now - this.startedAt) / 1000).toFixed(1);
    console.error(
      `[ears][capture] ${this.track.id} giving up — capture summary: ` +
        `${this.totalFramesDecoded} frame(s) decoded over ${seconds}s, ` +
        `${this.totalErrors} decoder error(s), ${this.restarts.length} restart(s) in window, ` +
        `${this.framesDroppedRecovering} frame(s) dropped while recovering, ` +
        `${this.redFramesUnwrapped} RED payload(s) unwrapped; ` +
        `first error: ${this.firstErrorReason ?? "n/a"}; last error: ${this.lastErrorReason ?? "n/a"}`,
    );
    this.onFatalError(
      `${this.lastErrorReason ?? "decoder error"} — ${this.restarts.length} decoder restarts within ` +
        `${DECODER_RESTART_WINDOW_MS / 1000}s, giving up`,
    );
  }

  private logDecoderError(reason: string, decodedThisLife: number, healthy: boolean): void {
    const last = this.recentFrames.at(-1);
    const frameDesc = last
      ? `${last.byteLength}B ts=${last.timestamp} toc=0x${(last.toc & 0xff).toString(16).padStart(2, "0")}`
      : "none";
    console.error(
      `[ears][capture] ${this.track.id} ${reason} — ${healthy ? "decoder was healthy" : "barren decoder"}, ` +
        `${decodedThisLife} frame(s) decoded since rebuild; failing frame ~${frameDesc}`,
    );
    if (DEBUG_AUDIO_NOW()) {
      console.debug(
        `[ears][debug][audio] ${this.track.id} decoder error — last ${this.recentFrames.length} frames fed:`,
        this.recentFrames,
      );
    }
  }

  private onEncodedFrame(raw: EncodedAudioFrameLike): void {
    if (this.stopped) return;
    // Meet interleaves RED-encapsulated packets into the Opus stream when its
    // redundancy kicks in; unwrap those to their primary Opus block before
    // decode (see unwrapRedPayload). Non-RED payloads pass through untouched.
    let frame = raw;
    const primary = unwrapRedPayload(raw.data);
    if (primary) {
      frame = { data: primary, timestamp: raw.timestamp };
      this.redFramesUnwrapped++;
      if (this.redFramesUnwrapped === 1) {
        console.debug(
          `[ears][capture] ${this.track.id} RED-encapsulated audio detected — unwrapping primary Opus blocks`,
        );
      }
    }
    this.recordFrame(frame);
    if (!this.decoder) {
      // Decoder died and is cooling down: drop frames from before the next
      // decodable boundary rather than re-feeding the poisoned window into a
      // fresh decoder (the old restart spiral). Rebuild once the cooldown has
      // elapsed, resuming at this live frame.
      const cooling = this.coolingSince ?? 0;
      if (this.now() - cooling < DECODER_RESTART_COOLDOWN_MS) {
        this.framesDroppedRecovering++;
        return;
      }
      if (!this.restartDecoder()) return; // gave up — fatal already reported
    }
    if (!this.decoder || !this.chunkCtor) return;
    try {
      // Opus has no inter-frame prediction — every chunk is a keyframe.
      this.decoder.decode(new this.chunkCtor({ type: "key", timestamp: frame.timestamp, data: frame.data }));
      // A queue that grows means decode is falling behind delivery — the one
      // capture-path backlog that isn't visible from timing the JS stages,
      // because WebCodecs decodes off-thread.
      if (perfEnabled()) {
        const depth = (this.decoder as { decodeQueueSize?: number }).decodeQueueSize;
        if (typeof depth === "number") captureMetrics().decodeQueue.set(depth);
      }
    } catch (err) {
      this.onDecoderError(`decode() threw: ${String(err)}`);
    }
  }

  private recordFrame(frame: EncodedAudioFrameLike): void {
    const toc = frame.data.byteLength > 0 ? new Uint8Array(frame.data)[0]! : -1;
    this.recentFrames.push({ byteLength: frame.data.byteLength, timestamp: frame.timestamp, toc });
    if (this.recentFrames.length > 8) this.recentFrames.shift();
  }
}

export function meetDecodeSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new MeetDecodeSource(track, onFrame, onFatalError);
}
