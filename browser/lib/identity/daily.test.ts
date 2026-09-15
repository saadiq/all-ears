import { describe, expect, it } from "vitest";
import { DAILY_UNHOOKED_GRACE_MS, DailyAudioCheck, isDailyHost, parseDailyRoom } from "./daily";

describe("isDailyHost", () => {
  it("matches Daily subdomains only", () => {
    expect(isDailyHost("meetco.daily.co")).toBe(true);
    expect(isDailyHost("daily.co")).toBe(true);
    expect(isDailyHost("notdaily.co")).toBe(false);
    expect(isDailyHost("app.cal.com")).toBe(false);
  });
});

describe("parseDailyRoom", () => {
  it("reads subdomain and room from the call frame URL", () => {
    expect(parseDailyRoom("https://meetco.daily.co/AbC123xyz")).toBe("meetco/AbC123xyz");
  });

  it("never reads the token in query or hash", () => {
    expect(parseDailyRoom("https://meetco.daily.co/room-1?t=eyJhbGci#x")).toBe("meetco/room-1");
  });

  it("returns null for non-room pages", () => {
    expect(parseDailyRoom("https://meetco.daily.co/")).toBeNull();
    expect(parseDailyRoom("https://daily.co/room")).toBeNull();
    expect(parseDailyRoom("https://a.b.daily.co/room")).toBeNull();
    expect(parseDailyRoom("https://app.cal.com/video/room")).toBeNull();
    expect(parseDailyRoom("not a url")).toBeNull();
    expect(parseDailyRoom(undefined)).toBeNull();
  });
});

describe("DailyAudioCheck", () => {
  const snap = (hooked: string[], played: string[], pcs = 1) => ({
    peerConnections: pcs,
    hookedTrackIds: hooked,
    elementTrackIds: played,
  });

  it("logs a summary only when the snapshot changes", () => {
    const check = new DailyAudioCheck();
    expect(check.observe(snap([], []), 0).log).toBe("pcs=1 hooked=- played=-");
    expect(check.observe(snap([], []), 1000).log).toBeUndefined();
    expect(check.observe(snap(["88c71de4-aaaa"], ["88c71de4-aaaa"]), 2000).log).toBe(
      "pcs=1 hooked=88c71de4 played=88c71de4",
    );
  });

  it("stays quiet while every played track is hooked", () => {
    const check = new DailyAudioCheck();
    for (let t = 0; t <= 20_000; t += 1000) {
      expect(check.observe(snap(["a"], ["a"]), t).warn).toBeUndefined();
    }
  });

  it("warns once when a played track stays unhooked past the grace period", () => {
    const check = new DailyAudioCheck();
    expect(check.observe(snap([], ["track-x"]), 0).warn).toBeUndefined();
    expect(check.observe(snap([], ["track-x"]), DAILY_UNHOOKED_GRACE_MS - 1).warn).toBeUndefined();
    expect(check.observe(snap([], ["track-x"]), DAILY_UNHOOKED_GRACE_MS).warn).toContain("track-x");
    expect(check.observe(snap([], ["track-x"]), DAILY_UNHOOKED_GRACE_MS * 3).warn).toBeUndefined();
  });

  it("does not warn when the hook catches up within the grace period", () => {
    const check = new DailyAudioCheck();
    check.observe(snap([], ["b"]), 0);
    check.observe(snap(["b"], ["b"]), 2000);
    expect(check.observe(snap(["b"], ["b"]), DAILY_UNHOOKED_GRACE_MS * 2).warn).toBeUndefined();
  });
});
