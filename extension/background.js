// Turns the stored profile into one pre-registered MAIN-world content script and one
// Accept-Language rule, both scoped to claude.ai. Storage holds `profile` (v1 JSON object) and
// `enabled` (boolean, kept outside the profile).
//
// minimum_chrome_version is 119, the first release whose registerContentScripts accepts
// matchOriginAsFallback. Without it, an about:blank or srcdoc iframe that claude.ai creates gets no
// override, and the page could read native values through that frame's Date and Intl. MAIN world
// and persistAcrossSessions need 102; DNR requestDomains needs 101.
import { parseProfile } from "./core/profile.js";
import { TIME_ZONES, LOCALES, ACCEPT_LANGUAGE, zoneFile, localeFile } from "./generated/catalog.js";

const SCRIPT_ID = "claude-locale";
const RULE_ID = 1;
const CATALOG = { timeZones: TIME_ZONES, locales: LOCALES };
const RESOURCE_TYPES = ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
  "xmlhttprequest", "ping", "csp_report", "media", "websocket", "other"];

/** Validated profile from storage, or null when absent or invalid. */
async function storedState() {
  const { profile, enabled } = await chrome.storage.local.get(["profile", "enabled"]);
  let valid = null;
  try { if (profile !== undefined) valid = parseProfile(profile, CATALOG); } catch { /* treated as no profile */ }
  return { profile: valid, enabled: enabled === true };
}

// Only the fields this extension sets; Chrome may report others (css, excludeMatches) too.
const sameScript = (a, b) => Object.keys(b).every((k) => JSON.stringify(a[k]) === JSON.stringify(b[k]));
const sameRule = (a, b) => JSON.stringify(normalizeRule(a)) === JSON.stringify(normalizeRule(b));
const normalizeRule = (r) => r && {
  id: r.id, priority: r.priority,
  headers: r.action?.requestHeaders?.map((h) => [h.header.toLowerCase(), h.operation, h.value]),
  domains: r.condition?.requestDomains, types: [...(r.condition?.resourceTypes ?? [])].sort(),
};

/** Content script step. Never unregister-then-register: tabs restored at startup load while
 * this runs, and a gap would let them read native values. Returns what it did. */
async function applyScript(profile) {
  const [existing] = await chrome.scripting.getRegisteredContentScripts({ ids: [SCRIPT_ID] });
  if (!profile) {
    if (!existing) return "none";
    await chrome.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] });
    return "unregistered";
  }
  const script = {
    id: SCRIPT_ID,
    matches: ["https://claude.ai/*"],
    js: [zoneFile(profile.timeZone), localeFile(profile.locale), "core/override.js"],
    world: "MAIN",
    runAt: "document_start",
    allFrames: true,
    matchOriginAsFallback: true, // about:blank, srcdoc and blob: frames created by claude.ai
    persistAcrossSessions: true,
  };
  if (!existing) {
    await chrome.scripting.registerContentScripts([script]);
    return "registered";
  }
  if (sameScript(existing, script)) return "unchanged";
  await chrome.scripting.updateContentScripts([script]);
  return "updated";
}

/** Header step. removeRuleIds + addRules in one call is atomic; an equal rule is left alone. */
async function applyHeader(profile) {
  const [existing] = await chrome.declarativeNetRequest.getDynamicRules({ ruleIds: [RULE_ID] });
  const rule = profile && {
    id: RULE_ID,
    priority: 1,
    action: {
      type: "modifyHeaders",
      requestHeaders: [{ header: "Accept-Language", operation: "set", value: ACCEPT_LANGUAGE[profile.locale] }],
    },
    // Listed explicitly: without resourceTypes a rule skips main_frame, the page request itself.
    condition: { requestDomains: ["claude.ai"], resourceTypes: RESOURCE_TYPES },
  };
  if (!rule && !existing) return "none";
  if (rule && existing && sameRule(existing, rule)) return "unchanged";
  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [RULE_ID], addRules: rule ? [rule] : [] });
  return rule ? "set" : "removed";
}

const settle = (p) => p.then((done) => ({ ok: true, done }), (e) => ({ ok: false, error: String(e?.message ?? e) }));

/** Both steps run even if one fails, so the popup can report each. */
async function applyNow() {
  const { profile, enabled } = await storedState();
  const target = enabled ? profile : null;
  const script = await settle(applyScript(target));
  const header = await settle(applyHeader(target));
  return { ok: script.ok && header.ok, active: target !== null, script, header };
}

// Serialized: overlapping triggers (startup, storage change, popup) run one after another.
let queue = Promise.resolve();
function apply() {
  const run = queue.then(applyNow);
  queue = run.catch(() => {});
  return run;
}

chrome.runtime.onInstalled.addListener(() => { apply(); });
chrome.runtime.onStartup.addListener(() => { apply(); });
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && ("profile" in changes || "enabled" in changes)) apply();
});
// The popup asks after writing storage so it can report whether both steps took effect.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || message?.type !== "apply") return false;
  apply().then(sendResponse, (error) => sendResponse({ ok: false, error: String(error?.message ?? error) }));
  return true;
});
