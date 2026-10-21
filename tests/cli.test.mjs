// claude-locale CLI: arguments, environment, exit status, signals and profile validation.
// A fake `claude` (a sh script) stands in for Claude Code; nothing here starts the real one.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT } from "../scripts/catalog.mjs";

let BIN;
let dir;
const PROFILE = (tz, locale, cli) => JSON.stringify({ schema: "claude-locale-kit/profile", version: 1, timeZone: tz, locale, ...(cli ? { cli } : {}) });

before(() => {
  BIN = process.env.CLAUDE_LOCALE_BIN;
  if (!BIN) {
    execFileSync("swift", ["build", "--package-path", join(ROOT, "mac"), "--product", "claude-locale"], { stdio: "ignore" });
    BIN = execFileSync("swift", ["build", "--package-path", join(ROOT, "mac"), "--show-bin-path"], { encoding: "utf8" }).trim() + "/claude-locale";
  }
  dir = mkdtempSync(join(tmpdir(), "claude-locale-cli-"));
  // Fake Claude Code: report pid, argv and the variables the wrapper controls, then honour FAKE_MODE.
  writeFileSync(join(dir, "claude"), `#!/bin/sh
printf 'pid=%s\\n' "$$"
for a in "$@"; do printf 'arg=[%s]\\n' "$a"; done
for v in TZ LANG LC_ALL DISABLE_TELEMETRY DISABLE_ERROR_REPORTING KEEP_ME; do eval "printf '%s=%s\\n' $v \\"\\\${$v-<unset>}\\""; done
case "$FAKE_MODE" in
  exit) exit 42 ;;
  wait) printf 'ready\\n'; while :; do sleep 1; done ;;
  stdin) cat ;;
esac
`);
  chmodSync(join(dir, "claude"), 0o755);
  writeFileSync(join(dir, "profile.json"), PROFILE("Asia/Kolkata", "hi-IN", { disableTelemetry: true }));
  writeFileSync(join(dir, "plain.json"), PROFILE("Europe/London", "en-GB"));
  writeFileSync(join(dir, "bad.json"), '{"schema":"claude-locale-kit/profile","version":1,"timeZone":"Mars/Base","locale":"en-US"}');
  writeFileSync(join(dir, "noexec"), "#!/bin/sh\n");
});
after(() => rmSync(dir, { recursive: true, force: true }));

const env = (extra = {}) => ({ PATH: `${dir}:/usr/bin:/bin`, HOME: dir, XDG_CONFIG_HOME: join(dir, "xdg"), ...extra });
const cli = (args, extra, input) => spawnSync(BIN, args, { env: env(extra), encoding: "utf8", input });
const kv = (out) => Object.fromEntries(out.split("\n").filter((l) => /^[A-Z_]+=/.test(l)).map((l) => l.split(/=(.*)/s).slice(0, 2)));

test("run sets TZ/LANG/LC_ALL and enabled opt-outs, keeps other variables, passes args verbatim", () => {
  const r = cli(["run", "--profile", join(dir, "profile.json"), "--", "--model", "opus", "two words", "it's", "--", ""], { KEEP_ME: "yes", TZ: "America/New_York" });
  assert.equal(r.status, 0, r.stderr);
  const v = kv(r.stdout);
  assert.deepEqual([v.TZ, v.LANG, v.LC_ALL, v.DISABLE_TELEMETRY, v.DISABLE_ERROR_REPORTING, v.KEEP_ME],
    ["Asia/Kolkata", "hi_IN.UTF-8", "hi_IN.UTF-8", "1", "<unset>", "yes"]);
  assert.deepEqual(r.stdout.match(/^arg=\[.*\]$/gm), ["arg=[--model]", "arg=[opus]", "arg=[two words]", "arg=[it's]", "arg=[--]", "arg=[]"]);
});

