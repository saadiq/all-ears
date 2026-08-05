import { claimInstall } from "./epoch";
import {
  inflateGzip,
  parseCollectionsMessage,
  summarizeFields,
  type CollectionsMuteEvent,
} from "./identity/meet-collections";
import { AudioGraphRegistry } from "./meet-audio-graph";

// The RTCPeerConnection constructor hook — the singleton part of the capture
// spine, installed exactly once per page realm (claimInstall guards it). On
// meet.google.com it also wraps RTCRtpReceiver.prototype.createEncodedStreams
// (see §Meet encoded-audio tee below) — Meet's client decodes RTP itself off
// the standard pipeline, so this is the only way to ever see real audio there.
//
// Several things live on `window` so they survive across re-injected epochs,
// which each load a fresh module instance but share the one realm:
//
//   __earsOnTrack              the current epoch's track sink (audio-tap installs it)
//   __earsLiveTracks            our own registry of live remote audio tracks, so a new
//                               epoch can replay them and take over without dropping audio
//   __earsEncodedAudioListeners the current epoch's per-track Meet encoded-audio
//                               listener (audio-tap installs it, Meet only)
//
// We never enumerate getReceivers()/getTransceivers() (breaks when Zoom wraps
// tracks) and never touch transceiver.direction or SDP (the crash class). The
// hook is a passive listener on the `track` event plus an ontrack-setter wrap.

export type TrackSink = (
  track: MediaStreamTrack,
  stream: MediaStream,
  transceiver: RTCRtpTransceiver,
) => void;

export interface TrackRecord {
  stream: MediaStream;
  transceiver: RTCRtpTransceiver;
}

/** The raw pre-decode RTP frame shape delivered by createEncodedStreams()'s readable. */
export interface EncodedAudioFrameLike {
  readonly data: ArrayBuffer;
  readonly timestamp: number;
}

export type EncodedAudioListener = (frame: EncodedAudioFrameLike) => void;

interface HookWindow extends Window {
  __earsOnTrack?: TrackSink;
  __earsLiveTracks?: Map<MediaStreamTrack, TrackRecord>;
  __earsEncodedAudioListeners?: Map<MediaStreamTrack, EncodedAudioListener>;
  __earsLivePCs?: Set<RTCPeerConnection>;
  RTCPeerConnection: typeof RTCPeerConnection;
}

function hw(): HookWindow {
  return window as unknown as HookWindow;
}

/** The shared registry of currently-live remote audio tracks. */
export function liveTracks(): Map<MediaStreamTrack, TrackRecord> {
  const g = hw();
  if (!g.__earsLiveTracks) g.__earsLiveTracks = new Map();
  return g.__earsLiveTracks;
}

/**
 * The shared registry of peer connections this realm has constructed, kept so
 * the perf collector can poll `getStats()` for inbound *video* receive quality
 * (perf-sources.ts). The hook already sees every construction; nothing else in
 * the capture path needs the connection objects themselves, which is why this
 * registry did not exist before.
 *
 * Entries are dropped when the connection closes or fails, so a long call that
 * renegotiates repeatedly doesn't accumulate dead objects.
 */
export function livePeerConnections(): Set<RTCPeerConnection> {
  const g = hw();
  if (!g.__earsLivePCs) g.__earsLivePCs = new Set();
  return g.__earsLivePCs;
}

function registerPeerConnection(pc: RTCPeerConnection): void {
  const registry = livePeerConnections();
  registry.add(pc);
  pc.addEventListener("connectionstatechange", () => {
    if (pc.connectionState === "closed" || pc.connectionState === "failed") registry.delete(pc);
  });
}

/** Point the singleton hook at the newest epoch's sink. */
export function setTrackSink(sink: TrackSink): void {
  hw().__earsOnTrack = sink;
}

function dispatchTrack(e: RTCTrackEvent): void {
  if (e.track.kind !== "audio") return;
  registerTrackProvenance(e.track.id, "remote", "ontrack");
  const stream = e.streams[0] ?? new MediaStream([e.track]);
  const record: TrackRecord = { stream, transceiver: e.transceiver };
  const registry = liveTracks();
  registry.set(e.track, record);
  // Keep the registry honest so a later epoch's replay never resurrects a dead
  // track. Deleting here is safe: the sink also handles its own onended.
  e.track.addEventListener("ended", () => registry.delete(e.track));
  if (location.host === "meet.google.com") noteMeetAudioTrackLive();
  hw().__earsOnTrack?.(e.track, stream, e.transceiver);
}

function onPeerConnection(pc: RTCPeerConnection): void {
  pc.addEventListener("track", dispatchTrack);
  registerPeerConnection(pc);
  if (location.host === "meet.google.com") installMeetCollectionsTracer(pc);

  // Also wrap the ontrack *setter* so a page handler assigned after us can't
  // shadow the hook. We call our dispatch first, then the page's handler.
  const desc = Object.getOwnPropertyDescriptor(RTCPeerConnection.prototype, "ontrack");
  if (desc?.set && desc.get) {
    const nativeSet = desc.set;
    const nativeGet = desc.get;
    Object.defineProperty(pc, "ontrack", {
      configurable: true,
      enumerable: true,
      get() {
        return nativeGet.call(this);
      },
      set(handler: ((e: RTCTrackEvent) => void) | null) {
        nativeSet.call(this, (e: RTCTrackEvent) => {
          dispatchTrack(e);
          return handler?.call(this, e);
        });
      },
    });
  }
}

/**
 * Install the constructor wrapper once per realm. Safe to call on every epoch;
 * only the first call wraps. Must run at document_start, before the page's
 * first `new RTCPeerConnection()` (Zoom caches the constructor at bootstrap).
 */
export function installHook(): void {
  if (!claimInstall()) return; // already wrapped in this realm

  const g = hw();
  const Original = g.RTCPeerConnection;

  function Wrapped(this: unknown, ...args: unknown[]): RTCPeerConnection {
    const pc = new (Original as unknown as new (...a: unknown[]) => RTCPeerConnection)(...args);
    onPeerConnection(pc); // register + attach track listeners
    return pc; // returning the real pc supersedes `this` — callers get a native PC
  }

  Wrapped.prototype = Original.prototype; // instanceof stays true
  Object.setPrototypeOf(Wrapped, Original); // inherit statics (generateCertificate…)
  // Stable, minification-proof marker so tests/tools can tell our wrapper from
  // the native constructor without relying on Function.name.
  Object.defineProperty(Wrapped, "__earsWrapped", { value: true, enumerable: false });
  g.RTCPeerConnection = Wrapped as unknown as typeof RTCPeerConnection;

  // Meet-only: intercept createEncodedStreams() before Meet's own client calls
  // it (~2s after connect) and diverts audio off the standard decode pipeline
  // (see specs/extension.md §Audio extraction — Meet path). Gated here, at
  // install time, on the resolved host — not through audio-tap.ts's
  // capture-epoch config, which isn't populated until after this returns.
  // Applying the tee on other platforms would double-capture where the
  // standard MediaStreamTrackProcessor path already works.
  if (location.host === "meet.google.com") installMeetEncodedAudioTee();
  if (location.host === "meet.google.com") installMeetTransformProbe();
  if (location.host === "meet.google.com") installMeetWebAudioProbe();
  // Meet-only like the probes above: the webaudio-track seam is the sole
  // consumer (seamOrderFor), and Zoom's own track wrapping is exactly the
  // surface rtc-hook stays off (see the constraint at the top of this file).
  if (location.host === "meet.google.com") installProvenanceWraps();

  console.debug("[ears][hook] RTCPeerConnection hook installed");
}

