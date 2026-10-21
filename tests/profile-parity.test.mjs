// The extension's validator must accept every profile/fixtures/valid file and reject every
// invalid one, the same verdicts the Swift ProfileCore tests assert on these files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, loadCatalog } from "../scripts/catalog.mjs";
import { parseProfile, parseProfileText, profileJSON, ProfileError } from "../extension/core/profile.js";

const { zones, locales } = loadCatalog();
const catalog = { timeZones: zones, locales };
const dir = (kind) => join(ROOT, "profile/fixtures", kind);
const read = (kind, name) => readFileSync(join(dir(kind), name), "utf8");

for (const name of readdirSync(dir("valid")).filter((f) => f.endsWith(".json"))) {
  test(`accepts valid/${name}`, () => {
    const text = read("valid", name);
    const profile = parseProfileText(text, catalog);
    const raw = JSON.parse(text);
    assert.equal(profile.timeZone, raw.timeZone);
    assert.equal(profile.locale, raw.locale);
    assert.deepEqual(profile.cli, raw.cli, "cli block is preserved as given");
    assert.deepEqual(parseProfileText(profileJSON(profile), catalog), profile, "export round-trips");
  });
}

for (const name of readdirSync(dir("invalid")).filter((f) => f.endsWith(".json"))) {
  test(`rejects invalid/${name}`, () => {
    assert.throws(() => parseProfileText(read("invalid", name), catalog), ProfileError);
  });
}

test("error codes name the Swift ProfileError case", () => {
  const base = { schema: "claude-locale-kit/profile", version: 1, timeZone: "UTC", locale: "en-US" };
  const code = (v) => { try { parseProfile(v, catalog); } catch (e) { return [e.code, e.detail]; } return null; };
  assert.deepEqual(code([]), ["notObject", ""]);
  assert.deepEqual(code({ ...base, extra: 1 }), ["unknownKey", "extra"]);
  assert.deepEqual(code(JSON.parse('{"__proto__":{},"schema":"claude-locale-kit/profile"}')), ["unknownKey", "__proto__"]);
  assert.deepEqual(code({ ...base, version: true }), ["wrongType", "version"]);
  assert.deepEqual(code({ ...base, version: "1" }), ["wrongType", "version"]);
  assert.deepEqual(code({ ...base, version: 2 }), ["wrongVersion", ""]);
  assert.deepEqual(code({ ...base, schema: 1 }), ["wrongType", "schema"]);
  assert.deepEqual(code({ ...base, timeZone: null }), ["wrongType", "timeZone"]);
  assert.deepEqual(code({ ...base, cli: { disableTelemetry: 1 } }), ["wrongType", "cli.disableTelemetry"]);
  assert.deepEqual(code({ ...base, cli: [] }), ["wrongType", "cli"]);
  assert.deepEqual(code({ ...base, timeZone: "Asia/Kolkata" }), null, "current IANA name");
  assert.deepEqual(code({ ...base, timeZone: "Asia/Calcutta" }), null, "ICU legacy name");
  assert.throws(() => parseProfileText("{", catalog), (e) => e.code === "notJSON");
});
