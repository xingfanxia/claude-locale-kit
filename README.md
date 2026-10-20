# claude-locale-kit

Choose the time zone and locale that Claude sees on your Mac: Claude Code CLI, claude.ai in Chrome, and Claude
Desktop. MIT licensed.

It changes what client-side code reads from your clock and language settings. It does not change your network
address, account country, billing, or anything Anthropic determines on its servers. It is not a way to avoid
account enforcement.

## Checkpoint: incomplete, nothing is built or released

Product work is paused until the Claude Desktop Chat route is validated.

| Part | State |
|---|---|
| Profile format ([profile/](profile/README.md)) | Written: v1 contract, locale catalog, golden valid/invalid fixtures |
| Build scripts (`scripts/`) | Written. The extension build fails until `extension/manifest.json` exists |
| CLI wrapper (`mac/Sources/claude-locale`) and shared parser (`mac/Sources/ProfileCore`) | Written, not built or tested: the Swift package build fails because the app target is incomplete |
| Mac companion app (`mac/Sources/ClaudeLocaleKit`) | Partial (about half the files); does not build |
| Browser extension (`extension/`) | Only the time zone/locale override script exists, untested; no manifest, UI or tests |
| Claude Desktop Chat | Coverage not established. See [desktop-chat-feasibility.md](docs/research/desktop-chat-feasibility.md) |

Research and evidence: [audit-2026-10-20.md](docs/research/audit-2026-10-20.md).

**Next prerequisite:** an independent macOS VM or separate macOS test account with a test Claude login, chosen by
the user and not yet confirmed. Runtime validation of the Desktop Chat routes runs only there.
