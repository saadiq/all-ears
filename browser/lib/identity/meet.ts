import { registerAdapter, type PlatformAdapter } from "./adapter";
import { recordAttribution } from "../attribution-recorder";
import type { RosterEntry } from "../protocol";
import type { PlatformParticipantId } from "./adapter";
import { setCollectionsListener } from "../rtc-hook";
import type { CollectionsMuteEvent } from "./meet-collections";
import {
  MeetIdentityEngine,
  type MeetBindingDecision,
  type MeetIdentityDecision,
} from "./meet-identity-engine";

// Meet identity — Phase 4: tile-DOM correlation (identify(), synchronous),
// plus Phase 4 collections-datachannel upgrade (onIdentity(), asynchronous).
//
// identify() approach (specs/extension.md §Platform adapter): Meet renders a
// per-participant tile; identify() correlates the captured remote track to
// the tile's media element (srcObject match) and reads the participant id +
// display name off the tile's DOM. Everything is synchronous and best-effort
// by contract: any miss — tile not mounted yet, DOM shape changed, track not
// attached to any media element — returns null and the track's anonymous
// source handle carries the audio unnamed. Identity never blocks, throws
// into, or delays capture. The VERIFICATION STATUS section below records this
// path dead on the 2026-07-18 build; the 2026-08-05 probes found the tile id
// attributes BACK (see the addendum there), so identify() is opportunistic
// again — it may resolve, and the handle still carries every call where it
// doesn't.
//
// ── COLLECTIONS-DATACHANNEL UPGRADE (journal #49-#58) ───────────────────────
//
// identify()'s one-shot, synchronous contract can't express a correlation
// that only becomes confident after observing speaking activity (the
// collections datachannel gives a device id tied to "someone is speaking now",
// not to a specific MediaStreamTrack — see
// docs/specs/browser/extension.md (the collections exception)'s Task 2/3).
// So this doesn't change identify()'s behavior at all. Instead:
//
//   1. rtc-hook.ts's installMeetCollectionsTracer parses the "collections"
//      RTCDataChannel (meet-collections.ts) and forwards events here via
//      setCollectionsListener.
//   2. audio-tap.ts calls onTrackSpeaking(track, speaking) on every track's
//      audio-domain speaking edge (unconditionally, not debug-gated), and
//      onTrackUnmute(track) on every track's "unmute" event.
//   3. THREE SpeakingCorrelator instances (meet-correlator.ts, pure logic,
//      independently unit-tested; owned by MeetIdentityEngine, the pure
//      decision half this adapter feeds) pair device events against track
//      events:
//      - `correlator`: collections mic-open edge ↔ decoded-audio speaking
//        onset within ~200ms. This was the original design when the flag was
//        believed to be a per-turn speaking indicator; on the current build
//        the channel emits NO per-turn events (verified 2026-07-24,
//        dev/captures/2026-07-24-meet-collections-drift.md), so this pairing
//        can only fire in the join-unmuted case where the mic-open edge lands
//        with the first audio. Kept because it costs nothing and re-arms
//        automatically if a future build brings per-turn events back.
//      - `unmuteCorrelator`: collections mic-open edge ↔ the track-level
//        "unmute" event, within ~2s. This is the pairing the current build
//        actually supports: the controlled 2026-07-24 test showed the two
//        edges landing within the same second on every deliberate toggle.
//        One shot per participant per unmute, but reliable — anyone who joins
//        muted and unmutes to speak produces exactly this pair.
//      - `domCorrelator`: tile speaking-ring burst onset (meet-speaking-dom.ts,
//        via onDeviceSpeaking) ↔ decoded-audio speaking onset, within ~1s.
//        Added 2026-08-05: two instrumented live calls showed the ring is the
//        only per-turn per-device signal on current builds — Meet animates it
//        from its own audio-analyzer worklet per participant track — so this
//        pairing confirms on natural turn-taking, no mute toggle needed. The
//        window is wider than `correlator`'s because the ring rides Meet's
//        render pipeline (RAF batching, style flush) behind the audio domain.
//      All require CONFIRM_THRESHOLD (see its comment in
//      meet-identity-engine.ts) consecutive
//      confirming pairings — per correlator, never summed across them — before
//      being trusted.
//   4. Once confirmed, the identity is pushed via the onIdentity(cb) callback
//      registered by audio-tap.ts, which forwards it to the daemon as an
//      attendee upsert linking the track's source handle
//      (participant-identified). Nothing restarts: source ids are stable
//      per-track handles and never carry identity (R3).
//
// Degrades silently if the channel never appears or stops parsing (Meet
// changed the format) — the correlator just never confirms a match, and the
// track's source simply stays anonymous, exactly as it started.
// rtc-hook.ts warns once (not per-message) if messages arrive but stop
// parsing; see maybeWarnCollectionsSchema there.
//
// Investigated and rejected: bootstrapping identity at call start from the
// larger multi-device "roster" message collections also sends (containing
// each device id plus SSRC-shaped numbers, e.g. one entry per device with a
// paired-SSRC "FID" group) by matching those numbers against our own
// RTCPeerConnection's getStats() SSRCs, to skip waiting for anyone to speak.
// Live-tested (2026-07-19): none of the roster message's numeric fields
// appear anywhere in our own receivers' stats, across every report type
// (inbound-rtp, remote-outbound-rtp, transport, candidate-pair, etc) — Meet's
// SFU remaps SSRCs to small local sequential values (6666, 6667, ...) with no
// numeric relationship to whatever it reports internally, matching journal
// #43's original SSRC-correlation finding. There is no bootstrap shortcut;
// speaking-onset correlation is the only signal available.
//
// ── LIVE VERIFICATION STATUS (collections upgrade) ──────────────────────────
// Live-verified end to end (2026-07-19, journal #55-#58, real 3-participant
// Meet call): the production tracer parsed real traffic, the correlator
// accumulated and reported a correct match, and MeetAdapter pushed an
// identity upgrade that audio-tap.ts applied cleanly (via the pipeline
// restart of the day — R3 has since replaced that with the identity-link
// upsert) — confirmed correct for one participant end-to-end. That same session caught and fixed a real schema bug (the
// speaking-flag path was missing a nesting level; see meet-collections.ts's
// header comment). The second non-self participant's track died mid-test to
// the pre-existing, unrelated AudioDecoder bug (journal #45) before its
// upgrade could be observed — likely fine (its wire data looked identical in
// shape) but not itself confirmed. CONFIRM_THRESHOLD was 3 for this run and
// is now 1 (see that constant's comment) based on zero ambiguous matches
// observed across every turn in this session.
//
// ── VERIFICATION STATUS ──────────────────────────────────────────────────
// Live-verified 2026-07-18 (Chrome, meet.google.com, 3-account real call —
// journal #41–#46). Conclusion: identify() is expected to return null in
// practice on this Meet build. Every correlation mechanism investigated was
// confirmed dead, not just theoretically risky:
//
//   - Tile attributes/name: data-participant-id + data-requested-participant-id
//     both hold (spaces/<space>/devices/<device>-shaped, confirmed live —
//     PARTICIPANT_ID_ATTRIBUTES is correct as written). Display name does NOT
//     live in data-self-name or aria-label on this build (both empty/null on
//     every tile) — the real name text is a descendant `span.notranslate`
//     (journal #41), which extractDisplayName now also probes.
//   - Tile-media correlation (this file's primary path): zero <audio>/<video>
//     elements exist anywhere in the document, including shadow DOM (journal
//     #42) — findMediaElementForTrack() is structurally guaranteed to return
//     null, not just occasionally mismatched. Matches rtc-hook.ts's own note
//     that Meet decodes audio via createEncodedStreams() (journal #28–#31)
//     and never touches an HTMLMediaElement.
//   - CSRC fallback: getContributingSources() returns [] for every live
//     receiver (journal #43) — our own encoded-audio tee diverts frames
//     before the native stats pipeline that populates CSRC ever runs.
//   - SSRC correlation (tried live, not in the original spec): tile
//     data-ssrc and the audio receiver's inbound-rtp SSRC (via getStats())
//     are in disjoint numeric namespaces — no bridge there either (#43).
//   - Track/tile ordering heuristic (tried live at explicit request after the
//     above three failed): fails its own precondition. A fresh join fires
//     +track before tiles mount (identify()'s one-shot structural warning
//     fired at the literal instant of join, confirming zero tiles existed
//     yet), and a 3-person call produces 3 remote audio tracks against only 2
//     non-self tiles, reproduced on two separate meetings — there is no
//     stable 1:1 track↔tile correspondence to order against (journal #44).
//
// identify() keeps returning null by design; the anonymous track handle
// already handles this correctly and needs no change. Re-verify if
// a future Meet build changes any of the above (e.g. media elements return,
// or track/tile counts start matching) — see journal #41–#46 for full detail
// and #45 for an unrelated capture-pipeline bug (AudioDecoder errors) noticed
// during this pass.
//
// ── 2026-08-05 ADDENDUM: the tile-id path is back ───────────────────────────
// Two instrumented live calls found `data-participant-id` and
// `data-requested-participant-id` present again on tile roots, values
// `spaces/<space>/devices/<n>`-shaped and mapping cleanly to both call
// participants; the production roster path resolved names off those tiles the
// same day ("Meet roster resolved" debug-log lines). `data-initial-participant-
// id` is still gone (kept in PARTICIPANT_ID_ATTRIBUTES — costs nothing);
// a new opaque `data-tile-media-id` appeared (unused). `media.srcObject`
// assignments were also observed again on the same build, so
// findMediaElementForTrack() may resolve too. The attributes vanished once
// (July 24) and returned, so every consumer stays opportunistic — the
// speaker-<n> fallback remains fully intact. Also from those calls: tile
// `data-ssrc` does NOT join to the receiver's RTP source ids (SFU rewrites
// them; decisively probed during audible speech), and the speaking-ring DOM
// is the only per-turn per-device signal — see meet-speaking-dom.ts.
//
// The returned PlatformParticipantId is the raw tile attribute value (historically
// "spaces/<space>/devices/<device>"-shaped); protocol.ts's sanitizeLabel maps
// it into the earsd source label downstream. This code is left in place
// (rather than short-circuited to `return null`) because it's still correct
// against the DOM shape that does exist, and costs nothing to keep for
// re-verification against a future build.

