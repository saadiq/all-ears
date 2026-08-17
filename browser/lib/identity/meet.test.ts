import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  MeetAdapter,
  SELF_MARKER,
  findLocalDeviceId,
  findLocalDeviceIdByTileIcons,
  resolveLocalDeviceId,
  PARTICIPANT_ID_ATTRIBUTES,
  extractDisplayName,
  extractParticipantId,
  findMediaElementForTrack,
  findParticipantTile,
  type DocumentLike,
  type MediaElementLike,
} from "./meet";
import { CONFIRM_THRESHOLD } from "./meet-identity-engine";

// Hand-rolled fake DOM (repo prefers small fakes over jsdom — see
// rtc-hook.test.ts; vitest runs in the node environment). Implements exactly
// the structural slice the helpers use: getAttribute, parentElement,
// textContent, and querySelector limited to the "[attr],[attr]" selector
// shape meet.ts passes.

interface FakeElInit {
  attrs?: Record<string, string>;
  text?: string;
  children?: FakeEl[];
  srcObject?: unknown;
  tag?: string;
  classes?: string[];
}

// Fake querySelector supports exactly the two selector shapes meet.ts uses:
// "[attr]" (attribute presence, comma-separated) and "tag.class".
interface SelectorPattern {
  attr?: string;
  tag?: string;
  cls?: string;
}

function parseFakeSelector(selector: string): SelectorPattern {
  const attrMatch = selector.match(/^\[([^\]]+)\]$/);
  if (attrMatch) return { attr: attrMatch[1]! };
  const tagClassMatch = selector.match(/^([a-zA-Z]+)\.([\w-]+)$/);
  if (tagClassMatch) return { tag: tagClassMatch[1]!.toUpperCase(), cls: tagClassMatch[2]! };
  const tagOnlyMatch = selector.match(/^([a-zA-Z]+)$/);
  if (tagOnlyMatch) return { tag: tagOnlyMatch[1]!.toUpperCase() };
  throw new Error(`unsupported fake selector: ${selector}`);
}

class FakeEl implements MediaElementLike {
  parentElement: FakeEl | null = null;
  textContent: string | null;
  srcObject?: unknown;
  readonly tag: string;
  private readonly attrs: Map<string, string>;
  private readonly children: FakeEl[];
  private readonly classes: Set<string>;

  constructor(init: FakeElInit = {}) {
    this.attrs = new Map(Object.entries(init.attrs ?? {}));
    this.textContent = init.text ?? null;
    this.children = init.children ?? [];
    this.tag = (init.tag ?? "DIV").toUpperCase();
    this.classes = new Set(init.classes ?? []);
    for (const child of this.children) child.parentElement = this;
    if ("srcObject" in init) this.srcObject = init.srcObject;
  }

  getAttribute(name: string): string | null {
    if (name === "class") return this.classes.size ? [...this.classes].join(" ") : null;
    return this.attrs.get(name) ?? null;
  }

  private matches(pattern: SelectorPattern): boolean {
    if (pattern.attr) return this.getAttribute(pattern.attr) !== null;
    if (pattern.tag && this.tag !== pattern.tag) return false;
    if (pattern.cls && !this.classes.has(pattern.cls)) return false;
    return true;
  }

  querySelector(selectors: string): FakeEl | null {
    const patterns = selectors.split(",").map((s) => parseFakeSelector(s.trim()));
    const walk = (el: FakeEl): FakeEl | null => {
      for (const child of el.children) {
        if (patterns.some((p) => child.matches(p))) return child;
        const hit = walk(child);
        if (hit) return hit;
      }
      return null;
    };
    return walk(this);
  }

