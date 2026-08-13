import {
  sourceLabel,
  type AttendeeUpsert,
  type EventFrame,
  type SessionWire,
  type ParticipantId,
  type Platform,
  type RosterEntry,
  type SnapshotWire,
} from "./protocol";

// Background-side session signal forwarder. The daemon owns the session
// state machine in protocol v2 (docs/specs/control-protocol.md);
// this class just translates what the tabs' DOM layers observe into the
// daemon's session verbs:
//
//   meeting-started      → session.start (idempotent on platform+external id)
//   meeting name scraped → session.rename (compare-and-set on rev)
//   participant joined   → session.attendee upsert (display name)
//   ingest stream opened → session.attendee upsert (source link)
//   participant left     → session.attendee upsert (left timestamp)
//   popup pause toggle   → session.pause / session.resume (marks, never capture)
//   meeting-ended / port → session.end
//   job events           → the "transcribing" badge (real pipeline state,
//                          not a guessed timer)
//
// Recovery is re-declaration: after service-worker eviction or a daemon
// restart, the transport's onReady fires with a fresh snapshot and this
// tracker re-declares every session its records (rebuilt from the DOM's
// signals) say are live — session.start converges instead of duplicating.

/** What the session layer contributes to the popup badge. */
export type SessionState = "idle" | "recording" | "paused" | "transcribing";

/** The full badge vocabulary: transport status (which wins while there's a
 * connection problem) plus the session states above. */
export type BadgeState =
  | "disconnected"
  | "connecting"
  | "connected"
  | "recording"
  | "paused"
  | "transcribing";

/** The control-plane surface SessionTracker consumes — ControlSocket
 * (control-transport.ts) in production, a recording fake in tests. */
export interface SessionControl {
  sessionStart(
    platform: Platform,
    externalMeetingId: string,
    title?: string,
  ): Promise<SessionWire>;
  sessionEnd(session: string): Promise<SessionWire>;
  sessionRename(session: string, title: string, ifRev?: number): Promise<SessionWire>;
  sessionPause(session: string): Promise<SessionWire>;
  sessionResume(session: string): Promise<SessionWire>;
  sessionAttendee(session: string, attendee: AttendeeUpsert): Promise<SessionWire>;
}

/**
 * A participant/stream signal that arrived on a port before its session.start
 * was declared (the linkage race — the DOM's participant-joined / ingest
 * stream-opened events can beat the Meet meeting-id resolution). Buffered
 * per-port and replayed onto the record once meetingStarted lands, instead of
 * being silently dropped (which stranded the session with no attendees and no
 * browser:* source, so the daemon never classified it as a browser session).
 */
type PendingPortEvent =
  | { kind: "joined"; platform: Platform; participantId: ParticipantId; displayName?: string }
  | { kind: "stream"; platform: Platform; participantId: ParticipantId }
  | { kind: "roster"; platform: Platform; entries: RosterEntry[] }
  | { kind: "renamed"; platform: Platform; fromId: ParticipantId; toId: ParticipantId };

// Guard against unbounded growth if a port never declares a session (e.g. a
// non-meeting tab that still opens a pcm port). Far above any real pre-declare
// burst; oldest events drop first.
const MAX_PENDING_PER_PORT = 256;

interface SessionRecord {
  /** Every port that has declared this meeting. Normally one, but the content
   * scripts inject with `allFrames` (Zoom nests the call in a same-origin
   * iframe), and each frame opens its own port — so one call can be spread
   * across several. The session is the *call*, not the frame: any member port
   * resolves it, and it ends only when the last one disconnects. */
  portIds: Set<string>;
  platform: Platform;
  externalMeetingId: string;
  /** Daemon-assigned session UUID, once session.start lands. */
  sessionId?: string;
  /** The session's last known revision — `session.rename`'s compare-and-set
   * key, so a title discovered mid-call never clobbers a manual rename. */
  rev?: number;
  /** The meeting name declared to the daemon, if any. */
  title?: string;
  /** Names already sent as a rename: at most one `session.rename` per
   * discovered name, and none at all once one has failed its compare-and-set
   * (that failure means a manual rename won, and it keeps winning). */
  renamesSent: Set<string>;
  /** A name discovered before session.start landed, applied on arrival. */
  pendingTitle?: string;
  /** A session.start is in flight. */
  starting: boolean;
  paused: boolean;
  ended: boolean;
  /** Attendee upserts observed before the session id was known. */
  pendingAttendees: AttendeeUpsert[];
  participants: Set<ParticipantId>;
}

