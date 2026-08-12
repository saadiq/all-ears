import { describe, expect, it, vi } from "vitest";
import {
  extractMeetingTitle,
  isMeetingCode,
  MeetMeetingTitleWatcher,
  type TitleDocumentLike,
} from "./meet-meeting-title";

// Hand-rolled fakes (no jsdom), matching meet-meeting-id.test.ts's convention.

function fakeDoc(title: string, headings: string[] = []): TitleDocumentLike {
  return {
    title,
    querySelectorAll: () => headings.map((text) => ({ textContent: text })),
  };
}

describe("isMeetingCode", () => {
  it("recognises Meet's xxx-yyyy-zzz code shape", () => {
    expect(isMeetingCode("abc-defg-hij")).toBe(true);
    expect(isMeetingCode("ABC-DEFG-HIJ")).toBe(true);
    expect(isMeetingCode("  abc-defg-hij  ")).toBe(true);
  });

  it("does not mistake a real meeting name for a code", () => {
    expect(isMeetingCode("Kevin Weekly")).toBe(false);
    expect(isMeetingCode("abc-defg")).toBe(false);
    expect(isMeetingCode("abcd-defg-hij")).toBe(false);
    expect(isMeetingCode("")).toBe(false);
  });
});

describe("extractMeetingTitle", () => {
  it("reads a calendar meeting's name out of the document title", () => {
    expect(extractMeetingTitle(fakeDoc("Meet – Kevin Weekly"))).toBe("Kevin Weekly");
    expect(extractMeetingTitle(fakeDoc("Meet - Kevin Weekly"))).toBe("Kevin Weekly");
    expect(extractMeetingTitle(fakeDoc("Kevin Weekly - Google Meet"))).toBe("Kevin Weekly");
  });

  it("treats a meeting-code-shaped title as no name found", () => {
    expect(extractMeetingTitle(fakeDoc("Meet – abc-defg-hij"))).toBeNull();
    expect(extractMeetingTitle(fakeDoc("abc-defg-hij - Google Meet"))).toBeNull();
  });

  it("returns null for the bare product name and an empty title", () => {
    expect(extractMeetingTitle(fakeDoc("Meet"))).toBeNull();
    expect(extractMeetingTitle(fakeDoc("Google Meet"))).toBeNull();
    expect(extractMeetingTitle(fakeDoc(""))).toBeNull();
    expect(extractMeetingTitle(fakeDoc("   "))).toBeNull();
  });

  it("ignores the notification-count prefix Meet adds to the tab title", () => {
    expect(extractMeetingTitle(fakeDoc("(3) Meet – Kevin Weekly"))).toBe("Kevin Weekly");
  });

  it("falls back to the in-call details heading when the title carries no name", () => {
    expect(extractMeetingTitle(fakeDoc("Meet – abc-defg-hij", ["Kevin Weekly"]))).toBe(
      "Kevin Weekly",
    );
  });

  it("ignores a heading that is itself just the meeting code", () => {
    expect(extractMeetingTitle(fakeDoc("Meet", ["abc-defg-hij"]))).toBeNull();
  });
});

describe("MeetMeetingTitleWatcher", () => {
  it("reports the first resolved name exactly once", () => {
    const onResolved = vi.fn();
    const watcher = new MeetMeetingTitleWatcher(onResolved);

    watcher.poll(fakeDoc("Meet – abc-defg-hij"));
    expect(onResolved).not.toHaveBeenCalled();
    expect(watcher.title).toBeNull();

    watcher.poll(fakeDoc("Meet – Kevin Weekly"));
    expect(onResolved).toHaveBeenCalledExactlyOnceWith("Kevin Weekly");
    expect(watcher.title).toBe("Kevin Weekly");

    // A later poll — even one showing a different name — never fires again:
    // one rename per discovered name, and the first name is the one that
    // reached the daemon.
    watcher.poll(fakeDoc("Meet – Something Else"));
    expect(onResolved).toHaveBeenCalledTimes(1);
  });
});
