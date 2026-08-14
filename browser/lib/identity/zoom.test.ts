import { describe, expect, it } from "vitest";
import { parseZoomMeetingId, parseZoomParticipantId } from "./zoom";

describe("parseZoomMeetingId", () => {
  it("reads the id from the web-client path", () => {
    // The shape observed live on app.zoom.us (journal #151).
    expect(parseZoomMeetingId("/wc/87973734905/join")).toBe("87973734905");
  });

  it("reads the /wc/join/<id> entry-flow shape", () => {
    expect(parseZoomMeetingId("/wc/join/87973734905")).toBe("87973734905");
  });

  it("accepts other web-client sub-paths", () => {
    expect(parseZoomMeetingId("/wc/87973734905/start")).toBe("87973734905");
  });

  it("ignores the /j/ landing page, which never hosts a call", () => {
    // Declaring here would start a session for a meeting nobody joined.
    expect(parseZoomMeetingId("/j/87973734905")).toBeNull();
  });

  it("ignores non-meeting paths", () => {
    expect(parseZoomMeetingId("/")).toBeNull();
    expect(parseZoomMeetingId("/profile")).toBeNull();
    expect(parseZoomMeetingId("/wc/join")).toBeNull();
  });

  it("returns null on empty/nullish input", () => {
    expect(parseZoomMeetingId("")).toBeNull();
    expect(parseZoomMeetingId(null)).toBeNull();
    expect(parseZoomMeetingId(undefined)).toBeNull();
  });
});

describe("parseZoomParticipantId", () => {
  it("masks the low 10 bits to a stable participant node", () => {
    // 16781312 = 0x1002000; low 10 bits cleared → 16781312 already aligned.
    // Use a value with dirty low bits: 16781312 + 500 → same participant.
    const base = 16781312;
    expect(parseZoomParticipantId(`${base + 500}+CS+audio`)).toBe(`zoom-${base}`);
    expect(parseZoomParticipantId(`${base + 1023}+CS+audio`)).toBe(`zoom-${base}`);
    expect(parseZoomParticipantId(`${base}+CS+audio`)).toBe(`zoom-${base}`);
  });

  it("is stable across streams from the same participant (mute/re-subscribe)", () => {
    const a = parseZoomParticipantId("16781312+CS+a");
    const b = parseZoomParticipantId("16781700+CS+b"); // same top bits, different low
    expect(a).toBe(b);
  });

  it("distinguishes different participants", () => {
    const a = parseZoomParticipantId("16781312+CS+x");
    const b = parseZoomParticipantId("16782336+CS+x"); // +1024 → next node
    expect(a).not.toBe(b);
  });

  it("requires the +CS+ marker", () => {
    expect(parseZoomParticipantId("16781312+audio")).toBeNull();
    expect(parseZoomParticipantId("16781312")).toBeNull();
  });

  it("requires leading digits before +", () => {
    expect(parseZoomParticipantId("abc+CS+audio")).toBeNull();
    expect(parseZoomParticipantId("+CS+audio")).toBeNull();
  });

  it("decodes percent-encoded stream ids", () => {
    // "16781312+CS+a" with the + encoded as %2B.
    expect(parseZoomParticipantId("16781312%2BCS%2Ba")).toBe("zoom-16781312");
  });

  it("returns null on empty/nullish input", () => {
    expect(parseZoomParticipantId("")).toBeNull();
    expect(parseZoomParticipantId(null)).toBeNull();
    expect(parseZoomParticipantId(undefined)).toBeNull();
  });
});