// ── Meet collections datachannel: device-id/speaking-flag signal ───────────
//
// Narrow, reviewed exception to specs/extension.md's MUST-NOT #6 (journal
// #49-#51; see docs/specs/browser/extension.md (the collections exception))
// — decodes exactly the two fields documented there via meet-collections.ts's
// defensive parser, nothing else. Unlike installChannelTracer below (debug-
// only, investigation-scoped), this runs in production whenever the hook
// installs on meet.google.com: lib/identity/meet.ts's MeetAdapter needs this
// signal at runtime to correlate speaking activity to device ids, not just
// during investigation.
//
// Passive and best-effort. Per-message parse failures are silent (the parser
// itself never throws and returns null on any mismatch); this tracer only
// tracks aggregate seen/parsed counts so it can warn once if the channel is
// live but nothing is parsing — e.g. Meet changed the wire format — the same
// "warn once, degrade silently otherwise" shape as installMeetEncodedAudioTee
// and meet.ts's maybeWarnStructure().

export type CollectionsListener = (event: CollectionsMuteEvent) => void;

interface CollectionsWindow extends Window {
  __earsCollectionsListener?: CollectionsListener;
}

/** MeetAdapter registers here (latest-registration wins, same handoff pattern
 * as setTrackSink) to receive parsed collections events. */
export function setCollectionsListener(listener: CollectionsListener | null): void {
  const g = window as unknown as CollectionsWindow;
  if (listener) g.__earsCollectionsListener = listener;
  else delete g.__earsCollectionsListener;
}

let collectionsSeen = 0;
let collectionsParsed = 0;
let warnedCollectionsSchema = false;

function maybeWarnCollectionsSchema(): void {
  if (warnedCollectionsSchema) return;
  if (collectionsSeen < 5 || collectionsParsed > 0) return; // give it a few messages before concluding it's broken
  warnedCollectionsSchema = true;
  console.warn(
    "[ears][hook] Meet 'collections' datachannel is sending messages but none parsed as the expected " +
      "device-id/speaking-flag shape — Meet likely changed its wire format. Identity upgrade via " +
      "this path is disabled for this page load; capture still works via speaker-<n>. See lib/identity/meet-collections.ts.",
  );
}

function bufferFromMessageData(data: unknown): Promise<ArrayBuffer> | null {
  if (data instanceof ArrayBuffer) return Promise.resolve(data);
  if (data instanceof Blob) return data.arrayBuffer();
  if (ArrayBuffer.isView(data)) {
    const view = data as ArrayBufferView;
    return Promise.resolve(new Uint8Array(view.buffer, view.byteOffset, view.byteLength).slice().buffer);
  }
  return null; // string frames aren't expected on this channel; ignore rather than guess
}

function attachCollectionsLogger(ch: RTCDataChannel): void {
  ch.addEventListener("message", (ev: MessageEvent) => {
    const bufPromise = bufferFromMessageData(ev.data);
    if (!bufPromise) return;
    collectionsSeen++;
    void bufPromise
      .then((buf) => parseCollectionsMessage(buf))
      .then((parsed) => {
        if (!parsed) {
          maybeWarnCollectionsSchema();
          return;
        }
        collectionsParsed++;
        (window as unknown as CollectionsWindow).__earsCollectionsListener?.(parsed);
      })
      .catch(() => {
        // parseCollectionsMessage already never throws; this guards the
        // promise chain itself so a malformed message can never surface as
        // an unhandled rejection in the page.
      });
  });
}

function installMeetCollectionsTracer(pc: RTCPeerConnection): void {
  pc.addEventListener("datachannel", (ev: RTCDataChannelEvent) => {
    if (ev.channel.label === "collections") attachCollectionsLogger(ev.channel);
    else if (ev.channel.label === "audioprocessor") maybeAttachAudioprocessorTee(ev.channel);
  });
}

// ── Meet audioprocessor datachannel tee (debug-gated, investigation) ────────
//
// Open question from the 2026-08-05 live probes: `audioprocessor` runs at a
// steady ~2/s regardless of speech, but its payloads have never been examined
// — and meet.new now auto-joins with no pre-join screen, so every channel
// opens before injected page JS can attach. This document_start tee is the
// only remaining way to see them. Purpose: settle whether the channel carries
// per-device activity data. Unlike the collections tracer above it is
// investigation-scoped: gated on `__earsDebugAudio` (read once at channel
// open, same flag as the energy probes), records only {timestamp, byteLength}
// plus a field-number/wire-type sketch (summarizeFields — structure, never
// content), and logs one throttled summary line per window.

const AUDIOPROCESSOR_SUMMARY_MS = 10_000;
/** Backstop on per-window sample growth; ~2/s observed, so never reached. */
const AUDIOPROCESSOR_RING_MAX = 512;

export interface ChannelSample {
  t: number;
  byteLength: number;
}

/** One log line per summary window: count, size histogram, payload sketch.
 * Pure and exported for tests. */
export function formatChannelSummary(samples: readonly ChannelSample[], sniff: string | null): string {
  const buckets = { "≤64B": 0, "≤256B": 0, "≤1KB": 0, ">1KB": 0 };
  for (const s of samples) {
    if (s.byteLength <= 64) buckets["≤64B"]++;
    else if (s.byteLength <= 256) buckets["≤256B"]++;
    else if (s.byteLength <= 1024) buckets["≤1KB"]++;
    else buckets[">1KB"]++;
  }
  const sizes = Object.entries(buckets)
    .filter(([, n]) => n > 0)
    .map(([k, n]) => `${k}:${n}`)
    .join(" ");
  return `${samples.length} msgs sizes{${sizes}} fields=${sniff ?? "unsniffed"}`;
}

function maybeAttachAudioprocessorTee(ch: RTCDataChannel): void {
  try {
    if (!energyProbeEnabled()) return;
  } catch {
    return;
  }
  let samples: ChannelSample[] = [];
  let windowStart = 0;
  let sniff: string | null = null;
  let sniffPending = false;

  ch.addEventListener("message", (ev: MessageEvent) => {
    try {
      const t = Date.now();
      const data: unknown = ev.data;
      const byteLength =
        data instanceof ArrayBuffer
          ? data.byteLength
          : data instanceof Blob
            ? data.size
            : ArrayBuffer.isView(data)
              ? data.byteLength
              : typeof data === "string"
                ? data.length
                : 0;
      if (windowStart === 0) windowStart = t;
      if (samples.length < AUDIOPROCESSOR_RING_MAX) samples.push({ t, byteLength });

      // One payload sketch per window — enough to recognize the schema
      // without touching every message.
      if (sniff === null && !sniffPending) {
        const bufPromise = bufferFromMessageData(data);
        if (bufPromise) {
          sniffPending = true;
          void bufPromise
            .then(async (buf) => {
              const bytes = (await inflateGzip(buf)) ?? new Uint8Array(buf);
              sniff = summarizeFields(bytes, 2) ?? "unparsed";
            })
            .catch(() => {
              sniff = "unparsed";
            })
            .finally(() => {
              sniffPending = false;
            });
        }
      }

      if (t - windowStart >= AUDIOPROCESSOR_SUMMARY_MS) {
        console.debug(`[ears][probe][audioprocessor] ${formatChannelSummary(samples, sniff)}`);
        samples = [];
        windowStart = t;
        sniff = null; // re-sniff next window — schema may vary by message type
      }
    } catch {
      // diagnostic only — never throws into Meet's channel handling
    }
  });
}

