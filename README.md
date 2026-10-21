# claude-locale-kit

Choose the time zone and locale that Claude's client-side code reads on your Mac. MIT licensed.

Covered today: **Claude Code CLI**, for processes started through the `claude-locale` wrapper, and
**claude.ai in Chromium browsers**, through the extension. **Claude Desktop Chat is not covered.**
Against the real app, only a tunnel-only proxy run has happened; which time zone and locale fields
Chat sends is still unobserved (see below).

This kit changes what client code reads from the clock and language settings. It does not change
your network address, account country, billing, or anything Anthropic determines on its servers. It
is not a way to avoid account enforcement.

## Status

| Part | State |
|---|---|
| Profile format ([profile/](profile/README.md)) | v1 contract, generated catalog, golden fixtures; JS and Swift validators agree on every fixture |
| `claude-locale` CLI (`mac/Sources/claude-locale`) | Sets `TZ`, `LANG` and `LC_ALL` for the process it launches and that process's children, then `execve`s Claude Code (same PID, signals and exit status). It does not normalize other request metadata |
| Mac companion app (`mac/Sources/ClaudeLocaleKit`) | Edits and saves the profile; checks it with a test process (`/bin/date`); opens Claude Code in Terminal through the wrapper |
| Browser extension (`extension/`) | Chromium MV3, Chrome 119+. On `https://claude.ai/*` only (pages and the frames they create), it sets the page's JavaScript `Date`/`Intl`/`navigator.language(s)` and the `Accept-Language` request header. It does not reach Web Workers, the network address or the account |
| Claude Desktop Chat | **Not covered.** Static findings plus one runtime step ([feasibility](docs/research/desktop-chat-feasibility.md)): Desktop 3.1623.0 accepted `--proxy-server` and loaded Chat through the local audit proxy, tunnel-only. The field audit ([tools/desktop-proxy](tools/desktop-proxy/README.md), `live-audit.sh`) has not run |

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
  `claude-locale check` prints the profile next to what `/bin/date` reports with it. Run
  `claude-locale help` for the rest, including exit codes.
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

Which time zone and locale fields Desktop Chat requests carry is unknown. No rewrite is designed
until real request evidence exists. The [audit proxy](tools/desktop-proxy/README.md) records
only field names from a fixed list, value kinds and match flags. Its tunnel-only stage has run on
Desktop 3.1623.0. The field audit, `tools/desktop-proxy/live-audit.sh`, needs a short-lived,
name-constrained CA trusted in the login keychain (a macOS password prompt), one new chat that sends
`test`, and a restore that checks the certificate and its trust setting are gone by exact hash.
