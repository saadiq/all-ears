import { describe, expect, it } from "vitest";
import { SpeakingCorrelator } from "./meet-correlator";

describe("SpeakingCorrelator", () => {
  it("matches a device onset to the one audio onset within the window (audio first)", () => {
    const c = new SpeakingCorrelator(200);
    expect(c.recordAudioOnset("track-a", 1000)).toBeNull();
    const match = c.recordDeviceOnset("device-377", 1042);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 1 });
  });

  it("matches a device onset to the one audio onset within the window (device first)", () => {
    const c = new SpeakingCorrelator(200);
    expect(c.recordDeviceOnset("device-378", 2000)).toBeNull();
    const match = c.recordAudioOnset("track-b", 2015);
    expect(match).toEqual({ trackKey: "track-b", deviceId: "device-378", confirmations: 1 });
  });

  it("does not match when zero audio onsets are within the window", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    const match = c.recordDeviceOnset("device-377", 5000); // 4s away, way outside window
    expect(match).toBeNull();
  });

  it("does not match when multiple audio onsets are within the window (ambiguous)", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    c.recordAudioOnset("track-b", 1050);
    const match = c.recordDeviceOnset("device-377", 1030);
    expect(match).toBeNull();
  });

  it("accumulates confirmations across repeated turns for the same pairing", () => {
    const c = new SpeakingCorrelator(200);
    let t = 0;
    let last = null as ReturnType<SpeakingCorrelator["recordDeviceOnset"]>;
    for (let turn = 0; turn < 3; turn++) {
      t += 1000;
      c.recordAudioOnset("track-a", t);
      last = c.recordDeviceOnset("device-377", t + 20);
    }
    expect(last).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 3 });
  });

  it("resets confirmations when a different track matches the same device id", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    expect(c.recordDeviceOnset("device-377", 1020)).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 1 });

    c.recordAudioOnset("track-b", 2000);
    expect(c.recordDeviceOnset("device-377", 2020)).toEqual({ trackKey: "track-b", deviceId: "device-377", confirmations: 1 });
  });

  it("tracks independent confidence per device id", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    c.recordDeviceOnset("device-377", 1010);
    c.recordAudioOnset("track-b", 2000);
    c.recordDeviceOnset("device-378", 2010);

    c.recordAudioOnset("track-a", 3000);
    const match = c.recordDeviceOnset("device-377", 3010);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 2 });
  });

  it("expires stale onsets outside the history window instead of matching them later", () => {
    const c = new SpeakingCorrelator(200, 1000); // 1s history
    c.recordAudioOnset("track-a", 1000);
    // Device onset arrives 5s later — long past both the correlation window and history — no match.
    const match = c.recordDeviceOnset("device-377", 6000);
    expect(match).toBeNull();
  });

  it("consumes matched events so they can't be reused by a later onset", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    c.recordDeviceOnset("device-377", 1010); // consumes both
    // A second, unrelated device onset close in time to the first audio onset
    // must not re-match it — it was already consumed.
    const match = c.recordDeviceOnset("device-999", 1015);
    expect(match).toBeNull();
  });

  it("matches a same-track onset cluster (multiple onsets, one track) unambiguously", () => {
    // The hook emits rapid onset clusters for one spoken turn (3+ within
    // ~300ms). Judged by distinct tracks, these are one unambiguous speaker.
    // Debounce off so the raw multi-onset case reaches tryMatch.
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-a", 1000);
    c.recordAudioOnset("track-a", 1080);
    c.recordAudioOnset("track-a", 1160);
    const match = c.recordDeviceOnset("device-377", 1120);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 1 });
  });

  it("still refuses a genuinely ambiguous window (onsets from two distinct tracks)", () => {
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-a", 1000);
    c.recordAudioOnset("track-b", 1040); // different track, same window
    const match = c.recordDeviceOnset("device-377", 1020);
    expect(match).toBeNull();
  });

  it("consumes the whole matched cluster so a later device onset can't reuse a leftover", () => {
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-a", 1000);
    c.recordAudioOnset("track-a", 1050);
    expect(c.recordDeviceOnset("device-377", 1020)).toEqual({
      trackKey: "track-a",
      deviceId: "device-377",
      confirmations: 1,
    });
    // Both onsets were consumed; a second device onset in the same window finds nothing.
    expect(c.recordDeviceOnset("device-999", 1040)).toBeNull();
  });

  it("debounces a same-track onset cluster to a single onset within the debounce window", () => {
    const c = new SpeakingCorrelator(200); // default 1s debounce
    c.recordAudioOnset("track-a", 1000);
    c.recordAudioOnset("track-a", 1100); // <1s after the accepted onset — ignored
    c.recordAudioOnset("track-a", 1200); // still <1s after the accepted onset — ignored
    // Only the first onset (t=1000) survives; a device onset near the cluster matches once.
    const match = c.recordDeviceOnset("device-377", 1150);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 1 });
  });

  it("refuses a pairing a rival device onset already in hand also fits", () => {
    // journal #158: the local participant's speaking-ring burst landing inside
    // the remote track's onset window is exactly as ambiguous as two tracks
    // sharing one device's window. This is the ordering where the rival is
    // visible before the match is attempted.
    const c = new SpeakingCorrelator(200, 3000, 0);
    expect(c.recordDeviceOnset("devices/160", 1020)).toBeNull(); // remote's own device
    expect(c.recordDeviceOnset("devices/159", 1040)).toBeNull(); // local participant's device
    expect(c.recordAudioOnset("track-remote", 1000)).toBeNull();
  });

  it("retracts a pairing when a second device's onset lands on the same burst afterwards", () => {
    // The live ordering: track onset, then both rings ~20ms apart. The first
    // device consumes the burst before the second is visible, so the collision
    // can only be caught retroactively.
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-remote", 1000);
    expect(c.recordDeviceOnset("devices/160", 1020)).toEqual({
      trackKey: "track-remote",
      deviceId: "devices/160",
      confirmations: 1,
    });
    expect(c.recordDeviceOnset("devices/159", 1040)).toBeNull();

    // That turn now counts for neither device: a second, clean turn comes back
    // at confirmations 1, not 2.
    c.recordAudioOnset("track-remote", 5000);
    expect(c.recordDeviceOnset("devices/160", 5020)).toEqual({
      trackKey: "track-remote",
      deviceId: "devices/160",
      confirmations: 1,
    });
  });

  it("never reaches a 2-turn threshold when every turn is shadowed (the journal #158 call)", () => {
    const c = new SpeakingCorrelator(200, 3000, 0);
    for (let turn = 0; turn < 6; turn++) {
      const t = 1000 + turn * 2000;
      c.recordAudioOnset("track-remote", t);
      const m = c.recordDeviceOnset("devices/160", t + 20);
      expect(m?.confirmations ?? 0).toBeLessThan(2);
      expect(c.recordDeviceOnset("devices/159", t + 40)).toBeNull();
    }
  });

  it("still confirms a pairing that is clean more often than it is shadowed", () => {
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-remote", 1000); // clean turn → 1
    c.recordDeviceOnset("devices/160", 1020);
    c.recordAudioOnset("track-remote", 5000); // clean turn → 2
    c.recordDeviceOnset("devices/160", 5020);
    c.recordAudioOnset("track-remote", 9000); // shadowed turn → 3, retracted to 2
    c.recordDeviceOnset("devices/160", 9020);
    c.recordDeviceOnset("devices/159", 9040);

    c.recordAudioOnset("track-remote", 13_000);
    expect(c.recordDeviceOnset("devices/160", 13_020)).toEqual({
      trackKey: "track-remote",
      deviceId: "devices/160",
      confirmations: 3,
    });
  });

  it("does not retract when the second device's onset is a separate turn", () => {
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-remote", 1000);
    c.recordDeviceOnset("devices/160", 1020);
    c.recordDeviceOnset("devices/159", 1900); // 900ms away — its own turn, not this burst

    c.recordAudioOnset("track-remote", 5000);
    expect(c.recordDeviceOnset("devices/160", 5020)).toEqual({
      trackKey: "track-remote",
      deviceId: "devices/160",
      confirmations: 2,
    });
  });

  it("treats a same-device onset cluster as one device, not a rival", () => {
    const c = new SpeakingCorrelator(200, 3000, 0);
    c.recordAudioOnset("track-a", 1000);
    expect(c.recordDeviceOnset("devices/160", 1010)).toEqual({
      trackKey: "track-a",
      deviceId: "devices/160",
      confirmations: 1,
    });
    // The same device bursting again over the same audio is one speaker, so it
    // must not retract its own match.
    c.recordDeviceOnset("devices/160", 1040);
    c.recordAudioOnset("track-a", 5000);
    expect(c.recordDeviceOnset("devices/160", 5010)).toEqual({
      trackKey: "track-a",
      deviceId: "devices/160",
      confirmations: 2,
    });
  });

  it("forgets a consumed pairing once it ages out of the history window", () => {
    const c = new SpeakingCorrelator(200, 1000, 0); // 1s history
    c.recordAudioOnset("track-remote", 1000);
    c.recordDeviceOnset("devices/160", 1020);
    c.recordDeviceOnset("devices/159", 3000); // 2s later — consumed record already pruned

    c.recordAudioOnset("track-remote", 5000);
    expect(c.recordDeviceOnset("devices/160", 5020)).toEqual({
      trackKey: "track-remote",
      deviceId: "devices/160",
      confirmations: 2,
    });
  });

  it("accepts a genuinely new turn from the same track once the debounce window passes", () => {
    const c = new SpeakingCorrelator(200); // default 1s debounce
    c.recordAudioOnset("track-a", 1000);
    c.recordDeviceOnset("device-377", 1010); // turn 1
    c.recordAudioOnset("track-a", 2500); // 1.5s later — a real new turn, not debounced
    const match = c.recordDeviceOnset("device-377", 2510);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 2 });
  });
});

