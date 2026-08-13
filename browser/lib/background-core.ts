import type { ParticipantRef, Platform, PortMessage, RosterEntry } from "./protocol";
import type { BadgeState, SessionState } from "./session-tracker";
import type { TransportStatus } from "./transport";

// The background's pure wiring core (attribution refactor R8). background.ts's
// pcm-port message switch moves here as reducers: functions of
// (state, message) → (state, effects), with every collaborator call —
// SessionTracker, KeepaliveTracker, EarsSocket — expressed as a typed effect a
// thin chrome shell executes (runBackgroundEffects). The collaborators keep
// their own well-tested state machines; what this module owns is the routing
// between them, which used to be testable only inside a live service worker.

/** Badge composition: transport problems win outright; otherwise the session
 * layer's recording/paused/transcribing, else plain "connected". */
export function composeBadgeState(status: TransportStatus, session: SessionState): BadgeState {
  if (status !== "connected") return status;
  if (session === "idle") return "connected";
  return session;
}

/** The port-routing facts the background accumulates across all pcm ports. */
export interface BackgroundPortState {
  /** participantId → the port (tab) its PCM arrives on, so an ingest-stream
   * open can be routed to that tab's session record. */
  participantPorts: Map<string, string>;
  /** participantId → frames forwarded, for the every-50-frames debug line. */
  frameCounts: Map<string, number>;
}

export function emptyBackgroundPortState(): BackgroundPortState {
  return { participantPorts: new Map(), frameCounts: new Map() };
}

/**
 * One collaborator call, as data. Kinds are named `target.method` after the
 * call the shell makes. `ingest.sendPcm` / `ingest.sendAttribution` carry the
 * port id instead of a session tag: the external meeting id is resolved at
 * execution time via `sessions.externalIdFor`, so the tag always reflects the
 * session layer's current belief, exactly as the inline switch did.
 */
export type BackgroundEffect =
  | { kind: "sessions.participantJoined"; portId: string; platform: Platform; participant: ParticipantRef }
  | { kind: "sessions.rosterUpdate"; portId: string; platform: Platform; entries: RosterEntry[] }
  | {
      kind: "sessions.participantIdentified";
      portId: string;
      platform: Platform;
      participantId: string;
      captureId: string;
      displayName?: string;
    }
  | { kind: "sessions.participantLeft"; portId: string; participantId: string }
  | {
      kind: "sessions.meetingStarted";
      portId: string;
      platform: Platform;
      externalMeetingId: string;
      title?: string;
    }
  | { kind: "sessions.meetingRenamed"; externalMeetingId: string; title: string }
  | { kind: "sessions.meetingEnded"; externalMeetingId: string }
  | { kind: "sessions.streamOpened"; portId: string; platform: Platform; participantId: string }
  | { kind: "sessions.portDisconnected"; portId: string }
  | { kind: "keepalive.participantActive"; portId: string; participantId: string; platform: Platform }
  | { kind: "keepalive.participantLeft"; portId: string; participantId: string }
  | { kind: "ingest.closeStream"; participantId: string }
  | {
      kind: "ingest.sendPcm";
      portId: string;
      participantId: string;
      platform: Platform;
      pcm: Uint8Array;
      seq: number;
      sentAt: number;
    }
  | { kind: "ingest.sendAttribution"; portId: string; platform: Platform; events: string[] }
  | { kind: "console"; level: "debug" | "error"; text: string };

/**
 * One pcm-port message in, the next port state and the effect plan out. Pure:
 * the input state is never mutated, and messages that change nothing hand the
 * same state object back.
 */
