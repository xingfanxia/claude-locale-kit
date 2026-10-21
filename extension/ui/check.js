// "Check current Claude tab": runs only on a click, only in the active tab of this window, and
// only when that tab is https://claude.ai. It reads what page JavaScript sees for the zone and
// language, nothing else: no DOM, storage, cookies or conversation.

/** Injected as-is into the page's MAIN world. Fixed and read-only; returns exactly these keys. */
export function readLocaleSurface() {
  const options = Intl.DateTimeFormat().resolvedOptions();
  return {
    timeZone: options.timeZone,
    locale: options.locale,
    timezoneOffset: new Date().getTimezoneOffset(),
    dateString: new Date().toString(),
    language: navigator.language,
    languages: Array.from(navigator.languages),
  };
}
export const SURFACE_KEYS = ["timeZone", "locale", "timezoneOffset", "dateString", "language", "languages"];

/** @returns {Promise<{kind: "notClaude"} | {kind: "error", error: string} | {kind: "observed", observed: object, at: number}>} */
export async function readActiveClaudeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  // Without the tabs permission, tab.url is only present for hosts this extension may access.
  let origin = null;
  try { origin = new URL(tab?.url).origin; } catch { /* no readable URL */ }
  if (origin !== "https://claude.ai") return { kind: "notClaude" };
  try {
    const at = Date.now();
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      world: "MAIN",
      func: readLocaleSurface,
    });
    return { kind: "observed", observed: result.result, at };
  } catch (e) {
    return { kind: "error", error: String(e?.message ?? e) };
  }
}

/** The engine's own canonical id, so Asia/Kolkata and Asia/Calcutta compare equal. */
const canonicalZone = (z) => {
  try { return new Intl.DateTimeFormat("en", { timeZone: z }).resolvedOptions().timeZone; } catch { return null; }
};

/**
 * Rows of {key, observed, selected, match, alias} comparing the observed surface with the
 * profile. `offsetAt(zone, ms)` gives the zone's UTC offset in minutes at that instant.
 */
export function compare(observed, profile, languages, offsetAt, at) {
  const offset = offsetAt(profile.timeZone, at);
  const gmt = (min) => `GMT${min < 0 ? "-" : "+"}${String(Math.floor(Math.abs(min) / 60)).padStart(2, "0")}${String(Math.abs(min) % 60).padStart(2, "0")}`;
  const zoneMatch = observed.timeZone === profile.timeZone
    || (canonicalZone(observed.timeZone) !== null && canonicalZone(observed.timeZone) === canonicalZone(profile.timeZone));
  return [
    { key: "timeZone", observed: observed.timeZone, selected: profile.timeZone, match: zoneMatch,
      alias: zoneMatch && observed.timeZone !== profile.timeZone },
    { key: "locale", observed: observed.locale, selected: profile.locale, match: observed.locale === profile.locale },
    { key: "timezoneOffset", observed: String(observed.timezoneOffset), selected: String(-offset),
      match: observed.timezoneOffset === -offset },
    { key: "language", observed: observed.language, selected: languages[0], match: observed.language === languages[0] },
    { key: "languages", observed: observed.languages.join(", "), selected: languages.join(", "),
      match: observed.languages.join(",") === languages.join(",") },
    { key: "dateString", observed: observed.dateString, selected: gmt(offset), match: observed.dateString.includes(` ${gmt(offset)} `) },
  ];
}