/** Tile attributes probed for a stable participant id, strongest first. */
export const PARTICIPANT_ID_ATTRIBUTES = [
  "data-participant-id",
  "data-requested-participant-id",
  "data-initial-participant-id",
] as const;

const TILE_SELECTOR = PARTICIPANT_ID_ATTRIBUTES.map((a) => `[${a}]`).join(",");
const MEDIA_SELECTOR = "audio, video";

// Structural slices of the DOM/WebRTC surfaces the helpers touch — real
// Element/Document/MediaStream objects satisfy these, and meet.test.ts feeds
// hand-rolled fakes (this repo's preference over jsdom; vitest runs in the
// node environment).

export interface ElementLike {
  getAttribute(name: string): string | null;
  parentElement: ElementLike | null;
  querySelector?(selectors: string): ElementLike | null;
  querySelectorAll?(selectors: string): Iterable<ElementLike>;
  textContent?: string | null;
}

export interface MediaElementLike extends ElementLike {
  srcObject?: unknown;
}

export interface DocumentLike {
  querySelectorAll(selectors: string): Iterable<ElementLike>;
  querySelector(selectors: string): ElementLike | null;
}

interface TrackRef {
  readonly id: string;
}

interface StreamRef {
  readonly id: string;
  getTracks(): TrackRef[];
}