export function reducePortMessage(
  state: BackgroundPortState,
  portId: string,
  msg: PortMessage,
): { state: BackgroundPortState; effects: BackgroundEffect[] } {
  switch (msg.type) {
    case "joined":
      return {
        state,
        effects: [
          { kind: "sessions.participantJoined", portId, platform: msg.platform, participant: msg.participant },
        ],
      };
    case "roster":
      return {
        state,
        effects: [{ kind: "sessions.rosterUpdate", portId, platform: msg.platform, entries: msg.entries }],
      };
    case "identified":
      return {
        state,
        effects: [
          {
            kind: "sessions.participantIdentified",
            portId,
            platform: msg.platform,
            participantId: msg.participantId,
            captureId: msg.captureId,
            ...(msg.displayName ? { displayName: msg.displayName } : {}),
          },
        ],
      };
    case "left": {
      const participantPorts = new Map(state.participantPorts);
      participantPorts.delete(msg.participantId);
      return {
        state: { ...state, participantPorts },
        effects: [
          { kind: "keepalive.participantLeft", portId, participantId: msg.participantId },
          { kind: "ingest.closeStream", participantId: msg.participantId },
          { kind: "sessions.participantLeft", portId, participantId: msg.participantId },
        ],
      };
    }
    case "capture-failed":
      // A participant's capture died mid-call (e.g. the Meet decoder gave
      // up). The daemon otherwise just sees the source fall silent; log it
      // loudly here so the recorded gap is attributable to a capture
      // failure, not a quiet speaker. The participant stays in the roster
      // (no stream close) — a later renegotiated track re-adopts and
      // resumes capture on its own.
      return {
        state,
        effects: [
          {
            kind: "console",
            level: "error",
            text: `[ears][bg] capture failed for ${msg.participantId} (${msg.platform}): ${msg.reason}`,
          },
        ],
      };
    case "meeting-started":
      return {
        state,
        effects: [
          {
            kind: "sessions.meetingStarted",
            portId,
            platform: msg.platform,
            externalMeetingId: msg.externalMeetingId,
            ...(msg.title ? { title: msg.title } : {}),
          },
        ],
      };
    case "meeting-renamed":
      return {
        state,
        effects: [
          { kind: "sessions.meetingRenamed", externalMeetingId: msg.externalMeetingId, title: msg.title },
        ],
      };
    case "meeting-ended":
      return {
        state,
        effects: [{ kind: "sessions.meetingEnded", externalMeetingId: msg.externalMeetingId }],
      };
    case "attribution":
      // Flight-recorder batch: ship to earsd filed under this port's live
      // session (resolved at execution time). With no session (yet) the batch
      // is dropped — the in-page ring still holds the events for on-demand
      // export.
      return {
        state,
        effects: [{ kind: "ingest.sendAttribution", portId, platform: msg.platform, events: msg.events }],
      };
    case "pcm": {
      const participantPorts =
        state.participantPorts.get(msg.participantId) === portId
          ? state.participantPorts
          : new Map(state.participantPorts).set(msg.participantId, portId);
      const frameCounts = new Map(state.frameCounts);
      const n = (frameCounts.get(msg.participantId) ?? 0) + 1;
      frameCounts.set(msg.participantId, n);
      const effects: BackgroundEffect[] = [
        { kind: "keepalive.participantActive", portId, participantId: msg.participantId, platform: msg.platform },
        {
          kind: "ingest.sendPcm",
          portId,
          participantId: msg.participantId,
          platform: msg.platform,
          pcm: base64ToBytes(msg.b64),
          seq: msg.seq,
          sentAt: msg.sentAt,
        },
      ];
      if (n % 50 === 0) {
        effects.push({
          kind: "console",
          level: "debug",
          text: `[ears][bg] forwarded ${n} frames for ${msg.participantId}`,
        });
      }
      return { state: { participantPorts, frameCounts }, effects };
    }
  }
}

/**
 * The tab's port went away (closed / navigated mid-call): close its orphaned
 * participants' streams now rather than leaking them on earsd until the socket
 * reconnects — and end its sessions. `orphaned` is what the keepalive tracker
 * returned for this port (a state-and-answer call the shell makes first).
 */
export function reducePortDisconnect(
  state: BackgroundPortState,
  portId: string,
  orphaned: string[],
): { state: BackgroundPortState; effects: BackgroundEffect[] } {
  const effects: BackgroundEffect[] = [];
  let participantPorts = state.participantPorts;
  if (orphaned.length > 0) {
    participantPorts = new Map(participantPorts);
    for (const id of orphaned) {
      effects.push({ kind: "ingest.closeStream", participantId: id });
      participantPorts.delete(id);
    }
  }
  effects.push(
    { kind: "sessions.portDisconnected", portId },
    {
      kind: "console",
      level: "debug",
      text:
        `[ears][bg] pcm port disconnected (${portId})` +
        (orphaned.length ? ` — closed ${orphaned.length} orphaned stream(s)` : ""),
    },
  );
  return {
    state: participantPorts === state.participantPorts ? state : { ...state, participantPorts },
    effects,
  };
}

/** An ingest stream is confirmed open on earsd — route the confirmation to
 * the tab whose PCM carried this participant, if any port ever did. */
export function reduceStreamOpened(
  state: BackgroundPortState,
  participantId: string,
  platform: Platform,
): BackgroundEffect[] {
  const portId = state.participantPorts.get(participantId);
  return portId ? [{ kind: "sessions.streamOpened", portId, platform, participantId }] : [];
}

