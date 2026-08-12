import { describe, expect, it } from "vitest";
import { SessionTracker, type SessionControl, type SessionState } from "./session-tracker";
import type { AttendeeUpsert, SessionWire, SnapshotWire } from "./protocol";

// The tracker is a signal forwarder in v2: the daemon owns the session state
// machine, so these tests assert exactly which session verbs each DOM signal
// turns into — no session churn, no client-side pause emulation.

function sessionWire(overrides: Partial<SessionWire> = {}): SessionWire {
  return {
    id: "m-1",
    identity: { platform: "meet", external_id: "abc" },
    title: "meet abc",
    state: "active",
    started: "2026-07-19T10:00:00.000Z",
    intervals: [{ start: "2026-07-19T10:00:00.000Z", end: null }],
    attendees: [],
    sources: [],
    trigger: "browser-extension",
    rev: 1,
    ...overrides,
  };
}

type Call =
  | { verb: "start"; platform: string; externalMeetingId: string; title?: string }
  | { verb: "end" | "pause" | "resume"; session: string }
  | { verb: "rename"; session: string; title: string; ifRev?: number }
  | { verb: "attendee"; session: string; attendee: AttendeeUpsert };

/** Records every verb; resolves immediately unless `deferStart` holds the
 * session.start promise open for in-flight-race tests. */
class FakeControl implements SessionControl {
  calls: Call[] = [];
  deferStart = false;
  private startResolvers: Array<(m: SessionWire) => void> = [];
  startResult: SessionWire = sessionWire();

  /** Set to make session.rename reject, standing in for the daemon's
   * `conflict` when `if_rev` no longer matches (a manual rename landed). */
  renameFails = false;

  sessionStart(platform: string, externalMeetingId: string, title?: string): Promise<SessionWire> {
    this.calls.push({ verb: "start", platform, externalMeetingId, ...(title ? { title } : {}) });
    if (this.deferStart) {
      return new Promise((resolve) => this.startResolvers.push(resolve));
    }
    return Promise.resolve(this.startResult);
  }

  resolveStart(session: SessionWire = this.startResult): void {
    this.startResolvers.shift()?.(session);
  }

  sessionEnd(session: string): Promise<SessionWire> {
    this.calls.push({ verb: "end", session });
    return Promise.resolve(sessionWire({ id: session, state: "ended" }));
  }

  sessionPause(session: string): Promise<SessionWire> {
    this.calls.push({ verb: "pause", session });
    return Promise.resolve(sessionWire({ id: session, state: "paused" }));
  }

  sessionResume(session: string): Promise<SessionWire> {
    this.calls.push({ verb: "resume", session });
    return Promise.resolve(sessionWire({ id: session, state: "active" }));
  }

  sessionRename(session: string, title: string, ifRev?: number): Promise<SessionWire> {
    this.calls.push({ verb: "rename", session, title, ...(ifRev === undefined ? {} : { ifRev }) });
    if (this.renameFails) return Promise.reject(new Error("conflict"));
    return Promise.resolve(sessionWire({ id: session, title, rev: (ifRev ?? 0) + 1 }));
  }

  sessionAttendee(session: string, attendee: AttendeeUpsert): Promise<SessionWire> {
    this.calls.push({ verb: "attendee", session, attendee });
    return Promise.resolve(sessionWire({ id: session }));
  }

  ofVerb(verb: Call["verb"]): Call[] {
    return this.calls.filter((c) => c.verb === verb);
  }
}

const NOW = "2026-07-19T11:00:00.000Z";

function makeTracker(control: FakeControl): {
  tracker: SessionTracker;
  states: SessionState[];
} {
  const states: SessionState[] = [];
  const tracker = new SessionTracker(control, (s) => states.push(s), () => NOW);
  return { tracker, states };
}

async function flush(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
}