/** Read the tile's participant id, or null if it carries none. */
export function extractParticipantId(tile: ElementLike): string | null {
  for (const attr of PARTICIPANT_ID_ATTRIBUTES) {
    const value = tile.getAttribute(attr)?.trim();
    if (value) return value;
  }
  return null;
}

/**
 * Marks the local participant's own roster row. Meet appends "(You)" to your
 * own name in the People panel, and — live-verified 2026-08-12, journal
 * #164/#167/#169 — that is the ONLY self signal left on this build:
 * `data-self-name` is gone entirely (zero elements document-wide) and tile
 * `aria-label` never contains it.
 *
 * The marker lives on the panel row, not the video tile: Meet renders two
 * elements per device, and only the `role="listitem"` one carries it. Both
 * carry `[data-participant-id]`, so a tile-selector scan finds it either way.
 * Closing the People panel collapses that row to 0×0 but does NOT unmount it,
 * and the rows exist before the panel is ever opened, so this needs no UI
 * interaction and no panel visit.
 *
 * LOCALE-DEPENDENT by construction — it is English UI text. Journal #148 is
 * the precedent: Meet DOM automation broke silently under a non-`en` locale.
 * ``findLocalDeviceId`` therefore fails CLOSED, returning undefined rather than
 * guessing, and every caller treats undefined as "exclude nobody" — the
 * pre-#158 behaviour, which is wrong in a bounded way rather than newly broken.
 */