// ── Meet encoded-audio tee ───────────────────────────────────────────────
//
// Empirically confirmed (journal #28–#31): Meet's client calls
// receiver.createEncodedStreams() on every audio receiver and decodes the RTP
// itself, so no MediaStreamTrack-based mechanism ever receives a frame for a
// Meet remote participant. The fix: intercept the same call, .tee() the
// readable so Meet's own playback branch is untouched, and read our branch
// independently.
//
// One persistent read loop per tee'd track, started here and never torn down
// across epochs — a ReadableStream reader can't be handed off between epochs
// without cancelling it, and cancelling a tee'd branch closes that branch
// permanently (Meet calls createEncodedStreams() once per receiver, so a
// closed branch would mean no audio for the rest of the call). Instead, raw
// frames dispatch to whichever epoch's listener is currently registered —
// exactly the same latest-wins handoff setTrackSink already uses for track
// events. With no listener registered, frames are simply dropped, never
// buffered.

interface EncodedStreamsResult {
  readable: ReadableStream<EncodedAudioFrameLike>;
  writable: WritableStream<EncodedAudioFrameLike>;
}

interface EncodedStreamsReceiver {
  readonly track: MediaStreamTrack | null;
  createEncodedStreams(): EncodedStreamsResult;
}

function encodedAudioListeners(): Map<MediaStreamTrack, EncodedAudioListener> {
  const g = hw();
  if (!g.__earsEncodedAudioListeners) g.__earsEncodedAudioListeners = new Map();
  return g.__earsEncodedAudioListeners;
}

/**
 * Meet only: (re)subscribe to raw pre-decode Opus frames for `track`. Pass
 * `null` to unsubscribe. Only the latest subscriber receives frames.
 */
export function setEncodedAudioListener(
  track: MediaStreamTrack,
  listener: EncodedAudioListener | null,
): void {
  if (listener) encodedAudioListeners().set(track, listener);
  else encodedAudioListeners().delete(track);
}

async function pumpEncodedAudio(
  track: MediaStreamTrack,
  readable: ReadableStream<EncodedAudioFrameLike>,
): Promise<void> {
  const reader = readable.getReader();
  track.addEventListener("ended", () => void reader.cancel().catch(() => {}), { once: true });
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return;
      encodedAudioListeners().get(track)?.(value);
    }
  } catch (err) {
    console.error(`[ears][hook] encoded-audio tee read error for track ${track.id}:`, err);
  }
}

// Diagnostic for the silent-capture failure (journal #72): count how many audio
// receivers Meet actually routed through our createEncodedStreams wrap. If audio
// tracks go live but this stays zero, Meet never called our hook and every
// participant records silence for the whole call — surface it loudly, once.
let teedAudioStreamCount = 0;
let teeWatchdogArmed = false;
const TEE_WATCHDOG_MS = 6_000;

// Probe findings (set by installMeetTransformProbe), surfaced in the tee
// watchdog so a single guaranteed-visible `[ears][hook]` line names the encoded-frame
// API Meet actually used this call — no separate probe line to hunt for.
let probeScriptTransformApiPresent = false;
let probeCreateEncodedStreamsPresent = false;
let probeScriptTransformCtorCount = 0;
let probeAudioTransformSetCount = 0;
// WebAudio / decoded-output probe counters (journal #75) — where Meet's audio
// actually surfaces once it bypasses every encoded-frame API.
let probeAudioContextCount = 0;
let probeAudioWorkletNodeCount = 0;
let probeNetEqWorkletCount = 0;
let probeTrackGeneratorCount = 0;
let probeMediaStreamSourceCount = 0;
let probeMediaElementSrcObjectCount = 0;

/** Hook-layer state for the popup's debug report (see hook.content.ts). */
export function hookDebugState(): {
  liveTracks: number;
  teedAudioStreamCount: number;
  probe: {
    createEncodedStreamsPresent: boolean;
    scriptTransformApiPresent: boolean;
    scriptTransformCtorCount: number;
    audioTransformSetCount: number;
  };
  webaudio: {
    audioContexts: number;
    audioWorkletNodes: number;
    netEqWorkletNodes: number;
    trackGenerators: number;
    mediaStreamSources: number;
    mediaElementSrcObjects: number;
  };
  graph: {
    nodes: number;
    edges: number;
    overflow: number;
    bridgedNodes: number;
  };
} {
  const graphCounts = graphRegistry?.counts() ?? { nodes: 0, edges: 0, overflow: 0 };
  return {
    liveTracks: liveTracks().size,
    teedAudioStreamCount,
    probe: {
      createEncodedStreamsPresent: probeCreateEncodedStreamsPresent,
      scriptTransformApiPresent: probeScriptTransformApiPresent,
      scriptTransformCtorCount: probeScriptTransformCtorCount,
      audioTransformSetCount: probeAudioTransformSetCount,
    },
    webaudio: {
      audioContexts: probeAudioContextCount,
      audioWorkletNodes: probeAudioWorkletNodeCount,
      netEqWorkletNodes: probeNetEqWorkletCount,
      trackGenerators: probeTrackGeneratorCount,
      mediaStreamSources: probeMediaStreamSourceCount,
      mediaElementSrcObjects: probeMediaElementSrcObjectCount,
    },
    graph: {
      ...graphCounts,
      bridgedNodes: bridgedNodeCount,
    },
  };
}

function noteMeetAudioTrackLive(): void {
  if (teeWatchdogArmed) return;
  teeWatchdogArmed = true;
  setTimeout(() => {
    if (teedAudioStreamCount > 0) return;
    console.error(
      "[ears][capture] ⚠ Meet audio capture is SILENT: audio tracks are live but Meet never called our " +
        "createEncodedStreams hook (0 streams tee'd). Meet likely changed its audio pipeline " +
        "(e.g. RTCRtpScriptTransform), or the receivers predate the hook. No participant audio " +
        "will be captured this call — reload the tab to re-arm. (journal #72)",
    );
    console.error(
      `[ears][probe] Meet audio API probe — createEncodedStreams:${probeCreateEncodedStreamsPresent ? "present" : "absent"}` +
        ` RTCRtpScriptTransform:${probeScriptTransformApiPresent ? "present" : "absent"}` +
        ` · scriptTransform ctor×${probeScriptTransformCtorCount}` +
        ` · audio receiver.transform set×${probeAudioTransformSetCount}` +
        " — the fix hooks whichever Meet actually used (journal #73)",
    );
  }, TEE_WATCHDOG_MS);
}

function installMeetEncodedAudioTee(): void {
  const proto = (window as unknown as { RTCRtpReceiver?: { prototype: EncodedStreamsReceiver } })
    .RTCRtpReceiver?.prototype;
  const native = proto?.createEncodedStreams;
  if (!proto || typeof native !== "function") {
    // MUST-NOT #13: surface this rather than silently reporting a working
    // capture that will actually record zero audio for every participant.
    console.error(
      "[ears][hook] RTCRtpReceiver.createEncodedStreams unavailable on meet.google.com — Meet audio capture will not work",
    );
    return;
  }

  proto.createEncodedStreams = function (this: EncodedStreamsReceiver, ...args: unknown[]): EncodedStreamsResult {
    const streams = (native as (...a: unknown[]) => EncodedStreamsResult).apply(this, args);
    const track = this.track;
    if (!track || track.kind !== "audio") return streams; // video: pass through untouched
    const [ours, theirs] = streams.readable.tee();
    teedAudioStreamCount += 1;
    void pumpEncodedAudio(track, ours);
    console.debug(`[ears][hook] tee'd encoded audio stream for track ${track.id} (${teedAudioStreamCount} total)`);
    return { readable: theirs, writable: streams.writable };
  };

  console.debug("[ears][hook] RTCRtpReceiver.createEncodedStreams hook installed (meet.google.com)");
}