describe("SessionTracker (v2 signal forwarder)", () => {
  it("meeting-started declares the session and records its daemon id", async () => {
    const control = new FakeControl();
    const { tracker, states } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    expect(control.calls).toEqual([{ verb: "start", platform: "meet", externalMeetingId: "abc" }]);
    expect(states).toEqual(["recording"]);
    expect(tracker.sessionActive).toBe(true);
  });

  it("externalIdFor answers for the declaring port and goes silent once the session ends", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    expect(tracker.externalIdFor("p1", "meet")).toBeUndefined();

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(tracker.externalIdFor("p1", "meet")).toBe("abc");
    expect(tracker.externalIdFor("p2", "meet")).toBeUndefined(); // another tab's port
    expect(tracker.externalIdFor("p1", "zoom")).toBeUndefined(); // platform mismatch

    tracker.meetingEnded("abc");
    await flush();
    expect(tracker.externalIdFor("p1", "meet")).toBeUndefined();
  });

  it("a title known at declare time rides along on session.start", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc", "Kevin Weekly");
    await flush();

    expect(control.ofVerb("start")).toEqual([
      { verb: "start", platform: "meet", externalMeetingId: "abc", title: "Kevin Weekly" },
    ]);
    expect(control.ofVerb("rename")).toEqual([]);
  });

  it("a title discovered after join renames the session, compare-and-set on rev", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.meetingRenamed("abc", "Kevin Weekly");
    await flush();

    expect(control.ofVerb("rename")).toEqual([
      { verb: "rename", session: "m-1", title: "Kevin Weekly", ifRev: 1 },
    ]);
  });

  it("sends at most one rename per discovered name", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.meetingRenamed("abc", "Kevin Weekly");
    tracker.meetingRenamed("abc", "Kevin Weekly");
    await flush();

    expect(control.ofVerb("rename")).toHaveLength(1);
  });

  it("never renames to the title it already declared with", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc", "Kevin Weekly");
    await flush();
    tracker.meetingRenamed("abc", "Kevin Weekly");
    await flush();

    expect(control.ofVerb("rename")).toEqual([]);
  });

  it("a rename that lost the compare-and-set is not retried — a manual rename wins", async () => {
    const control = new FakeControl();
    control.renameFails = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.meetingRenamed("abc", "Kevin Weekly");
    await flush();
    tracker.meetingRenamed("abc", "Kevin Weekly");
    await flush();

    expect(control.ofVerb("rename")).toHaveLength(1);
  });

  it("a title discovered before session.start lands still reaches the daemon", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.meetingRenamed("abc", "Kevin Weekly");
    await flush();
    // Nothing to rename yet — the session has no id.
    expect(control.ofVerb("rename")).toEqual([]);

    control.resolveStart();
    await flush();

    expect(control.ofVerb("rename")).toEqual([
      { verb: "rename", session: "m-1", title: "Kevin Weekly", ifRev: 1 },
    ]);
  });

  it("a duplicate meeting-started is not re-declared", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    expect(control.ofVerb("start")).toHaveLength(1);
  });

  it("a second frame's port joins the same session rather than starting another", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    // Zoom nests the call in an iframe and both frames declare (allFrames).
    tracker.meetingStarted("p1", "zoom", "87973734905");
    tracker.meetingStarted("p2", "zoom", "87973734905");
    await flush();

    expect(control.ofVerb("start")).toHaveLength(1);
    // The late-joining frame's port must resolve the session, or its PCM
    // carries no membership tag and earsd rejects every ingest.open.
    expect(tracker.externalIdFor("p2", "zoom")).toBe("87973734905");
  });

  it("replays a second frame's buffered pre-declare signals when it joins", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "zoom", "87973734905");
    await flush();
    // The media frame's audio beats its own declare.
    tracker.streamOpened("p2", "zoom", "zoom-16781312");
    expect(control.ofVerb("attendee")).toHaveLength(0); // buffered on p2

    tracker.meetingStarted("p2", "zoom", "87973734905");
    await flush();

    expect(control.ofVerb("attendee")).toEqual([
      {
        verb: "attendee",
        session: "m-1",
        attendee: { id: "zoom-16781312", source: "browser:zoom:zoom-16781312" },
      },
    ]);
  });

  it("ends the session only when the last frame's port disconnects", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "zoom", "87973734905");
    tracker.meetingStarted("p2", "zoom", "87973734905");
    await flush();

    tracker.portDisconnected("p1");
    await flush();
    expect(control.ofVerb("end")).toHaveLength(0); // p2 is still in the call

    tracker.portDisconnected("p2");
    await flush();
    expect(control.ofVerb("end")).toHaveLength(1);
  });

  it("attendee signals queue until the session id lands, then flush in order", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.participantJoined("p1", "meet", "jane", "Jane Doe");
    tracker.streamOpened("p1", "meet", "jane");
    expect(control.ofVerb("attendee")).toHaveLength(0); // still queued

    control.resolveStart();
    await flush();

    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", session: "m-1", attendee: { id: "jane", display_name: "Jane Doe" } },
      {
        verb: "attendee",
        session: "m-1",
        attendee: { id: "jane", source: "browser:meet:jane" },
      },
    ]);
  });

  it("buffers participant/stream signals that arrive before meeting-started and flushes them once it lands", async () => {
    // The linkage race: the tab's participant-joined / ingest stream-opened
    // events beat the Meet meeting-id resolution, so meeting-started arrives
    // last. These must not be dropped (which stranded the session with no
    // attendees and no browser:* source).
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.participantJoined("p1", "meet", "jane", "Jane Doe");
    tracker.streamOpened("p1", "meet", "jane");
    expect(control.ofVerb("attendee")).toHaveLength(0); // no record yet — buffered

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    expect(control.ofVerb("start")).toEqual([{ verb: "start", platform: "meet", externalMeetingId: "abc" }]);
    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", session: "m-1", attendee: { id: "jane", display_name: "Jane Doe" } },
      { verb: "attendee", session: "m-1", attendee: { id: "jane", source: "browser:meet:jane" } },
    ]);
  });

  it("drops buffered pre-start signals if the port disconnects before declaring", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.participantJoined("p1", "meet", "jane", "Jane Doe");
    tracker.portDisconnected("p1");

    // A later session on the same port id must not resurrect the dropped signal.
    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("attendee")).toHaveLength(0);
  });

  it("participant-left upserts a left timestamp; even the last leaver never ends the session", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.participantJoined("p1", "meet", "jane", "Jane");
    tracker.participantJoined("p1", "meet", "marcus", "Marcus");
    await flush();

    tracker.participantLeft("p1", "jane");
    await flush();
    expect(control.ofVerb("end")).toHaveLength(0);
    expect(control.calls.at(-1)).toEqual({
      verb: "attendee",
      session: "m-1",
      attendee: { id: "jane", left: NOW },
    });

    // A seam swap (escalateSeam) drains the whole set and re-adopts moments
    // later — zero participants is not evidence the call ended.
    tracker.participantLeft("p1", "marcus");
    await flush();
    expect(control.calls.at(-1)).toEqual({
      verb: "attendee",
      session: "m-1",
      attendee: { id: "marcus", left: NOW },
    });
    expect(control.ofVerb("end")).toHaveLength(0);
    expect(tracker.sessionActive).toBe(true);

    // The new seam's tracks re-join the same live session.
    tracker.participantJoined("p1", "meet", "webaudio-track-1");
    await flush();
    expect(control.calls.at(-1)).toEqual({
      verb: "attendee",
      session: "m-1",
      attendee: { id: "webaudio-track-1" },
    });
  });

  it("rosterUpdate upserts display-name-only attendees keyed by device id (issue #23)", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.rosterUpdate("p1", "meet", [
      { participantId: "spaces/s/devices/445", displayName: "Tom Elliot" },
      { participantId: "spaces/s/devices/446", displayName: "Tom E" },
    ]);
    await flush();

    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", session: "m-1", attendee: { id: "spaces/s/devices/445", display_name: "Tom Elliot" } },
      { verb: "attendee", session: "m-1", attendee: { id: "spaces/s/devices/446", display_name: "Tom E" } },
    ]);
  });

  it("a roster name is identity-only: it does not enrol a capture participant", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    // One real capture participant plus a roster name for someone never captured.
    tracker.participantJoined("p1", "meet", "speaker-1");
    tracker.rosterUpdate("p1", "meet", [{ participantId: "spaces/s/devices/445", displayName: "Tom Elliot" }]);
    await flush();
    const upsertsBefore = control.ofVerb("attendee").length;

    // No capture pipeline backs the roster id, so a track-teardown `left` for
    // it must not stamp the attendee row.
    tracker.participantLeft("p1", "spaces/s/devices/445");
    await flush();
    expect(control.ofVerb("attendee")).toHaveLength(upsertsBefore);

    // The capture participant's leave stamps its row (and ends nothing).
    tracker.participantLeft("p1", "speaker-1");
    await flush();
    expect(control.calls.at(-1)).toEqual({
      verb: "attendee",
      session: "m-1",
      attendee: { id: "speaker-1", left: NOW },
    });
    expect(control.ofVerb("end")).toHaveLength(0);
  });

  it("buffers roster names that arrive before meeting-started and flushes them once it lands", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.rosterUpdate("p1", "meet", [{ participantId: "spaces/s/devices/445", displayName: "Tom Elliot" }]);
    expect(control.ofVerb("attendee")).toHaveLength(0); // no record yet — buffered

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", session: "m-1", attendee: { id: "spaces/s/devices/445", display_name: "Tom Elliot" } },
    ]);
  });

  it("participantRenamed attaches the dead track's source to the named attendee", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    // The Etel case: speaker-1's audio recorded, the roster named the device,
    // and the track died before the identity upgrade could restart capture.
    tracker.rosterUpdate("p1", "meet", [
      { participantId: "spaces/s/devices/183", displayName: "Etel Friedmann" },
    ]);
    tracker.participantRenamed("p1", "meet", "speaker-1", "spaces/s/devices/183");
    await flush();

    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", session: "m-1", attendee: { id: "spaces/s/devices/183", display_name: "Etel Friedmann" } },
      // Name and source now land on the same attendee row — the join the
      // transcript's speaker map needs. The id is sanitized into the label.
      { verb: "attendee", session: "m-1", attendee: { id: "spaces/s/devices/183", source: "browser:meet:speaker-1" } },
    ]);
  });

  it("a rename is identity-only: it does not enrol a capture participant", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.participantJoined("p1", "meet", "speaker-1");
    tracker.participantRenamed("p1", "meet", "speaker-1", "spaces/s/devices/183");
    await flush();
    const upsertsBefore = control.ofVerb("attendee").length;

    // The rename target has no capture pipeline — its `left` stamps nothing.
    tracker.participantLeft("p1", "spaces/s/devices/183");
    await flush();
    expect(control.ofVerb("attendee")).toHaveLength(upsertsBefore);

    tracker.participantLeft("p1", "speaker-1");
    await flush();
    expect(control.calls.at(-1)).toEqual({
      verb: "attendee",
      session: "m-1",
      attendee: { id: "speaker-1", left: NOW },
    });
    expect(control.ofVerb("end")).toHaveLength(0);
  });

  it("buffers a rename that arrives before meeting-started and flushes it once it lands", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.participantRenamed("p1", "meet", "speaker-1", "spaces/s/devices/183");
    expect(control.ofVerb("attendee")).toHaveLength(0); // no record yet — buffered

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("attendee")).toEqual([
      { verb: "attendee", session: "m-1", attendee: { id: "spaces/s/devices/183", source: "browser:meet:speaker-1" } },
    ]);
  });

  it("rosterUpdate with an empty batch is a no-op", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.rosterUpdate("p1", "meet", []);
    await flush();
    expect(control.ofVerb("attendee")).toHaveLength(0);
  });

  it("the pause toggle maps to session.pause / session.resume — never session churn", async () => {
    const control = new FakeControl();
    const { tracker, states } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();

    await tracker.setPaused(true);
    expect(control.ofVerb("pause")).toEqual([{ verb: "pause", session: "m-1" }]);
    expect(states).toEqual(["recording", "paused"]);
    expect(tracker.paused).toBe(true);

    await tracker.setPaused(false);
    expect(control.ofVerb("resume")).toEqual([{ verb: "resume", session: "m-1" }]);
    expect(tracker.paused).toBe(false);
  });

  it("a pause toggled before the session id lands is applied when it does", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await tracker.setPaused(true);
    expect(control.ofVerb("pause")).toHaveLength(0); // no id yet

    control.resolveStart();
    await flush();
    expect(control.ofVerb("pause")).toEqual([{ verb: "pause", session: "m-1" }]);
  });

  it("meeting-ended and port disconnect both end the daemon session", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    tracker.meetingEnded("abc");
    await flush();
    expect(control.ofVerb("end")).toEqual([{ verb: "end", session: "m-1" }]);

    control.startResult = sessionWire({
      id: "m-2",
      identity: { platform: "meet", external_id: "xyz" },
    });
    tracker.meetingStarted("p2", "meet", "xyz");
    await flush();
    tracker.portDisconnected("p2");
    await flush();
    expect(control.ofVerb("end").at(-1)).toEqual({ verb: "end", session: "m-2" });
  });

  it("a session ended while session.start is in flight is ended once the id lands", async () => {
    const control = new FakeControl();
    control.deferStart = true;
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    tracker.meetingEnded("abc");
    expect(control.ofVerb("end")).toHaveLength(0);

    control.resolveStart();
    await flush();
    expect(control.ofVerb("end")).toEqual([{ verb: "end", session: "m-1" }]);
  });

  it("job telemetry drives the transcribing badge with real pipeline state", async () => {
    const control = new FakeControl();
    const { tracker, states } = makeTracker(control);

    tracker.jobEvent({
      event: "job",
      params: { job: "j1", kind: "transcribe", session: "m-1", state: "started" },
    });
    expect(states).toEqual(["transcribing"]);

    tracker.jobEvent({
      event: "job",
      params: { job: "j1", kind: "transcribe", session: "m-1", state: "done" },
    });
    expect(states).toEqual(["transcribing", "idle"]);
  });

  it("onReady re-declares live sessions (idempotent recovery) and adopts daemon pause state", async () => {
    const control = new FakeControl();
    const { tracker } = makeTracker(control);

    tracker.meetingStarted("p1", "meet", "abc");
    await flush();
    expect(control.ofVerb("start")).toHaveLength(1);

    // Reconnect: the daemon says the session is paused (e.g. paused from the
    // CLI while the worker was evicted).
    const snapshot: SnapshotWire = {
      rev: 50,
      sessions: [sessionWire({ state: "paused" })],
      sources: [],
    };
    control.startResult = sessionWire({ state: "paused" });
    tracker.onReady(snapshot, true);
    await flush();

    expect(control.ofVerb("start")).toHaveLength(2); // re-declared, converges
    expect(tracker.paused).toBe(true);
  });
});
