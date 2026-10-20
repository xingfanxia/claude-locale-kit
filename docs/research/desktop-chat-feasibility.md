# Claude Desktop Chat: feasibility of a chosen time zone and locale

Status: **not supported; runtime proof blocked on this machine.** Static analysis only. Nothing was
launched, patched, or reconfigured. The user's running Claude Desktop was not touched.

Analysed build: Claude Desktop 2.42304.0 (`com.anthropic.claudefordesktop`, team `Q6L2SF6YDW`),
analysed 2026-10-20. Every finding below is tied to this build and may change in later versions.

## Answer

| Route | Verdict | Why |
|---|---|---|
| Extension, plugin, CDP or script injection into the Chat renderer | **Not possible without bypassing the app's protections; out of scope** | Debug and network-override switches make the app exit at startup unless a signed developer token is present. Fuses enforce asar integrity and disable RunAsNode/inspect. We do not patch, re-sign or flip fuses. |
| Isolated test instance on this Mac (separate data folder) | **Cannot be established safely** | `CLAUDE_USER_DATA_DIR` is ignored in signed builds. `--user-data-dir` is not refused, but startup still writes outside the data folder (URL-scheme registration, browser native-host manifests), shares the bundle's Keychain item, and routes `claude://` login callbacks by bundle ID. See "Isolation blockers". |
| Trusted local proxy (`--proxy-server`) | **Transport only; not a Chat feature** | `--proxy-server` is accepted (the app emits it itself from managed config). Reading or changing Chat bodies needs a trusted CA, which is excluded here. A proxy cannot change what the renderer's JavaScript reads, and the native locale hand-off (below) never crosses the network as a header. Not recommended, and request-body rewriting is not something this kit will build. |
| Per-launch environment (`open -a Claude --env TZ=… --args -AppleLanguages '(en-US)'`) after the user quits Desktop | **Only candidate on a supported surface; unproven** | No switch in this command is on the refusal list. The main process's Node reads `TZ`. Renderer `Intl`, `app.getPreferredSystemLanguages()`, and what claude.ai then sends all need runtime proof. |

So for Chat, the kit cannot claim coverage today. The browser extension on claude.ai remains the supported Chat surface.

## Evidence

Hashes (SHA-256):

- `Contents/Resources/app.asar`: `e952a1c0f603e6c2f54f2fc9551843f6d7ccf9c73071a814e5ce4a49ee4c2f4d`
- `.vite/build/index.pre.js`: `58ddbd5eff5824cf4bfce1fd3d6f08a7102658a8250e6c5b172e7bddc5d3ccf8`
- `.vite/build/index.chunk-muI2IV6k.js`: `4a8f1c07e69231e47127d3c55fcdda84eddb089ce06d347ad29591e25b6fb5f5`
- `.vite/build/index.chunk-B8B2Bgah.js`: `1338431db69e5255d55f1c942ba67aa6049449713b5dd665f945f3132425721c`
- `.vite/build/index.chunk-CB6cNSrW.js`: `8c8f69d26ab6ace5397eb74a32c1f1ff235f321cf0b76e21b9c1078d4cfc9340`

Offsets are character offsets into the extracted file.

1. **Startup refusal.** `index.pre.js` ~808475: the denylist `LZ` = remote-debugging-port, remote-debugging-pipe,
   ignore-certificate-errors, host-resolver-rules, host-rules, disable-web-security, log-net-log, net-log-capture-mode,
   ssl-key-log-file, renderer/utility/zygote cmd prefixes, gpu-launcher, browser-subprocess-path. At ~904201,
   `zZ(process.argv) && !JZ()` writes "refusing to start" and calls `process.exit(1)`. `JZ` checks a signed developer
   token. Not in `LZ`: `proxy-server`, `proxy-pac-url`, `lang`, `user-data-dir`, `-AppleLanguages`.
2. **Data folder relocation.** `index.pre.js` ~904433: in packaged builds without the token, `UZ` deletes
   `CLAUDE_USER_DATA_DIR`, `SSLKEYLOGFILE`. `a7()` compares `userData` with the default path; a relocated folder is
   recorded as "userData relocated", which only disables local pairing. It does not exit. `index.chunk-B8B2Bgah.js`
   ~5042 logs that signed builds ignore `CLAUDE_USER_DATA_DIR`.
3. **No Electron single-instance lock.** No `requestSingleInstanceLock` in any of the 378 main-process bundles.
   `second-instance` appears only in the Linux XDG activation hand-off (`index.chunk-muI2IV6k.js` ~3863617). On macOS,
   LaunchServices activates the existing instance for `open -a`; starting the binary directly while Desktop runs would
   create a second process on the same default data folder.