export class SessionTracker {
  private readonly sessions = new Map<string, SessionRecord>();
  /** Live transcribe jobs, from `job` telemetry events. */
  private readonly activeJobs = new Set<string>();
  /** portId → signals seen before that port's session was declared. Drained
   * by meetingStarted, dropped by portDisconnected. */
  private readonly pendingByPort = new Map<string, PendingPortEvent[]>();
  private lastState: SessionState = "idle";

  constructor(
    private readonly control: SessionControl,
    private readonly onState: (s: SessionState) => void = () => {},
    /** Injectable wall clock for the roster's `left` timestamps. */
    private readonly nowISO: () => string = () => new Date().toISOString(),
  ) {}

  get state(): SessionState {
    for (const m of this.sessions.values()) {
      if (m.ended) continue;
      return m.paused ? "paused" : "recording";
    }
    return this.activeJobs.size > 0 ? "transcribing" : "idle";
  }

  /** True while any session is live (drives the popup's pause-toggle row). */
  get sessionActive(): boolean {
    for (const m of this.sessions.values()) if (!m.ended) return true;
    return false;
  }

  get paused(): boolean {
    return this.state === "paused";
  }

  /** The live session's external id for this tab's port — the membership tag
   * the transport stamps on ingest.open, so the daemon can link the source
   * into the session itself (grace-policy safety net for lost worker state). */
  externalIdFor(portId: string, platform: Platform): string | undefined {
    return this.findRecord(portId, platform)?.externalMeetingId;
  }

  /** meeting-started from a tab: declare it to the daemon. */
  meetingStarted(
    portId: string,
    platform: Platform,
    externalMeetingId: string,
    title?: string,
  ): void {
    const existing = this.sessions.get(externalMeetingId);
    if (existing && !existing.ended) {
      // Duplicate start — already tracked. Two ways that happens: the same
      // frame re-declaring, and (with `allFrames`) a second frame of the same
      // call declaring the same external id. Fold the new port into the
      // session, or its PCM resolves no session tag and its buffered signals
      // strand on a port no record matches.
      if (!existing.portIds.has(portId)) {
        existing.portIds.add(portId);
        this.drainPending(portId, existing);
      }
      // A title riding along on the duplicate is still news, though: treat it
      // exactly like a late scrape.
      if (title) this.meetingRenamed(externalMeetingId, title);
      return;
    }
    const record: SessionRecord = {
      portIds: new Set([portId]),
      platform,
      externalMeetingId,
      starting: false,
      paused: false,
      ended: false,
      pendingAttendees: [],
      participants: new Set(),
      renamesSent: new Set(),
      ...(title ? { title } : {}),
    };
    this.sessions.set(externalMeetingId, record);
    this.declare(record);
    this.drainPending(portId, record);
    this.emitState();
  }

  /**
   * The tab resolved the meeting's human name after the session was already
   * declared (calendar names often land seconds after join). Renamed with
   * `if_rev` as a compare-and-set, so a rename the user made by hand in the
   * meantime is never clobbered — and a lost compare-and-set is not retried.
   */
  meetingRenamed(externalMeetingId: string, title: string): void {
    const record = this.sessions.get(externalMeetingId);
    if (!record || record.ended) return;
    if (record.title === title || record.renamesSent.has(title)) return;
    if (!record.sessionId) {
      // The start is still in flight; declare() applies this when it lands.
      record.pendingTitle = title;
      return;
    }
    this.rename(record, title);
  }

