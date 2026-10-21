// End-to-end: the built extension in Playwright's Chromium against local fixture servers for
// claude.ai and example.com (see helpers/fixtures.mjs). What pages read, which frames are
// covered, the Accept-Language header, and the test browser's own isolation.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { HOST_ZONE, setState, inExtensionPage } from "./helpers/extension.mjs";
import { startSession, profile, CHATHAM, assertNative } from "./helpers/fixtures.mjs";

let s;
before(async () => { s = await startSession(); });
after(async () => { await s?.close(); });
const set = (values) => setState(s.context, s.extensionId, values);

test("test browser: unmapped names do not resolve and only the pinned certificate is accepted", async () => {
  // One page per rejected navigation: a second goto on a page showing a net error page stalls.
  // The short timeout keeps a stall from passing as a rejection; the regexes name the real error.
  for (const [url, error] of [["https://unmapped.example.net/", /ERR_NAME_NOT_RESOLVED/],
    ["https://untrusted.test/", /ERR_CERT_AUTHORITY_INVALID/]]) {
    const page = await s.context.newPage();
    await assert.rejects(page.goto(url, { timeout: 5000 }), error);
    await page.close();
  }
  assert.equal(s.untrusted.seen.filter((r) => r.path === "/").length, 0, "no request completed on the unpinned server");
});

test("before any profile, claude.ai reads the browser's own values", async () => {
  const { top, headers } = await s.visit("https://claude.ai/");
  assertNative(top);
  for (const h of headers) assert.match(h.acceptLanguage, /^en-US/);
});

test("first page load after enabling reads the profile in the page and its iframe", async () => {
  const res = await set({ profile: CHATHAM, enabled: true });
  assert.equal(res.ok, true);
  assert.equal(res.active, true);
  const { top, frame, headers } = await s.visit("https://claude.ai/");
  for (const read of [top, frame]) {
    assert.equal(read.timeZone, "Pacific/Chatham");
    assert.equal(read.offset, -825); // +13:45, Chatham daylight time in January
    assert.equal(read.language, "de-DE");
    assert.deepEqual(read.languages, ["de-DE", "de"]);
    assert.match(read.string, /^Fri Jan 16 2026 01:45:00 GMT\+1345 /);
  }
  assert.deepEqual(new Set(headers.map((h) => h.path)), new Set(["/", "/frame", "/api.json"]));
  for (const h of headers) assert.equal(h.acceptLanguage, "de-DE,de;q=0.9", h.path);
});

test("a second profile applies to the page and the header", async () => {
  await set({ profile: profile("Asia/Kolkata", "hi-IN"), enabled: true });
  const { top, headers } = await s.visit("https://claude.ai/");
  assert.match(top.timeZone, /^Asia\/(Kolkata|Calcutta)$/);
  assert.equal(top.offset, -330);
  assert.deepEqual(top.languages, ["hi-IN", "hi"]);
  for (const h of headers) assert.equal(h.acceptLanguage, "hi-IN,hi;q=0.9", h.path);
});

test("frames claude.ai creates itself are covered; Web Workers are not (documented scope)", async () => {
  await set({ profile: CHATHAM, enabled: true });
  const page = await s.context.newPage();
  await page.goto("https://claude.ai/made-frames");
  await page.waitForFunction(() => window.__srcdoc);
  const got = await page.evaluate(async () => ({
    blank: window.__blank,
    srcdoc: window.__srcdoc,
    worker: await new Promise((resolve, reject) => {
      const w = new Worker("/worker.js");
      const timer = setTimeout(() => reject(new Error("worker: no message within 5 s")), 5000);
      w.onmessage = (e) => { clearTimeout(timer); resolve(e.data); };
      w.onerror = w.onmessageerror = (e) => { clearTimeout(timer); reject(new Error(`worker failed: ${e.message ?? e.type}`)); };
    }),
  }));
  await page.close();
  const chatham = { timeZone: "Pacific/Chatham", language: "de-DE", offset: -825 };
  assert.deepEqual(got.blank, chatham, "about:blank iframe");
  assert.deepEqual(got.srcdoc, chatham, "srcdoc iframe");
  assert.deepEqual(got.worker, { timeZone: HOST_ZONE, language: "en-US" });
});

test("other sites keep native values and headers", async () => {
  await set({ profile: CHATHAM, enabled: true });
  const { top, frame, headers } = await s.visit("https://example.com/");
  assertNative(top);
  assertNative(frame);
  for (const h of headers) assert.match(h.acceptLanguage, /^en-US/, h.path);
});