  querySelectorAll(selectors: string): FakeEl[] {
    const patterns = selectors.split(",").map((s) => parseFakeSelector(s.trim()));
    const out: FakeEl[] = [];
    const walk = (el: FakeEl): void => {
      for (const child of el.children) {
        if (patterns.some((p) => child.matches(p))) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }
}

function fakeDoc(mediaEls: FakeEl[]): DocumentLike {
  return {
    querySelectorAll: (sel) => (sel === "audio, video" ? mediaEls : []),
    querySelector: () => null,
  };
}

const fakeTrack = (id: string) => ({ id });
const fakeStream = (id: string, tracks: { id: string }[]) => ({ id, getTracks: () => tracks });

describe("extractParticipantId", () => {
  it("reads each candidate attribute", () => {
    for (const attr of PARTICIPANT_ID_ATTRIBUTES) {
      const tile = new FakeEl({ attrs: { [attr]: "spaces/abc/devices/7" } });
      expect(extractParticipantId(tile)).toBe("spaces/abc/devices/7");
    }
  });

  it("trims whitespace and treats blank values as missing", () => {
    expect(extractParticipantId(new FakeEl({ attrs: { "data-participant-id": "  spaces/x  " } }))).toBe("spaces/x");
    expect(extractParticipantId(new FakeEl({ attrs: { "data-participant-id": "   " } }))).toBeNull();
  });

  it("returns null when no candidate attribute is present", () => {
    expect(extractParticipantId(new FakeEl({ attrs: { "data-something-else": "x" } }))).toBeNull();
  });
});

describe("findParticipantTile", () => {
  it("returns the element itself when it carries the id", () => {
    const tile = new FakeEl({ attrs: { "data-participant-id": "spaces/a" } });
    expect(findParticipantTile(tile)).toBe(tile);
  });

  it("climbs ancestors to the nearest tile", () => {
    const media = new FakeEl();
    const wrapper = new FakeEl({ children: [media] });
    const tile = new FakeEl({ attrs: { "data-requested-participant-id": "spaces/b" }, children: [wrapper] });
    new FakeEl({ children: [tile] }); // grid container above the tile
    expect(findParticipantTile(media)).toBe(tile);
  });

  it("returns null when no ancestor carries an id", () => {
    const media = new FakeEl();
    new FakeEl({ children: [media] });
    expect(findParticipantTile(media)).toBeNull();
  });
});

describe("extractDisplayName", () => {
  it("prefers the tile's own data-self-name", () => {
    const tile = new FakeEl({
      attrs: { "data-self-name": "Ada Lovelace", "aria-label": "Pin Ada Lovelace" },
      children: [new FakeEl({ attrs: { "data-self-name": "Nested" } })],
    });
    expect(extractDisplayName(tile)).toBe("Ada Lovelace");
  });

  it("falls back to a descendant's data-self-name attribute", () => {
    const tile = new FakeEl({
      children: [new FakeEl({ children: [new FakeEl({ attrs: { "data-self-name": "Grace Hopper" } })] })],
    });
    expect(extractDisplayName(tile)).toBe("Grace Hopper");
  });

  it("uses the descendant's text when its attribute is blank", () => {
    const tile = new FakeEl({
      children: [new FakeEl({ attrs: { "data-self-name": "  " }, text: " Katherine Johnson " })],
    });
    expect(extractDisplayName(tile)).toBe("Katherine Johnson");
  });

  it("falls back to a descendant span.notranslate (journal #41 live shape)", () => {
    // Real Meet markup: the name lives in a tag-qualified span.notranslate
    // (Google's do-not-translate marker), not data-self-name/aria-label —
    // neither of which is present on the current build.
    const tile = new FakeEl({
      children: [new FakeEl({ tag: "span", classes: ["notranslate"], text: "Tom Elliot" })],
    });
    expect(extractDisplayName(tile)).toBe("Tom Elliot");
  });

  it("ignores non-span notranslate elements (material-icon ligatures also carry the class)", () => {
    const tile = new FakeEl({
      children: [
        new FakeEl({ tag: "i", classes: ["notranslate"], text: "keep_outline" }),
        new FakeEl({ tag: "span", classes: ["notranslate"], text: "Grace Hopper" }),
      ],
    });
    expect(extractDisplayName(tile)).toBe("Grace Hopper");
  });

  it("skips an icon-wrapping span.notranslate and takes the real name", () => {
    // Confirmed live: a non-name tile's span.notranslate wraps a material <i>
    // whose ligature text ("devices") bubbles up as the span's textContent; the
    // span's own class carries no material marker. Order-agnostic: the icon span
    // precedes the name span here.
    const iconSpan = new FakeEl({
      tag: "span",
      classes: ["notranslate", "VfPpkd-kBDsod"],
      text: "devices",
      children: [new FakeEl({ tag: "i", classes: ["google-material-icons"], text: "devices" })],
    });
    const tile = new FakeEl({
      children: [iconSpan, new FakeEl({ tag: "span", classes: ["notranslate"], text: "Grace Hopper" })],
    });
    expect(extractDisplayName(tile)).toBe("Grace Hopper");
  });

  it("returns undefined when the only span.notranslate wraps an icon ligature", () => {
    const tile = new FakeEl({
      children: [
        new FakeEl({
          tag: "span",
          classes: ["notranslate"],
          text: "mic",
          children: [new FakeEl({ tag: "i", classes: ["google-material-icons"], text: "mic" })],
        }),
      ],
    });
    expect(extractDisplayName(tile)).toBeUndefined();
  });

  it("prefers data-self-name over span.notranslate when both are present", () => {
    const tile = new FakeEl({
      attrs: { "data-self-name": "Ada Lovelace" },
      children: [new FakeEl({ tag: "span", classes: ["notranslate"], text: "Someone Else" })],
    });
    expect(extractDisplayName(tile)).toBe("Ada Lovelace");
  });

  it("falls back to the tile's aria-label", () => {
    const tile = new FakeEl({ attrs: { "aria-label": "Alan Turing" } });
    expect(extractDisplayName(tile)).toBe("Alan Turing");
  });

  it("returns undefined when nothing name-shaped exists", () => {
    expect(extractDisplayName(new FakeEl())).toBeUndefined();
  });
});

describe("findMediaElementForTrack", () => {
  it("matches an element whose srcObject contains the exact track object", () => {
    const track = fakeTrack("t1");
    const el = new FakeEl({ srcObject: fakeStream("s1", [track]) });
    const doc = fakeDoc([new FakeEl(), el]);
    expect(findMediaElementForTrack(doc, track, null)).toBe(el);
  });

  it("matches by track id when the objects differ", () => {
    const el = new FakeEl({ srcObject: fakeStream("s1", [fakeTrack("t1")]) });
    expect(findMediaElementForTrack(fakeDoc([el]), fakeTrack("t1"), null)).toBe(el);
  });

  it("prefers a track match over an earlier stream-id match", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("msid-1", [track]);
    // Tile <video> holding a different stream with the same msid comes first
    // in DOM order; the element actually holding the track must still win.
    const videoEl = new FakeEl({ srcObject: fakeStream("msid-1", [fakeTrack("v1")]) });
    const audioEl = new FakeEl({ srcObject: fakeStream("other", [track]) });
    expect(findMediaElementForTrack(fakeDoc([videoEl, audioEl]), track, stream)).toBe(audioEl);
  });

  it("falls back to the element rendering the same MediaStream object", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("msid-1", [track]);
    const el = new FakeEl({ srcObject: stream });
    // The element's stream doesn't list our track (Meet's WASM decode path) —
    // shared stream identity still correlates.
    stream.getTracks = () => [fakeTrack("v1")];
    expect(findMediaElementForTrack(fakeDoc([el]), track, stream)).toBe(el);
  });

  it("falls back to a same-id MediaStream (tile <video> sharing the msid)", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("msid-1", [track]);
    const videoEl = new FakeEl({ srcObject: fakeStream("msid-1", [fakeTrack("v1")]) });
    expect(findMediaElementForTrack(fakeDoc([videoEl]), track, stream)).toBe(videoEl);
  });