  private rename(record: SessionRecord, title: string): void {
    if (record.renamesSent.size > 0) return; // one rename per session, at most
    record.renamesSent.add(title);
    const sessionId = record.sessionId;
    if (!sessionId) return;
    void this.control
      .sessionRename(sessionId, title, record.rev)
      .then((session) => {
        record.title = session.title;
        record.rev = session.rev;
      })
      .catch((err) => {
        // A `conflict` means the session was renamed by someone else since we
        // read `rev` — theirs wins, deliberately and permanently.
        console.warn(`[ears][session] session.rename(${sessionId}) failed:`, err);
      });
  }

  /** meeting-ended from the tab (capture toggled off, call teardown). */
  meetingEnded(externalMeetingId: string): void {
    const record = this.sessions.get(externalMeetingId);
    if (record) this.endSession(record);
  }

  /** A participant's identity (with display name, when known) from the
   * tab's DOM layer — upserted onto the daemon session's roster. */
  participantJoined(
    portId: string,
    platform: Platform,
    participantId: ParticipantId,
    displayName?: string,
  ): void {
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "joined", platform, participantId, displayName });
      return;
    }
    this.applyJoined(record, participantId, displayName);
  }

  /**
   * Resolved participant names from the platform roster (id → display name),
   * independent of capture. Upserts each onto the daemon session's attendee
   * roster so names land even for a participant whose track never correlated to
   * this id — unlike participantJoined, a roster entry is identity only and is
   * NOT enrolled as a capture participant (no capture pipeline exists for it,
   * so a track-teardown `left` must never stamp it). See issue #23.
   */
  rosterUpdate(portId: string, platform: Platform, entries: RosterEntry[]): void {
    if (entries.length === 0) return;
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "roster", platform, entries });
      return;
    }
    this.applyRoster(record, entries);
  }

  /**
   * A late identity join from the tab (see protocol.ts "participant-renamed"):
   * `fromId`'s track died before its identity upgrade could restart the
   * pipeline, so the audio already recorded stays under `fromId`'s source.
   * Attach that source to the *named* `toId` attendee so name and source land
   * on one roster row — which is what the transcript's speaker-name map keys
   * on. Identity only: `toId` is not enrolled as a capture participant.
   */
  participantRenamed(
    portId: string,
    platform: Platform,
    fromId: ParticipantId,
    toId: ParticipantId,
  ): void {
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "renamed", platform, fromId, toId });
      return;
    }
    this.applyRename(record, platform, fromId, toId);
  }

  /** An ingest stream for this participant is confirmed open on earsd — link
   * the attendee to their per-participant source (which downstream feeds the
   * transcript's speaker-name map). */
  streamOpened(portId: string, platform: Platform, participantId: ParticipantId): void {
    const record = this.findRecord(portId, platform);
    if (!record) {
      this.enqueuePending(portId, { kind: "stream", platform, participantId });
      return;
    }
    this.applyStream(record, platform, participantId);
  }

  private applyJoined(record: SessionRecord, participantId: ParticipantId, displayName?: string): void {
    record.participants.add(participantId);
    this.upsertAttendee(record, {
      id: participantId,
      ...(displayName ? { display_name: displayName } : {}),
    });
  }

  private applyStream(record: SessionRecord, platform: Platform, participantId: ParticipantId): void {
    record.participants.add(participantId);
    this.upsertAttendee(record, {
      id: participantId,
      source: sourceLabel(platform, participantId),
    });
  }

  private applyRename(
    record: SessionRecord,
    platform: Platform,
    fromId: ParticipantId,
    toId: ParticipantId,
  ): void {
    this.upsertAttendee(record, {
      id: toId,
      source: sourceLabel(platform, fromId),
    });
  }

  private applyRoster(record: SessionRecord, entries: RosterEntry[]): void {
    for (const entry of entries) {
      if (!entry.displayName) continue; // never upsert an empty name (issue #23)
      // Identity only — deliberately NOT added to record.participants: no
      // capture pipeline backs this id, so no pipeline-teardown `left` should
      // ever be stamped on it.
      this.upsertAttendee(record, {
        id: entry.participantId,
        display_name: entry.displayName,
        ...(entry.isLocal ? { self: true } : {}),
      });
    }
  }

  private enqueuePending(portId: string, event: PendingPortEvent): void {
    const queue = this.pendingByPort.get(portId) ?? [];
    queue.push(event);
    while (queue.length > MAX_PENDING_PER_PORT) queue.shift();
    this.pendingByPort.set(portId, queue);
  }

  /** Replay signals buffered before this port's session was declared. */
  private drainPending(portId: string, record: SessionRecord): void {
    const queue = this.pendingByPort.get(portId);
    if (!queue) return;
    this.pendingByPort.delete(portId);
    for (const event of queue) {
      if (event.platform !== record.platform) continue; // different platform on the same port — not this session
      if (event.kind === "joined") this.applyJoined(record, event.participantId, event.displayName);
      else if (event.kind === "roster") this.applyRoster(record, event.entries);
      else if (event.kind === "renamed") this.applyRename(record, event.platform, event.fromId, event.toId);
      else this.applyStream(record, event.platform, event.participantId);
    }
  }

  /** A participant left: upsert their roster `left` timestamp — never end the
   * session. The participant set drains to zero on a capture-seam swap
   * (escalateSeam stops every pipeline, then re-adopts under the new seam), so
   * "zero participants" is not evidence the call ended; treating it as an end
   * killed a live session 17s in and lost the rest of the meeting. Real ends
   * come from meeting-ended, the port disconnect (Meet's post-call redirect),
   * and the daemon's ingest-idle / superseded nets. */
  participantLeft(portId: string, participantId: ParticipantId): void {
    for (const record of this.sessions.values()) {
      if (!record.portIds.has(portId) || record.ended) continue;
      if (!record.participants.delete(participantId)) continue;
      this.upsertAttendee(record, { id: participantId, left: this.nowISO() });
    }
  }

  /** The tab's port went away (closed / navigated) — end its sessions and
   * drop any signals still buffered against a session that never declared. */
  portDisconnected(portId: string): void {
    this.pendingByPort.delete(portId);
    for (const record of this.sessions.values()) {
      if (record.ended || !record.portIds.has(portId)) continue;
      record.portIds.delete(portId);
      // Only the *last* frame leaving ends the call. A nested frame being torn
      // down or replaced mid-call must not end a session the sibling frames
      // are still capturing.
      if (record.portIds.size === 0) this.endSession(record);
    }
  }

  /**
   * The popup's pause toggle → session.pause / session.resume. Pausing
   * closes the session's open transcription mark on the daemon; capture and
   * PCM ingest are untouched throughout (marks, never capture control).
   */
  async setPaused(paused: boolean): Promise<void> {
    for (const record of this.sessions.values()) {
      if (record.ended || record.paused === paused) continue;
      record.paused = paused;
      if (!record.sessionId) continue; // declared state applies once start lands
      try {
        const session = paused
          ? await this.control.sessionPause(record.sessionId)
          : await this.control.sessionResume(record.sessionId);
        record.paused = session.state === "paused";
      } catch (err) {
        console.warn(`[ears][session] session.${paused ? "pause" : "resume"} failed:`, err);
      }
    }
    this.emitState();
  }

  /** A `job` telemetry event — real transcription progress for the badge. */
  jobEvent(frame: EventFrame): void {
    if (frame.event !== "job") return;
    const params = frame.params as { job?: string; kind?: string; state?: string };
    if (params.kind !== "transcribe" || !params.job) return;
    if (params.state === "done" || params.state === "failed") {
      this.activeJobs.delete(params.job);
    } else {
      this.activeJobs.add(params.job);
    }
    this.emitState();
  }

  /**
   * The transport (re)connected: hello + subscribe landed and `snapshot` is
   * fresh. Re-declare every session this tracker believes is live —
   * session.start is idempotent on identity, so this converges after
   * service-worker eviction and daemon restart alike.
   */
  onReady(snapshot: SnapshotWire, _bootChanged: boolean): void {
    for (const session of snapshot.sessions) {
      // Adopt daemon-side pause state for sessions we're re-syncing with.
      const record = session.identity
        ? this.sessions.get(session.identity.external_id)
        : undefined;
      if (record && !record.ended) {
        record.sessionId = session.id;
        record.rev = session.rev;
        record.paused = session.state === "paused";
      }
    }
    for (const record of this.sessions.values()) {
      if (!record.ended) this.declare(record);
    }
    this.emitState();
  }

  private findRecord(portId: string, platform: Platform): SessionRecord | undefined {
    for (const record of this.sessions.values()) {
      if (!record.ended && record.portIds.has(portId) && record.platform === platform) return record;
    }
    return undefined;
  }

  /** session.start (idempotent), then flush queued attendee upserts. */
  private declare(record: SessionRecord): void {
    if (record.starting) return;
    record.starting = true;
    void this.control
      .sessionStart(record.platform, record.externalMeetingId, record.title)
      .then((session) => {
        record.starting = false;
        if (record.ended) {
          // Ended while the start was in flight — end it right back.
          void this.control.sessionEnd(session.id).catch(() => {});
          return;
        }
        const wantPaused = record.paused;
        record.sessionId = session.id;
        record.rev = session.rev;
        console.debug(`[ears][session] session ${record.externalMeetingId} → ${session.id}`);
        // The popup may have toggled pause before the id was known; apply
        // it now. Otherwise adopt the daemon's state (idempotent re-declare
        // of an already-paused session stays paused).
        const daemonPaused = session.state === "paused";
        if (wantPaused && !daemonPaused) {
          void this.control.sessionPause(session.id).catch(() => {});
        } else {
          record.paused = daemonPaused;
        }
        const queued = record.pendingAttendees.splice(0, record.pendingAttendees.length);
        for (const attendee of queued) this.upsertAttendee(record, attendee);
        // A name scraped while the start was in flight.
        const pendingTitle = record.pendingTitle;
        record.pendingTitle = undefined;
        if (pendingTitle && pendingTitle !== record.title) this.rename(record, pendingTitle);
        this.emitState();
      })
      .catch((err) => {
        record.starting = false;
        console.warn(`[ears][session] session.start failed for ${record.externalMeetingId}:`, err);
      });
  }

  private upsertAttendee(record: SessionRecord, attendee: AttendeeUpsert): void {
    if (record.ended) return;
    if (!record.sessionId) {
      record.pendingAttendees.push(attendee);
      return;
    }
    const sessionId = record.sessionId;
    void this.control.sessionAttendee(sessionId, attendee).catch((err) => {
      console.warn(`[ears][session] session.attendee(${attendee.id}) failed:`, err);
    });
  }

  private endSession(record: SessionRecord): void {
    if (record.ended) return;
    record.ended = true;
    this.sessions.delete(record.externalMeetingId);
    if (record.sessionId) {
      void this.control.sessionEnd(record.sessionId).catch((err) => {
        console.warn(`[ears][session] session.end(${record.sessionId}) failed:`, err);
      });
    }
    // No sessionId yet: declare() notices `ended` when the start lands and
    // ends it then. If the start never landed at all, the daemon's
    // ingest-idle grace ends the session server-side.
    this.emitState();
  }

  private emitState(): void {
    const state = this.state;
    if (state === this.lastState) return;
    this.lastState = state;
    this.onState(state);
  }
}
