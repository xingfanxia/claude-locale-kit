// Differential test for extension/core/override.js: with the browser in zone A and a profile for
// zone B, every case must equal a native run in zone B (same Node, same ICU).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const runner = fileURLToPath(new URL("./override/run-override.mjs", import.meta.url));
const posix = (l) => `${l.replace("-", "_")}.UTF-8`;
const run = (mode, env, zone, locale) =>
  JSON.parse(execFileSync(process.execPath, [runner, mode, zone, locale], { env: { PATH: process.env.PATH, ...env }, encoding: "utf8" }));

const HOSTS = ["America/New_York", "Asia/Shanghai", "Australia/Lord_Howe"];
const TARGETS = [["UTC", "en-GB"], ["America/New_York", "en-US"], ["Europe/London", "en-GB"], ["Australia/Lord_Howe", "en-AU"],
  ["Asia/Kolkata", "hi-IN"], ["Pacific/Chatham", "en-NZ"], ["America/Sao_Paulo", "pt-BR"], ["Europe/Berlin", "de-DE"]];

for (const [zone, locale] of TARGETS) {
  test(`override matches native ${zone} / ${locale}`, async (t) => {
    const native = run("native", { TZ: zone, LANG: posix(locale) }, zone, locale);
    for (const host of HOSTS) {
      await t.test(`from host ${host}`, () => {
        const got = run("override", { TZ: host, LANG: "en_US.UTF-8" }, zone, locale);
        for (const name of Object.keys(native)) assert.deepEqual(got[name], native[name], `${name}: host ${host} -> ${zone}`);
      });
    }
  });
}

const src = readFileSync(new URL("../extension/core/override.js", import.meta.url), "utf8");
const install = (code) =>
  execFileSync(process.execPath, ["--input-type=module", "-e", `globalThis.self = globalThis; ${code}`], {
    env: { PATH: process.env.PATH, TZ: "America/New_York", LANG: "en_US.UTF-8", SRC: src }, encoding: "utf8" }).trim();

test("without a preset config the override is a no-op", () => {
  assert.equal(install(`(0, eval)(process.env.SRC); console.log(Intl.DateTimeFormat().resolvedOptions().timeZone, Date.name, Date === globalThis.Date)`),
    "America/New_York Date true");
});

test("consumes the preset config once and ignores a second install", () => {
  assert.equal(install(`self.__claudeLocaleKit = { timeZone: "Asia/Tokyo", locale: "ja-JP", languages: ["ja-JP", "ja"] };
    (0, eval)(process.env.SRC);
    const left = "__claudeLocaleKit" in self;
    self.__claudeLocaleKit = { timeZone: "UTC", locale: "en-GB", languages: ["en-GB", "en"] };
    (0, eval)(process.env.SRC);
    console.log(left, Intl.DateTimeFormat().resolvedOptions().timeZone, navigator.language, navigator.languages.join(","))`),
  "false Asia/Tokyo ja-JP ja-JP,ja");
});

test("Date keeps its native identity surface", () => {
  assert.equal(install(`self.__claudeLocaleKit = { timeZone: "Asia/Tokyo", locale: "ja-JP", languages: ["ja-JP", "ja"] };
    const P = Date.prototype; (0, eval)(process.env.SRC);
    console.log(Date.name, Date.length, Date.prototype === P, new Date() instanceof Date, P.constructor === Date, typeof Date(), Date.now === globalThis.Date.now)`),
  "Date 7 true true true string true");
});

// Known divergence, kept visible: for Collator and PluralRules V8 reports the default locale verbatim
// ("en-GB") but resolves an explicit "en-GB" to the data locale ("en"). The override passes the
// profile locale explicitly, so resolvedOptions().locale reads "en"; comparisons and plural rules match.
test("Collator/PluralRules resolvedOptions().locale is the explicit-locale value", () => {
  assert.equal(install(`self.__claudeLocaleKit = { timeZone: "UTC", locale: "en-GB", languages: ["en-GB", "en"] };
    (0, eval)(process.env.SRC);
    console.log(new Intl.Collator().resolvedOptions().locale, new Intl.PluralRules().resolvedOptions().locale)`), "en en");
});