4. **Writes outside the data folder at startup.** `index.chunk-muI2IV6k.js` ~6760566: `l4a()` calls
   `setAsDefaultProtocolClient` for the app's URL schemes with `keepExistingDefault: false`. ~3928622 to ~3929189:
   `HDr()` installs or **removes** the Claude browser native-host manifest in `~/Library/Application Support/<browser>/NativeMessagingHosts`
   for Chrome, Brave, Chromium, Arc, Vivaldi and Opera, depending on that instance's state.
5. **Login callback routing.** ~6774057: `app.on("open-url")` handles `claude://` links. LaunchServices delivers
   them by bundle ID, so a test instance's login can land in the user's running instance.
6. **Native locale hand-off to the Chat renderer.** ~4093898: `rK()` builds `--desktop-managed-config=` JSON with
   `preferredSystemLanguages: app.getPreferredSystemLanguages()` (normalised by `LLr`), which reaches the renderer as an
   argument, not as an HTTP header. ~1680271: app UI language is chosen from `getPreferredSystemLanguages()` /
   `getLocale()`. ~5123860: diagnostics include `getLocale()` and `getSystemLocale()`.
7. **Desktop sets TZ for Claude Code children.** `index.chunk-CB6cNSrW.js` ~374002 and ~296089:
   `TZ: Intl.DateTimeFormat().resolvedOptions().timeZone` in the env for Code/agent sessions and VM shells. A
   Desktop started with a different `TZ` would therefore pass that zone to its Code tab too. This is unverified.
8. **Proxy.** `index.pre.js` ~882271: `H6` maps managed proxy config to `proxy-server` + `proxy-bypass-list` or
   `proxy-pac-url`. `setCertificateVerifyProc` appears only on the `local-pairing` partition (~3914948). That is a
   bounded search, not proof that no pinning exists.
9. **Fuses** (Electron Framework sentinel, wire v1): RunAsNode off, NODE_OPTIONS off, node CLI inspect off,
   embedded asar integrity **on**, OnlyLoadAppFromAsar **on**, cookie encryption on.

## Isolation blockers on this Mac

A runtime spike needs an instance that cannot touch the user's profile, focus or credentials. On this Mac:

- `CLAUDE_USER_DATA_DIR` is dropped without a signed developer token (finding 2). We will not obtain or forge one.
- Even if `--user-data-dir` relocates `userData` (Electron behaviour, unverified for this build), startup still
  re-registers URL schemes and can delete the user's browser native-host manifests (finding 4). That would break
  their Claude in Chrome setup.
- Electron `safeStorage` on macOS uses one Keychain item per app name, not per data folder, so a test instance would
  read the user's Keychain item. That crosses the credential boundary.
- Login callbacks go to the running instance (finding 5), and the test window would open in the user's workspace.

Missing runtime prerequisites, any one of which unblocks a bounded test:

1. A **separate macOS user account or macOS VM** (its own home, Keychain, LaunchServices database and browser
   folders), with a **test Claude account** signed in there by the user; or
2. explicit user consent to quit and relaunch **their own** Desktop for a supervised test (currently forbidden).

## Bounded test plan (for the isolated macOS user or VM only)

Observation only; nothing is rewritten. CA trust is installed only inside the VM or test user, by user decision.

1. Baseline: start Desktop normally (system zone A, system language L). Record the Chat renderer's observed values
   indirectly: start a new chat and capture outgoing claude.ai API requests through a read-only logging proxy
   (`open -a Claude --args --proxy-server=http://127.0.0.1:PORT`, CA trusted in the VM only). Note every
   timezone or locale field in bodies and headers, and every non-claude.ai telemetry host contacted.
2. Quit Desktop. Relaunch with `open -a Claude --env TZ=B --args -AppleLanguages '(en-US)'`. Repeat the capture.
3. Compare runs. **Renderer covered** = request fields derived from the page (for example a body `timezone`/`locale`)
   change to B/en-US. **All traffic covered** = also no residual A/L in native telemetry or diagnostics
   (`getSystemLocale()` is expected to stay L, which makes "all traffic" unlikely). Also check the Code tab:
   `echo $TZ` in its shell and its `Today's date` line.
4. Repeat with `--lang=en-US` instead of `-AppleLanguages`, to record which one Chromium on macOS honours.

## Next implementation choice

- If step 3 shows renderer coverage: add a **"Relaunch Claude Desktop with this profile"** action to the Mac
  companion. It refuses while Desktop is running (checked by bundle ID) and asks the user to quit it first. It never
  quits the app itself. It then runs the `open --env … --args …` form above. The coverage table would read "Chat
  renderer: covered for that launch; native system locale: not covered", and normal launches revert.
- If not: Desktop Chat stays **unsupported**, and the documented path is claude.ai in Chrome with the extension.
- Either way: no CDP, no injection, no proxy rewriting, no CA installs on the user's system, no fuse or binary changes.
