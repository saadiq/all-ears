// Meet identity/capture probe — paste into the DevTools console of the tab
// that is IN the call. Strictly read-only: it polls and diffs, attaches no
// listeners to page objects, mutates no DOM, and never emits a display name
// (names are reduced to `name=true|false`).
//
// Answers two questions:
//   1. Which streams belong in the transcript — every track the hook knows
//      about, with provenance (local/remote, gum/ontrack/clone) and its
//      mute edges over time. Journal #142's phantom tracks and #158's
//      flip-flop both only show up as CHANGES, which is why this diffs.
//   2. Who each attendee is — tile participant ids, plus a hunt for any DOM
//      marker that distinguishes the LOCAL participant (journal #158's open
//      item: self-exclusion has no known signal on this build).
//
//   __ears.dump()   → the change log so far, plus the latest snapshot
//   __ears.now()    → one immediate snapshot
//   __ears.selfHunt() → wider search for a self marker
//   __ears.stop()   → stop polling
(() => {
  const W = window;
  const T = (s) => String(s ?? "?").slice(0, 8);
  const ID_ATTRS = [
    "data-participant-id",
    "data-requested-participant-id",
    "data-initial-participant-id",
  ];
  const TILE_SEL = ID_ATTRS.map((a) => `[${a}]`).join(",");
  const changes = [];
  const stamp = () => new Date().toISOString().slice(11, 23);
  const note = (...f) => {
    changes.push(`${stamp()} ${f.join(" ")}`);
    if (changes.length > 2000) changes.shift();
  };

  const maps = () => ({
    prov: W.__earsTrackProvenance instanceof Map ? W.__earsTrackProvenance : new Map(),
    live: W.__earsLiveTracks instanceof Map ? W.__earsLiveTracks : new Map(),
    wa: W.__earsWebAudioTracks instanceof Map ? W.__earsWebAudioTracks : new Map(),
  });

  const provStr = (id, p) =>
    p ? `${p.origin}/${p.via}${p.rootId !== id ? "/clone" : ""}#${p.seq}` : "UNCLASSIFIED";

  function snapshot() {
    const { prov, live, wa } = maps();
    const tracks = new Map();
    for (const t of live.keys()) {
      tracks.set(t.id, { reg: "rtc", state: t.readyState, muted: t.muted, prov: provStr(t.id, prov.get(t.id)) });
    }
    for (const [k, r] of wa.entries()) {
      const t = r?.track ?? r;
      const id = t?.id ?? k;
      tracks.set(id, { reg: "wa", state: t?.readyState ?? "?", muted: t?.muted ?? "?", prov: provStr(id, prov.get(id)) });
    }
    const tiles = new Map();
    for (const el of document.querySelectorAll(TILE_SEL)) {
      const id = ID_ATTRS.map((a) => el.getAttribute(a)).find((v) => v && v.trim());
      if (!id) continue;
      const ne = el.querySelector("span.notranslate, [data-self-name]");
      const nt = (ne?.textContent || "").trim();
      const all = (el.textContent || "").trim();
      const prev = tiles.get(id) || { named: false, you: false, selfAttr: false, aria: false };
      tiles.set(id, {
        named: prev.named || nt.length > 0,
        // Self-marker candidates — all name-free booleans.
        you: prev.you || /\(\s*you\s*\)/i.test(all),
        selfAttr: prev.selfAttr || el.hasAttribute("data-self-name") || !!el.querySelector("[data-self-name]"),
        aria: prev.aria || /\byou\b/i.test(el.getAttribute("aria-label") || ""),
      });
    }
    return {
      at: stamp(),
      n: { rtc: live.size, wa: wa.size, prov: prov.size, pc: W.__earsLivePCs?.size ?? 0, tiles: tiles.size },
      tracks,
      tiles,
    };
  }

  let prev = null;
  function tick() {
    let s;
    try {
      s = snapshot();
    } catch (e) {
      note("PROBE-ERROR", e?.message ?? e);
      return;
    }
    if (prev) {
      for (const [id, t] of s.tracks) {
        const p = prev.tracks.get(id);
        if (!p) note("track+", T(id), t.reg, `muted=${t.muted}`, t.prov);
        else {
          if (p.muted !== t.muted) note("mute", T(id), t.reg, `${p.muted}->${t.muted}`, t.prov);
          if (p.state !== t.state) note("state", T(id), t.reg, `${p.state}->${t.state}`);
          if (p.prov !== t.prov) note("prov", T(id), t.reg, `${p.prov}->${t.prov}`);
        }
      }
      for (const id of prev.tracks.keys()) if (!s.tracks.has(id)) note("track-", T(id));
      for (const [id, v] of s.tiles) {
        const p = prev.tiles.get(id);
        if (!p) note("tile+", id, `name=${v.named}`, `you=${v.you}`, `selfAttr=${v.selfAttr}`, `aria=${v.aria}`);
        else if (p.named !== v.named || p.you !== v.you || p.selfAttr !== v.selfAttr || p.aria !== v.aria)
          note("tile~", id, `name=${v.named}`, `you=${v.you}`, `selfAttr=${v.selfAttr}`, `aria=${v.aria}`);
      }
      for (const id of prev.tiles.keys()) if (!s.tiles.has(id)) note("tile-", id);
    } else {
      for (const [id, t] of s.tracks) note("track0", T(id), t.reg, `muted=${t.muted}`, t.prov);
      for (const [id, v] of s.tiles) note("tile0", id, `name=${v.named}`, `you=${v.you}`, `selfAttr=${v.selfAttr}`, `aria=${v.aria}`);
    }
    prev = s;
  }

  // Wider hunt for a LOCAL-participant marker. Reports ids, attribute NAMES,
  // and counts only — never the text of a name.
  function selfHunt() {
    const out = { exactYouNodes: [], attrNames: new Set(), idAttrValues: {}, panelRows: 0 };
    for (const el of document.querySelectorAll("*")) {
      const own = [...el.childNodes]
        .filter((n) => n.nodeType === 3)
        .map((n) => n.textContent.trim())
        .join(" ")
        .trim();
      if (!own) continue;
      if (/^\(?\s*you\s*\)?$/i.test(own) || /\(\s*you\s*\)$/i.test(own)) {
        let tile = el;
        while (tile && !ID_ATTRS.some((a) => tile.getAttribute?.(a))) tile = tile.parentElement;
        const id = tile ? ID_ATTRS.map((a) => tile.getAttribute(a)).find(Boolean) : null;
        out.exactYouNodes.push({ tag: el.tagName, cls: el.className?.slice?.(0, 24) ?? "", tileId: id });
      }
    }
    for (const el of document.querySelectorAll(TILE_SEL)) {
      for (const a of el.attributes) {
        out.attrNames.add(a.name);
        // Record values only for attributes that look like ids/flags, never names.
        if (/^data-/.test(a.name) && /^(spaces\/|true|false|\d+)$/i.test(a.value.trim())) {
          (out.idAttrValues[a.name] ||= new Set()).add(a.value.slice(0, 40));
        }
      }
    }
    return {
      exactYouNodes: out.exactYouNodes,
      tileAttrNames: [...out.attrNames],
      idAttrValues: Object.fromEntries(Object.entries(out.idAttrValues).map(([k, v]) => [k, [...v]])),
      selfNameAttrCount: document.querySelectorAll("[data-self-name]").length,
    };
  }

  clearInterval(W.__earsProbeTimer);
  W.__earsProbeTimer = setInterval(tick, 1000);
  tick();

  W.__ears = {
    now: () => {
      const s = snapshot();
      return { at: s.at, n: s.n, tracks: [...s.tracks].map(([id, t]) => `${t.reg} ${T(id)} ${t.state} muted=${t.muted} ${t.prov}`), tiles: [...s.tiles].map(([id, v]) => `${id} name=${v.named} you=${v.you} selfAttr=${v.selfAttr} aria=${v.aria}`) };
    },
    dump: () => ({ changes: [...changes], latest: W.__ears.now() }),
    selfHunt,
    stop: () => clearInterval(W.__earsProbeTimer),
  };
  return "__ears ready — __ears.dump() / __ears.now() / __ears.selfHunt() / __ears.stop()";
})();