// Temporary diagnostic (journal #73): Meet stopped calling createEncodedStreams,
// and the loaded modules (loadNetEqSabWrapper — SharedArrayBuffer WASM NetEQ)
// point at RTCRtpScriptTransform, the worker-based successor. This probe reports
// which encoded-frame API Meet actually uses on this build and logs where it
// routes audio — WITHOUT changing behaviour (every wrap passes straight through)
// so the real capture fix knows exactly what to hook. Remove once the fix lands.
function installMeetTransformProbe(): void {
  try {
    const w = window as unknown as {
      RTCRtpScriptTransform?: new (...a: unknown[]) => object;
      RTCRtpReceiver?: { prototype: object };
    };
    const proto = w.RTCRtpReceiver?.prototype;
    const hasScriptTransform = typeof w.RTCRtpScriptTransform === "function";
    const hasCreateEncodedStreams =
      !!proto && typeof (proto as { createEncodedStreams?: unknown }).createEncodedStreams === "function";
    const hasTransformAccessor = !!proto && !!Object.getOwnPropertyDescriptor(proto, "transform")?.set;
    probeScriptTransformApiPresent = hasScriptTransform;
    probeCreateEncodedStreamsPresent = hasCreateEncodedStreams;
    // Bracket-tree tag: filter `[ears][probe]` for just this, `[ears]` for all.
    console.debug(
      `[ears][probe] Meet audio APIs on this build — RTCRtpScriptTransform:${hasScriptTransform} ` +
        `receiver.transform:${hasTransformAccessor} createEncodedStreams:${hasCreateEncodedStreams}`,
    );

    // Log every RTCRtpScriptTransform construction — the options name Meet's
    // decode topology (which worker, what role). Pass-through constructor.
    if (hasScriptTransform) {
      const Native = w.RTCRtpScriptTransform!;
      const Wrapped = function (this: unknown, ...args: unknown[]): object {
        probeScriptTransformCtorCount += 1;
        console.debug("[ears][probe] new RTCRtpScriptTransform — options:", args[1]);
        return new Native(...args);
      } as unknown as new (...a: unknown[]) => object;
      Wrapped.prototype = Native.prototype;
      Object.setPrototypeOf(Wrapped, Native);
      w.RTCRtpScriptTransform = Wrapped;
    }

    // Log when Meet assigns a transform to an audio receiver — the exact seam
    // the real fix will tee encoded Opus from. Pass-through setter.
    if (proto) {
      const desc = Object.getOwnPropertyDescriptor(proto, "transform");
      if (desc?.set && desc.get) {
        const nativeSet = desc.set;
        const nativeGet = desc.get;
        Object.defineProperty(proto, "transform", {
          configurable: true,
          enumerable: desc.enumerable ?? true,
          get(): unknown {
            return nativeGet.call(this);
          },
          set(value: unknown): void {
            const kind = (this as { track?: MediaStreamTrack }).track?.kind ?? "?";
            if (kind === "audio") probeAudioTransformSetCount += 1;
            const name = (value as { constructor?: { name?: string } })?.constructor?.name ?? String(value);
            console.debug(`[ears][probe] receiver.transform set on a ${kind} receiver → ${name}`);
            nativeSet.call(this, value);
          },
        });
      }
    }
  } catch (err) {
    console.debug("[ears][probe] transform probe failed to install (non-fatal):", err);
  }
}

