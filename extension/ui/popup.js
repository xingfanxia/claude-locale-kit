// Popup and options page. Storage keys: `profile` (v1 JSON object) and `enabled` (boolean).
// After every write it asks the background to apply, so the status line reflects the result.
import { parseProfile, parseProfileText, profileJSON, ProfileError, SCHEMA_ID, CURRENT_VERSION } from "../core/profile.js";
import { readActiveClaudeTab, compare } from "./check.js";
import { TIME_ZONES, LEGACY_TIME_ZONES, LOCALES, LANGUAGES, ACCEPT_LANGUAGE } from "../generated/catalog.js";

const CATALOG = { timeZones: TIME_ZONES, locales: LOCALES };
const t = (key, ...subs) => chrome.i18n.getMessage(key, subs.map(String));
const $ = (id) => document.getElementById(id);
const uiLang = chrome.i18n.getUILanguage();

const state = { profile: null, enabled: false, activeIndex: -1, visible: [] };

// ---- static text --------------------------------------------------------------------------
for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
for (const el of document.querySelectorAll("[data-i18n-placeholder]")) el.placeholder = t(el.dataset.i18nPlaceholder);
document.documentElement.lang = uiLang;

// ---- zone catalog with current offsets ----------------------------------------------------
function offsetMinutes(timeZone, at) {
  const name = new Intl.DateTimeFormat("en-US", { timeZone, timeZoneName: "longOffset" })
    .formatToParts(at).find((p) => p.type === "timeZoneName").value; // "GMT", "GMT+05:30"
  const m = /([+-])(\d\d):(\d\d)/.exec(name);
  return m ? (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : 0;
}
function offsetLabel(min) {
  const sign = min > 0 ? "+" : min < 0 ? "−" : "±";
  const a = Math.abs(min);
  return `${sign}${String(Math.floor(a / 60)).padStart(2, "0")}:${String(a % 60).padStart(2, "0")}`;
}
const now = new Date();
const zones = TIME_ZONES.map((id) => {
  const parts = id.split("/");
  const offset = offsetMinutes(id, now);
  const label = offsetLabel(offset);
  const city = parts.at(-1).replaceAll("_", " ");
  const region = parts.slice(0, -1).join(" / ").replaceAll("_", " ");
  // Matches "+05:30", "+5:30", "utc+05:30", and "+00:00"/"-00:00" for zero offsets.
  const ascii = offset === 0 ? "+00:00 -00:00" : label.replace("−", "-");
  const haystack = `${id} ${city} ${region} ${ascii} ${ascii.replace(/([+-])0/g, "$1")} utc${ascii}`.toLowerCase();
  return { id, city, region, offset, label, haystack, legacy: LEGACY_TIME_ZONES.includes(id) };
}).sort((a, b) => a.offset - b.offset || a.id.localeCompare(b.id));

const list = $("zone-list");
const search = $("zone-search");
for (const [i, z] of zones.entries()) {
  const li = document.createElement("li");
  li.role = "option";
  li.id = `zone-${i}`;
  li.dataset.zone = z.id;
  const name = document.createElement("span");
  name.className = "zone-name";
  name.textContent = z.city;
  if (z.region) {
    const region = document.createElement("span");
    region.className = "zone-region";
    region.textContent = z.region;
    name.append(" ", region);
  }
  const off = document.createElement("span");
  off.className = "zone-offset";
  off.textContent = z.label;
  li.append(name, off);
  z.el = li;
  list.append(li);
}

// Combobox: the input shows the chosen zone; focusing it opens the list, typing filters it.
function filterZones(query) {
  const terms = query.trim().toLowerCase().replaceAll("\u2212", "-").split(/\s+/).filter(Boolean);
  state.visible = [];
  for (const z of zones) {
    // Older ICU names (Asia/Calcutta) stay listed only while an imported profile uses one.
    const show = (!z.legacy || z.id === state.profile?.timeZone) && terms.every((term) => z.haystack.includes(term));
    z.el.hidden = !show;
    if (show) state.visible.push(z);
  }
  $("zone-empty").hidden = state.visible.length > 0;
  $("zone-empty").textContent = state.visible.length ? "" : t("zoneNoMatch", query.trim());
  setActive(terms.length ? 0 : state.visible.findIndex((z) => z.id === state.profile?.timeZone), "nearest");
}
function setActive(index, scroll) {
  const prev = state.visible[state.activeIndex];
  if (prev) prev.el.classList.remove("active");
  state.activeIndex = index;
  const cur = state.visible[index];
  if (cur) {
    cur.el.classList.add("active");
    search.setAttribute("aria-activedescendant", cur.el.id);
    if (scroll) cur.el.scrollIntoView({ block: scroll });
  } else {
    search.removeAttribute("aria-activedescendant");
  }
}
function markSelected() {
  for (const z of zones) z.el.setAttribute("aria-selected", String(z.id === state.profile?.timeZone));
}
const isOpen = () => search.getAttribute("aria-expanded") === "true";
function openList() {
  if (isOpen()) return;
  search.setAttribute("aria-expanded", "true");
  $("zone-popover").hidden = false;
  filterZones("");
  state.visible[state.activeIndex]?.el.scrollIntoView({ block: "center" });
  search.select();
}
function closeList() {
  search.setAttribute("aria-expanded", "false");
  $("zone-popover").hidden = true;
  search.removeAttribute("aria-activedescendant");
  search.value = state.profile.timeZone;
}
function choose(zone) {
  closeList();
  updateProfile({ timeZone: zone });
}

search.addEventListener("focus", openList);
search.addEventListener("click", openList);
search.addEventListener("blur", closeList);
search.addEventListener("input", () => { if (!isOpen()) openList(); filterZones(search.value); });
search.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && isOpen()) { e.preventDefault(); closeList(); search.select(); return; }
  if (!isOpen()) { if (e.key === "ArrowDown" || e.key === "ArrowUp") openList(); return; }
  const n = state.visible.length;
  if (!n) return;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    const step = e.key === "ArrowDown" ? 1 : -1;
    setActive(state.activeIndex < 0 ? 0 : (state.activeIndex + step + n) % n, "nearest");
  } else if (e.key === "Enter" && state.activeIndex >= 0) {
    e.preventDefault();
    choose(state.visible[state.activeIndex].id);
  }
});
// Keep focus in the input while clicking a row, so blur does not close the list first.
list.addEventListener("mousedown", (e) => e.preventDefault());
list.addEventListener("click", (e) => {
  const li = e.target.closest("li[data-zone]");
  if (li) choose(li.dataset.zone);
});

