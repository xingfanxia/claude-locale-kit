// Shared catalog derivation for the build and the tests. Source of truth: profile/locales.json
// plus the IANA zones known to this Node's ICU.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const ROOT = fileURLToPath(new URL("..", import.meta.url));
const ZONE_RE = /^[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)*$/;
// Current IANA names that ICU still lists under an older canonical ID (Asia/Calcutta for
// Asia/Kolkata, ...). Intl accepts both; profiles may use either.
const IANA_PRIMARY = ["Africa/Asmara", "America/Argentina/Buenos_Aires", "America/Argentina/Catamarca",
  "America/Argentina/Cordoba", "America/Argentina/Jujuy", "America/Argentina/Mendoza", "America/Atikokan",
  "America/Indiana/Indianapolis", "America/Kentucky/Louisville", "America/Nuuk", "Asia/Ho_Chi_Minh", "Asia/Kathmandu",
  "Asia/Kolkata", "Asia/Yangon", "Atlantic/Faroe", "Europe/Kyiv", "Pacific/Chuuk", "Pacific/Kanton", "Pacific/Pohnpei"];

export function loadCatalog() {
  const { locales } = JSON.parse(readFileSync(new URL("../profile/locales.json", import.meta.url), "utf8"));
  const listed = Intl.supportedValuesOf("timeZone");
  for (const z of IANA_PRIMARY) {
    const resolved = new Intl.DateTimeFormat("en", { timeZone: z }).resolvedOptions().timeZone;
    if (!listed.includes(resolved)) throw new Error(`${z} resolves to unlisted ${resolved}`);
  }
  const zones = [...new Set([...listed, ...IANA_PRIMARY, "UTC"])].sort();
  for (const z of zones) if (!ZONE_RE.test(z) || z.includes("__")) throw new Error(`unsafe zone id ${z}`);
  for (const l of locales) if (!/^[a-z]{2,3}-[A-Z]{2}$/.test(l)) throw new Error(`unsupported locale shape ${l}`);
  const languages = Object.fromEntries(locales.map((l) => [l, [l, l.split("-")[0]]]));
  return { zones, locales, languages };
}

export const zoneFile = (z) => `presets/tz/${z.replaceAll("/", "__")}.js`;
export const localeFile = (l) => `presets/locale/${l}.js`;
export const acceptLanguage = (langs) => langs.map((l, i) => (i === 0 ? l : `${l};q=${(1 - i / 10).toFixed(1)}`)).join(",");
export const posixLocale = (l) => `${l.replace("-", "_")}.UTF-8`;