// WebAudio / decoded-output probe (journal #75). Meet uses no JS encoded-frame
// tap, so its decoded participant audio must surface later — through WebAudio
// nodes, a MediaStreamTrackGenerator, or a media element. This maps that graph
// (pass-through, diagnostic only) to answer the one question that decides
// feasibility: does Meet keep ONE node/generator PER participant (per-participant
// capture still possible), or mix everything into one (only blended audio left)?
// Filter the console by `[ears][probe][webaudio]`.
function installMeetWebAudioProbe(): void {
  try {
    const w = window as unknown as Record<string, unknown>;

    // Record the arm in the debug log: which probes this page load actually
    // ran is the first thing to know when reading a bug report.
    console.debug(
      `[ears][probe] audio probes — debugAudio:${energyProbeEnabled()} bridge:${graphBridgeEnabled()}`,
    );

    const streamTracks = (v: unknown): string => {
      const s = v as { getAudioTracks?: () => Array<{ id: string }> } | null;
      const ids = s?.getAudioTracks?.().map((t) => t.id) ?? null;
      return ids ? `[${ids.join(",")}]` : String(v);
    };

    // Pass-through constructor wrap: log each construction + count it.
    const wrapCtor = (name: string, label: (args: unknown[]) => string, tick: () => void): void => {
      const Native = w[name];
      if (typeof Native !== "function") return;
      const N = Native as new (...a: unknown[]) => object;
      const Wrapped = function (this: unknown, ...args: unknown[]): object {
        tick();
        console.debug(`[ears][probe][webaudio] new ${name} — ${label(args)}`);
        return new N(...args);
      } as unknown as new (...a: unknown[]) => object;
      Wrapped.prototype = N.prototype;
      Object.setPrototypeOf(Wrapped, N);
      w[name] = Wrapped;
    };

    wrapCtor(
      "AudioContext",
      (a) => `sampleRate=${(a[0] as { sampleRate?: number })?.sampleRate ?? "default"}`,
      () => (probeAudioContextCount += 1),
    );
    wrapCtor("webkitAudioContext", () => "webkit", () => (probeAudioContextCount += 1));
    // AudioWorkletNode gets a dedicated wrap (not wrapCtor) because the
    // bridge needs the constructed INSTANCE: neteq-processor nodes are the
    // playout end of Meet's WASM decode pipeline, and the edges Meet gives
    // them name the one safe tap point for decoded audio. Pass-through: the
    // native node is always constructed and returned; all bookkeeping is
    // flag-gated and try/caught.
    {
      const Native = w.AudioWorkletNode;
      if (typeof Native === "function") {
        const N = Native as new (...a: unknown[]) => object;
        const Wrapped = function (this: unknown, ...args: unknown[]): object {
          probeAudioWorkletNodeCount += 1;
          const processor = String(args[1]);
          console.debug(
            `[ears][probe][webaudio] new AudioWorkletNode — processor="${processor}" ch=${(args[2] as { channelCount?: number })?.channelCount ?? "?"}`,
          );
          const instance = new N(...args);
          try {
            if (processor === "neteq-processor") {
              probeNetEqWorkletCount += 1;
              // Remembered so the connect wrap can spot neteq→X edges. NEVER
              // branch off this node itself: an extra output edge on Meet's
              // neteq worklet trips a Chromium CHECK on the realtime audio
              // thread and kills the renderer (journal #93). The bridge taps
              // the NATIVE node downstream instead — see tapNetEqDownstream.
              netEqWorklets.add(instance);
            }
            if (energyProbeEnabled()) {
              meetGraph().noteWorklet(instance, processor);
              ensureGraphTimer();
            }
          } catch {
            // diagnostic only — never throws into Meet's audio path
          }
          return instance;
        } as unknown as new (...a: unknown[]) => object;
        Wrapped.prototype = N.prototype;
        Object.setPrototypeOf(Wrapped, N);
        w.AudioWorkletNode = Wrapped;
      }
    }
    // Audio generators are the leading candidate output of Meet's post-RTP
    // pipeline (2026-07-24 drift capture): register each constructed audio
    // generator (it IS a MediaStreamTrack) so a live debugging run can reach the
    // object, and fingerprint its energy when the debug flag is on.
    {
      const Native = w.MediaStreamTrackGenerator;
      if (typeof Native === "function") {
        const N = Native as new (...a: unknown[]) => object;
        const Wrapped = function (this: unknown, ...args: unknown[]): object {
          probeTrackGeneratorCount += 1;
          const kind = (args[0] as { kind?: string })?.kind ?? String(args[0]);
          console.debug(`[ears][probe][webaudio] new MediaStreamTrackGenerator — kind=${kind}`);
          const instance = new N(...args);
          if (kind === "audio") {
            const track = instance as unknown as MediaStreamTrack;
            registerWebAudioTrack(track, "generator");
            monitorTrackEnergy(track, "generator");
            // An audio generator IS a MediaStreamTrack — the zero-new-code
            // capture path. Record its appearance in the perf ring (the console
            // dies with Meet's post-call redirect) and, when the bridge flag is
            // on, feed it straight into the existing pipeline.
            try {
              if (energyProbeEnabled()) {
                graphEmit("meet_graph_generator", { kind: "audio", track: track.id ?? "?" });
              }
              if (graphBridgeEnabled()) bridgeTrack(track, "graphgen");
            } catch {
              // diagnostic only
            }
          }
          return instance;
        } as unknown as new (...a: unknown[]) => object;
        Wrapped.prototype = N.prototype;
        Object.setPrototypeOf(Wrapped, N);
        w.MediaStreamTrackGenerator = Wrapped;
      }
    }

    // createMediaStreamSource tells us which stream (→ which participant) Meet
    // routes into WebAudio, if any. Pass-through method wrap on the prototype.
    // Each audio track fed in is registered + energy-fingerprinted: on the
    // drift-affected build the RTP receiver tracks are silent decoys, and
    // whatever Meet hands to WebAudio here is where decoded participant audio
    // actually lives — energy-per-track answers whether it's still
    // per-participant (re-tappable) or already mixed.
    const acProto = (w.AudioContext as { prototype?: Record<string, unknown> } | undefined)?.prototype;
    const orig = acProto?.createMediaStreamSource;
    if (acProto && typeof orig === "function") {
      const native = orig as (...a: unknown[]) => unknown;
      nativeCreateMediaStreamSource = native;
      acProto.createMediaStreamSource = function (this: unknown, ...args: unknown[]): unknown {
        probeMediaStreamSourceCount += 1;
        console.debug(`[ears][probe][webaudio] createMediaStreamSource(audioTracks=${streamTracks(args[0])})`);
        const tracks = (args[0] as { getAudioTracks?: () => MediaStreamTrack[] } | null)?.getAudioTracks?.() ?? [];
        for (const track of tracks) {
          registerWebAudioTrack(track, "createMediaStreamSource");
          monitorTrackEnergy(track, "createMediaStreamSource");
        }
        const node = native.apply(this, args);
        // Register the RESULT node with the track ids feeding it: node →
        // participant cannot join on track id (these ids never match any hooked
        // receiver), so the graph records them for the offline unmute-edge join
        // instead. Ids only — never names.
        try {
          if (energyProbeEnabled() && node !== null && typeof node === "object") {
            meetGraph().noteSource(node, tracks.map((t) => t.id));
          }
        } catch {
          // diagnostic only
        }
        return node;
      };
    }

    // ── Graph mapping: AudioNode.connect / disconnect (journal #76) ─────────
    // The connect topology is what tells a per-participant graph from a mixer:
    // N neteq nodes fanning into one destination is tappable per node; one
    // neteq node fed by everything is already mixed. Pass-through: the native
    // call ALWAYS runs (first, so a bookkeeping bug can't break Meet's audio),
    // its result is returned untouched, and bookkeeping is flag-gated.
    const nodeProto = (w.AudioNode as { prototype?: Record<string, unknown> } | undefined)
      ?.prototype;
    const nativeConnect = nodeProto?.connect;
    if (nodeProto && typeof nativeConnect === "function") {
      const native = nativeConnect as (...a: unknown[]) => unknown;
      nativeAudioNodeConnect = native;
      nodeProto.connect = function (this: object, ...args: unknown[]): unknown {
        const result = native.apply(this, args);
        try {
          if (energyProbeEnabled()) {
            meetGraph().noteConnect(this, args[0]);
            ensureGraphTimer();
          }
          // Meet wiring a neteq worklet into its own graph names the one safe
          // tap point for that participant's decoded audio: the NATIVE node
          // downstream. Branch the capture bridge off that, never the worklet.
          if (graphBridgeEnabled() && netEqWorklets.has(this)) {
            tapNetEqDownstream(args[0]);
          }
        } catch {
          // diagnostic only
        }
        return result;
      };
    }
    const nativeDisconnect = nodeProto?.disconnect;
    if (nodeProto && typeof nativeDisconnect === "function") {
      const native = nativeDisconnect as (...a: unknown[]) => unknown;
      nativeAudioNodeDisconnect = native;
      nodeProto.disconnect = function (this: object, ...args: unknown[]): unknown {
        const result = native.apply(this, args);
        try {
          if (energyProbeEnabled()) meetGraph().noteDisconnect(this, args[0]);
        } catch {
          // diagnostic only
        }
        return result;
      };
    }

    // media.srcObject = stream — the other way decoded audio reaches output.
    const meProto = (w.HTMLMediaElement as { prototype?: object } | undefined)?.prototype;
    const desc = meProto && Object.getOwnPropertyDescriptor(meProto, "srcObject");
    if (meProto && desc?.set && desc.get) {
      const nset = desc.set;
      const nget = desc.get;
      Object.defineProperty(meProto, "srcObject", {
        configurable: true,
        enumerable: desc.enumerable ?? true,
        get(): unknown {
          return nget.call(this);
        },
        set(value: unknown): void {
          if (value) {
            probeMediaElementSrcObjectCount += 1;
            console.debug(`[ears][probe][webaudio] media.srcObject = audioTracks=${streamTracks(value)}`);
          }
          nset.call(this, value);
        },
      });
    }
  } catch (err) {
    console.debug("[ears][probe][webaudio] probe failed to install (non-fatal):", err);
  }
}

// ── Re-tap investigation: WebAudio track registry + energy fingerprint ──────
//
// 2026-07-24 (dev/captures/2026-07-24-meet-collections-drift.md): Meet migrated
// call audio off the RTCRtpReceiver path mid-call — receiver tracks stayed
// live-but-silent while playback ran through a page-side NetEQ AudioWorklet fed
// from tracks the hook never saw. The next instrumented call needs two things
// this section provides:
//
//   1. `window.__earsWebAudioTracks` — the actual MediaStreamTrack objects Meet
//      routes through WebAudio (createMediaStreamSource inputs, audio
//      MediaStreamTrackGenerator outputs), keyed by track id. During the live
//      capture run the track objects were unreachable (only their ids had
//      been logged), which blocked measuring them; this registry closes that gap.
//   2. Per-track energy fingerprints (`[ears][probe][webaudio] energy …`),
//      gated by the same `__earsDebugAudio` localStorage flag as audio-tap's
//      instrumentation: a throttled peak log per registered track, which
//      answers THE feasibility question — is the WebAudio-side audio still
//      per-participant (re-tappable), or already mixed?

export interface WebAudioTrackRecord {
  track: MediaStreamTrack;
  via: string;
  registeredAt: string;
}
interface WebAudioTrackWindow extends Window {
  __earsWebAudioTracks?: Map<string, WebAudioTrackRecord>;
}