// ---- locales ------------------------------------------------------------------------------
const select = $("locale");
const names = new Intl.DisplayNames([uiLang], { type: "language" });
for (const code of [...LOCALES].sort((a, b) => names.of(a).localeCompare(names.of(b), uiLang))) {
  select.append(new Option(t("localeOption", names.of(code), code), code));
}
select.addEventListener("change", () => updateProfile({ locale: select.value }));

// ---- preview ------------------------------------------------------------------------------
function zoneName(timeZone, locale, at) {
  const part = new Intl.DateTimeFormat(locale, { timeZone, timeZoneName: "long" })
    .formatToParts(at).find((p) => p.type === "timeZoneName");
  return part ? part.value : timeZone;
}
function renderPreview() {
  const at = new Date();
  const on = state.enabled && state.profile;
  const timeZone = on ? state.profile.timeZone : Intl.DateTimeFormat().resolvedOptions().timeZone;
  const locale = on ? state.profile.locale : navigator.language;
  const languages = on ? LANGUAGES[state.profile.locale] : navigator.languages;
  $("preview").classList.toggle("off", !on);
  $("preview-heading").textContent = on ? t("previewOn") : t("previewOff");
  $("clock").textContent = new Intl.DateTimeFormat(locale, { timeZone, hour: "numeric", minute: "2-digit" }).format(at);
  $("date").textContent = new Intl.DateTimeFormat(locale, { timeZone, dateStyle: "full" }).format(at);
  $("offset").textContent = `UTC${offsetLabel(offsetMinutes(timeZone, at))}`;
  $("fact-zone").textContent = zoneName(timeZone, locale, at);
  $("fact-zone").title = timeZone;
  $("fact-languages").textContent = languages.join(", ");
  $("fact-header").textContent = on ? ACCEPT_LANGUAGE[state.profile.locale] : t("previewHeaderNative");
}
function scheduleTick() {
  setTimeout(() => { renderPreview(); scheduleTick(); }, 1000 - (Date.now() % 1000) + 5);
}

// ---- state --------------------------------------------------------------------------------
function defaultProfile() {
  const host = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const lang = navigator.language;
  const locale = LOCALES.includes(lang) ? lang
    : LOCALES.find((l) => l.split("-")[0] === lang.split("-")[0]) ?? "en-US";
  return { schema: SCHEMA_ID, version: CURRENT_VERSION, timeZone: TIME_ZONES.includes(host) ? host : "UTC", locale };
}
function render() {
  $("enabled").checked = state.enabled;
  select.value = state.profile.locale;
  markSelected();
  if (!isOpen()) search.value = state.profile.timeZone;
  renderPreview();
}
function setStatus(text, kind = "info") {
  const el = $("status");
  el.textContent = text;
  el.dataset.kind = kind;
}
async function save(values, okMessage) {
  await chrome.storage.local.set(values);
  // The reload prompt in okMessage only appears once both the script and the header step worked.
  const res = await chrome.runtime.sendMessage({ type: "apply" });
  if (res?.ok) setStatus(okMessage);
  else if (res?.script && !res.script.ok) setStatus(t("scriptStepFailed", res.script.error), "error");
  else if (res?.header && !res.header.ok) setStatus(t("headerStepFailed", res.header.error), "error");
  else setStatus(t("applyFailed", res?.error ?? "?"), "error");
}
function updateProfile(change) {
  state.profile = { ...state.profile, ...change };
  render();
  save({ profile: state.profile }, state.enabled ? t("savedOn") : t("savedOff"));
}

