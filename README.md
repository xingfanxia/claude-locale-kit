# claude-locale-kit

Choose the time zone and locale that Claude's client-side code reads on your Mac. MIT licensed.

Covered today: **Claude Code CLI**, for processes started through the `claude-locale` wrapper, and
**claude.ai in Chromium browsers**, through the extension. **Claude Desktop Chat is partly covered:**
`claude-locale desktop` (or the Mac app's Restart with Profile) starts Claude Desktop with the profile's
time zone and language for that launch. In a live test on Desktop 3.6556.2, Chat requests carried the
profile's language; **whether Chat sends the profile's time zone is not verified yet** (see below).

This kit changes what client code reads from the clock and language settings. It does not change
your network address, account country, billing, or anything Anthropic determines on its servers. It
is not a way to avoid account enforcement.

## Status

| Part | State |
|---|---|
| Profile format ([profile/](profile/README.md)) | v1 contract, generated catalog, golden fixtures; JS and Swift validators agree on every fixture |
| `claude-locale` CLI (`mac/Sources/claude-locale`) | `run`: sets `TZ`, `LANG` and `LC_ALL` for the process it launches and that process's children, then `execve`s Claude Code (same PID, signals and exit status). It does not normalize other request metadata. `desktop`: starts Claude Desktop with `TZ` and `-AppleLanguages` from the profile for that launch only; quits a running Desktop normally only with `--restart`; `--normal` starts it without them |
| Mac companion app (`mac/Sources/ClaudeLocaleKit`) | Edits and saves the profile; checks it with a test process (`/bin/date`); opens Claude Code in Terminal through the wrapper; restarts Claude Desktop with the saved profile or normally (through the CLI) |
| Browser extension (`extension/`) | Chromium MV3, Chrome 119+. On `https://claude.ai/*` only (pages and the frames they create), it sets the page's JavaScript `Date`/`Intl`/`navigator.language(s)` and the `Accept-Language` request header. It does not reach Web Workers, the network address or the account |
| Claude Desktop Chat | **Partly covered, Desktop 3.6556.2 only** ([feasibility](docs/research/desktop-chat-feasibility.md)). Live field audit: with the per-launch profile, every inspected Chat request carried `Accept-Language` equal to the profile's locale, and a new test chat got its reply. Time zone: not verified (the message requests are not JSON; the protobuf-aware audit has not run yet). No rewrite proxy is shipped |

Research and evidence: [audit-2026-10-20.md](docs/research/audit-2026-10-20.md).

## Build

Requirements: Node 24+, Xcode command-line tools (Swift 6), and `uv` for the proxy tests.

```sh
npm install                # Playwright, used only by the tests
npm run build              # dist/extension and dist/claude-locale-kit-extension-<version>.zip
npm run build:mac          # dist/Claude Locale Kit.app, dist/claude-locale, dist/claude-locale-kit-mac-<version>.zip
```

The two builds write separate files in `dist/` and do not delete each other's output.

## Use

- **Extension:** open `chrome://extensions`, turn on Developer mode, then either load `dist/extension`
  unpacked or unzip the ZIP and load that folder. Choose a zone and locale in the popup, turn it on,
  and reload claude.ai tabs. "Check current Claude tab" (it runs only when clicked) shows what the
  open claude.ai page's JavaScript reads. It does not check the header.
- **CLI:** `claude-locale run [--profile PATH] [--tz ZONE] [--locale TAG] [--] [claude args...]`.
  `claude-locale check` prints the profile next to what `/bin/date` reports with it.
  `claude-locale desktop --restart` asks a running Claude Desktop to quit (it may ask about unsaved
  work) and starts it with the profile; `claude-locale desktop --normal --restart` undoes that, as does
  quitting Desktop and opening it the usual way. Run `claude-locale help` for the rest, including exit codes.
- **Mac app:** pick a zone and locale, save, then press Verify. The profile is saved to
  `~/.config/claude-locale-kit/profile.json`, which the CLI reads and the extension can import.

## Test

```sh
npm test            # catalog sync, override differential, profile parity, extension e2e + popup, CLI
npm run test:swift  # ProfileCore
npm run test:proxy  # Desktop Chat audit proxy, against local fixtures only
```

The extension tests run Playwright Chromium against local fixture HTTPS servers. Only the two test
hosts resolve, and only the fixture certificate is accepted. The override test compares every case
with native V8 running in the target zone, from three different host zones.

## Desktop Chat: the remaining step

Verified so far, on Desktop 3.6556.2 only: the per-launch language reaches Chat requests, and Chat
works through the audit proxy. Open: whether Chat's message requests carry a time zone, and whether it
follows the per-launch `TZ`. Those requests are not JSON; the [audit proxy](tools/desktop-proxy/README.md)
now parses protobuf bodies for zone and locale fields (field numbers and match flags only, never values),
and one more field-audit run (`tools/desktop-proxy/live-audit.sh`) answers it. No rewrite is designed
unless that evidence shows the per-launch route falls short.