/** Native (unwrapped) createMediaStreamSource, captured by the probe so the
 * energy monitor never re-enters its own wrap. */
let nativeCreateMediaStreamSource: ((...a: unknown[]) => unknown) | null = null;
/** Lazy shared context for energy monitoring — one per page, only ever built
 * when the debug flag is on and a track gets monitored. */
let energyProbeContext: AudioContext | null = null;
let monitoredTrackCount = 0;
const ENERGY_PROBE_MAX_TRACKS = 16;
const ENERGY_PROBE_INTERVAL_MS = 5_000;

function webAudioTrackRegistry(): Map<string, WebAudioTrackRecord> {
  const g = window as unknown as WebAudioTrackWindow;
  if (!g.__earsWebAudioTracks) g.__earsWebAudioTracks = new Map();
  return g.__earsWebAudioTracks;
}

function registerWebAudioTrack(track: MediaStreamTrack, via: string): void {
  try {
    const registry = webAudioTrackRegistry();
    if (registry.has(track.id)) return;
    registry.set(track.id, { track, via, registeredAt: new Date().toISOString() });
  } catch {
    // diagnostic only — never throws into Meet's audio path
  }
}

/**
 * Live audio tracks Meet has routed into WebAudio, newest last.
 *
 * Started as a diagnostic (is the WebAudio-side audio still per-participant?)
 * and became a capture seam once journal #105 showed these tracks carry real
 * decoded audio on builds where the RTP receiver tracks are silent decoys. The
 * `webaudio-track` seam in audio-tap.ts reads this; see capture-seams.ts.
 *
 * Ended tracks are pruned on read rather than on a `ended` listener, so the
 * registry costs nothing while nobody is asking. Returns a fresh array — the
 * caller must not hold the registry itself.
 */
export function webAudioTracks(): MediaStreamTrack[] {
  const registry = webAudioTrackRegistry();
  for (const [id, rec] of registry) {
    if (rec.track.readyState === "ended") {
      registry.delete(id);
      pruneTrackProvenance(id);
    }
  }
  return [...registry.values()].map((rec) => rec.track);
}

// ── Track provenance: local/remote lineage for the webaudio seam ────────────
//
// The webaudio-track seam self-discovers anonymous tracks, and Meet's WebAudio
// graph carries the user's own outgoing audio alongside remote participants —
// on the 2026-08-05 call three of six adopted tracks were the local mic, so
// every utterance landed in the transcript four times. Provenance classifies a
// track from the page's own API contract, never from signal analysis: a track
// handed out by getUserMedia/getDisplayMedia or handed to a sender is local by
// construction; a track delivered by `ontrack` is remote; a clone inherits its
// parent. Everything else stays unknown — and unknown ADOPTS (capture-seams.ts
// policy): a wrongly dropped remote track is unrecoverable data loss, a missed
// local one only a transcript-quality bug, so classification can only fail safe.
//
// Realm-global like __earsLiveTracks, so re-injected epochs share one lineage.
// Reads and writes never enumerate getSenders()/getReceivers() — only the
// page's own calls are observed (the constraint at the top of this file).

export type TrackOrigin = "local" | "remote";

export interface TrackProvenanceRecord {
  origin: TrackOrigin;
  /** The API that established it: gum, display-media, sender, replaceTrack, ontrack, clone. */
  via: string;
  /** Lineage root — the original this track was (transitively) cloned from. */
  rootId: string;
  /** Registration order; clone-dedup keeps the earliest-registered per root. */
  seq: number;
}

interface ProvenanceWindow extends Window {
  __earsTrackProvenance?: Map<string, TrackProvenanceRecord>;
  __earsTrackProvenanceSeq?: number;
}

/** Leak backstop only — entries are pruned with the webaudio registry sweep,
 * but gUM/sender tracks the sweep never sees would otherwise accrue forever
 * on a page that mints tracks pathologically. Oldest evict first. */
export const PROVENANCE_MAX_ENTRIES = 512;

function provenanceRegistry(): Map<string, TrackProvenanceRecord> {
  const g = window as unknown as ProvenanceWindow;
  if (!g.__earsTrackProvenance) g.__earsTrackProvenance = new Map();
  return g.__earsTrackProvenance;
}

/** First write wins: an id's origin never flips (a remote track looped back
 * into a sender is still remote content). Bookkeeping only — never throws. */
export function registerTrackProvenance(
  id: string,
  origin: TrackOrigin,
  via: string,
  rootId: string = id,
): void {
  try {
    const registry = provenanceRegistry();
    if (registry.has(id)) return;
    while (registry.size >= PROVENANCE_MAX_ENTRIES) {
      const oldest = registry.keys().next().value;
      if (oldest === undefined) break;
      registry.delete(oldest);
    }
    const g = window as unknown as ProvenanceWindow;
    const seq = (g.__earsTrackProvenanceSeq = (g.__earsTrackProvenanceSeq ?? 0) + 1);
    registry.set(id, { origin, via, rootId, seq });
  } catch {
    // bookkeeping only — never throws into the page
  }
}

export function trackProvenance(id: string): TrackProvenanceRecord | undefined {
  try {
    return provenanceRegistry().get(id);
  } catch {
    return undefined;
  }
}

/** Drop an ended track's entry unless a live entry still claims it as root —
 * the root id is what keeps that root's later clones deduplicated. */
function pruneTrackProvenance(id: string): void {
  try {
    const registry = provenanceRegistry();
    const record = registry.get(id);
    if (!record) return;
    for (const other of registry.values()) {
      if (other !== record && other.rootId === id) return;
    }
    registry.delete(id);
  } catch {
    // bookkeeping only
  }
}

/**
 * Passive provenance wraps (installHook, once per realm, Meet only). Every
 * wrap is pass-through: the native call always runs first, its result returns
 * untouched, and bookkeeping failures never surface into the page.
 */
