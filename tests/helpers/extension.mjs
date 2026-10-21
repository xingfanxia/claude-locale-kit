// Launches Playwright's Chromium with dist/extension loaded in a throwaway profile. The browser's
// host resolver maps the fixture names to local HTTPS servers and fails every other name, and TLS
// errors are ignored only for the fixture certificates' public keys. That covers what the page
// and the extension fetch through the browser's network stack; it is not an OS-level firewall.
import { execFileSync } from "node:child_process";
import { X509Certificate, createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium } from "playwright";
import { ROOT } from "../../scripts/catalog.mjs";

export const EXTENSION_DIR = join(ROOT, "dist/extension");
export const HOST_ZONE = "America/New_York";

/** `npm test` builds dist/extension once before the parallel test files start; a test file run
 * on its own uses whatever `npm run build` last produced. */
export function requireBuild() {
  if (!existsSync(join(EXTENSION_DIR, "manifest.json"))) throw new Error("dist/extension is missing; run npm run build");
}

export const newUserDataDir = () => mkdtempSync(join(tmpdir(), "claude-locale-kit-e2e-"));
export const removeUserDataDir = (dir) => rmSync(dir, { recursive: true, force: true });

/**
 * @param {Record<string, number>} hosts fixture host name -> local port
 * @param {string[]} pins base64 SHA-256 SPKI hashes of certificates to accept despite being self-signed
 * @returns {Promise<{context: import("playwright").BrowserContext, extensionId: string}>}
 */
export async function launch(userDataDir, { hosts = {}, pins = [] } = {}) {
  const rules = [...Object.entries(hosts).map(([host, port]) => `MAP ${host} 127.0.0.1:${port}`), "MAP * ~NOTFOUND"];
  const context = await chromium.launchPersistentContext(userDataDir, {
    channel: "chromium", // the full build runs extensions in new headless mode; headless shell cannot
    headless: true,
    env: { ...process.env, TZ: HOST_ZONE },
    args: [
      `--disable-extensions-except=${EXTENSION_DIR}`,
      `--load-extension=${EXTENSION_DIR}`,
      "--lang=en-US",
      `--host-resolver-rules=${rules.join(", ")}`,
      ...(pins.length ? [`--ignore-certificate-errors-spki-list=${pins.join(",")}`] : []),
    ],
  });
  let [worker] = context.serviceWorkers();
  worker ??= await context.waitForEvent("serviceworker");
  return { context, extensionId: new URL(worker.url()).host };
}

/**
 * HTTPS server with its own throwaway self-signed certificate (written under `dir/name`). Request
 * headers are recorded as the server receives them, after Chrome and declarativeNetRequest set
 * them, which Playwright's route() cannot show. Records `{host, path, acceptLanguage}`; `spki` is
 * the value for launch()'s `pins`.
 */
export async function startServer(pages, dir, name = "fixture") {
  const key = join(dir, `${name}-key.pem`);
  const cert = join(dir, `${name}-cert.pem`);
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
    "-days", "1", "-subj", `/CN=${name}`], { stdio: "ignore" });
  const certPem = readFileSync(cert);
  const spkiDer = new X509Certificate(certPem).publicKey.export({ type: "spki", format: "der" });
  const spki = createHash("sha256").update(spkiDer).digest("base64");
  const seen = [];
  const server = createServer({ key: readFileSync(key), cert: certPem }, (req, res) => {
    const path = new URL(req.url, "https://x").pathname;
    seen.push({ host: req.headers.host, path, acceptLanguage: req.headers["accept-language"] });
    const body = pages[path];
    res.writeHead(body === undefined ? 404 : 200, {
      "content-type": path.endsWith(".json") ? "application/json"
        : path.endsWith(".js") ? "application/javascript; charset=utf-8" : "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(body ?? "");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const close = () => { server.closeAllConnections(); return new Promise((r) => server.close(r)); };
  return { port: server.address().port, spki, seen, close };
}

/** Opens the popup page as a tab and runs `fn(arg)` in it with extension API access. */
export async function inExtensionPage(context, extensionId, fn, arg) {
  const page = await context.newPage();
  await page.goto(`chrome-extension://${extensionId}/popup.html`);
  try {
    return await page.evaluate(fn, arg);
  } finally {
    await page.close();
  }
}

/** Stores the profile and enabled flag the way the popup does, then waits for the background. */
export function setState(context, extensionId, values) {
  return inExtensionPage(context, extensionId, async (v) => {
    await chrome.storage.local.set(v);
    return chrome.runtime.sendMessage({ type: "apply" });
  }, values);
}

export const extensionWorker = (context, extensionId) =>
  context.serviceWorkers().find((w) => w.url().startsWith(`chrome-extension://${extensionId}/`));

/** Stops the extension's service worker the way Chrome does when it goes idle. Playwright keeps
 * the same Worker handle and attaches it to the next instance. */
export async function stopServiceWorker(context) {
  const page = await context.newPage();
  await page.goto("chrome://serviceworker-internals/");
  await page.getByText("Stop", { exact: true }).first().click();
  await page.waitForFunction(() => /Running Status: STOPPED/.test(document.body.innerText));
  await page.close();
}

const MUTATORS = { scripting: ["registerContentScripts", "updateContentScripts", "unregisterContentScripts"],
  declarativeNetRequest: ["updateDynamicRules"] };

/** Records every call the running worker instance makes to the registration/rule mutators. Wraps
 * them once per worker instance; later calls only clear the record. */
export function instrumentWorker(worker) {
  return worker.evaluate((mutators) => {
    self.__mutations = [];
    if (self.__instrumented) return;
    self.__instrumented = true;
    for (const [ns, names] of Object.entries(mutators)) {
      for (const name of names) {
        const original = chrome[ns][name];
        chrome[ns][name] = (...args) => { self.__mutations.push(name); return original.apply(chrome[ns], args); };
      }
    }
  }, MUTATORS);
}
export const workerMutations = (worker) => worker.evaluate(() => self.__mutations);
