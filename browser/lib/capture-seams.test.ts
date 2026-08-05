import { describe, expect, it } from "vitest";
import {
  SeamArbiter,
  SEAM_ESCALATION_GRACE_MS,
  seamUsesReceiverTracks,
  seamOrderFor,
  seamTracksToAdopt,
  type TrackProvenanceInfo,
} from "./capture-seams";

// Pure tier-0 unit: every timestamp is injected, nothing reads the clock.
const T0 = 1_000_000;

function arbiter(seams = ["a", "b", "c"], graceMs = SEAM_ESCALATION_GRACE_MS): SeamArbiter {
  return new SeamArbiter(seams, graceMs);
}

describe("SeamArbiter", () => {
  it("starts on the first seam and does not escalate before anything unmutes", () => {
    const a = arbiter();
    expect(a.active).toBe("a");
    // A call where nobody has spoken yet must never escalate: no unmute means
    // the platform is not claiming audio is flowing, so "no frames" is normal.
    expect(a.tick(T0 + 10 * SEAM_ESCALATION_GRACE_MS)).toBeNull();
    expect(a.active).toBe("a");
  });

  it("escalates to the next seam when an unmute yields no frame within the grace", () => {
    const a = arbiter();
    a.noteUnmute(T0);
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS - 1)).toBeNull();
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS)).toBe("b");
    expect(a.active).toBe("b");
  });

  it("re-arms the grace on the new seam so a dead second seam escalates again", () => {
    const a = arbiter();
    a.noteUnmute(T0);
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS)).toBe("b");
    // The unmute is still outstanding — the new seam gets its own full grace.
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS + 1)).toBeNull();
    expect(a.tick(T0 + 2 * SEAM_ESCALATION_GRACE_MS)).toBe("c");
  });

  it("locks in a seam that produces a frame and never escalates off it again", () => {
    const a = arbiter();
    a.noteUnmute(T0);
    a.noteFrame(T0 + 100);
    expect(a.proven).toBe(true);
    // A proven seam going quiet is legitimate — participants stop talking.
    a.noteUnmute(T0 + 200);
    expect(a.tick(T0 + 200 + 10 * SEAM_ESCALATION_GRACE_MS)).toBeNull();
    expect(a.active).toBe("a");
  });

  it("stops at the last seam and reports exhaustion instead of cycling", () => {
    const a = arbiter(["a", "b", "c"]);
    a.noteUnmute(T0);
    expect(a.exhausted).toBe(false);
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS)).toBe("b");
    expect(a.exhausted).toBe(false);
    // Landing on the final seam is itself exhaustion — there is nothing left
    // to fall back to, even though this tick did escalate.
    expect(a.tick(T0 + 2 * SEAM_ESCALATION_GRACE_MS)).toBe("c");
    expect(a.exhausted).toBe(true);
    // Exhausted must be terminal: no wrap-around to "a", no repeated churn.
    expect(a.tick(T0 + 3 * SEAM_ESCALATION_GRACE_MS)).toBeNull();
    expect(a.tick(T0 + 100 * SEAM_ESCALATION_GRACE_MS)).toBeNull();
    expect(a.active).toBe("c");
  });

  it("treats a later unmute as a fresh grace window when nothing has decoded", () => {
    const a = arbiter();
    a.noteUnmute(T0);
    // Escalated once; a subsequent unmute on the new seam restarts its window
    // from the later of the two rather than inheriting the stale deadline.
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS)).toBe("b");
    a.noteUnmute(T0 + SEAM_ESCALATION_GRACE_MS + 500);
    expect(a.tick(T0 + 2 * SEAM_ESCALATION_GRACE_MS)).toBeNull();
    expect(a.tick(T0 + 2 * SEAM_ESCALATION_GRACE_MS + 500)).toBe("c");
  });

  it("ignores a frame arriving after escalation for a seam that is no longer active", () => {
    const a = arbiter();
    a.noteUnmute(T0);
    expect(a.tick(T0 + SEAM_ESCALATION_GRACE_MS)).toBe("b");
    // A straggler frame from the torn-down seam must not mark "b" as proven.
    a.noteFrame(T0 + SEAM_ESCALATION_GRACE_MS + 1, "a");
    expect(a.proven).toBe(false);
    expect(a.tick(T0 + 2 * SEAM_ESCALATION_GRACE_MS)).toBe("c");
  });

  it("accepts a frame tagged with the active seam", () => {
    const a = arbiter();
    a.noteUnmute(T0);
    a.noteFrame(T0 + 50, "a");
    expect(a.proven).toBe(true);
  });

  it("is a no-op arbiter when given a single seam", () => {
    const a = arbiter(["only"]);
    a.noteUnmute(T0);
    expect(a.tick(T0 + 10 * SEAM_ESCALATION_GRACE_MS)).toBeNull();
    expect(a.active).toBe("only");
    expect(a.exhausted).toBe(true);
  });
});

