// The popup page driven like a user: pick a zone and locale, toggle, import, export. Runs the
// page as a tab (where Import opens the file chooser directly) against the built extension.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "../scripts/catalog.mjs";
import { requireBuild, launch, newUserDataDir, removeUserDataDir } from "./helpers/extension.mjs";

let tempDir, context, extensionId, page;
const stored = () => page.evaluate(() => chrome.storage.local.get(["profile", "enabled"]));
const registered = () => page.evaluate(() => chrome.scripting.getRegisteredContentScripts());
const status = () => page.getByTestId("status").textContent();

before(async () => {
  requireBuild();
  tempDir = newUserDataDir();
  ({ context, extensionId } = await launch(join(tempDir, "profile")));
  page = await context.newPage();
  await page.goto(`chrome-extension://${extensionId}/popup.html`);
  await page.getByTestId("zone-list").locator("li").first().waitFor({ state: "attached" });
});
after(async () => {
  await context?.close();
  removeUserDataDir(tempDir);
});

test("nothing is stored or registered until the user acts", async () => {
  assert.deepEqual(await stored(), {});
  assert.deepEqual(await registered(), []);
  assert.equal(await page.getByTestId("enabled").isChecked(), false);
});

test("searching and pressing Enter picks a zone; choosing a locale saves it", async () => {
  await page.getByTestId("zone-search").fill("chatham");
  const visible = page.getByTestId("zone-list").locator("li:visible");
  assert.equal(await visible.count(), 1);
  await page.getByTestId("zone-search").press("Enter");
  await page.getByTestId("locale").selectOption("de-DE");
  await page.waitForFunction(() => chrome.storage.local.get("profile").then((s) => s.profile?.locale === "de-DE"));
  const { profile, enabled } = await stored();
  assert.deepEqual(profile, { schema: "claude-locale-kit/profile", version: 1, timeZone: "Pacific/Chatham", locale: "de-DE" });
  assert.equal(enabled, undefined);
  assert.deepEqual(await registered(), [], "saving while off registers nothing");
});

test("offset search matches +05:30 and 5:30", async () => {
  for (const q of ["+05:30", "5:30", "utc+05:30"]) {
    await page.getByTestId("zone-search").fill(q);
    const names = await page.getByTestId("zone-list").locator("li:visible").evaluateAll((els) => els.map((e) => e.dataset.zone));
    assert.ok(names.includes("Asia/Kolkata"), q);
    assert.ok(!names.includes("Asia/Calcutta"), "legacy alias hidden");
  }
  await page.getByTestId("zone-search").fill("");
});

test("the switch turns the override on and off", async () => {
  await page.getByTestId("enabled").check();
  await page.waitForFunction(() => chrome.scripting.getRegisteredContentScripts().then((s) => s.length === 1));
  assert.equal((await stored()).enabled, true);
  assert.match(await page.getByTestId("preview").textContent(), /de-DE,de;q=0\.9/);
  await page.getByTestId("enabled").uncheck();
  await page.waitForFunction(() => chrome.scripting.getRegisteredContentScripts().then((s) => s.length === 0));
  assert.equal((await stored()).enabled, false);
});

test("import rejects an invalid profile with a specific message and keeps the old one", async () => {
  const bad = join(tempDir, "bad.json");
  writeFileSync(bad, readFileSync(join(ROOT, "profile/fixtures/invalid/version-string.json")));
  await page.getByTestId("import").click();
  await page.locator("#import-file").setInputFiles(bad);
  await page.waitForFunction(() => document.querySelector("[data-testid=status]").dataset.kind === "error");
  assert.equal(await status(), "“version” has the wrong type.");
  assert.equal((await stored()).profile.timeZone, "Pacific/Chatham");
});

test("import accepts a valid profile and keeps its cli block; export writes it back", async () => {
  const good = join(ROOT, "profile/fixtures/valid/full.json");
  await page.locator("#import-file").setInputFiles(good);
  await page.waitForFunction(() => chrome.storage.local.get("profile").then((s) => s.profile?.timeZone === "America/Los_Angeles"));
  assert.deepEqual((await stored()).profile, JSON.parse(readFileSync(good, "utf8")));
  assert.equal(await page.getByTestId("locale").inputValue(), "en-US");

  const [download] = await Promise.all([page.waitForEvent("download"), page.getByTestId("export").click()]);
  assert.equal(download.suggestedFilename(), "claude-locale-profile.json");
  const path = join(tempDir, "export.json");
  await download.saveAs(path);
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), JSON.parse(readFileSync(good, "utf8")));
});

test("reload with no claude.ai tabs says so", async () => {
  await page.getByTestId("reload").click();
  await page.waitForFunction(() => document.querySelector("[data-testid=status]").textContent.startsWith("No claude.ai"));
});