  it("never stream-id-matches on an empty id", () => {
    const track = fakeTrack("t1");
    const stream = fakeStream("", [track]);
    const el = new FakeEl({ srcObject: fakeStream("", [fakeTrack("v1")]) });
    expect(findMediaElementForTrack(fakeDoc([el]), track, stream)).toBeNull();
  });

  it("ignores elements without a MediaStream-shaped srcObject", () => {
    const track = fakeTrack("t1");
    const doc = fakeDoc([
      new FakeEl(), // no srcObject at all
      new FakeEl({ srcObject: null }),
      new FakeEl({ srcObject: "not-a-stream" }),
      new FakeEl({ srcObject: { id: "s", getTracks: "nope" } }),
    ]);
    expect(findMediaElementForTrack(doc, track, fakeStream("s1", [track]))).toBeNull();
  });

  it("returns null when nothing matches", () => {
    const el = new FakeEl({ srcObject: fakeStream("s9", [fakeTrack("t9")]) });
    expect(findMediaElementForTrack(fakeDoc([el]), fakeTrack("t1"), fakeStream("s1", []))).toBeNull();
  });

  it("correlates end to end through the tile (pure parts): media element → tile id + name", () => {
    const track = fakeTrack("t1");
    const media = new FakeEl({ srcObject: fakeStream("s1", [track]) });
    const tile = new FakeEl({
      attrs: { "data-participant-id": "spaces/abc/devices/7" },
      children: [new FakeEl({ children: [media] }), new FakeEl({ attrs: { "data-self-name": "Ada" } })],
    });
    new FakeEl({ children: [tile] });

    const found = findMediaElementForTrack(fakeDoc([media]), track, null);
    expect(found).toBe(media);
    const foundTile = findParticipantTile(found as FakeEl);
    expect(foundTile).toBe(tile);
    expect(extractParticipantId(foundTile as FakeEl)).toBe("spaces/abc/devices/7");
    expect(extractDisplayName(foundTile as FakeEl)).toBe("Ada");
  });
});

