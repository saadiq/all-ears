import { beforeEach, describe, expect, it } from "vitest";
import {
  KEEPALIVE_ALARM,
  KEEPALIVE_PERIOD_MINUTES,
  KEEPALIVE_STATE_KEY,
  KeepaliveTracker,
  parseKeepaliveState,
  type AlarmsLike,
  type StorageAreaLike,
} from "./keepalive";

// Plain-object fakes for the two browser APIs, same pattern as
// transport.test.ts's FakeWebSocket — no mocking library.

class FakeAlarms implements AlarmsLike {
  created: { name: string; periodInMinutes: number }[] = [];
  cleared: string[] = [];
  create(name: string, info: { periodInMinutes: number }): void {
    this.created.push({ name, periodInMinutes: info.periodInMinutes });
  }
  clear(name: string): void {
    this.cleared.push(name);
  }
}

// Fake of the chrome.storage.session area (the browser API).
class FakeStorageArea implements StorageAreaLike {
  store: Record<string, unknown> = {};
  async get(key: string): Promise<Record<string, unknown>> {
    return key in this.store ? { [key]: this.store[key] } : {};
  }
  async set(items: Record<string, unknown>): Promise<void> {
    Object.assign(this.store, items);
  }
  async remove(key: string): Promise<void> {
    delete this.store[key];
  }
}

describe("parseKeepaliveState", () => {
  it("reads back what activate persists", () => {
    expect(parseKeepaliveState({ active: true, platform: "meet" })).toEqual({
      active: true,
      platform: "meet",
    });
  });

  it("treats missing/malformed state as capture not live", () => {
    expect(parseKeepaliveState(undefined)).toEqual({ active: false });
    expect(parseKeepaliveState(null)).toEqual({ active: false });
    expect(parseKeepaliveState("yes")).toEqual({ active: false });
    expect(parseKeepaliveState({ active: "true" })).toEqual({ active: false });
  });

  it("drops an unknown platform but keeps the active flag", () => {
    expect(parseKeepaliveState({ active: true, platform: "skype" })).toEqual({ active: true });
  });
});

describe("KeepaliveTracker", () => {
  let alarms: FakeAlarms;
  let storage: FakeStorageArea;
  let tracker: KeepaliveTracker;

  beforeEach(() => {
    alarms = new FakeAlarms();
    storage = new FakeStorageArea();
    tracker = new KeepaliveTracker(alarms, storage);
  });

  it("arms the keepalive and persists state on the first participant only", async () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p1", "alice", "meet"); // repeat PCM frame
    tracker.participantActive("p1", "bob", "meet");
    await Promise.resolve(); // let the fire-and-forget storage write land

    expect(alarms.created).toEqual([{ name: KEEPALIVE_ALARM, periodInMinutes: KEEPALIVE_PERIOD_MINUTES }]);
    expect(storage.store[KEEPALIVE_STATE_KEY]).toEqual({ active: true, platform: "meet" });
  });

  it("disarms and clears state only when the LAST participant leaves", async () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p1", "bob", "meet");
    tracker.participantLeft("p1", "alice");
    expect(alarms.cleared).toEqual([]);

    tracker.participantLeft("p1", "bob");
    await Promise.resolve();
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
    expect(storage.store[KEEPALIVE_STATE_KEY]).toBeUndefined();
  });

  it("ignores a leave for a participant it never saw", () => {
    tracker.participantLeft("p1", "ghost");
    expect(alarms.cleared).toEqual([]);
  });

  it("counts participants across ports; one tab closing doesn't disarm the keepalive", () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p2", "zoom-guy", "zoom");

    const orphaned = tracker.portDisconnected("p2");
    expect(orphaned).toEqual(["zoom-guy"]);
    expect(alarms.cleared).toEqual([]); // alice's capture is still live
  });

  it("returns orphaned participants and disarms on the last port's disconnect", async () => {
    tracker.participantActive("p1", "alice", "meet");
    tracker.participantActive("p1", "bob", "meet");

    const orphaned = tracker.portDisconnected("p1");
    await Promise.resolve();
    expect(orphaned).toEqual(["alice", "bob"]);
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
    expect(storage.store[KEEPALIVE_STATE_KEY]).toBeUndefined();
  });

  it("disconnect of an unknown/empty port returns nothing and touches nothing", () => {
    expect(tracker.portDisconnected("never-seen")).toEqual([]);
    expect(alarms.cleared).toEqual([]);
  });

  it("restore() re-arms the keepalive after a worker respawn mid-capture", async () => {
    storage.store[KEEPALIVE_STATE_KEY] = { active: true, platform: "zoom" };
    await tracker.restore();
    expect(alarms.created).toEqual([{ name: KEEPALIVE_ALARM, periodInMinutes: KEEPALIVE_PERIOD_MINUTES }]);
  });

  it("restore() clears any stale alarm when capture was not live", async () => {
    await tracker.restore();
    expect(alarms.created).toEqual([]);
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
  });

  it("restore() survives a failing storage read (treats it as inactive)", async () => {
    const failing: StorageAreaLike = {
      get: () => Promise.reject(new Error("gone")),
      set: () => Promise.resolve(),
      remove: () => Promise.resolve(),
    };
    const t = new KeepaliveTracker(alarms, failing);
    await t.restore();
    expect(alarms.cleared).toEqual([KEEPALIVE_ALARM]);
  });
});
