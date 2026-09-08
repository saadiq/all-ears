// Teams identity probe — paste into the DevTools console of the tab that is IN
// the call. Strictly read-only: it polls and diffs, attaches no listeners to
// page objects, mutates no DOM, and never emits a display name.
//
// Deliberately NOT extension code. A probe shipped into the live extension
// untested once killed capture mid-call; this runs beside the extension and
// cannot touch the capture path.
//
// The question it answers: Teams gives the extension ONE mixed far-end track
// (`identity/teams.ts` returns null, so every remote voice files as
// `browser:teams:<track>`). To attribute turns we need two things out of the
// DOM, and neither is known for this build:
//
//   1. A stable per-participant key, and a name attached to it.
//   2. A *speaking* signal that toggles as people talk — the dominant-speaker
//      indicator the extension spec assumes exists but nothing has verified.
//
// So the probe hunts rather than asserting selectors: it censuses the
// attribute surface once, picks whatever looks like a participant row, and
// then diffs those rows every second. Whichever attribute flips on and off
// while people talk IS the speaking signal. Every toggle is timestamped in
// wall clock, so the log lines up against earsd's own VAD/segment events for
// `browser:teams:*` — the extension's audio says WHEN someone spoke, this says
// WHICH row lit up.
//
// PRIVACY: names, aria text and any free text are reduced to a 7-char hash
// before they are recorded. A hash is stable within a call, so "row a3f9k2m
// lit up 14 times" is answerable without the log ever carrying who that is.
// Developer-authored strings (class names, data-tid values) are emitted
// verbatim — they are how we write the selector afterwards — unless they
// contain something id- or name-shaped.
//
//   __earsTeams.census()    → one-off full attribute sweep (expensive, ~5ms)
//   __earsTeams.now()       → immediate snapshot of the rows being watched
//   __earsTeams.dump()      → census + change log + latest snapshot
//   __earsTeams.post(url)   → POST the dump to a local receiver (see below)
//   __earsTeams.stop()      → stop polling
//
// Getting the data out — copy() has silently failed here before, so prefer the
// receiver. In a terminal:
//     python3 browser/dev/probes/probe-receiver.py
// then in the tab console:
//     __earsTeams.post()
(() => {
  const W = window;
  const D = document;

  // ── bounded change log ────────────────────────────────────────────────────
  const MAX_LOG = 5000;
  const changes = [];
  const stamp = () => new Date().toISOString();
  const note = (...fields) => {
    changes.push(`${stamp()} ${fields.join(" ")}`);
    if (changes.length > MAX_LOG) changes.shift();
  };

  // ── redaction ─────────────────────────────────────────────────────────────
  // djb2. Not a secret — just enough that one row is distinguishable from
  // another across ticks without the log carrying anybody's name.
  const hash = (s) => {
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return h.toString(36).padStart(7, "0").slice(-7);
  };
  const GUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
  const MRI = /^(8:orgid:|8:live:|28:|19:|4:)/;
  // A developer-authored token (class name, data-tid) is safe to print; a guid
  // or MRI inside one is not, and neither is anything longer or spacier.
  const DEV_TOKEN = /^[a-z][a-z0-9._:-]{0,48}$/i;
  const safeToken = (v) => DEV_TOKEN.test(v) && !GUID.test(v) && !MRI.test(v);

  /** What a value IS, never what it says. */
  const shape = (v) => {
    const s = String(v ?? "").trim();
    if (!s) return "empty";
    if (GUID.test(s)) return MRI.test(s) ? `mri#${hash(s)}` : `guid#${hash(s)}`;
    if (MRI.test(s)) return `mri#${hash(s)}`;
    if (/^(true|false)$/i.test(s)) return s.toLowerCase();
    if (/^-?\d+$/.test(s)) return `int(${s.length})`;
    if (safeToken(s)) return s;
    return `text(${s.length})#${hash(s)}`;
  };

  // aria labels are where Teams puts "<name>, speaking" — the state word is the
  // whole point and the name must not survive. Segments are matched against a
  // fixed vocabulary; anything else is hashed.
  const STATE_WORDS =
    /^(speaking|not speaking|muted|unmuted|mute|microphone (on|off|muted)|camera (on|off)|video (on|off)|presenting|sharing( content)?|hand raised|raised hand|organi[sz]er|presenter|attendee|guest|pinned|spotlighted|in the meeting|joined|left|waiting in lobby|active speaker|you)$/i;
  const ariaTokens = (label) =>
    String(label ?? "")
      .split(/[,()]/)
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => (STATE_WORDS.test(s) ? s.toLowerCase() : `·${hash(s)}`))
      .join("|");

  // ── candidate discovery ───────────────────────────────────────────────────
  // Attribute NAMES worth treating as a participant key. Teams changes these
  // between builds, so the census discovers them rather than the probe naming
  // them up front.
  const ID_ATTR_HINT = /participant|person|user|attendee|roster|member|mri|oid|objectid|stream|tile/i;
  const STATE_CLASS_HINT = /speak|voice|talk|active|audio|level|ring|halo|pulse|animate/i;
  const ROW_TID_HINT = /roster|participant|attendee|tile|stream|avatar|person|member/i;

  let rowAttrs = []; // attribute names that turned out to identify rows
  let censusResult = null;

  /**
   * One full sweep of the document's attribute surface. Expensive on the Teams
   * SPA (journal #161 measured ~5ms for a full-markup pass), so it runs once at
   * start and thereafter only on demand — never in the tick.
   */
  function census() {
    const started = performance.now();
    const attrNames = new Map(); // name → count
    const idAttrs = new Map(); // name → Set of value shapes
    const tids = new Map(); // data-tid value → count
    const stateClasses = new Map(); // class token → count
    let elements = 0;

    for (const el of D.querySelectorAll("*")) {
      elements++;
      for (const a of el.attributes) {
        attrNames.set(a.name, (attrNames.get(a.name) ?? 0) + 1);
        if (a.name === "data-tid" && safeToken(a.value)) {
          tids.set(a.value, (tids.get(a.value) ?? 0) + 1);
        }
        const looksLikeId = GUID.test(a.value) || MRI.test(a.value);
        if (looksLikeId || ID_ATTR_HINT.test(a.name)) {
          if (!idAttrs.has(a.name)) idAttrs.set(a.name, new Set());
          idAttrs.get(a.name).add(shape(a.value));
        }
      }
      const cls = typeof el.className === "string" ? el.className : "";
      for (const token of cls.split(/\s+/)) {
        if (token && STATE_CLASS_HINT.test(token) && safeToken(token)) {
          stateClasses.set(token, (stateClasses.get(token) ?? 0) + 1);
        }
      }
    }

    // A row attribute is one that carries id-shaped values on more than one
    // element — one element means it is the local user or a singleton, which
    // cannot key a roster.
    rowAttrs = [...idAttrs.entries()]
      .filter(([name, shapes]) => {
        const n = D.querySelectorAll(`[${CSS.escape(name)}]`).length;
        return n > 1 && [...shapes].some((s) => /^(guid|mri)#/.test(s) || s.startsWith("int"));
      })
      .map(([name]) => name);

    censusResult = {
      at: stamp(),
      elements,
      ms: Math.round(performance.now() - started),
      rowAttrs,
      idAttrs: Object.fromEntries([...idAttrs].map(([k, v]) => [k, [...v].slice(0, 6)])),
      dataTids: Object.fromEntries(
        [...tids].filter(([v]) => ROW_TID_HINT.test(v)).sort((a, b) => b[1] - a[1]).slice(0, 60)),
      stateClasses: Object.fromEntries([...stateClasses].sort((a, b) => b[1] - a[1]).slice(0, 40)),
      totalAttrNames: attrNames.size,
    };
    note("census", `elements=${elements}`, `rowAttrs=${rowAttrs.join(",") || "NONE"}`,
      `stateClasses=${Object.keys(censusResult.stateClasses).length}`, `${censusResult.ms}ms`);
    return censusResult;
  }

  // ── the watched rows ──────────────────────────────────────────────────────
  const rowSelector = () => {
    const byAttr = rowAttrs.map((a) => `[${CSS.escape(a)}]`);
    // Fallback while the census has found nothing: Teams' own test ids.
    const byTid = Object.keys(censusResult?.dataTids ?? {}).map(
      (v) => `[data-tid="${CSS.escape(v)}"]`);
    return [...byAttr, ...byTid].join(",");
  };

  const MAX_ROWS = 60;

  /** Volatile state of one row — everything a speaking signal could hide in. */
  function fingerprint(el) {
    const aria = {};
    const data = {};
    for (const a of el.attributes) {
      if (a.name.startsWith("aria-")) {
        aria[a.name] = a.name === "aria-label" ? ariaTokens(a.value) : shape(a.value);
      } else if (a.name.startsWith("data-") && a.name !== "data-tid") {
        data[a.name] = shape(a.value);
      }
    }
    const cls = typeof el.className === "string" ? el.className : "";
    const stateCls = cls
      .split(/\s+/)
      .filter((t) => t && STATE_CLASS_HINT.test(t) && safeToken(t))
      .sort()
      .join(" ");
    // Descendant shapes that commonly carry the animation: count them rather
    // than reading them, so a re-render that swaps class names still shows up.
    const kids = el.querySelectorAll("*");
    let stateKids = 0;
    for (const k of kids) {
      const kc = typeof k.className === "string" ? k.className : "";
      if (STATE_CLASS_HINT.test(kc)) stateKids++;
    }
    return {
      clsHash: hash(cls),
      stateCls,
      stateKids,
      kids: kids.length,
      aria,
      data,
      named: (el.textContent ?? "").trim().length > 0,
    };
  }

  /** Stable-ish key for a row: its id-shaped attribute value, else its shape. */
  function rowKey(el) {
    for (const a of rowAttrs) {
      const v = el.getAttribute(a);
      if (v) return `${a}=${shape(v)}`;
    }
    const tid = el.getAttribute("data-tid");
    // No id attribute: fall back to position among same-tid siblings, which is
    // unstable across re-renders and flagged as such.
    const peers = tid ? [...D.querySelectorAll(`[data-tid="${CSS.escape(tid)}"]`)] : [];
    return `tid=${tid ?? "?"}[${peers.indexOf(el)}]~`;
  }

  function snapshot() {
    const sel = rowSelector();
    const rows = new Map();
    if (!sel) return { at: stamp(), rows, n: 0 };
    const els = [...D.querySelectorAll(sel)].slice(0, MAX_ROWS);
    for (const el of els) rows.set(rowKey(el), fingerprint(el));
    return { at: stamp(), rows, n: els.length };
  }

  // ── the tick ──────────────────────────────────────────────────────────────
  // Runs on the same thread the call renders on, so it polices its own cost:
  // three slow ticks and it backs off rather than degrading the meeting.
  let prev = null;
  let interval = 1000;
  let slow = 0;
  let ticks = 0;

  const diffMap = (key, a, b, kind) => {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (a[k] !== b[k]) note(`row~ ${key} ${kind}:${k}`, `${a[k] ?? "-"} -> ${b[k] ?? "-"}`);
    }
  };

  function tick() {
    const started = performance.now();
    let s;
    try {
      s = snapshot();
    } catch (e) {
      note("PROBE-ERROR", e?.message ?? String(e));
      return;
    }
    ticks++;
    if (prev) {
      for (const [key, f] of s.rows) {
        const p = prev.rows.get(key);
        if (!p) {
          note("row+", key, `stateCls="${f.stateCls}"`, `stateKids=${f.stateKids}`, `named=${f.named}`);
          continue;
        }
        if (p.stateCls !== f.stateCls) note("row~", key, "class", `"${p.stateCls}" -> "${f.stateCls}"`);
        if (p.stateKids !== f.stateKids) note("row~", key, "stateKids", `${p.stateKids} -> ${f.stateKids}`);
        if (p.clsHash !== f.clsHash && p.stateCls === f.stateCls) note("row~", key, "clsOther", `${p.clsHash} -> ${f.clsHash}`);
        if (p.named !== f.named) note("row~", key, "named", `${p.named} -> ${f.named}`);
        diffMap(key, p.aria, f.aria, "aria");
        diffMap(key, p.data, f.data, "data");
      }
      for (const key of prev.rows.keys()) if (!s.rows.has(key)) note("row-", key);
      if (prev.n !== s.n) note("rows", `${prev.n} -> ${s.n}`);
    } else {
      for (const [key, f] of s.rows) {
        note("row0", key, `stateCls="${f.stateCls}"`, `stateKids=${f.stateKids}`, `named=${f.named}`,
          `aria=${Object.keys(f.aria).join(",") || "-"}`);
      }
      note("rows0", String(s.n));
    }
    prev = s;

    const ms = performance.now() - started;
    if (ms > 15) {
      slow++;
      note("SLOW-TICK", `${Math.round(ms)}ms`, `slow=${slow}`);
      if (slow >= 3 && interval < 5000) {
        interval = 5000;
        clearInterval(W.__earsTeamsTimer);
        W.__earsTeamsTimer = setInterval(tick, interval);
        note("BACKOFF", "interval -> 5000ms (probe was costing the render thread)");
      }
    }
    if (ticks % 60 === 0) note("heartbeat", `ticks=${ticks}`, `rows=${s.n}`, `log=${changes.length}`);
  }

  // ── exports ───────────────────────────────────────────────────────────────
  const dump = () => ({
    schema: 1,
    probe: "teams-identity",
    href: location.pathname, // never the query string: it carries meeting ids
    startedAt: stamp(),
    census: censusResult,
    changes: [...changes],
    latest: prev
      ? { at: prev.at, n: prev.n, rows: [...prev.rows].map(([k, f]) => ({ key: k, ...f })) }
      : null,
  });

  // no-cors + text/plain avoids a preflight; the opaque response is irrelevant.
  const post = (url = "http://127.0.0.1:8899/teams-probe") =>
    fetch(url, {
      method: "POST",
      mode: "no-cors",
      headers: { "Content-Type": "text/plain" },
      body: JSON.stringify(dump()),
    }).then(() => "posted", (e) => `POST failed: ${e?.message ?? e}`);

  clearInterval(W.__earsTeamsTimer);
  census();
  W.__earsTeamsTimer = setInterval(tick, interval);
  tick();

  W.__earsTeams = {
    census,
    now: () => ({ at: prev?.at, n: prev?.n, rows: prev ? [...prev.rows.keys()] : [] }),
    dump,
    post,
    stop: () => {
      clearInterval(W.__earsTeamsTimer);
      return `stopped after ${ticks} ticks, ${changes.length} log lines`;
    },
  };
  return `__earsTeams ready — rows=${prev?.n ?? 0}, rowAttrs=${rowAttrs.join(",") || "NONE (see census)"}`;
})();