// ── Track ↔ device binding (journal #158) ───────────────────────────────────
//
// The binding rules themselves live in MeetIdentityEngine and are tested
// exhaustively in meet-identity-engine.test.ts. These tests drive the same
// behaviours through the adapter shell — real entry points, real track
// objects — so the shell→engine wiring (observation forwarding, TrackPresence,
// callback translation) stays covered end to end. MeetAdapter reaches `window`
// only in its constructor (setCollectionsListener); onTrackSpeaking/
// onDeviceSpeaking touch no DOM at all, so a bare window stub is enough.

class FakeTrack {
  constructor(
    readonly id: string,
    public readyState: "live" | "ended" = "live",
  ) {}
}

describe("MeetAdapter track ↔ device binding", () => {
  let clock = 0;

  /** One clean turn: the track's audio onset, then that device's ring burst
   * 50ms later. Turns are 5s apart — clear of the 1s onset debounce and of the
   * 3s history that holds consumed pairings. Timestamps are plain arguments —
   * the adapter's entry points take the caller's clock, no timers to fake. */
  function turn(adapter: MeetAdapter, track: FakeTrack, deviceId: string): void {
    clock += 5000;
    adapter.onTrackSpeaking(track as unknown as MediaStreamTrack, true, clock);
    adapter.onDeviceSpeaking(deviceId, clock + 50);
  }

  function confirm(adapter: MeetAdapter, track: FakeTrack, deviceId: string): void {
    for (let i = 0; i < CONFIRM_THRESHOLD; i++) turn(adapter, track, deviceId);
  }

  function newAdapter(): { adapter: MeetAdapter; joins: Array<[string, string]> } {
    const adapter = new MeetAdapter();
    const joins: Array<[string, string]> = [];
    adapter.onIdentity((trackId, id) => joins.push([trackId, id]));
    return { adapter, joins };
  }

  beforeEach(() => {
    clock = 100_000;
    (globalThis as { window?: unknown }).window ??= {};
  });

  it("refuses to rebind a track that already carries a device (the 86-generation flip-flop)", () => {
    const { adapter, joins } = newAdapter();
    const remote = new FakeTrack("track-remote");

    confirm(adapter, remote, "devices/160");
    // The local participant's device then confirms against the same remote
    // track — the live failure, once its ring bursts stopped colliding.
    confirm(adapter, remote, "devices/159");

    expect(joins).toEqual([["track-remote", "devices/160"]]);
  });

  it("lets a fresh track claim a device whose previous track has ended (a rejoin)", () => {
    const { adapter, joins } = newAdapter();
    const first = new FakeTrack("track-a");

    confirm(adapter, first, "devices/160");
    first.readyState = "ended";
    confirm(adapter, new FakeTrack("track-a2"), "devices/160");

    expect(joins).toEqual([
      ["track-a", "devices/160"],
      ["track-a2", "devices/160"],
    ]);
  });
});

// ── Local-participant detection (journal #164, #167, #169) ──────────────────