describe("seamOrderFor", () => {
  it("puts the receiver track first on every platform — it carries identity", () => {
    for (const platform of ["meet", "zoom", "teams"] as const) {
      expect(seamOrderFor(platform)[0]).toBe("receiver-track");
    }
  });

  it("gives Meet its extra fallbacks, ordered cheapest-first", () => {
    // WebAudio before the encoded tee: the tee needs Meet to call
    // createEncodedStreams (absent on current builds, journal #104), while the
    // WebAudio registry is populated by a passive wrap that always runs.
    expect(seamOrderFor("meet")).toEqual(["receiver-track", "webaudio-track", "meet-encoded-tee"]);
  });

  it("leaves Zoom and Teams on the single seam that already works", () => {
    // Their receiver tracks carry real audio; adding speculative fallbacks
    // would risk double-capture for no benefit (journal #31).
    expect(seamOrderFor("zoom")).toEqual(["receiver-track"]);
    expect(seamOrderFor("teams")).toEqual(["receiver-track"]);
  });
});

describe("seamUsesReceiverTracks", () => {
  it("includes the encoded tee — it keys its pipeline on the receiver track", () => {
    // Only the FRAMES come from the decoder; the pipeline (and therefore the
    // identity) is still the receiver's. Excluding it here would leave the tee
    // seam with no tracks to adopt and no identity — journal #31 shows it
    // delivering named per-participant audio.
    expect(seamUsesReceiverTracks("receiver-track")).toBe(true);
    expect(seamUsesReceiverTracks("meet-encoded-tee")).toBe(true);
  });

  it("excludes the WebAudio seam — its ids never match a hooked receiver", () => {
    // So it must start under a provisional id rather than inherit a
    // neighbouring participant's name (rtc-hook.ts:654).
    expect(seamUsesReceiverTracks("webaudio-track")).toBe(false);
  });
});

describe("seamTracksToAdopt", () => {
  it("adopts nothing for receiver-based seams — those tracks arrive via the sink", () => {
    // Adopting here as well as in the ontrack sink would double-capture every
    // participant on Zoom and Teams.
    expect(seamTracksToAdopt("receiver-track", ["t1", "t2"], new Set())).toEqual([]);
    expect(seamTracksToAdopt("meet-encoded-tee", ["t1", "t2"], new Set())).toEqual([]);
  });

  it("adopts every unseen track for a non-receiver seam", () => {
    expect(seamTracksToAdopt("webaudio-track", ["t1", "t2"], new Set())).toEqual(["t1", "t2"]);
  });

  it("never re-adopts a track the sweep already captured", () => {
    // reconcile() runs every 3s for the life of the call; without this the
    // same source track would gain a new pipeline on every sweep.
    expect(seamTracksToAdopt("webaudio-track", ["t1", "t2"], new Set(["t1"]))).toEqual(["t2"]);
    expect(seamTracksToAdopt("webaudio-track", ["t1"], new Set(["t1"]))).toEqual([]);
  });
});

describe("seamTracksToAdopt with provenance", () => {
  const info = (origin: "local" | "remote", rootId: string, seq: number): TrackProvenanceInfo => ({
    origin,
    rootId,
    seq,
  });

  it("skips local-origin tracks: the 2026-08-05 call fixture", () => {
    // Six webaudio tracks: three clones of the local mic (self-audio the
    // daemon's mic source already records), one remote, two unknown. The
    // policy must adopt the remote and the unknowns and drop the mic copies —
    // the actual call adopted all six and quadruplicated every utterance.
    const provenance = new Map([
      ["t1", info("local", "mic-root", 1)],
      ["t2", info("local", "mic-root", 2)],
      ["t6", info("local", "mic-root", 3)],
      ["t3", info("remote", "t3", 4)],
    ]);
    expect(
      seamTracksToAdopt("webaudio-track", ["t1", "t2", "t3", "t4", "t5", "t6"], new Set(), provenance),
    ).toEqual(["t3", "t4", "t5"]);
  });

  it("adopts one track per lineage root — the earliest-registered clone", () => {
    const provenance = new Map([
      ["late", info("remote", "r", 9)],
      ["early", info("remote", "r", 2)],
    ]);
    expect(seamTracksToAdopt("webaudio-track", ["late", "early"], new Set(), provenance)).toEqual([
      "early",
    ]);
  });

  it("treats a root with an already-adopted member as settled", () => {
    // The adopted clone may have ended (gone from available) — its sibling
    // still carries the same audio and must not gain a second pipeline.
    const provenance = new Map([
      ["sibling", info("remote", "r", 5)],
      ["captured", info("remote", "r", 1)],
    ]);
    expect(
      seamTracksToAdopt("webaudio-track", ["sibling"], new Set(["captured"]), provenance),
    ).toEqual([]);
  });

  it("adopts unknown-origin tracks — dropping a real remote is data loss", () => {
    const provenance = new Map([["t1", info("local", "t1", 1)]]);
    expect(seamTracksToAdopt("webaudio-track", ["t1", "mystery"], new Set(), provenance)).toEqual([
      "mystery",
    ]);
  });

  it("keeps unknown ids as their own roots — two unknowns both adopt", () => {
    expect(seamTracksToAdopt("webaudio-track", ["u1", "u2"], new Set(), new Map())).toEqual([
      "u1",
      "u2",
    ]);
  });
});