// MeetAdapter's second correlator instance: collections mic-open edge ↔ the
// track-level "unmute" event, with a 2s window (the two edges ride different
// transports; the 2026-07-24 controlled test measured them ≤ ~900ms apart on
// every deliberate toggle — dev/captures/2026-07-24-meet-collections-drift.md).
// Same class, wider window; these tests replay the live timelines.
describe("SpeakingCorrelator as the unmute-edge correlator (2s window)", () => {
  const UNMUTE_WINDOW_MS = 2000;

  it("pairs a mic-open edge with a track unmute ~900ms apart (live 2026-07-24 timing)", () => {
    const c = new SpeakingCorrelator(UNMUTE_WINDOW_MS);
    // Track unmute at 17:31:49.0xx, collections flag=0 at 17:31:49.909.
    expect(c.recordAudioOnset("track-0915597b", 109_000)).toBeNull();
    const match = c.recordDeviceOnset("spaces/KGtf2n-bR-gB/devices/105", 109_909);
    expect(match).toEqual({
      trackKey: "track-0915597b",
      deviceId: "spaces/KGtf2n-bR-gB/devices/105",
      confirmations: 1,
    });
  });

  it("pairs the join-unmuted case where the edges land within the same second", () => {
    const c = new SpeakingCorrelator(UNMUTE_WINDOW_MS);
    // Guest joined unmuted: collections flag=0 at 17:03:28.x, track unmute same second.
    expect(c.recordDeviceOnset("spaces/nN-Aql2-48gB/devices/87", 208_500)).toBeNull();
    const match = c.recordAudioOnset("track-b485e2d8", 208_900);
    expect(match).toEqual({
      trackKey: "track-b485e2d8",
      deviceId: "spaces/nN-Aql2-48gB/devices/87",
      confirmations: 1,
    });
  });

  it("refuses to pair when a DTX-resume unmute from another track shares the window", () => {
    // A remote track also fires "unmute" when RTP resumes after DTX silence,
    // with no collections edge. If one coincides with someone else's real
    // toggle, the pairing is ambiguous and must stay unconsumed.
    const c = new SpeakingCorrelator(UNMUTE_WINDOW_MS);
    c.recordAudioOnset("track-toggler", 50_000);
    c.recordAudioOnset("track-dtx-resume", 50_600);
    expect(c.recordDeviceOnset("devices/105", 50_400)).toBeNull();
  });

  it("lets a lone DTX-resume unmute age out without ever matching", () => {
    const c = new SpeakingCorrelator(UNMUTE_WINDOW_MS);
    c.recordAudioOnset("track-dtx-resume", 10_000); // no collections edge follows
    // A real toggle 5s later pairs with its own unmute only.
    c.recordAudioOnset("track-toggler", 15_000);
    const match = c.recordDeviceOnset("devices/105", 15_400);
    expect(match).toEqual({ trackKey: "track-toggler", deviceId: "devices/105", confirmations: 1 });
  });
});