describe("findLocalDeviceId", () => {
  const tile = (id: string, text: string) =>
    new FakeEl({ attrs: { "data-participant-id": id }, text });

  // fakeDoc above only answers the "audio, video" selector; the tile scan uses
  // the participant-id selector, so it needs its own document fake.
  const fakeTileDoc = (tiles: FakeEl[]): DocumentLike => ({
    querySelectorAll: (sel) => (sel.includes("data-participant-id") ? tiles : []),
    querySelector: () => null,
  });

  it("returns the device id of the tile carrying the (You) marker", () => {
    const doc = fakeTileDoc([
      tile("spaces/s/devices/108", "Priya Raman"),
      tile("spaces/s/devices/107", "Tom Elliot (You)"),
    ]);
    expect(findLocalDeviceId(doc)).toBe("spaces/s/devices/107");
  });

  it("matches the live shape: two elements per device, only the panel row marked", () => {
    // Meet renders a video tile and a People row per participant; only the row
    // carries the marker, and both carry the same data-participant-id.
    const doc = fakeTileDoc([
      tile("spaces/s/devices/108", "Priya Raman"),
      tile("spaces/s/devices/107", "Tom Elliot"),
      tile("spaces/s/devices/107", "Tom Elliot (You)"),
      tile("spaces/s/devices/108", "Priya Raman"),
    ]);
    expect(findLocalDeviceId(doc)).toBe("spaces/s/devices/107");
  });

  it("returns undefined when no tile is marked (a non-English UI)", () => {
    const doc = fakeTileDoc([tile("spaces/s/devices/108", "Priya Raman"), tile("spaces/s/devices/107", "Tom Elliot")]);
    expect(findLocalDeviceId(doc)).toBeUndefined();
  });

  it("returns undefined when two devices are marked — ambiguous beats wrong", () => {
    const doc = fakeTileDoc([
      tile("spaces/s/devices/107", "Tom Elliot (You)"),
      tile("spaces/s/devices/108", "A Trickster (you)"),
    ]);
    expect(findLocalDeviceId(doc)).toBeUndefined();
  });

  it("does not match a name that merely starts with 'you'", () => {
    expect(SELF_MARKER.test("Youssef Haddad")).toBe(false);
    const doc = fakeTileDoc([tile("spaces/s/devices/107", "Youssef Haddad")]);
    expect(findLocalDeviceId(doc)).toBeUndefined();
  });

  it("tolerates spacing variations Meet might render", () => {
    expect(SELF_MARKER.test("Tom Elliot ( You )")).toBe(true);
    expect(SELF_MARKER.test("Tom Elliot (you)")).toBe(true);
  });

  it("returns undefined for a document with no tiles at all", () => {
    expect(findLocalDeviceId(fakeTileDoc([]))).toBeUndefined();
  });
});

describe("findLocalDeviceIdByTileIcons / resolveLocalDeviceId (journal #178)", () => {
  const icon = (name: string) => new FakeEl({ tag: "i", text: name });
  const tile = (id: string, text: string, icons: FakeEl[] = []) =>
    new FakeEl({ attrs: { "data-participant-id": id }, text, children: icons });
  const fakeTileDoc = (tiles: FakeEl[]): DocumentLike => ({
    querySelectorAll: (sel) => (sel.includes("data-participant-id") ? tiles : []),
    querySelector: () => null,
  });

  it("returns the device whose tile carries a self-only control icon, even under identical display names", () => {
    // The live validation call: two devices, one shared display name — every
    // name-based rule is blind here; only the self-tile controls distinguish.
    const doc = fakeTileDoc([
      tile("spaces/s/devices/105", "Tom Elliot", [icon("devices")]),
      tile("spaces/s/devices/104", "Tom Elliot", [icon("frame_person"), icon("visual_effects"), icon("more_vert")]),
    ]);
    expect(findLocalDeviceIdByTileIcons(doc)).toBe("spaces/s/devices/104");
  });

  it("ignores icon ligatures that are not self-only controls", () => {
    const doc = fakeTileDoc([tile("spaces/s/devices/105", "Priya Raman", [icon("devices"), icon("more_vert")])]);
    expect(findLocalDeviceIdByTileIcons(doc)).toBeUndefined();
  });

  it("fail-closed when two devices carry self icons — ambiguous beats wrong", () => {
    const doc = fakeTileDoc([
      tile("spaces/s/devices/104", "Tom Elliot", [icon("frame_person")]),
      tile("spaces/s/devices/105", "A Trickster", [icon("visual_effects")]),
    ]);
    expect(findLocalDeviceIdByTileIcons(doc)).toBeUndefined();
  });

  it("resolveLocalDeviceId: icons alone suffice when the People panel was never opened (journal #176)", () => {
    // No listitem exists, so no "(You)" text anywhere — the failure mode of
    // the first live call. The grid tile's controls still answer.
    const doc = fakeTileDoc([
      tile("spaces/s/devices/105", "Priya Raman"),
      tile("spaces/s/devices/104", "Tom Elliot", [icon("frame_person")]),
    ]);
    expect(findLocalDeviceId(doc)).toBeUndefined();
    expect(resolveLocalDeviceId(doc)).toBe("spaces/s/devices/104");
  });

  it("resolveLocalDeviceId: the marker alone still suffices", () => {
    const doc = fakeTileDoc([
      tile("spaces/s/devices/105", "Priya Raman"),
      tile("spaces/s/devices/104", "Tom Elliot (You)"),
    ]);
    expect(resolveLocalDeviceId(doc)).toBe("spaces/s/devices/104");
  });

  it("resolveLocalDeviceId: disagreeing signals trust neither", () => {
    const doc = fakeTileDoc([
      tile("spaces/s/devices/105", "Priya Raman (You)"),
      tile("spaces/s/devices/104", "Tom Elliot", [icon("visual_effects")]),
    ]);
    expect(resolveLocalDeviceId(doc)).toBeUndefined();
  });
});