function installProvenanceWraps(): void {
  try {
    const w = window as unknown as {
      navigator?: { mediaDevices?: Record<string, unknown> };
      MediaDevices?: { prototype?: Record<string, unknown> };
      MediaStreamTrack?: { prototype?: Record<string, unknown> };
      RTCRtpSender?: { prototype?: Record<string, unknown> };
      RTCPeerConnection?: { prototype?: Record<string, unknown> };
    };

    const registerStreamAudio = (value: unknown, via: string): void => {
      const tracks =
        (value as { getAudioTracks?: () => Array<{ id?: string }> } | null)?.getAudioTracks?.() ?? [];
      for (const track of tracks) {
        if (typeof track?.id === "string") registerTrackProvenance(track.id, "local", via);
      }
    };

    // getUserMedia / getDisplayMedia — the local roots. Wrap the prototype
    // when the platform exposes it (survives the page caching
    // navigator.mediaDevices), the instance otherwise.
    const wrapCapture = (holder: Record<string, unknown> | undefined, method: string, via: string): boolean => {
      const native = holder?.[method];
      if (!holder || typeof native !== "function") return false;
      holder[method] = function (this: unknown, ...args: unknown[]): unknown {
        const result = (native as (...a: unknown[]) => unknown).apply(this, args);
        try {
          void (result as Promise<unknown> | null)?.then?.(
            (stream) => registerStreamAudio(stream, via),
            () => {}, // the page's own copy of the rejection is untouched
          );
        } catch {
          // bookkeeping only
        }
        return result;
      };
      return true;
    };
    const mdProto = w.MediaDevices?.prototype;
    if (!wrapCapture(mdProto, "getUserMedia", "gum")) {
      wrapCapture(w.navigator?.mediaDevices, "getUserMedia", "gum");
    }
    if (!wrapCapture(mdProto, "getDisplayMedia", "display-media")) {
      wrapCapture(w.navigator?.mediaDevices, "getDisplayMedia", "display-media");
    }

    // Outgoing by construction: any audio track the page hands to a sender.
    // Observation of the page's own calls — getSenders() is never invoked.
    const wrapSenderArg = (holder: Record<string, unknown> | undefined, method: string, via: string): void => {
      const native = holder?.[method];
      if (!holder || typeof native !== "function") return;
      holder[method] = function (this: unknown, ...args: unknown[]): unknown {
        const result = (native as (...a: unknown[]) => unknown).apply(this, args);
        try {
          // addTransceiver's first arg may be a kind string — the guard skips it.
          const track = args[0] as { id?: string; kind?: string } | null;
          if (track && typeof track.id === "string" && track.kind === "audio") {
            registerTrackProvenance(track.id, "local", via);
          }
        } catch {
          // bookkeeping only
        }
        return result;
      };
    };
    const pcProto = w.RTCPeerConnection?.prototype;
    wrapSenderArg(pcProto, "addTrack", "sender");
    wrapSenderArg(pcProto, "addTransceiver", "sender");
    wrapSenderArg(w.RTCRtpSender?.prototype, "replaceTrack", "replaceTrack");

    // Lineage: a clone inherits origin and root, which is what makes "three
    // clones of one mic" one capture decision instead of three. A clone of an
    // unregistered parent stays unknown.
    const trackProto = w.MediaStreamTrack?.prototype;
    const nativeClone = trackProto?.clone;
    if (trackProto && typeof nativeClone === "function") {
      trackProto.clone = function (this: { id?: string }, ...args: unknown[]): unknown {
        const result = (nativeClone as (...a: unknown[]) => unknown).apply(this, args);
        try {
          const parent = typeof this?.id === "string" ? trackProvenance(this.id) : undefined;
          const cloneId = (result as { id?: string } | null)?.id;
          if (parent && typeof cloneId === "string") {
            registerTrackProvenance(cloneId, parent.origin, "clone", parent.rootId);
          }
        } catch {
          // bookkeeping only
        }
        return result;
      };
    }
  } catch (err) {
    console.debug("[ears][hook] provenance wraps failed to install (non-fatal):", err);
  }
}

function energyProbeEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugAudio") === "1";
  } catch {
    return false;
  }
}

/** Attach a throttled peak meter to `track`, logging only while it carries
 * signal. Diagnostic only, `__earsDebugAudio`-gated, capped at
 * ENERGY_PROBE_MAX_TRACKS so a tile-heavy call can't build unbounded graph.
 * The meter lives in the probe's OWN AudioContext — it never adds an edge to
 * Meet's graph, which is what makes it safe (journal #90, arm 2). */
function monitorTrackEnergy(track: MediaStreamTrack, via: string): void {
  try {
    if (!energyProbeEnabled() || !nativeCreateMediaStreamSource) return;
    if (monitoredTrackCount >= ENERGY_PROBE_MAX_TRACKS) return;
    monitoredTrackCount += 1;

    if (!energyProbeContext) {
      const Ctor = (window as unknown as { AudioContext?: typeof AudioContext }).AudioContext;
      if (!Ctor) return;
      energyProbeContext = new Ctor();
    }
    const ctx = energyProbeContext;
    const source = nativeCreateMediaStreamSource.call(ctx, new MediaStream([track])) as MediaStreamAudioSourceNode;
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 2048;
    source.connect(analyser); // analyser has no output connection — no playback
    const buf = new Float32Array(analyser.fftSize);

    const timer = setInterval(() => {
      if (track.readyState === "ended") {
        clearInterval(timer);
        try {
          source.disconnect();
        } catch {
          // already gone
        }
        console.debug(`[ears][probe][webaudio] energy via=${via} track=${track.id} — track ended, meter off`);
        return;
      }
      analyser.getFloatTimeDomainData(buf);
      let peak = 0;
      for (let i = 0; i < buf.length; i++) {
        const a = Math.abs(buf[i]!);
        if (a > peak) peak = a;
      }
      // Silent samples are the common case — only signal is worth a line.
      if (peak > 0.001) {
        console.debug(
          `[ears][probe][webaudio] energy via=${via} track=${track.id} peak=${peak.toFixed(4)} (AUDIO)`,
        );
      }
    }, ENERGY_PROBE_INTERVAL_MS);
  } catch (err) {
    console.debug("[ears][probe][webaudio] energy meter failed to attach (non-fatal):", err);
  }
}


// ── Meet audio-graph probe: topology map + downstream capture bridge ────────
//
// Meet's participant audio lives downstream of a WASM NetEQ decode (journal
// #75): decoded PCM surfaces only through AudioWorkletNode("neteq-processor"),
// so no encoded-frame or receiver-track hook ever sees it. Two pieces recover
// it, both built around one hard constraint — adding an output edge to Meet's
// neteq worklet trips a Chromium CHECK on the realtime audio thread and kills
// the renderer (journal #93, #96). Nothing here ever connects anything to a
// worklet:
//
//   1. Topology map (`__earsDebugAudio`): pure-JS bookkeeping fed by the
//      pass-through connect/disconnect wraps, emitted through the perf ring so
//      it survives Meet's post-call redirect. Cannot touch the render graph.
//   2. Capture bridge (`__earsGraphBridge`): when Meet connects a neteq
//      worklet to a NATIVE node, branch THAT node into a
//      MediaStreamAudioDestinationNode and feed its stream to the real capture
//      pipeline as `graphtap-<n>`. The worklet keeps exactly the edges Meet
//      gave it; the extra edge sits on the native node, which is ordinary
//      graph work. If Meet's graph is per-participant the daemon records
//      separate streams; if it is mixed, the recordings prove that instead.
//      Audio-kind MediaStreamTrackGenerators bridge directly (`graphgen-<n>`)
//      — they already are tracks and involve no graph mutation at all.
//
// The MAIN world has no extension APIs and audio-tap/perf-main must not be
// imported here (audio-tap already imports this module), so the perf emitter
// and the bridge's pipeline entry are injected by hook.content.ts via
// setMeetGraphSinks — same realm-singleton pattern as __earsOnTrack.

/** Cap on bridged nodes/tracks — each one is a full capture pipeline. */
export const GRAPH_BRIDGE_MAX_NODES = 8;
/** Topology/summary emission cadence (summary every tick, topology every 2nd). */
const GRAPH_SUMMARY_INTERVAL_MS = 15_000;

export interface MeetGraphSinks {
  /** Ship one perf record (routed to mainPerf().emit by hook.content.ts). */
  emitPerf: (metric: string, fields: Record<string, number | string>) => void;
  /** Feed a bridged stream into the real capture pipeline (__devCaptureStream). */
  bridgeStream: (stream: MediaStream, participantId: string) => void;
}

interface GraphSinksWindow extends Window {
  __earsGraphSinks?: MeetGraphSinks;
}

/** Inject the perf emitter + bridge entry (hook.content.ts, once per realm).
 * Stored on `window` so re-injected epochs reach the live wraps' sinks. */
export function setMeetGraphSinks(sinks: MeetGraphSinks | null): void {
  const g = window as unknown as GraphSinksWindow;
  if (sinks) g.__earsGraphSinks = sinks;
  else delete g.__earsGraphSinks;
}

function graphEmit(metric: string, fields: Record<string, number | string>): void {
  try {
    (window as unknown as GraphSinksWindow).__earsGraphSinks?.emitPerf(metric, fields);
  } catch {
    // diagnostic only
  }
}

