// The Meet encoded-audio tee (split out of rtc-hook.ts, refactor R7):
// intercepts RTCRtpReceiver.createEncodedStreams before Meet's client calls
// it, tees the readable, and pumps raw pre-decode frames to whichever epoch's
// listener is currently registered. Installed once per realm by rtc-hook.ts's
// installHook (Meet only); the listener registry lives on `window`
// (__earsEncodedAudioListeners) so re-injected epochs hand off cleanly.

/** The raw pre-decode RTP frame shape delivered by createEncodedStreams()'s readable. */
export interface EncodedAudioFrameLike {
  readonly data: ArrayBuffer;
  readonly timestamp: number;
}

export type EncodedAudioListener = (frame: EncodedAudioFrameLike) => void;

interface EncodedListenersWindow extends Window {
  __earsEncodedAudioListeners?: Map<MediaStreamTrack, EncodedAudioListener>;
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
  const g = window as unknown as EncodedListenersWindow;
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

/** How many audio receivers Meet routed through our wrap (debug report). */
export function teedStreamCount(): number {
  return teedAudioStreamCount;
}

export function noteMeetAudioTrackLive(): void {
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
  }, TEE_WATCHDOG_MS);
}

export function installMeetEncodedAudioTee(): void {
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

