import type { LogEntry } from "./debug-log";
import type { PerfRecord } from "./perf";
import type {
  MainMessage,
  ParticipantOrigin,
  Platform,
  PortMessage,
  RosterEntry,
} from "./protocol";

// The content relay's pure core (attribution refactor R8). The message switch
// that used to live inline in content.ts is a reducer here: a function of
// (state, message) → (state, effects), with the chrome plumbing — the pcm
// port, runtime messaging, perf instruments, the console — left to a thin
// shell that executes the returned effects (runRelayEffects). Everything the
// relay decides is therefore testable without a browser: what gets forwarded,
// what gets dropped, and what the durable state remembers for the
// worker-respawn replay (respawnReplay).

/**
 * Lifecycle facts this document knows, mirrored from the hook's messages: the
 * live meeting and current participants. This is the durable copy of what the
 * MV3 service worker holds only in memory — the worker can be evicted mid-call
 * and respawn empty, so the relay replays these to every fresh port (see
 * ReconnectingPort's onReconnect and {@link respawnReplay}).
 */
export interface RelayState {
  /** participant id (track handle) → its platform, learned from
   * participant-joined (which precedes the participant's first PCM), so PCM
   * frames can carry their platform and reconnect replays can re-teach the
   * roster. `kind` is the ref's provenance, replayed so a respawned worker
   * still stamps the attendee's origin correctly. */
  participants: Map<string, { platform: Platform; kind: ParticipantOrigin }>;
  /** participantId → resolved roster name, accumulated from participant-roster
   * (identity only, no capture pipeline). Replayed in full on worker respawn
   * because the MAIN world only ever sends deltas (#23). */
  roster: Map<string, { platform: Platform; displayName: string; isLocal?: boolean }>;
  /** captureId → identity link (participant-identified), keyed on the capture
   * id so a repeat confirmation overwrites rather than duplicates. Replayed on
   * worker respawn for the same reason as the roster. */
  identities: Map<string, { platform: Platform; participantId: string; displayName?: string }>;
  liveMeeting: { platform: Platform; externalMeetingId: string; title?: string } | null;
}

export function emptyRelayState(): RelayState {
  return { participants: new Map(), roster: new Map(), identities: new Map(), liveMeeting: null };
}

/**
 * Everything the reducer wants done in the impure world, in order. `post` is
 * a message for the background port; `countDrop` marks the posts (pcm) whose
 * failure the dropped-frames counter should record. The forward-* effects ride
 * runtime messaging instead of the port; count-* effects are the relay hop's
 * perf instruments.
 */
export type RelayEffect =
  | { kind: "post"; msg: PortMessage; countDrop?: boolean }
  | { kind: "forward-log"; entries: LogEntry[] }
  | { kind: "forward-perf"; records: PerfRecord[] }
  | { kind: "tag-platform"; platform: Platform }
  | { kind: "count-frame"; bytes: number; encodeMs?: number }
  | { kind: "count-dropped-no-identity" }
  | { kind: "console"; level: "debug" | "warn"; text: string };

/** The reducer's only impure inputs, both instrumentation: `detail` gates the
 * per-frame encode timing, `now` is the clock that measures it. */
export interface RelayOptions {
  detail: boolean;
  now: () => number;
}

const NO_TIMING: RelayOptions = { detail: false, now: () => 0 };

/**
 * One MAIN-world message in, the next relay state and the effect plan out.
 * Pure: the input state is never mutated, and when nothing changed the same
 * state object comes back (the pcm hot path allocates no new state).
 */
