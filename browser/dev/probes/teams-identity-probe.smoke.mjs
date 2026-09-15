// Smoke test for teams-identity-probe.js against a synthetic Teams-shaped DOM.
//
// The probe runs in the tab of a call that is being recorded, so "it threw on
// paste" or "it leaked a name" are both discovered at the worst possible
// moment. This drives it headless first: build a roster, toggle a speaking
// class the way a live build would, run the ticks, and assert on what came out.
//
//   node browser/dev/probes/teams-identity-probe.smoke.mjs
import { readFileSync } from "node:fs";
import { parseHTML } from "linkedom";
import { fileURLToPath } from "node:url";

// The trailing `;` is dropped so the IIFE can be parenthesised into an
// expression below; the leading comment block is why it has to be.
const probeSource = readFileSync(
  fileURLToPath(new URL("./teams-identity-probe.js", import.meta.url)), "utf8")
  .trim().replace(/;$/, "");

// Two participants and a self tile, keyed the way Teams keys things: an MRI on
// the roster row, a test id on the container. Names are real-looking on
// purpose — the point is proving they do not reach the output.
const NAMES = { a: "Priyanka Raghunathan", b: "Bartosz Kowalczyk", self: "Tom Elliot" };
const MRI = {
  a: "8:orgid:0f8fad5b-d9cb-469f-a165-70867728950e",
  b: "8:orgid:7c9e6679-7425-40de-944b-e07fc1f90ae7",
  self: "8:orgid:16fd2706-8baf-433b-82eb-8c7fada847da",
};
const row = (k) => `
  <div data-tid="roster-participant" data-participant-mri="${MRI[k]}" class="row-2f8c"
       aria-label="${NAMES[k]}, muted">
    <span class="fui-Persona__primaryText">${NAMES[k]}</span>
    <div class="voice-level-indicator" data-tid="voice-level"></div>
  </div>`;

const { document, window } = parseHTML(`<!doctype html><html><body>
  <div data-tid="roster-section">${row("self")}${row("a")}${row("b")}</div>
</body></html>`);

// linkedom ships no CSS.escape; the probe only ever escapes attribute names
// and dev-authored test ids, so the identity function is faithful enough here.
const CSS = { escape: (s) => String(s) };
const location = { pathname: "/v2/", href: "https://teams.microsoft.com/v2/" };

let tick = null;
const setInterval = (fn) => { tick = fn; return 1; };
const clearInterval = () => {};

const scope = { window, document, CSS, location, performance, setInterval, clearInterval,
  fetch: () => Promise.resolve() };
// Parenthesised: the probe opens with a comment block, and `return` followed by
// a newline would otherwise be `return undefined` via ASI.
const run = new Function(...Object.keys(scope), `return (${probeSource})`);
const banner = run(...Object.values(scope));

const fail = [];
const check = (ok, msg) => { if (!ok) fail.push(msg); };

check(/rowAttrs=data-participant-mri/.test(banner), `census missed the row attribute: ${banner}`);

// A speaking turn: the class appears on one row, then goes away again — the
// exact shape of the signal we are hunting for on the live build.
const rowA = document.querySelectorAll("[data-participant-mri]")[1];
tick();
rowA.className = "row-2f8c is-speaking-8a1";
tick();
rowA.setAttribute("aria-label", `${NAMES.a}, speaking`);
tick();
rowA.className = "row-2f8c";
tick();

const dump = window.__earsTeams.dump();
const text = JSON.stringify(dump);

check(dump.census.rowAttrs.includes("data-participant-mri"), "row attribute not recorded in census");
// Three roster rows plus their container: the container is watched too, on
// purpose — a build that names its dominant speaker does it at that level.
check(
  dump.latest.rows.filter((r) => r.key.startsWith("data-participant-mri=")).length === 3,
  `expected 3 keyed rows, got ${dump.latest?.rows.map((r) => r.key).join(" ")}`);
check(
  dump.changes.some((l) => l.includes('class') && l.includes("is-speaking-8a1")),
  "the speaking class toggle never reached the change log");
check(
  dump.changes.some((l) => l.includes("aria:aria-label") && l.includes("speaking")),
  "the aria speaking token never reached the change log");

// The whole privacy contract, asserted rather than trusted.
for (const [who, name] of Object.entries(NAMES)) {
  check(!text.includes(name), `LEAK: ${who}'s display name is in the output`);
  for (const part of name.split(" ")) check(!text.includes(part), `LEAK: name fragment "${part}"`);
}
for (const [who, mri] of Object.entries(MRI)) {
  check(!text.includes(mri), `LEAK: ${who}'s MRI is in the output`);
}
check(!text.includes("teams.microsoft.com"), "LEAK: the meeting URL is in the output");
// ...while the developer-authored strings we need for the selector survive.
check(text.includes("roster-participant"), "data-tid was redacted — the selector is unrecoverable");
check(text.includes("voice-level-indicator"), "state class was redacted — the signal is unnameable");

if (fail.length) {
  console.error(`FAIL (${fail.length}):`);
  for (const f of fail) console.error(`  - ${f}`);
  process.exit(1);
}
if (process.env.VERBOSE) {
  console.log(JSON.stringify(dump.census, null, 2));
  for (const line of dump.changes) console.log(line);
}
console.log(`ok — ${banner}`);
console.log(`   ${dump.changes.length} change lines, ${dump.latest.rows.length} rows, no leaks`);