test("run without -- passes the first unknown argument and everything after it through", () => {
  const r = cli(["run", "--profile", join(dir, "plain.json"), "--model", "opus", "--tz", "UTC"]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(kv(r.stdout).TZ, "Europe/London");
  assert.deepEqual(r.stdout.match(/^arg=\[.*\]$/gm), ["arg=[--model]", "arg=[opus]", "arg=[--tz]", "arg=[UTC]"]);
});

test("a disabled opt-out leaves the user's own value untouched", () => {
  const v = kv(cli(["run", "--profile", join(dir, "plain.json")], { DISABLE_TELEMETRY: "0" }).stdout);
  assert.equal(v.DISABLE_TELEMETRY, "0");
});

test("--tz/--locale override the profile and work without one", () => {
  const v = kv(cli(["run", "--tz", "Pacific/Chatham", "--locale", "en-NZ"]).stdout);
  assert.deepEqual([v.TZ, v.LANG], ["Pacific/Chatham", "en_NZ.UTF-8"]);
});

test("run replaces itself: same pid, exit status and stdin are Claude Code's", () => {
  const r = cli(["run", "--profile", join(dir, "plain.json")], { FAKE_MODE: "exit" });
  assert.equal(r.status, 42);
  const s = cli(["run", "--profile", join(dir, "plain.json")], { FAKE_MODE: "stdin" }, "piped input\n");
  assert.match(s.stdout, /piped input\n$/);
});

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  test(`${signal} reaches Claude Code directly (no wrapper process in between)`, async () => {
    const child = spawn(BIN, ["run", "--profile", join(dir, "plain.json")], { env: env({ FAKE_MODE: "wait" }) });
    let out = "";
    await new Promise((resolve) => child.stdout.on("data", (d) => { out += d; if (out.includes("ready")) resolve(); }));
    assert.equal(Number(out.match(/pid=(\d+)/)[1]), child.pid, "exec keeps the pid");
    const [code, sig] = await new Promise((resolve) => { child.on("exit", (c, s) => resolve([c, s])); child.kill(signal); });
    assert.deepEqual([code, sig], [null, signal]);
  });
}

test("errors map to documented exit codes", () => {
  const cases = [
    [["run"], 2, /no profile/],
    [["run", "--profile", join(dir, "bad.json")], 2, /not a supported IANA time zone/],
    [["run", "--profile", join(dir, "plain.json"), "--tz", "Not/AZone"], 2, /not a supported IANA time zone/],
    [["run", "--tz"], 2, /--tz needs a value/],
    [["run", "--profile", join(dir, "plain.json"), "--claude", join(dir, "missing")], 127, /could not start/],
    [["run", "--profile", join(dir, "plain.json"), "--claude", join(dir, "noexec")], 126, /could not start/],
    [["check", "--bogus"], 2, /unknown option/],
    [["frobnicate"], 2, /unknown command/],
    [["validate"], 2, /exactly one FILE/],
  ];
  for (const [args, status, err] of cases) {
    const r = cli(args);
    assert.equal(r.status, status, `${args.join(" ")}: ${r.stderr}`);
    assert.match(r.stderr, err, args.join(" "));
  }
  assert.equal(cli(["run", "--profile", join(dir, "plain.json")], { PATH: "/usr/bin:/bin" }).status, 127);
});

test("finding claude on PATH skips a `claude` that is the wrapper itself", () => {
  const loop = mkdtempSync(join(tmpdir(), "claude-locale-loop-"));
  try {
    symlinkSync(BIN, join(loop, "claude"));
    const r = spawnSync(join(loop, "claude"), ["run", "--profile", join(dir, "plain.json")], { env: env({ PATH: `${loop}:${dir}:/usr/bin:/bin` }), encoding: "utf8" });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(kv(r.stdout).TZ, "Europe/London");
  } finally { rmSync(loop, { recursive: true, force: true }); }
});

test("validate agrees with the golden fixtures (Swift side of the schema parity)", () => {
  for (const kind of ["valid", "invalid"]) {
    for (const f of readdirSync(join(ROOT, "profile/fixtures", kind))) {
      const r = cli(["validate", join(ROOT, "profile/fixtures", kind, f)]);
      assert.equal(r.status, kind === "valid" ? 0 : 1, `${kind}/${f}: ${r.stdout}`);
    }
  }
});

test("check --json reports configured and observed values", () => {
  const r = cli(["check", "--json", "--profile", join(dir, "profile.json")]);
  assert.equal(r.status, 0, r.stderr);
  const j = JSON.parse(r.stdout);
  assert.equal(j.configured.timeZone, "Asia/Kolkata");
  assert.equal(j.observed.utcOffset, "+0530");
  assert.equal(j.childEnvironment.LC_ALL, "hi_IN.UTF-8");
  assert.equal(j.claudePath, join(dir, "claude"));
  const missing = cli(["check", "--json", "--profile", join(dir, "nope.json")]);
  assert.equal(missing.status, 1);
  assert.equal(JSON.parse(missing.stdout).profileError, "No profile saved yet.");
});