// ── Effect execution ─────────────────────────────────────────────────────────

/** The session layer as the effects see it — SessionTracker satisfies this
 * structurally; tests hand in recorders. */
export interface BackgroundSessionSink {
  participantJoined(portId: string, platform: Platform, participant: ParticipantRef): void;
  rosterUpdate(portId: string, platform: Platform, entries: RosterEntry[]): void;
  participantIdentified(
    portId: string,
    platform: Platform,
    participantId: string,
    captureId: string,
    displayName?: string,
  ): void;
  participantLeft(portId: string, participantId: string): void;
  meetingStarted(portId: string, platform: Platform, externalMeetingId: string, title?: string): void;
  meetingRenamed(externalMeetingId: string, title: string): void;
  meetingEnded(externalMeetingId: string): void;
  streamOpened(portId: string, platform: Platform, participantId: string): void;
  portDisconnected(portId: string): void;
  /** The live session's external id for this tab's port — the membership tag
   * stamped on ingest.open and attribution batches. */
  externalIdFor(portId: string, platform: Platform): string | undefined;
}

/** KeepaliveTracker's effect surface. */
export interface BackgroundKeepaliveSink {
  participantActive(portId: string, participantId: string, platform: Platform): void;
  participantLeft(portId: string, participantId: string): void;
}

/** EarsSocket's effect surface (the ingest WebSocket). */
export interface BackgroundIngestSink {
  /** socket.participantLeft: close the participant's ingest stream. */
  closeStream(participantId: string): void;
  sendPcm(
    participantId: string,
    platform: Platform,
    pcm: Uint8Array,
    meetingExternalId: string | undefined,
    stamp: { seq: number; sentAt: number },
  ): void;
  sendAttribution(events: string[], platform: Platform, meetingExternalId: string | undefined): void;
}

export interface BackgroundSinks {
  sessions: BackgroundSessionSink;
  keepalive: BackgroundKeepaliveSink;
  ingest: BackgroundIngestSink;
}

/** Execute a reducer's effect plan, in order. */
export function runBackgroundEffects(effects: BackgroundEffect[], sinks: BackgroundSinks): void {
  for (const effect of effects) {
    switch (effect.kind) {
      case "sessions.participantJoined":
        sinks.sessions.participantJoined(effect.portId, effect.platform, effect.participant);
        break;
      case "sessions.rosterUpdate":
        sinks.sessions.rosterUpdate(effect.portId, effect.platform, effect.entries);
        break;
      case "sessions.participantIdentified":
        sinks.sessions.participantIdentified(
          effect.portId,
          effect.platform,
          effect.participantId,
          effect.captureId,
          effect.displayName,
        );
        break;
      case "sessions.participantLeft":
        sinks.sessions.participantLeft(effect.portId, effect.participantId);
        break;
      case "sessions.meetingStarted":
        sinks.sessions.meetingStarted(
          effect.portId,
          effect.platform,
          effect.externalMeetingId,
          effect.title,
        );
        break;
      case "sessions.meetingRenamed":
        sinks.sessions.meetingRenamed(effect.externalMeetingId, effect.title);
        break;
      case "sessions.meetingEnded":
        sinks.sessions.meetingEnded(effect.externalMeetingId);
        break;
      case "sessions.streamOpened":
        sinks.sessions.streamOpened(effect.portId, effect.platform, effect.participantId);
        break;
      case "sessions.portDisconnected":
        sinks.sessions.portDisconnected(effect.portId);
        break;
      case "keepalive.participantActive":
        sinks.keepalive.participantActive(effect.portId, effect.participantId, effect.platform);
        break;
      case "keepalive.participantLeft":
        sinks.keepalive.participantLeft(effect.portId, effect.participantId);
        break;
      case "ingest.closeStream":
        sinks.ingest.closeStream(effect.participantId);
        break;
      case "ingest.sendPcm":
        sinks.ingest.sendPcm(
          effect.participantId,
          effect.platform,
          effect.pcm,
          sinks.sessions.externalIdFor(effect.portId, effect.platform),
          { seq: effect.seq, sentAt: effect.sentAt },
        );
        break;
      case "ingest.sendAttribution":
        sinks.ingest.sendAttribution(
          effect.events,
          effect.platform,
          sinks.sessions.externalIdFor(effect.portId, effect.platform),
        );
        break;
      case "console":
        if (effect.level === "error") console.error(effect.text);
        else console.debug(effect.text);
        break;
    }
  }
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
