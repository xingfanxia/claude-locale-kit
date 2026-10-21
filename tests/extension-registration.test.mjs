// The content script registration must never have a gap: an apply that finds the correct
// registration leaves it alone, a profile change updates it in place, and it outlives both the
// service worker and the browser process.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { setState, extensionWorker, stopServiceWorker, instrumentWorker, workerMutations } from "./helpers/extension.mjs";
import { startSession, profile, CHATHAM } from "./helpers/fixtures.mjs";

let s;
before(async () => {
  s = await startSession();
  await setState(s.context, s.extensionId, { profile: CHATHAM, enabled: true });
});
after(async () => { await s?.close(); });

/** First-read values of a fresh claude.ai tab. */
async function firstRead() {
  const page = await s.context.newPage();
  await page.goto("https://claude.ai/");
  const read = await page.evaluate(() => window.__read);
  await page.close();
  return read;
}

test("after a service worker restart, an apply with nothing to change touches nothing, even mid-navigation", async () => {
  const worker = extensionWorker(s.context, s.extensionId);
  await stopServiceWorker(s.context);
  // The registration lives in the browser, not the worker: a load while it is stopped is covered.
  assert.equal((await firstRead()).timeZone, "Pacific/Chatham");

  const popup = await s.context.newPage();
  await popup.goto(`chrome-extension://${s.extensionId}/popup.html`);
  await popup.evaluate(() => chrome.runtime.sendMessage({ type: "wake" }).catch(() => {})); // starts a new instance
  await instrumentWorker(worker);

  // The same apply() that onStartup and onInstalled run, racing a claude.ai navigation.
  const page = await s.context.newPage();
  const [, res] = await Promise.all([
    page.goto("https://claude.ai/"),
    popup.evaluate(() => chrome.runtime.sendMessage({ type: "apply" })),
  ]);
  assert.equal((await page.evaluate(() => window.__read)).timeZone, "Pacific/Chatham");
  assert.deepEqual(res.script, { ok: true, done: "unchanged" });
  assert.deepEqual(res.header, { ok: true, done: "unchanged" });
  assert.deepEqual(await workerMutations(worker), [], "no register, update, unregister or rule write");
  await page.close();
  await popup.close();
});

test("changing the profile while enabled updates the registration in place", async () => {
  const worker = extensionWorker(s.context, s.extensionId);
  await instrumentWorker(worker);
  const res = await setState(s.context, s.extensionId, { profile: profile("Asia/Kolkata", "hi-IN") });
  assert.equal(res.ok, true);
  // storage.onChanged and the popup message both apply; the second finds nothing left to do.
  assert.deepEqual(await workerMutations(worker), ["updateContentScripts", "updateDynamicRules"]);
  const read = await firstRead();
  assert.match(read.timeZone, /^Asia\/(Kolkata|Calcutta)$/);
  assert.equal(read.language, "hi-IN");
  await setState(s.context, s.extensionId, { profile: CHATHAM });
});

test("the registration survives a browser restart and covers its first page load", async () => {
  await s.relaunch();
  s.server.seen.length = 0;
  const read = await firstRead();
  assert.equal(read.timeZone, "Pacific/Chatham");
  assert.equal(read.language, "de-DE");
  const page = s.server.seen.find((r) => r.host === "claude.ai" && r.path === "/");
  assert.equal(page.acceptLanguage, "de-DE,de;q=0.9");
});
