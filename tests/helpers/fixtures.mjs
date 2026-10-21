// Fixture pages and a browser session shared by the extension test files. The browser runs in
// HOST_ZONE with en-US; profiles pick other zones and locales.
import assert from "node:assert/strict";
import { join } from "node:path";
import { HOST_ZONE, launch, newUserDataDir, removeUserDataDir, requireBuild, startServer } from "./extension.mjs";

// Runs before any page script: the first inline script at the top of <head>.
const READ = `<script>window.__read = {
  timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  offset: new Date(2026, 0, 15, 12).getTimezoneOffset(),
  language: navigator.language,
  languages: [...navigator.languages],
  string: new Date(Date.UTC(2026, 0, 15, 12)).toString(),
};</script>`;

export const PAGES = {
  "/": `<!doctype html><html><head>${READ}</head><body><iframe src="/frame"></iframe></body></html>`,
  "/frame": `<!doctype html><html><head>${READ}</head><body>frame</body></html>`,
  "/api.json": "{}",
  // Frames the page creates itself, read synchronously from the parent before any load event.
  "/made-frames": `<!doctype html><html><head><script>
    const read = (w) => ({ timeZone: w.Intl.DateTimeFormat().resolvedOptions().timeZone, language: w.navigator.language,
      offset: new w.Date(2026, 0, 15, 12).getTimezoneOffset() });
    const blank = document.createElement("iframe");
    document.documentElement.append(blank);
    window.__blank = read(blank.contentWindow);
  </script></head><body><iframe srcdoc="<script>parent.__srcdoc = parent.__readFrame(window)</script>"></iframe>
  <script>window.__readFrame = read;</script></body></html>`,
  "/worker.js": "postMessage({ timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, language: navigator.language })",
};

export const profile = (timeZone, locale) => ({ schema: "claude-locale-kit/profile", version: 1, timeZone, locale });
export const CHATHAM = profile("Pacific/Chatham", "de-DE");

export const assertNative = (read) => {
  assert.equal(read.timeZone, HOST_ZONE);
  assert.equal(read.offset, 300);
  assert.equal(read.language, "en-US");
  assert.match(read.string, /GMT-0500/);
};

/**
 * Fixture servers plus a browser with the extension. claude.ai and example.com go to the pinned
 * fixture server; untrusted.test goes to a second server whose certificate is not pinned.
 */
export async function startSession() {
  requireBuild();
  const tempDir = newUserDataDir();
  const userDataDir = join(tempDir, "profile");
  const server = await startServer(PAGES, tempDir, "fixture");
  const untrusted = await startServer(PAGES, tempDir, "untrusted");
  const options = {
    hosts: { "claude.ai": server.port, "example.com": server.port, "untrusted.test": untrusted.port },
    pins: [server.spki],
  };
  const session = { server, untrusted, userDataDir };
  session.relaunch = async () => {
    await session.context?.close();
    Object.assign(session, await launch(userDataDir, options));
  };
  session.close = async () => {
    await session.context?.close();
    await server.close();
    await untrusted.close();
    removeUserDataDir(tempDir);
  };
  /** Loads `url` in a fresh tab; returns what the top frame and the iframe read, plus headers. */
  session.visit = async (url) => {
    server.seen.length = 0;
    const page = await session.context.newPage();
    await page.goto(url);
    await page.frames()[1]?.waitForLoadState();
    const top = await page.evaluate(() => window.__read);
    const frame = await page.frames()[1]?.evaluate(() => window.__read);
    // A page-initiated request after load, like claude.ai's own API calls.
    await page.evaluate(() => fetch("/api.json").then((r) => r.text()));
    const headers = server.seen.filter((s) => s.host === new URL(url).host);
    assert.ok(headers.length >= 3, "page, frame and fetch requests reached the fixture server");
    await page.close();
    return { top, frame, headers };
  };
  await session.relaunch();
  return session;
}