test("registration and rule are exactly the expected ones", async () => {
  await set({ profile: CHATHAM, enabled: true });
  const state = await inExtensionPage(s.context, s.extensionId, async () => ({
    scripts: await chrome.scripting.getRegisteredContentScripts(),
    rules: await chrome.declarativeNetRequest.getDynamicRules(),
  }));
  assert.equal(state.scripts.length, 1);
  const [script] = state.scripts;
  assert.equal(script.id, "claude-locale");
  assert.deepEqual(script.matches, ["https://claude.ai/*"]);
  assert.deepEqual(script.js, ["presets/tz/Pacific__Chatham.js", "presets/locale/de-DE.js", "core/override.js"]);
  assert.equal(script.world, "MAIN");
  assert.equal(script.runAt, "document_start");
  assert.equal(script.allFrames, true);
  assert.equal(script.matchOriginAsFallback, true);
  assert.equal(script.persistAcrossSessions, true);
  assert.equal(state.rules.length, 1);
  assert.deepEqual(state.rules[0].condition.requestDomains, ["claude.ai"]);
});

test("disabling restores native values and headers after reload", async () => {
  const res = await set({ enabled: false });
  assert.deepEqual([res.ok, res.active], [true, false]);
  const { top, frame, headers } = await s.visit("https://claude.ai/");
  assertNative(top);
  assertNative(frame);
  for (const h of headers) assert.match(h.acceptLanguage, /^en-US/, h.path);
  const state = await inExtensionPage(s.context, s.extensionId, async () => ({
    scripts: await chrome.scripting.getRegisteredContentScripts(),
    rules: await chrome.declarativeNetRequest.getDynamicRules(),
  }));
  assert.deepEqual(state, { scripts: [], rules: [] });
});

test("an invalid stored profile is never applied", async () => {
  const res = await set({ profile: { ...CHATHAM, timeZone: "Mars/Olympus" }, enabled: true });
  assert.deepEqual([res.ok, res.active], [true, false]);
  assertNative((await s.visit("https://claude.ai/")).top);
});

test("Reload claude.ai tabs finds and reloads only claude.ai tabs (host permission, no tabs permission)", async () => {
  const claude = await s.context.newPage();
  await claude.goto("https://claude.ai/");
  const other = await s.context.newPage();
  await other.goto("https://example.com/");
  await claude.evaluate(() => { window.__marker = 1; });
  await other.evaluate(() => { window.__marker = 1; });
  const popup = await s.context.newPage();
  await popup.goto(`chrome-extension://${s.extensionId}/popup.html`);
  const reloaded = claude.waitForEvent("load");
  await popup.getByTestId("reload").click();
  await reloaded;
  await popup.waitForFunction(() => document.querySelector("[data-testid=status]").textContent !== "");
  assert.equal(await popup.getByTestId("status").textContent(), "Reloaded claude.ai tabs: 1.");
  assert.equal(await claude.evaluate(() => window.__marker), undefined);
  assert.equal(await other.evaluate(() => window.__marker), 1);
  for (const p of [claude, other, popup]) await p.close();
});

test("Check current Claude tab reads only the fixed values from the active claude.ai tab, on click", async () => {
  await set({ profile: CHATHAM, enabled: true });
  const popup = await s.context.newPage();
  await popup.goto(`chrome-extension://${s.extensionId}/popup.html`);
  // Active tab is the popup page itself: not claude.ai, so nothing is read.
  await popup.getByTestId("check").click();
  await popup.waitForFunction(() => document.querySelector("[data-testid=status]").textContent.length > 0);
  assert.equal(await popup.getByTestId("check-result").isHidden(), true);
  // Make the fixture claude.ai tab the active tab of the same window, then click.
  const claude = await s.context.newPage();
  await claude.goto("https://claude.ai/");
  await claude.bringToFront();
  const keys = await popup.evaluate(() => import("./ui/check.js").then(async (m) => {
    const r = await m.readActiveClaudeTab();
    return { kind: r.kind, keys: Object.keys(r.observed ?? {}).sort(), expected: [...m.SURFACE_KEYS].sort() };
  }));
  assert.equal(keys.kind, "observed");
  assert.deepEqual(keys.keys, keys.expected, "the injected function returns exactly the fixed keys");
  await popup.evaluate(() => document.querySelector("[data-testid=check]").click());
  await popup.getByTestId("check-result").waitFor({ state: "visible" });
  const rows = await popup.evaluate(() => [...document.querySelectorAll("#check-rows tr")].map((tr) =>
    [tr.dataset.key, tr.dataset.match, tr.querySelector("td").textContent]));
  const byKey = Object.fromEntries(rows.map(([k, m, o]) => [k, { match: m, observed: o }]));
  assert.equal(byKey.timeZone.observed, "Pacific/Chatham");
  for (const k of ["timeZone", "locale", "timezoneOffset", "language", "languages", "dateString"]) assert.equal(byKey[k].match, "true", k);
  await claude.close();
  await popup.close();
});