export const SELF_MARKER = /\(\s*you\s*\)/i;

/**
 * The local participant's device id, read from the "(You)" marker, or
 * undefined when it cannot be established beyond doubt.
 *
 * Requires exactly ONE device id to carry the marker. Zero means a build or
 * locale that does not render it; two or more means something ambiguous (a
 * nested container, or a participant whose display name literally contains
 * "(You)") and a wrong answer here is worse than none — excluding the wrong
 * device would silence a real participant's identity for the whole call.
 */
export function findLocalDeviceId(doc: DocumentLike): string | undefined {
  const marked = new Set<string>();
  for (const tile of doc.querySelectorAll(TILE_SELECTOR)) {
    const id = extractParticipantId(tile);
    if (!id) continue;
    if (SELF_MARKER.test(tile.textContent ?? "")) marked.add(id);
  }
  return marked.size === 1 ? [...marked][0] : undefined;
}

/** Climb from a media element to the nearest ancestor carrying a participant id. */
export function findParticipantTile(el: ElementLike): ElementLike | null {
  for (let node: ElementLike | null = el; node; node = node.parentElement) {
    if (extractParticipantId(node)) return node;
  }
  return null;
}

/**
 * Read the tile's display name: its own data-self-name, a descendant's
 * data-self-name (attribute value, else that element's text), a descendant
 * `span.notranslate` (the name-overlay element observed live — journal #41),
 * then the tile's aria-label. undefined when none — name is optional, id is
 * what matters.
 *
 * The `notranslate` class is not unique to the name overlay: Meet also renders
 * material icon ligatures under it. On the current build (confirmed live) the
 * same participant id is carried by several tiles, and a non-name tile's
 * `span.notranslate` *wraps* a material `<i>` whose ligature text bubbles up as
 * the icon name — e.g. "devices", "mic". The real name overlay is instead a
 * text-only leaf `<span class="notranslate">`. Tag-qualifying isn't enough, so
 * we walk every match and skip any icon-ligature span (see
 * ``isIconLigatureSpan``), taking the first real name.
 */
export function extractDisplayName(tile: ElementLike): string | undefined {
  const own = clean(tile.getAttribute("data-self-name"));
  if (own) return own;
  const nameEl = tile.querySelector?.("[data-self-name]");
  if (nameEl) {
    const fromAttr = clean(nameEl.getAttribute("data-self-name"));
    if (fromAttr) return fromAttr;
    const fromText = clean(nameEl.textContent);
    if (fromText) return fromText;
  }
  const spans = tile.querySelectorAll?.("span.notranslate") ?? [];
  for (const span of spans) {
    if (isIconLigatureSpan(span)) continue;
    const text = clean(span.textContent);
    if (text) return text;
  }
  return clean(tile.getAttribute("aria-label"));
}

/**
 * Whether a `span.notranslate` is a material icon ligature rather than a name
 * overlay. The name overlay is a text-only leaf; an icon overlay contains a
 * material `<i>` element whose ligature text (e.g. "devices") bubbles up as the
 * span's textContent — so the presence of a descendant `<i>` is the reliable
 * signal (confirmed live: the icon span's own class is `notranslate <obfusc>`,
 * carrying no material marker). The icon-font class check is a secondary guard
 * for builds that put the ligature directly on the span.
 */
