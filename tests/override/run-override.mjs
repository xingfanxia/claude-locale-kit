// node run-override.mjs <native|override> <zone> <locale>: prints the case results as JSON.
// "native" relies on the TZ/LANG the caller set; "override" installs override.js for <zone>/<locale>.
import { readFileSync } from "node:fs";
const [mode, timeZone, locale] = process.argv.slice(2);
if (mode === "override") {
  globalThis.self = globalThis;
  self.__claudeLocaleKit = { timeZone, locale, languages: [locale, locale.split("-")[0]] };
  (0, eval)(readFileSync(new URL("../../extension/core/override.js", import.meta.url), "utf8"));
}
const { cases } = await import("./cases.mjs");
const enc = (v) => (typeof v === "number" && !Number.isFinite(v) ? String(v) : Object.is(v, -0) ? "-0" : v);
const out = {};
for (const [name, fn] of Object.entries(cases)) out[name] = JSON.parse(JSON.stringify(fn(), (_, v) => enc(v)));
process.stdout.write(JSON.stringify(out));
