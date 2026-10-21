# Profile format (v1)

One JSON object, shared by the browser extension, the `claude-locale` CLI and the Mac app.
Every reader rejects unknown keys, wrong types and values outside the generated catalog.
A profile cannot carry commands, paths or arbitrary environment variables.

```json
{
  "schema": "claude-locale-kit/profile",
  "version": 1,
  "timeZone": "America/Los_Angeles",
  "locale": "en-US",
  "cli": { "disableTelemetry": false, "disableErrorReporting": false }
}
```

| Key | Type | Rule |
|---|---|---|
| `schema` | string | exactly `claude-locale-kit/profile` |
| `version` | integer | exactly `1` |
| `timeZone` | string | an IANA zone from `Intl.supportedValuesOf("timeZone")` at build time, `UTC`, or a current IANA name ICU lists under an older ID (`Asia/Kolkata` for `Asia/Calcutta`); both spellings are accepted |
| `locale` | string | one of `profile/locales.json` |
| `cli` | object, optional | only `disableTelemetry` and `disableErrorReporting`, both booleans |

Default location for the CLI and the Mac app: `~/.config/claude-locale-kit/profile.json`
(`$XDG_CONFIG_HOME/claude-locale-kit/profile.json` when set). The extension stores its copy in
`chrome.storage.local` and moves profiles in and out only through explicit Import/Export. Its on/off
switch is stored separately, outside the profile. Its zone picker shows the current IANA names only.

`fixtures/valid` and `fixtures/invalid` are golden cases; the JS and Swift validators must agree on them.