export function reduceRelay(
  state: RelayState,
  msg: MainMessage,
  opts: RelayOptions = NO_TIMING,
): { state: RelayState; effects: RelayEffect[] } {
  switch (msg.kind) {
    case "participant-joined": {
      const participants = new Map(state.participants);
      participants.set(msg.participant.id, {
        platform: msg.platform,
        kind: msg.participant.kind,
      });
      return {
        state: { ...state, participants },
        effects: [
          { kind: "tag-platform", platform: msg.platform },
          // Forward the capture declaration so the background can upsert the
          // daemon session's attendee roster (identity rides other messages).
          { kind: "post", msg: { type: "joined", participant: msg.participant, platform: msg.platform } },
          {
            kind: "console",
            level: "debug",
            text: `[ears][relay] joined ${msg.participant.id} gen${msg.generation} (${msg.platform})`,
          },
        ],
      };
    }
    case "participant-left": {
      const participants = new Map(state.participants);
      participants.delete(msg.participantId);
      return {
        state: { ...state, participants },
        effects: [
          { kind: "post", msg: { type: "left", participantId: msg.participantId } },
          {
            kind: "console",
            level: "debug",
            text: `[ears][relay] left ${msg.participantId} gen${msg.generation}`,
          },
        ],
      };
    }
    case "participant-roster": {
      // Identity-only names resolved from the platform roster; remember them for
      // respawn replay and forward so the background upserts the daemon roster.
      // News is a new *or changed* name, or a first `isLocal` — the local
      // marker often resolves after the name it belongs to has already been
      // forwarded, and filtering on the name alone would drop it forever.
      const fresh = msg.entries.filter((e) => {
        const known = state.roster.get(e.participantId);
        return known?.displayName !== e.displayName || (e.isLocal === true && !known?.isLocal);
      });
      const roster = new Map(state.roster);
      for (const entry of msg.entries) {
        roster.set(entry.participantId, {
          platform: msg.platform,
          displayName: entry.displayName,
          isLocal: entry.isLocal || state.roster.get(entry.participantId)?.isLocal,
        });
      }
      const effects: RelayEffect[] = [];
      if (fresh.length > 0) {
        effects.push(
          { kind: "post", msg: { type: "roster", platform: msg.platform, entries: fresh } },
          {
            kind: "console",
            level: "debug",
            text:
              `[ears][relay] roster ${fresh.length} name(s) (${msg.platform}): ` +
              fresh.map((e) => `${e.participantId}="${e.displayName}"`).join(", "),
          },
        );
      }
      return { state: { ...state, roster }, effects };
    }
    case "participant-identified": {
      const identities = new Map(state.identities);
      identities.set(msg.captureId, {
        platform: msg.platform,
        participantId: msg.participantId,
        ...(msg.displayName ? { displayName: msg.displayName } : {}),
      });
      return {
        state: { ...state, identities },
        effects: [
          {
            kind: "post",
            msg: {
              type: "identified",
              platform: msg.platform,
              participantId: msg.participantId,
              captureId: msg.captureId,
              ...(msg.displayName ? { displayName: msg.displayName } : {}),
            },
          },
          {
            kind: "console",
            level: "debug",
            text:
              `[ears][relay] identified ${msg.captureId} → ${msg.participantId}` +
              `${msg.displayName ? ` "${msg.displayName}"` : ""} (${msg.platform})`,
          },
        ],
      };
    }
    case "status":
      return {
        state,
        effects: [{ kind: "console", level: "debug", text: `[ears][relay] status: ${msg.text}` }],
      };
    case "log":
      // The MAIN-world hook's tapped console entries; hand them straight to
      // the background store (already batched by the hook).
      return {
        state,
        effects: msg.entries.length ? [{ kind: "forward-log", entries: msg.entries }] : [],
      };
    case "capture-failed": {
      // The participant is still in the call but their capture pipeline died;
      // forward it (with the platform learned at join) so the background can
      // attribute the audio gap. Not a participant-left: don't drop the roster.
      const platform = state.participants.get(msg.participantId)?.platform;
      const effects: RelayEffect[] = [
        {
          kind: "console",
          level: "warn",
          text: `[ears][relay] capture-failed ${msg.participantId} gen${msg.generation}: ${msg.reason}`,
        },
      ];
      if (platform) {
        effects.push({
          kind: "post",
          msg: { type: "capture-failed", participantId: msg.participantId, platform, reason: msg.reason },
        });
      }
      return { state, effects };
    }
    case "meeting-started": {
      const liveMeeting = {
        platform: msg.platform,
        externalMeetingId: msg.externalMeetingId,
        ...(msg.title ? { title: msg.title } : {}),
      };
      return {
        state: { ...state, liveMeeting },
        effects: [
          {
            kind: "post",
            msg: {
              type: "meeting-started",
              platform: msg.platform,
              externalMeetingId: msg.externalMeetingId,
              ...(msg.title ? { title: msg.title } : {}),
            },
          },
          {
            kind: "console",
            level: "debug",
            text: `[ears][relay] meeting started: ${msg.platform}/${msg.externalMeetingId}`,
          },
        ],
      };
    }
    case "meeting-renamed": {
      // Fold the name into the durable relay state too, so a respawned
      // service worker's replayed `meeting-started` already carries it.
      const liveMeeting =
        state.liveMeeting?.externalMeetingId === msg.externalMeetingId
          ? { ...state.liveMeeting, title: msg.title }
          : state.liveMeeting;
      return {
        state: liveMeeting === state.liveMeeting ? state : { ...state, liveMeeting },
        effects: [
          {
            kind: "post",
            msg: {
              type: "meeting-renamed",
              platform: msg.platform,
              externalMeetingId: msg.externalMeetingId,
              title: msg.title,
            },
          },
          { kind: "console", level: "debug", text: `[ears][relay] meeting named: ${msg.title}` },
        ],
      };
    }
    case "meeting-ended":
      return {
        state: { ...state, liveMeeting: null },
        effects: [
          {
            kind: "post",
            msg: {
              type: "meeting-ended",
              platform: msg.platform,
              externalMeetingId: msg.externalMeetingId,
            },
          },
          {
            kind: "console",
            level: "debug",
            text: `[ears][relay] meeting ended: ${msg.platform}/${msg.externalMeetingId}`,
          },
        ],
      };
    case "perf":
      // MAIN-world records; hand them straight to the background store. Kept
      // off the console-tap path on purpose (see perf.ts).
      return {
        state,
        effects: msg.records.length ? [{ kind: "forward-perf", records: msg.records }] : [],
      };
    case "attribution":
      // Attribution flight-recorder batch: opaque pre-encoded lines, straight
      // through to the background. No relay state — the MAIN world's ring is
      // the durable in-page copy, and the daemon's attribution.jsonl is
      // best-effort, so a respawned worker has nothing to replay here.
      return {
        state,
        effects: msg.events.length
          ? [{ kind: "post", msg: { type: "attribution", platform: msg.platform, events: msg.events } }]
          : [],
      };
    case "pcm": {
      const platform = state.participants.get(msg.participantId)?.platform;
      if (!platform) {
        // No join seen yet; drop until identity is known.
        return { state, effects: [{ kind: "count-dropped-no-identity" }] };
      }
      const bytes = new Uint8Array(msg.samples.buffer, msg.samples.byteOffset, msg.samples.byteLength);
      // base64 allocates a string the size of the frame on this thread — the
      // same thread the page renders on — so it is measured, not assumed cheap.
      const started = opts.detail ? opts.now() : 0;
      const b64 = bytesToBase64(bytes);
      const encodeMs = opts.detail ? opts.now() - started : undefined;
      return {
        state,
        effects: [
          {
            kind: "count-frame",
            bytes: bytes.byteLength,
            ...(encodeMs === undefined ? {} : { encodeMs }),
          },
          {
            kind: "post",
            msg: {
              type: "pcm",
              participantId: msg.participantId,
              platform,
              b64,
              seq: msg.seq,
              sentAt: msg.sentAt,
            },
            countDrop: true,
          },
        ],
      };
    }
  }
}

