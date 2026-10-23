# Claude Desktop Chat: feasibility of a chosen time zone and locale

Status: **Time zone and primary language covered on Claude Desktop 3.6556.2, with one residual locale field.**
Started with a per-launch `TZ` and `-AppleLanguages` (`claude-locale desktop`, or the Mac app's Restart with
Profile), Chat's message request carried the profile's IANA zone and locale, and every inspected request
carried the profile's `Accept-Language`. One locale field in the same requests still carried the Mac's own
`en-US`. Evidence is from local field audits on this Mac only (the VM was cancelled), tied to this build. See
[field audit 3.6556.2](#field-audit-claude-desktop-365562).

Method: static inspection of the shipped app only. Nothing was launched, patched or reconfigured, and the user's
running Desktop was not touched. Analysed build: Claude Desktop 2.42304.0 (`com.anthropic.claudefordesktop`, team
`Q6L2SF6YDW`), inspected 2026-10-20. All findings are tied to this build.

Labels used below: **Observed** = seen in shipped code or files. **Inferred** = a reasoned expectation not yet
tested. **Unknown** = not determined.

## Summary by route

| Route | Status |
|---|---|
| Debugging, certificate-bypass and host-resolution switches (the denylist in observation 1; `--proxy-server` and `--lang` are not on it) | **Observed blocked** (static, both builds). The app exits at startup when these switches are present without a signed developer token. Other injection routes were not evaluated. We do not bypass the token check, patch the binary, or change fuses. |
| Same-user isolated instance on the current Mac | **Not established.** The blockers inspected are listed below. The user did not select a supervised restart of their own Desktop. |
| Per-launch environment: `open -a Claude --env TZ=… --args -AppleLanguages '(…)'` (shipped as `claude-locale desktop` and the Mac app's Restart with Profile) | **Observed working (3.6556.2)** for the time zone and the primary language: the message request carried the profile's IANA zone and locale, and every inspected request carried the profile's `Accept-Language`. One locale field still carried the system locale (see run 2). |
| User-trusted local proxy (`--proxy-server`) that rewrites time zone/locale fields | **Candidate.** The switch is not on the denylist, and at runtime 3.1623.0 started with it and loaded Chat through a local proxy (tunnel-only). It requires the user to choose to trust a local CA, and runtime validation of which fields exist and whether rewriting them is accepted. Whether certificate pinning applies is unknown. |

## Field audit (Claude Desktop 3.6556.2)

Build: 3.6556.2, `app.asar` SHA-256 `b2dfbbb40325d978dcb7561ad12a6f9bc199f8f46b7d3d2897af74ce8965d68a`, same
bundle ID and team; startup denylist (`hZ`) unchanged. System: `Asia/Shanghai`, `en-US`. Per-launch profile:
`Asia/Tokyo`, `en-GB`.

Run 1, 2026-10-23 05:27–05:39 UTC, with `live-audit.sh`: a 1-day CA name-constrained to `claude.ai` was trusted
for SSL in the login keychain (the user authenticated the macOS prompt). Desktop was quit normally and started
with `TZ=Asia/Tokyo`, `-AppleLanguages (en-GB)` and `--proxy-server` to the local audit proxy.

- Chat loaded through the proxy with the trusted CA; claude.ai requests were decrypted and inspected by the
  fixed-field add-on.
- Two new chats were opened through the app's own new-chat link, and `test` was sent through the accessibility
  API after checking the target composer. The first test chat showed the visible assistant reply.
- No request matched the `chat_conversations/…/completion` candidates. Sending produced POST requests whose
  route shape is `/{id}/{id}/{id}` (no segment in the fixed route vocabulary) with non-JSON bodies, plus
  conversation reads under `/api/organizations/{id}/chat_conversations/{id}/{id}`.
- `Accept-Language`: on all 15 inspected requests, a single locale equal to the profile (`en-GB`), not the system
  (`en-US`).
- Time zone: no field observed. The non-JSON bodies were not parsed in run 1; the add-on now classifies content
  types and parses protobuf/Connect bodies for zone and locale fields (field numbers and match flags only).
- Restore, verified: the user approved the removal prompt (after about an hour); the certificate's SHA-1 was
  absent from the login keychain listing and from the exported trust settings (checked by the script and
  again by hand), the CA folder was deleted, the proxy stopped, `scutil --proxy` matched the before-state, and
  Desktop ran normally. The script exited 3 only because the cleanup it had loaded at start could not tell
  a normally reopened Desktop from a proxied one; the current script checks the process for the proxy flag.

Run 2, 2026-10-23 07:01–07:17 UTC, same build and profile, with the shipped CLI: `claude-locale desktop
--restart` quit Desktop normally and started it with `TZ=Asia/Tokyo`, `-AppleLanguages (en-GB)` and the proxy
flag (process environment and arguments checked). The add-on now parsed protobuf and Connect bodies,
recording field numbers and match flags only.

- A new chat opened through the app's own new-chat action sent `test` (accessibility API, composer checked
  first), and the visible assistant reply appeared.
- The protobuf POST sent at the moment of `test` (07:14:06) carried an IANA zone equal to the **profile**
  zone (field `#.2.12`) and a locale equal to the **profile** locale (`#.2.13`). A Connect request sent
  around each message carried the profile zone as well (`#.8`).
- The same requests carried one more locale field equal to the **system** locale `en-US` (`#.1.14`; `#.5`
  in the Connect request). Restarting with an added `-AppleLocale en_GB` (same trust window) did not change
  it, so it does not come from the macOS region setting. Its source, possibly the system's preferred-language
  list or the account's own language setting, is not determined; both are `en-US` on this Mac.
- `Accept-Language`: the profile locale on all 74 inspected requests.
- No rewrite was built: the time zone follows the per-launch route, and rewriting the remaining protobuf field
  would need a permanently trusted local CA and a proxy in the path.
- Restore, verified (script exit 0, rechecked by hand): neither run's certificate SHA-1 is in the login keychain
  or the exported trust settings, the CA folder is gone, nothing listens on the proxy port, `scutil --proxy`
  matches the before-state, and Desktop runs normally without flags or `TZ`.

## Runtime observations (Claude Desktop 3.1623.0)

Build: 3.1623.0, `app.asar` SHA-256 `760e7cbb6f861f0bc0e71e71fd9c6b721ba735f0f638b6ea623645daff4261a7`, same
bundle ID and team. A staged auto-update replaced 2.42304.0 on 2026-10-22; the static observations below are
for 2.42304.0. In 3.1623.0 the startup denylist (`NZ`) has the same 16 switches, matched by prefix after
stripping `-`/`--` (so `ignore-certificate-errors-spki-list` is refused too); `proxy-server` and `lang` are not on it.

Tunnel-only run, 2026-10-22 (no CA, nothing decrypted, system proxy settings untouched): Desktop was quit
normally and started with `open -g -a Claude --args --proxy-server=http://127.0.0.1:18080`.

- It started and kept running with the switch (no startup refusal).
- At the moment of inspection, all 9 TCP sockets of its network-service process connected to the local proxy;
  none went directly to a remote address. That is one sample, not proof about all traffic over time.
- The proxy logged 26 opaque tunnels (connections to non-allowlisted hosts; no names recorded).
- The app log showed the Chat web app loaded and the account session established (`Loaded <url> (web commit …)`,
  `claude.ai account details provided`). No message was sent; that needs foreground input.
- The main window took focus at launch despite `open -g`.
- Restore: proxy stopped (exit 0), Desktop quit and started again without flags, `scutil --proxy` identical
  to the before-state.

This shows that the proxy route is reachable. It says nothing yet about which time zone or locale fields Chat
sends, or whether it follows a per-launch `TZ`; that is the field audit (`live-audit.sh`).

## Observations

Hashes (SHA-256):

- `Contents/Resources/app.asar`: `e952a1c0f603e6c2f54f2fc9551843f6d7ccf9c73071a814e5ce4a49ee4c2f4d`
- `.vite/build/index.pre.js`: `58ddbd5eff5824cf4bfce1fd3d6f08a7102658a8250e6c5b172e7bddc5d3ccf8`
- `.vite/build/index.chunk-muI2IV6k.js`: `4a8f1c07e69231e47127d3c55fcdda84eddb089ce06d347ad29591e25b6fb5f5`
- `.vite/build/index.chunk-B8B2Bgah.js`: `1338431db69e5255d55f1c942ba67aa6049449713b5dd665f945f3132425721c`
- `.vite/build/index.chunk-CB6cNSrW.js`: `8c8f69d26ab6ace5397eb74a32c1f1ff235f321cf0b76e21b9c1078d4cfc9340`

Offsets are character offsets into the extracted file.

1. **Startup refusal.** `index.pre.js` ~808475 defines the denylist `LZ`: remote-debugging-port,
   remote-debugging-pipe, ignore-certificate-errors, host-resolver-rules, host-rules, disable-web-security,
   log-net-log, net-log-capture-mode, ssl-key-log-file, the renderer/utility/zygote cmd prefixes, gpu-launcher, and
   browser-subprocess-path. At ~904201, `zZ(process.argv) && !JZ()` prints "refusing to start" and calls
   `process.exit(1)`. `JZ` checks a signed developer token. Not in `LZ`: `proxy-server`, `proxy-pac-url`, `lang`,
   `user-data-dir`, `-AppleLanguages`.
2. **Data folder.** `index.pre.js` ~904433: in packaged builds without the token, `UZ` deletes
   `CLAUDE_USER_DATA_DIR` and `SSLKEYLOGFILE` from the environment. `a7()` compares `userData` with the default path,
   and a relocated folder is recorded as "userData relocated" (this disables local pairing; it does not exit).
   `index.chunk-B8B2Bgah.js` ~5042 logs that signed builds ignore `CLAUDE_USER_DATA_DIR`.
3. **Single instance.** No `requestSingleInstanceLock` call was found in the 378 main-process bundles.
   `second-instance` appears only in a Linux XDG activation hand-off (`index.chunk-muI2IV6k.js` ~3863617).
4. **Startup side effects outside the data folder.** `index.chunk-muI2IV6k.js` ~6760566: `l4a()` calls
   `setAsDefaultProtocolClient` for the app's URL schemes with `keepExistingDefault: false`. ~3928622 to ~3929189:
   `HDr()` installs or removes the Claude browser native-host manifest in each supported browser's
   `NativeMessagingHosts` folder (Chrome, Brave, Chromium, Arc, Vivaldi, Opera).
5. **URL callbacks.** ~6774057: `app.on("open-url")` handles `claude://` links.
6. **Native locale to the Chat renderer.** ~4093898: `rK()` builds a `--desktop-managed-config=` argument whose JSON
   includes `preferredSystemLanguages` from `app.getPreferredSystemLanguages()`. ~1680271: the app UI language is
   picked from `getPreferredSystemLanguages()` / `getLocale()`. ~5123860: diagnostics text includes `getLocale()` and
   `getSystemLocale()`.
7. **TZ for Claude Code children.** `index.chunk-CB6cNSrW.js` ~374002 and ~296089:
   `TZ: Intl.DateTimeFormat().resolvedOptions().timeZone` is set in the environment of Code/agent sessions and VM shells.
8. **Proxy and certificates.** `index.pre.js` ~882271: `H6` maps managed proxy config to `proxy-server` +
   `proxy-bypass-list` or `proxy-pac-url`. `setCertificateVerifyProc` was found only on the `local-pairing`
   partition (~3914948). This was a bounded search and does not show that no pinning exists.
9. **Fuses** (Electron Framework sentinel, wire v1): RunAsNode off, NODE_OPTIONS off, node CLI inspect off,
   embedded asar integrity on, OnlyLoadAppFromAsar on, cookie encryption on.

## Inferences and unknowns

- Inferred: a second process started directly while Desktop runs would use the same default data folder
  (from 2 and 3).
- Inferred: an instance with a relocated `userData` would still perform the side effects in 4. The URL-scheme
  registration, and a possible removal of the user's browser native-host manifests, would leave that instance's
  folder. Electron `safeStorage` on macOS keys its Keychain item by app name, so the instance would share the user's
  Keychain item. LaunchServices routes `claude://` callbacks by bundle ID, so the instance's login could reach the
  user's running instance. These are the reasons same-user isolation was not established.
- Inferred: a Desktop launched with `TZ=B` would pass `B` to its Code tab (from 7, because the main process's Node
  reads `TZ`). Not tested.
- Unknown: whether Chromium's renderer on macOS adopts `TZ` from the environment, and whether `-AppleLanguages`
  or `--lang` changes `getPreferredSystemLanguages()` and `navigator.languages`.
- Unknown: which time zone and locale fields Chat traffic contains. The native locale reaches the renderer as an
  argument (6), not as a header. The page can still read that value and put it into later requests, so a proxy
  that only looks at headers could miss it.
- Unknown: whether a rewriting proxy is accepted end to end (pinning, integrity checks, consistency checks).

## Local validation plan

The executable plan, with start, trust, restore and verification commands and a checklist, is in
[tools/desktop-proxy/README.md](../../tools/desktop-proxy/README.md). In outline:

1. **Tunnel-only run** (no CA, nothing decrypted): the user relaunches Desktop with
   `--proxy-server=http://127.0.0.1:PORT`. This confirms the switch is accepted and Chat traffic routes
   through the proxy.
2. **Field audit** (user approval required): a one-day, name-constrained CA from `make-ca.sh` is stored in
   `~/creds` and trusted in the login keychain for SSL only. The fixed flows are run (new chat, send `test`,
   open Settings), and for exact path templates only, fixed-list field names, value kinds and match flags are
   recorded. Prompts, cookies, authorization, raw bodies and URLs are never recorded. Requests pass unchanged
   and responses stream.
3. **Per-launch route** on the same proxy: `--env TZ=B --args -AppleLanguages '(en-US)'`, compared with step 2.
4. **Restore**: remove exactly that certificate by its recorded SHA-1, delete the CA, relaunch Desktop
   normally, and check that `scutil --proxy` matches the before-state.
5. **Report per route**: for each field observed, whether it shows the system value, the profile value or
   neither, for the tested flows only. A field not observed means "not observed in these flows".

Risks of the local route compared with the cancelled isolated environment: the run uses the user's real
login and Desktop data, and the trusted CA briefly affects that user's TLS trust for claude.ai. This is why
the trust step is the user's explicit decision and is removed right after.

## Decision after validation

- The per-launch route changes the step-1 fields → candidate product action: "Relaunch Claude Desktop with this
  profile" in the Mac companion. It refuses while Desktop is running and never quits the app itself.
- The proxy route is needed → a separate user decision on local CA trust and on running a local proxy. It would
  stay limited to time zone and locale fields: no identifiers, credentials or other content.
- Neither works → the gap is reported with the step-4 table; no coverage claim.