describe("MeetAdapter local-participant exclusion", () => {
  let clock = 0;

  const tileEl = (id: string, text: string) =>
    new FakeEl({ attrs: { "data-participant-id": id }, text });

  function stubDocument(tiles: FakeEl[]): void {
    (globalThis as { document?: unknown }).document = {
      querySelectorAll: (sel: string) => (sel.includes("data-participant-id") ? tiles : []),
      querySelector: () => null,
      body: null,
      documentElement: null,
    };
  }

  function turn(adapter: MeetAdapter, track: { id: string }, deviceId: string): void {
    clock += 5000;
    adapter.onTrackSpeaking(track as unknown as MediaStreamTrack, true, clock);
    adapter.onDeviceSpeaking(deviceId, clock + 50);
  }

  beforeEach(() => {
    clock = 100_000;
    (globalThis as { window?: unknown }).window ??= {};
  });

  afterEach(() => {
    delete (globalThis as { document?: unknown }).document;
  });

  it("never binds a remote track to the local device, however many turns confirm", () => {
    // The journal #172 failure: the user backchannels over the remote's turn,
    // their ring burst lands in the remote track's window, and the pairing
    // confirms — titling the remote's whole call with the local user's name.
    stubDocument([
      tileEl("devices/107", "Tom Elliot (You)"),
      tileEl("devices/108", "Priya Raman"),
    ]);
    const adapter = new MeetAdapter();
    const joins: Array<[string, string]> = [];
    adapter.onIdentity((trackId, id) => joins.push([trackId, id]));
    adapter.pollIdentities(); // roster scan latches the local device

    for (let i = 0; i < 6; i++) turn(adapter, { id: "track-remote" }, "devices/107");

    expect(joins).toEqual([]);
  });

  it("still binds the REMOTE device on the same track", () => {
    stubDocument([
      tileEl("devices/107", "Tom Elliot (You)"),
      tileEl("devices/108", "Priya Raman"),
    ]);
    const adapter = new MeetAdapter();
    const joins: Array<[string, string]> = [];
    adapter.onIdentity((trackId, id) => joins.push([trackId, id]));
    adapter.pollIdentities();

    for (let i = 0; i < CONFIRM_THRESHOLD; i++) turn(adapter, { id: "track-remote" }, "devices/108");

    expect(joins).toEqual([["track-remote", "devices/108"]]);
  });

  it("excludes nobody when the marker is absent — degrades to pre-fix behaviour, not to silence", () => {
    // A non-English UI: no marker anywhere. Identity must still work; it is only
    // the self-exclusion guarantee that is lost.
    stubDocument([tileEl("devices/107", "Tom Elliot"), tileEl("devices/108", "Priya Raman")]);
    const adapter = new MeetAdapter();
    const joins: Array<[string, string]> = [];
    adapter.onIdentity((trackId, id) => joins.push([trackId, id]));
    adapter.pollIdentities();

    for (let i = 0; i < CONFIRM_THRESHOLD; i++) turn(adapter, { id: "track-remote" }, "devices/108");

    expect(joins).toEqual([["track-remote", "devices/108"]]);
  });

  it("ignores the local device's collections mic-open edge too", () => {
    stubDocument([tileEl("devices/107", "Tom Elliot (You)")]);
    const adapter = new MeetAdapter();
    const joins: Array<[string, string]> = [];
    adapter.onIdentity((trackId, id) => joins.push([trackId, id]));
    adapter.pollIdentities();

    // Drive the unmute correlator: track unmute + the local device's mic-open.
    for (let i = 0; i < 6; i++) {
      clock += 5000;
      adapter.onTrackUnmute({ id: "track-remote" } as unknown as MediaStreamTrack, clock);
      (adapter as unknown as {
        onCollectionsEvent(e: { deviceId: string; micOpen: boolean }, at: number): void;
      }).onCollectionsEvent({ deviceId: "devices/107", micOpen: true }, clock);
    }

    expect(joins).toEqual([]);
  });
});