$("enabled").addEventListener("change", (e) => {
  state.enabled = e.target.checked;
  renderPreview();
  // Saving the shown profile too: on first use it is a default nobody has stored yet.
  save({ enabled: state.enabled, profile: state.profile }, state.enabled ? t("turnedOn") : t("turnedOff"));
});

$("reload").addEventListener("click", async () => {
  const tabs = await chrome.tabs.query({ url: "https://claude.ai/*" });
  await Promise.all(tabs.map((tab) => chrome.tabs.reload(tab.id)));
  setStatus(tabs.length ? t("reloadedTabs", tabs.length) : t("noTabs"));
});

$("check").addEventListener("click", async () => {
  $("check-result").hidden = true;
  const read = await readActiveClaudeTab();
  if (read.kind === "notClaude") return setStatus(t("checkNotClaude"), "error");
  if (read.kind === "error") return setStatus(t("checkFailed", read.error), "error");
  const rows = compare(read.observed, state.profile, LANGUAGES[state.profile.locale], offsetMinutes, read.at);
  const body = $("check-rows");
  body.replaceChildren(...rows.map((row) => {
    const tr = document.createElement("tr");
    tr.dataset.key = row.key;
    tr.dataset.match = String(row.match);
    const label = document.createElement("th");
    label.scope = "row";
    label.textContent = t(`checkRow_${row.key}`);
    const observed = document.createElement("td");
    observed.textContent = row.observed;
    const selected = document.createElement("td");
    const mark = document.createElement("span");
    mark.className = "mark";
    mark.textContent = row.match ? "\u2713" : "\u2260";
    mark.title = t(row.match ? "checkMatch" : "checkMismatch");
    mark.setAttribute("aria-label", mark.title);
    selected.append(row.selected, " ", mark);
    tr.append(label, observed, selected);
    return tr;
  }));
  const notes = [];
  const zone = rows.find((r) => r.key === "timeZone");
  if (zone.alias) notes.push(t("checkAlias", zone.observed, zone.selected));
  if (!state.enabled) notes.push(t("checkOff"));
  notes.push(t("checkScope"));
  $("check-notes").replaceChildren(...notes.map((n) => Object.assign(document.createElement("span"), { textContent: n + " " })));
  $("check-result").hidden = false;
  setStatus(t("checkDone"));
  $("check-result").scrollIntoView({ block: "nearest" });
});

$("export").addEventListener("click", () => {
  const url = URL.createObjectURL(new Blob([profileJSON(state.profile)], { type: "application/json" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = "claude-locale-profile.json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  setStatus(t("exported"));
});

// A file chooser can close the action popup before the file arrives, so the popup hands
// Import to the same page opened in a tab.
const inTab = (await chrome.tabs.getCurrent()) !== undefined;
$("import").addEventListener("click", () => {
  if (inTab) $("import-file").click();
  else chrome.tabs.create({ url: chrome.runtime.getURL("popup.html#import") });
});
$("import-file").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  e.target.value = "";
  if (!file) return;
  let text;
  try { text = await file.text(); } catch { setStatus(t("errReadFile"), "error"); return; }
  try {
    state.profile = parseProfileText(text, CATALOG);
  } catch (err) {
    setStatus(errorMessage(err), "error");
    return;
  }
  render();
  save({ profile: state.profile }, t("imported", state.profile.timeZone, state.profile.locale));
});
function errorMessage(err) {
  if (!(err instanceof ProfileError)) return String(err);
  const key = "err" + err.code[0].toUpperCase() + err.code.slice(1);
  return t(key, err.detail);
}

// ---- start --------------------------------------------------------------------------------
const stored = await chrome.storage.local.get(["profile", "enabled"]);
try { state.profile = parseProfile(stored.profile, CATALOG); } catch { state.profile = defaultProfile(); }
state.enabled = stored.enabled === true;
document.body.classList.toggle("in-tab", inTab);
render();
scheduleTick();
if (inTab && location.hash === "#import") {
  setStatus(t("importOpensTab"));
  $("import").focus();
}
