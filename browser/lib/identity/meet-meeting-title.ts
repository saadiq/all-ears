// Meet's *human* meeting name — the calendar event's title for a scheduled
// call ("Kevin Weekly"), which becomes the session title the daemon files
// transcripts under (`{title}` in a path template, see
// docs/configuration.md).
//
// Same standing contract as every other identity path here: best-effort,
// never blocks, throws into, or delays capture. No name found means no title
// is sent at all, and the daemon's own default (identity → Meet id) stands.
//
// ── SURFACES ────────────────────────────────────────────────────────────────
//
//   1. `document.title` — the load-bearing path. Meet renders the meeting's
//      name there for a calendar-created call and the raw meeting code for an
//      ad-hoc one, in either order relative to the product name, sometimes
//      behind a "(3) " notification prefix. `stripProductName` handles all of
//      those shapes rather than matching one exact spelling.
//   2. The in-call details heading — a fallback for builds where the tab
//      title stays generic. UNVERIFIED against a live Meet build: the
//      selectors below are the plausible shapes, and a miss costs nothing
//      because surface 1 already carries the common case. Treat a live
//      confirmation as owed, the way meet.ts records its own probe results.
//
// A meeting-code-shaped string (`xxx-yyyy-zzz`) is explicitly "no name found":
// naming a transcript after the join code is strictly worse than the daemon's
// own default, which at least stays stable across renames.

/** Meet's ad-hoc join code: three-four-three lowercase letters. */
const MEETING_CODE_RE = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/i;

/** Leading "(3) " style unread/notification counts Meet prepends to the tab title. */
const NOTIFICATION_PREFIX_RE = /^\(\d+\)\s*/;

/** The product name, in the spellings that bracket a real meeting name. */
const PRODUCT_NAMES = ["Google Meet", "Meet"];

/** Separators Meet uses between the product name and the meeting name. */
const SEPARATORS = ["–", "—", "-", "|", ":"];

/** In-call "meeting details" heading candidates (see SURFACES note 2). */
const DETAILS_HEADING_SELECTORS = "[data-meeting-title], [data-call-title]";

/** True for Meet's `xxx-yyyy-zzz` join code — which is never a meeting name. */
export function isMeetingCode(value: string): boolean {
  return MEETING_CODE_RE.test(value.trim());
}

/** The DOM slice the title scan needs — hand-rolled fakes in tests, the real
 * document in production (same pattern as meet-meeting-id.ts's
 * `TileDocumentLike`). */
export interface TitleDocumentLike {
  title: string;
  querySelectorAll(selectors: string): Iterable<{ textContent: string | null }>;
}

/**
 * The meeting's human name, or null when this call has none (an ad-hoc
 * meeting, or a build whose surfaces have moved).
 */
export function extractMeetingTitle(doc: TitleDocumentLike): string | null {
  const fromTitle = usableName(stripProductName(doc.title ?? ""));
  if (fromTitle) return fromTitle;

  for (const el of doc.querySelectorAll(DETAILS_HEADING_SELECTORS)) {
    const heading = usableName(el.textContent ?? "");
    if (heading) return heading;
  }
  return null;
}

/** A candidate name, or null when it is empty, the bare product name, or the
 * join code. */
function usableName(candidate: string): string | null {
  const name = candidate.trim();
  if (!name) return null;
  if (PRODUCT_NAMES.some((product) => product.toLowerCase() === name.toLowerCase())) return null;
  if (isMeetingCode(name)) return null;
  return name;
}

/**
 * Removes the product name and its separator from either end of a tab title,
 * leaving whatever Meet put in the middle. Handles "Meet – X", "X - Google
 * Meet", and the "(3) " notification prefix without pinning one exact
 * spelling.
 */
function stripProductName(rawTitle: string): string {
  let title = rawTitle.replace(NOTIFICATION_PREFIX_RE, "").trim();
  for (const product of PRODUCT_NAMES) {
    for (const separator of SEPARATORS) {
      const prefix = `${product} ${separator} `;
      if (title.toLowerCase().startsWith(prefix.toLowerCase())) {
        return title.slice(prefix.length).trim();
      }
      const suffix = ` ${separator} ${product}`;
      if (title.toLowerCase().endsWith(suffix.toLowerCase())) {
        return title.slice(0, title.length - suffix.length).trim();
      }
    }
  }
  return title;
}

/**
 * Takes the first meeting name observed and reports it exactly once.
 *
 * Calendar names often resolve *after* join — the tab title is generic for
 * the first seconds — so this is polled while the call runs rather than read
 * once at declare time. Reporting only the first name found is deliberate:
 * it bounds the daemon traffic to one `session.rename`, and a user who
 * renames the session by hand afterwards is never fought over it.
 *
 * The timer wiring stays in hook.content.ts; this class is the pure,
 * unit-testable part.
 */
export class MeetMeetingTitleWatcher {
  private resolved: string | null = null;

  constructor(private readonly onResolved: (title: string) => void) {}

  /** The resolved meeting name, or null while still unknown. */
  get title(): string | null {
    return this.resolved;
  }

  /** Scan the title/DOM (cheap; call on a short interval while unresolved). */
  poll(doc: TitleDocumentLike): void {
    if (this.resolved) return;
    const title = extractMeetingTitle(doc);
    if (!title) return;
    this.resolved = title;
    this.onResolved(title);
  }
}