let graphRegistry: AudioGraphRegistry | null = null;

function meetGraph(): AudioGraphRegistry {
  if (!graphRegistry) graphRegistry = new AudioGraphRegistry();
  return graphRegistry;
}

function graphBridgeEnabled(): boolean {
  try {
    return localStorage.getItem("__earsGraphBridge") === "1";
  } catch {
    return false;
  }
}

/** Every neteq-processor worklet Meet has constructed. Membership is the
 * connect wrap's cue that the edge's TARGET is a decoded-audio tap point. */
let netEqWorklets = new WeakSet<object>();

/** Native nodes already bridged (or ruled untappable) — Meet reconnects and
 * N neteq worklets can share one mixer, and each target is tapped once. */
let tappedTargets = new WeakSet<object>();

/** Live taps, kept so capture-off can sever the branches: an idle extension
 * must not keep Meet's graph pulled (an output edge keeps a node processing,
 * and processing propagates upstream to the worklets feeding it). Bounded by
 * GRAPH_BRIDGE_MAX_NODES. */
let bridgeTaps: Array<{ target: object; dest: AudioNode }> = [];

let bridgedNodeCount = 0;

/** Native (unwrapped) AudioNode.prototype.connect, captured by the probe so
 * the bridge's own branches never pollute the graph map. */
let nativeAudioNodeConnect: ((...a: unknown[]) => unknown) | null = null;

/** Native (unwrapped) AudioNode.prototype.disconnect, used to sever the
 * bridge's own branches without touching the graph bookkeeping. */
let nativeAudioNodeDisconnect: ((...a: unknown[]) => unknown) | null = null;

/** False only when the node reports zero outputs — nothing to branch off. An
 * unknown shape reads as connectable; the attach is try/caught regardless. */
function hasAudioOutput(node: object): boolean {
  const outputs = (node as { numberOfOutputs?: number }).numberOfOutputs;
  return typeof outputs !== "number" || outputs > 0;
}

/**
 * Meet just connected a neteq worklet to `target`. Branch `target` into the
 * capture pipeline — never the worklet itself (the renderer-fatal edge,
 * journal #93). One tap per target: if all N worklets feed one mixer this
 * yields a single `graphtap-1` carrying the mix; if each feeds its own native
 * node it yields one stream per participant. Either recording answers the
 * per-participant-vs-mixed question with ground truth.
 */
function tapNetEqDownstream(target: unknown): void {
  try {
    if (bridgedNodeCount >= GRAPH_BRIDGE_MAX_NODES) return;
    if (typeof target !== "object" || target === null) return;
    if (tappedTargets.has(target)) return;
    const ctx = (target as { context?: BaseAudioContext }).context;
    if (!ctx || typeof (ctx as AudioContext).createMediaStreamDestination !== "function") {
      return; // an AudioParam or non-node destination — not a tap point
    }
    tappedTargets.add(target);
    if (!hasAudioOutput(target)) {
      // neteq feeds a sink-shaped node (the context destination, or a
      // zero-output worklet) directly: there is no native node to branch off,
      // and per-participant capture needs a different seam on this build.
      // Recorded so a post-call read of the perf ring says so explicitly.
      graphEmit("meet_graph_bridge", { node: meetGraph().idOf(target) ?? "?", kind: "untappable-sink" });
      console.debug("[ears][probe][graph] neteq output feeds a sink-shaped node — no native tap point");
      return;
    }
    const dest = (ctx as AudioContext).createMediaStreamDestination();
    const connect = nativeAudioNodeConnect ?? (target as AudioNode).connect;
    connect.call(target, dest);
    bridgedNodeCount += 1;
    bridgeTaps.push({ target, dest });
    const participantId = `graphtap-${bridgedNodeCount}`;
    const id = meetGraph().idOf(target) ?? "?";
    (window as unknown as GraphSinksWindow).__earsGraphSinks?.bridgeStream(dest.stream, participantId);
    graphEmit("meet_graph_bridge", { node: id, kind: "downstream-tap", participant: participantId });
    console.debug(`[ears][probe][graph] bridged neteq downstream ${id} → ${participantId}`);
  } catch (err) {
    console.debug("[ears][probe][graph] downstream tap failed (non-fatal):", err);
  }
}

/** Bridge a bare audio track (MediaStreamTrackGenerator output) — it already
 * IS a MediaStreamTrack, so no graph mutation is involved at all. */
function bridgeTrack(track: MediaStreamTrack, prefix: string): void {
  try {
    if (bridgedNodeCount >= GRAPH_BRIDGE_MAX_NODES) return;
    bridgedNodeCount += 1;
    const participantId = `${prefix}-${bridgedNodeCount}`;
    (window as unknown as GraphSinksWindow).__earsGraphSinks?.bridgeStream(
      new MediaStream([track]),
      participantId,
    );
    graphEmit("meet_graph_bridge", { node: "generator", kind: "generator", participant: participantId });
    console.debug(`[ears][probe][graph] bridged audio generator → ${participantId}`);
  } catch (err) {
    console.debug("[ears][probe][graph] generator bridge failed (non-fatal):", err);
  }
}

let graphTimer: ReturnType<typeof setInterval> | null = null;
let graphTick = 0;

/** Start the topology/summary emitter (idempotent). Pure bookkeeping reads —
 * the timer never touches the audio graph, so it cannot crash a call. */
function ensureGraphTimer(): void {
  if (graphTimer) return;
  graphTimer = setInterval(() => {
    try {
      graphTick += 1;
      emitGraphSummary();
      if (graphTick % 2 === 0) emitGraphTopology();
    } catch {
      // diagnostic only
    }
  }, GRAPH_SUMMARY_INTERVAL_MS);
}

function emitGraphSummary(): void {
  const counts = meetGraph().counts();
  graphEmit("meet_graph_summary", {
    neteq_nodes: probeNetEqWorkletCount,
    graph_nodes: counts.nodes,
    graph_edges: counts.edges,
    graph_overflow: counts.overflow,
    bridged: bridgedNodeCount,
  });
  console.debug(
    `[ears][probe][graph] neteq=${probeNetEqWorkletCount} nodes=${counts.nodes} ` +
      `edges=${counts.edges} bridged=${bridgedNodeCount}`,
  );
}

function emitGraphTopology(): void {
  const fields = meetGraph().topologyFields();
  if (Object.keys(fields).length > 0) graphEmit("meet_graph_topology", fields);
}

/**
 * Sever every bridge branch and stop the emitter. Called when capture is
 * switched off: an idle extension must not keep Meet's graph pulled. Bridging
 * re-arms on the next neteq connect Meet makes (already-tapped targets stay
 * retired for the page's lifetime — new calls build new nodes).
 */
export function stopMeetGraphProbe(): void {
  for (const { target, dest } of bridgeTaps.splice(0)) {
    try {
      const disconnect = nativeAudioNodeDisconnect ?? (target as AudioNode).disconnect;
      disconnect.call(target, dest);
    } catch {
      // node already torn down by the page — the branch went with it
    }
  }
  if (graphTimer) {
    clearInterval(graphTimer);
    graphTimer = null;
  }
}

/** Test seam: drop the graph probe's realm state so each test starts clean.
 * (The wraps themselves stay installed — claimInstall owns that lifecycle.) */
export function __resetMeetGraphProbe(): void {
  stopMeetGraphProbe();
  graphRegistry = null;
  graphTick = 0;
  bridgedNodeCount = 0;
  probeNetEqWorkletCount = 0;
  netEqWorklets = new WeakSet();
  tappedTargets = new WeakSet();
}