function isIconLigatureSpan(el: ElementLike): boolean {
  if (el.querySelector?.("i")) return true;
  const cls = el.getAttribute("class") ?? "";
  return /material-(?:icons|symbols)|google-symbols|google-material-icons/i.test(cls);
}

function clean(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

/**
 * Find the media element rendering `track`. Strongest signal first: an element
 * whose srcObject contains the track itself (by identity, then id). Falls back
 * to an element rendering the same MediaStream — Meet bundles a participant's
 * audio+video under one msid, so the tile's <video> can share the audio
 * track's stream even when no per-tile <audio> exists (and even when Meet's
 * WASM decode path means the audio track itself never reaches an element).
 */
export function findMediaElementForTrack(
  doc: DocumentLike,
  track: TrackRef,
  stream: StreamRef | null,
): MediaElementLike | null {
  const els: MediaElementLike[] = [];
  for (const el of doc.querySelectorAll(MEDIA_SELECTOR)) els.push(el as MediaElementLike);

  for (const el of els) {
    const so = mediaStreamOf(el);
    if (so?.getTracks().some((t) => t === track || t.id === track.id)) return el;
  }
  if (stream) {
    for (const el of els) {
      const so = mediaStreamOf(el);
      if (so && (so === stream || (stream.id !== "" && so.id === stream.id))) return el;
    }
  }
  return null;
}

function mediaStreamOf(el: MediaElementLike): StreamRef | null {
  const so = el.srcObject as StreamRef | null | undefined;
  if (!so || typeof so.getTracks !== "function" || typeof so.id !== "string") return null;
  return so;
}

// Exported for meet.test.ts's binding tests only — production wiring goes
// through registerAdapter at the bottom of this file, never a direct import.
export class MeetAdapter implements PlatformAdapter {
  readonly platform = "meet" as const;

  private observer: MutationObserver | null = null;
  private tilesDirty = true;
  private warnedMissingIds = false;
  private disposed = false;

  // ── Collections-datachannel upgrade state (see file-header doc comment) ──
  /** The pure decision half: correlators, binding maps, and the latched local
   * device id all live there; this shell feeds it observations (each stamped
   * at the entry point) and translates its decisions into callbacks and
   * flight-recorder events. */
  private readonly engine = new MeetIdentityEngine({
    hasTrack: (trackId) => this.liveTracksById.has(trackId),
    isTrackLive: (trackId) => this.liveTracksById.get(trackId)?.readyState === "live",
  });
  /** track.id → live track — the backing store for the engine's
   * TrackPresence (is this device's owning track still live?). Populated from
   * both identify() and onTrackSpeaking(), whichever sees a track first;
   * never explicitly pruned (bounded by the small number of tracks live in a
   * call, and dispose() clears it). */
  private readonly liveTracksById = new Map<string, MediaStreamTrack>();
  private identityCb: ((trackId: string, id: PlatformParticipantId) => void) | null = null;
  private rosterCb: ((entries: RosterEntry[]) => void) | null = null;

  constructor() {
    // Latest-registration-wins, same handoff pattern as rtc-hook.ts's own
    // setTrackSink — each epoch's fresh MeetAdapter re-registers itself.
    setCollectionsListener((event) => this.onCollectionsEvent(event));
  }

  identify(track: MediaStreamTrack, stream: MediaStream): PlatformParticipantId | null {
    // Best-effort by contract: a broken or changed Meet DOM must degrade to
    // an anonymous source, never throw into the capture path.
    this.liveTracksById.set(track.id, track);
    try {
      return this.correlate(track, stream);
    } catch {
      return null;
    }
  }

  displayName(id: PlatformParticipantId): string | undefined {
    try {
      this.refreshNamesIfDirty();
    } catch {
      // stale cache is fine
    }
    return this.engine.displayName(id);
  }

  onIdentity(cb: (trackId: string, id: PlatformParticipantId) => void): void {
    this.identityCb = cb;
  }

  onRoster(cb: (entries: RosterEntry[]) => void): void {
    this.rosterCb = cb;
  }

  /**
   * Re-scan the participant tiles and emit any newly-resolved names via
   * onRoster. Called periodically by the capture reconciler so the roster is
   * harvested even for participants who never speak (the collections-datachannel
   * correlation only fires on speaking onsets, so a silent participant's name
   * would otherwise never reach the daemon — issue #23). Best-effort: a broken
   * DOM degrades to no roster, never throws into the capture path.
   */
  pollIdentities(at: number = Date.now()): void {
    if (this.disposed) return;
    try {
      this.tilesDirty = true; // force a re-scan even when no mutation fired since last poll
      this.refreshNamesIfDirty(at);
    } catch {
      // best-effort — identity harvesting must never affect capture
    }
  }

  /** audio-tap.ts calls this unconditionally on every track's audio-domain
   * speaking edge. Best-effort: never throws into the capture path. `at` is
   * the observation's epoch-ms timestamp; it defaults to the wall clock only
   * because the PlatformAdapter callback carries no timestamp — every decision
   * downstream takes the caller's `at`, never reads a clock itself. */
  onTrackSpeaking(track: MediaStreamTrack, speaking: boolean, at: number = Date.now()): void {
    if (this.disposed) return;
    try {
      this.liveTracksById.set(track.id, track);
      this.dispatch(this.engine.trackSpeaking(track.id, speaking, at));
    } catch {
      // best-effort — a broken correlation must never affect capture
    }
  }

  /** hook.content.ts calls this on every tile speaking-ring burst onset
   * (meet-speaking-dom.ts). Same best-effort contract as onTrackSpeaking. */
  onDeviceSpeaking(deviceId: PlatformParticipantId, at: number): void {
    if (this.disposed) return;
    try {
      // Recorded before the engine's local-device filter on purpose: the
      // flight recorder wants the evidence as observed, and roster-delta's
      // isLocal is what lets a replay re-derive the exclusion. The filter
      // itself — the real fix for journal #158 (the 2026-08-12 call, #172, is
      // the worked example) — lives in the engine.
      recordAttribution({ type: "dom-burst", t: at, deviceId });
      this.dispatch(this.engine.deviceSpeaking(deviceId, at));
    } catch {
      // best-effort — same contract as onTrackSpeaking
    }
  }

  /** audio-tap.ts calls this on every track's "unmute" event. A remote track
   * unmutes when its RTP resumes — for a mic toggle that's the same moment the
   * collections channel emits the device's mic-open edge, and the
   * unmuteCorrelator pairs the two. (RTP also resumes after DTX silence with
   * no collections edge; those unmutes just age out of the correlator's
   * history, and its distinct-tracks ambiguity rule holds when one coincides
   * with someone else's toggle.) */
  onTrackUnmute(track: MediaStreamTrack, at: number = Date.now()): void {
    if (this.disposed) return;
    try {
      this.liveTracksById.set(track.id, track);
      this.dispatch(this.engine.trackUnmuted(track.id, at));
    } catch {
      // best-effort — same contract as onTrackSpeaking
    }
  }

  private onCollectionsEvent(event: CollectionsMuteEvent, at: number = Date.now()): void {
    if (this.disposed) return;
    try {
      this.dispatch(this.engine.collectionsEdge(event.deviceId, event.micOpen, at));
    } catch {
      // best-effort — same contract as onTrackSpeaking
    }
  }

  /** Translate the engine's decisions into effects: flight-recorder events,
   * debug logs, and the onIdentity/onRoster callbacks. */
  private dispatch(decisions: MeetIdentityDecision[]): void {
    for (const decision of decisions) {
      switch (decision.kind) {
        case "binding":
          this.applyBinding(decision);
          break;
        case "local-resolved":
          console.debug(
            `[ears][identity] Meet local participant resolved: ${decision.deviceId} — excluded from identity correlation`,
          );
          break;
        case "roster":
          this.emitRoster(decision.t, decision.entries);
          break;
        case "no-self-marker":
          // MUST-NOT #13: a build or locale that never renders the marker must
          // not look like working code.
          console.warn(
            `[ears][identity] Meet roster has ${decision.namedCount} named participant(s) but no "(You)" marker on any tile — ` +
              `the local participant cannot be identified, so identity correlation may attribute a remote track to the local user ` +
              `(journal #158). Most likely a non-English Meet UI; see lib/identity/meet.ts SELF_MARKER.`,
          );
          break;
      }
    }
  }

  /** Forward a decided roster delta to the roster callback. Logs every
   * resolution (device id → display name) per issue #23's debug-logging
   * requirement. The engine already marked the local participant's row — the
   * roster is the only channel that reaches the daemon carrying identity
   * alone, so it is where "which of these is me" belongs, and the daemon
   * needs it to enforce the no-remote-track-is-you invariant on durable
   * state, where this build's missing "(You)" marker cannot silently disable
   * the check. */
  private emitRoster(at: number, fresh: RosterEntry[]): void {
    for (const entry of fresh) {
      console.debug(
        `[ears][identity] Meet roster resolved: ${entry.participantId} → "${entry.displayName}"` +
          (entry.isLocal ? " (you)" : ""),
      );
    }
    // Flight recorder: the roster delta as observed, including the
    // "(You)"-marker evidence — the isLocal flag a replay needs to re-derive
    // the local-device exclusion.
    recordAttribution({
      type: "roster-delta",
      t: at,
      entries: fresh.map((e) => ({
        participantId: e.participantId,
        displayName: e.displayName,
        ...(e.isLocal ? { isLocal: true } : {}),
      })),
    });
    this.rosterCb?.(fresh);
  }

  /** Every confirmed match records what was decided about it, with its cause
   * (which correlator, how many confirming turns) — the flight recorder's
   * `provisional-binding` event, which the decision mirrors field for field. */
  private applyBinding(d: MeetBindingDecision): void {
    recordAttribution({
      type: "provisional-binding",
      t: d.t,
      trackId: d.trackId,
      deviceId: d.deviceId,
      correlator: d.correlator,
      confirmations: d.confirmations,
      outcome: d.outcome,
    });
    switch (d.outcome) {
      case "refused-local-device":
        console.debug(
          `[ears][identity] Meet identity match refused: ${d.deviceId} is the local participant, ` +
            `so track ${d.trackId} cannot be it (journal #158)`,
        );
        return;
      case "refused-rebind":
        console.debug(
          `[ears][identity] Meet identity rebind refused: track ${d.trackId} is already ` +
            `${d.boundDeviceId}, so a ${d.confirmations}-turn match on ${d.deviceId} is a ` +
            `competing claim, not an upgrade (journal #158)`,
        );
        return;
      case "refused-device-claimed":
        console.debug(
          `[ears][identity] Meet identity claim refused: device ${d.deviceId} is already ` +
            `carried by live track ${d.owningTrackId}, so track ` +
            `${d.trackId} cannot also be it (journal #158)`,
        );
        return;
      case "bound-late-rename":
        console.debug(
          `[ears][identity] Meet late join: no live track for device ${d.deviceId} ` +
            `(track ${d.trackId} ended before ${d.confirmations}-turn confirmation landed)` +
            ` — pushing the identity link anyway`,
        );
        this.identityCb?.(d.trackId, d.deviceId);
        return;
      case "bound": {
        const name = this.engine.displayName(d.deviceId);
        console.debug(
          `[ears][identity] Meet identity join: track ${d.trackId} → ${d.deviceId}` +
            `${name ? ` "${name}"` : " (name not yet resolved from tiles)"} ` +
            `via speaking-onset correlation (${d.confirmations} confirming turns)`,
        );
        this.identityCb?.(d.trackId, d.deviceId);
        return;
      }
    }
  }

  /**
   * Disconnect the observer and drop caches. Idempotent. Called by epoch
   * teardown (audio-tap.ts initCapture's supersede chain): adapters are
   * minted per epoch by hook.content.ts, so disposal ends this instance — and
   * its engine — for good. Deliberately does NOT call
   * setCollectionsListener(null): a newer epoch's MeetAdapter may already
   * have re-registered itself by the time an older one disposes, and clearing
   * unconditionally would clobber that registration — the disposed-guard in
   * onCollectionsEvent/onTrackSpeaking is what actually stops a disposed
   * adapter from acting.
   */
  dispose(): void {
    this.disposed = true;
    this.observer?.disconnect();
    this.observer = null;
    this.liveTracksById.clear();
  }

  private correlate(track: MediaStreamTrack, stream: MediaStream): PlatformParticipantId | null {
    if (this.disposed || typeof document === "undefined") return null;
    this.ensureObserver();
    this.refreshNamesIfDirty();

    const media = findMediaElementForTrack(document, track, stream);
    const tile = media ? findParticipantTile(media) : null;
    if (!tile) {
      // Normal not-(yet-)correlated case — quiet null, the handle carries it.
      // But distinguish it from a structural total failure, which warns once.
      this.maybeWarnStructure();
      return null;
    }
    const id = extractParticipantId(tile)!;
    const name = extractDisplayName(tile);
    if (name) this.engine.nameObserved(id, name);
    return id;
  }

  private ensureObserver(): void {
    if (this.observer || this.disposed || typeof MutationObserver === "undefined") return;
    // Constructed at document_start, so the observer can't start until a real
    // identify() call, by which point the document exists. No stable Meet grid
    // container is verified yet, so observe body (documentElement as belt and
    // braces) — cheap, because the callback only marks the tile cache dirty;
    // rescans happen lazily inside identify()/displayName(). Meet's grid
    // mutates constantly (audio-level animations), so doing real work per
    // mutation would burn main-thread time for nothing.
    const root = document.body ?? document.documentElement;
    if (!root) return;
    this.observer = new MutationObserver(() => {
      this.tilesDirty = true;
    });
    this.observer.observe(root, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: [...PARTICIPANT_ID_ATTRIBUTES, "data-self-name"],
    });
  }

  /** Scan the tiles and hand the engine one roster observation: every named
   * tile, plus the "(You)"-marked device id when a scan can establish it
   * beyond doubt (``findLocalDeviceId``). The marker scan is skipped once the
   * engine has latched the answer — it cannot change within a call, and a
   * mid-call DOM churn that briefly empties the tile set must not clear an
   * exclusion already relied on. */
  private refreshNamesIfDirty(at: number = Date.now()): void {
    if (!this.tilesDirty || this.disposed || typeof document === "undefined") return;
    this.tilesDirty = false;
    const named: Array<{ deviceId: PlatformParticipantId; displayName: string }> = [];
    for (const tile of document.querySelectorAll(TILE_SELECTOR)) {
      const id = extractParticipantId(tile);
      if (!id) continue;
      const name = extractDisplayName(tile);
      if (name) named.push({ deviceId: id, displayName: name });
    }
    const local = this.engine.localDevice === undefined ? findLocalDeviceId(document) : undefined;
    this.dispatch(this.engine.rosterObserved(named, local, at));
  }

  // MUST-NOT #13 (no swallowing structural failures): a Meet build whose tiles
  // carry none of the expected attributes would otherwise look like working
  // code that happens to produce zero real names. Warn once — only once media
  // is demonstrably rendering (early in a call, zero tiles is normal).
  private maybeWarnStructure(): void {
    if (this.warnedMissingIds) return;
    if (document.querySelector(TILE_SELECTOR)) return; // expected shape present; this track just isn't placed (yet)
    let anyStream = false;
    for (const el of document.querySelectorAll(MEDIA_SELECTOR)) {
      if (mediaStreamOf(el as MediaElementLike)) {
        anyStream = true;
        break;
      }
    }
    if (!anyStream) return;
    this.warnedMissingIds = true;
    console.warn(
      `[ears][identity] Meet DOM carries none of the expected participant-id attributes (${PARTICIPANT_ID_ATTRIBUTES.join(", ")}) on any tile — sources stay anonymous. The Meet build's tile DOM has likely changed; see lib/identity/meet.ts for the verification checklist and CSRC fallback notes.`,
    );
  }
}

registerAdapter((host) => host === "meet.google.com", () => new MeetAdapter());