/** The relay hop's instruments, minimal shapes so tests can hand in plain
 * recorders (content.ts hands in perf.ts's Histogram/Counter). */
export interface RelayMetricSinks {
  encode: { observe(ms: number): void };
  frames: { add(n?: number): void };
  bytes: { add(n?: number): void };
  dropped: { add(n?: number): void };
  unknownParticipant: { add(n?: number): void };
}

/** The impure surface the effect runner drives — the thin chrome shell. */
export interface RelaySinks {
  /** Post on the background pcm port; false means the frame was dropped. */
  post(msg: PortMessage): boolean;
  /** Fire-and-forget runtime message (log/perf batches to the background). */
  sendRuntimeMessage(
    msg: { kind: "log-batch"; entries: LogEntry[] } | { kind: "perf-batch"; records: PerfRecord[] },
  ): void;
  tagPlatform(platform: Platform): void;
  metrics: RelayMetricSinks;
}

/** Execute a reducer's effect plan, in order. */
export function runRelayEffects(effects: RelayEffect[], sinks: RelaySinks): void {
  for (const effect of effects) {
    switch (effect.kind) {
      case "post": {
        const sent = sinks.post(effect.msg);
        if (!sent && effect.countDrop) sinks.metrics.dropped.add();
        break;
      }
      case "forward-log":
        sinks.sendRuntimeMessage({ kind: "log-batch", entries: effect.entries });
        break;
      case "forward-perf":
        sinks.sendRuntimeMessage({ kind: "perf-batch", records: effect.records });
        break;
      case "tag-platform":
        sinks.tagPlatform(effect.platform);
        break;
      case "count-frame":
        if (effect.encodeMs !== undefined) sinks.metrics.encode.observe(effect.encodeMs);
        sinks.metrics.frames.add();
        sinks.metrics.bytes.add(effect.bytes);
        break;
      case "count-dropped-no-identity":
        sinks.metrics.unknownParticipant.add();
        break;
      case "console":
        if (effect.level === "warn") console.warn(effect.text);
        else console.debug(effect.text);
        break;
    }
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}
