# Desktop Chat audit proxy

A small local tool for one job: find out which time zone and locale fields Claude Desktop Chat
requests actually carry. A rewrite schema is chosen only after that evidence exists, so this
tool has **no rewrite mode**. It forwards every request and response unchanged.

Status: fixture-tested (`tests/`) and run against Claude Desktop: tunnel-only on 3.1623.0, two field audits
on 3.6556.2 (per-launch time zone and locale observed in the message request; one locale field kept the
system value). See the
[feasibility report](../../docs/research/desktop-chat-feasibility.md#field-audit-claude-desktop-365562).

## What it records

`locale_audit.py` (a mitmproxy add-on) writes one JSONL line per event to
`scratch/data/desktop-proxy/audit-<time>.jsonl` (Git-ignored, mode 0600):

- `request`: only for an allowlisted host **and** an exact path template from your config. For each one it records:
  - fields whose name is on a fixed list (`KNOWN_FIELDS`: `timezone`, `locale`, `tz_offset`, ...), found under fixed container names (`metadata`, `client`, ...);
  - a fixed list of headers (`accept-language`, `content-language`, `x-timezone`, ...) and query names;
  - for each of these: the value's kind (`iana_zone`, `locale`, `locale_list`, `utc_offset`, `datetime_*`, `number`, ...) and whether it equals the system or profile zone, locale, date or UTC offset;
  - for everything else, counts only, plus a count of other values that exactly equal a reference zone or locale;
  - the method, as a fixed enum (`POST`, ..., or `OTHER`), the body's content type as a fixed class
    (`json`, `proto`, `connect_proto`, `grpc`, `grpc_web`, `form`, `text`, `other`, `none`) and a size bucket;
  - for protobuf bodies (plain or Connect/gRPC-framed, uncompressed): numeric field paths (`#.2.3`) whose
    string value classifies as a zone, locale, offset or date, or whose integer equals a reference UTC
    offset in minutes, with kind and match flags. Never a value.
- `response`: for template routes, after the response has streamed through: status code and content class
  only. A complete HTTP response does not by itself show that a chat reply succeeded.
- `unmatched_route`: the allowlisted host name only. With `"discoverRoutes": true` also the method and a
  route shape in which every path segment outside a fixed vocabulary of structural route words
  (`SHAPE_VOCAB`) is `{id}`, so names and IDs never appear. Never the query.
- `tunnel`: one line per connection to a non-allowlisted host. Such a connection is an opaque TLS tunnel: it is never decrypted, and its host name is not recorded.

It never records values, URLs or paths, unknown key/header/query names, cookies, authorization,
or message content. It never reads `prompt`, `messages`, `content`, `tools`, `attachments` and similar
containers. Bodies that are neither JSON nor protobuf, are encoded, have no length, or exceed 256 KiB
stream through unread (`skipped_*`). Responses are always streamed and never read, so server-sent events arrive as
sent.

`run.sh` discards mitmproxy's own terminal output, because its error messages can name hosts or URLs.
`CLA_RAW_FRAMEWORK_LOG=1` keeps that output in a separate 0600 file, for debugging only. Delete that
file afterwards.

Boundaries: the tool can only show fields in the routes you list and the flows you exercise. It
cannot see WebSocket messages, response bodies, or anything sent through another route. A
missing field is "not observed in these flows", never "absent".

## Separation from other network tools

The proxy listens on `127.0.0.1` only. Only an app started with `--proxy-server` uses it. It does not
change system proxy settings, routes, DNS or any VPN configuration, and it is not chained to a VPN.
Its upstream connections use whatever network path the Mac already has. Do not point VPN software at
it, and do not point it at VPN software.

## Prerequisites

- `uv` (fetches Python 3.14 and `mitmproxy==12.2.3` into its cache on first use).
- Claude Desktop installed.
- Fixture tests: `npm run test:proxy` (includes `live-audit.sh` cleanup with a fake `security`).

## Supervised live run: `live-audit.sh`

```sh
tools/desktop-proxy/live-audit.sh Asia/Tokyo en-GB    # ZONE and LOCALE from the project catalog
```

It runs steps 0 and 3–7 below in order. With the built CLI (`dist/claude-locale`), it restarts Desktop
through the product path, `claude-locale desktop --restart` (a normal quit, then a launch with the
per-launch profile plus the proxy flag), and restores it with `claude-locale desktop --normal --restart`.
Without the CLI the user quits Desktop and the script starts it. The user authenticates the macOS trust
prompts (adding and removing), and a new chat must send `test` (by the user, or by an accessibility
script that first checks the target composer). Every wait has a time limit (`CLA_CHAT_TIMEOUT`, default
900 s, bounds the chat step). It records the Desktop version and `app.asar` hash that ran and writes
everything to `scratch/data/desktop-proxy/live-<time>/`.

On exit, including after a failure or Ctrl-C, it stops the proxy it started (by process ID), removes the
trust setting and certificate, and then checks the keychain listing and the exported trust settings for the
certificate's exact SHA-1. It deletes the CA folder only when both checks read 0. If a check fails or cannot
be read, it keeps only the public certificate and `sha1.txt`, prints the recovery commands and exits with 3.
The private key is always deleted. Desktop is restored by looking at the processes: one still carrying this
run's proxy flag is restarted normally, and if Desktop had been running but is not, it is opened normally. A
cancelled password prompt or a Desktop left open can stop cleanup from finishing, so read `restore.txt`
after every run.

The config's paths are candidates, not observed routes: the classic `chat_conversations` routes plus
structural shapes seen when a message was sent on 3.6556.2 (any segment may match `{id}`). They are for
auditing only, never a rewrite target. Other claude.ai requests are logged as `unmatched_route` with a
vocabulary-limited shape. If the summary shows no `request` lines, the candidates missed and the run says
nothing about fields.

## Manual steps (what `live-audit.sh` automates)

Step 1 has been run once (3.1623.0, see Status). Steps 1–2 change no certificate trust and no system
proxy setting. Step 3 is the only trust change; step 7 removes exactly that certificate.

**0. Record the before-state** (read-only):

```sh
scutil --proxy > /tmp/cla-proxy-before.txt
```

**1. Tunnel-only run: no CA and nothing decrypted.** This shows that the relaunched app routes through
the proxy.

```sh
cp tools/desktop-proxy/config.example.json scratch/data/desktop-proxy-config.json   # hosts: []
tools/desktop-proxy/run.sh scratch/data/desktop-proxy-config.json 18080
# The user quits Claude Desktop (Cmd-Q), then:
open -a Claude --args --proxy-server=http://127.0.0.1:18080
```

Check: Desktop starts (no "refusing to start"), Chat works, and the log fills with `tunnel` lines.
Then quit Desktop and press Ctrl-C in the proxy terminal.

**2. Templates.** Put `"claude.ai"` under `hosts` and the candidate templates from `live-audit.sh` under
`paths` (`{id}` is one path segment). They stay candidates until `request` lines show they matched.

**3. Create and trust the audit CA. Requires approval.**

```sh
tools/desktop-proxy/make-ca.sh claude.ai      # writes ~/creds/claude-locale-kit/audit-ca/, valid 1 day
```

It prints the new certificate's SHA-1 and saves it in `audit-ca/sha1.txt`. Restore deletes that
exact certificate by hash.

Add a row for it to `~/creds/README.md` (purpose: Desktop Chat audit CA; consumer: run.sh; remove
after the run). Then trust it in the **login** keychain for SSL only (macOS asks for your password):

```sh
security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db \
  ~/creds/claude-locale-kit/audit-ca/mitmproxy-ca-cert.pem
```

The CA carries a critical name constraint permitting only `claude.ai` (and its subdomains), with
`pathlen:0`. OpenSSL enforces this constraint in the fixture tests. Whether macOS or Chromium enforce
it for a user-trusted root has **not** been tested, so do not rely on it. Rely on the short validity
and on removing the CA in step 7.

**4. Field-audit run.**

```sh
tools/desktop-proxy/run.sh scratch/data/desktop-proxy-config.json 18080
# The user quits Claude Desktop, then:
open -a Claude --args --proxy-server=http://127.0.0.1:18080
```

Run the fixed flows: open Chat, start a new chat, send `test`, open Settings. Then quit Desktop and
press Ctrl-C.

If Chat shows a connection or certificate error, stop. That outcome is the result: the app did not
accept the trusted local CA for that host (pinning or another check). Do not work around it.

**5. Optional, same proxy:** repeat step 4 with the per-launch route:
`open -a Claude --env TZ=America/Los_Angeles --args --proxy-server=http://127.0.0.1:18080 -AppleLanguages '(en-US)'`,
then compare the two logs.

**6. Summarize.**

```sh
uv run --no-project --python 3.14 python tools/desktop-proxy/summarize.py scratch/data/desktop-proxy/audit-<time>.jsonl
```

Copy the table into `docs/research/desktop-chat-feasibility.md`. Each field is reported as "observed
as system / profile / neither, in these flows".

**7. Restore.** Do this every time, including after a failed run.

```sh
ca=~/creds/claude-locale-kit/audit-ca
security remove-trusted-cert "$ca/mitmproxy-ca-cert.pem"
security delete-certificate -Z "$(cat "$ca/sha1.txt")" ~/Library/Keychains/login.keychain-db
security find-certificate -a -Z ~/Library/Keychains/login.keychain-db | grep -c "$(cat "$ca/sha1.txt")"   # expect: 0
rm -rf "$ca"                                       # then remove its ~/creds/README.md row
rm -f scratch/data/desktop-proxy/mitmproxy-raw-*   # only exists if raw debug output was enabled
# Quit Claude Desktop, then start it normally from the Dock or Finder (no proxy flag).
```

Verify:

```sh
scutil --proxy | diff /tmp/cla-proxy-before.txt -   # expect: no difference
```

Delete the audit JSONL after its table is copied, if you do not want to keep it.

## Validation checklist

- [ ] Before-state recorded (step 0); `sha1.txt` noted after step 3
- [ ] Tunnel-only: Desktop starts with `--proxy-server`; `tunnel` lines appear; Chat works
- [ ] Templates come from your own DevTools, not guessed
- [ ] User approved step 3; CA created in `~/creds`, row added, trusted in login keychain for SSL only
- [ ] Field audit: Chat works (or the certificate failure is recorded as the outcome); `request` lines have `body.status: inspected`
- [ ] Summary table copied into the feasibility doc, scoped to the flows run
- [ ] Restore done: the hash lookup prints 0, `scutil --proxy` matches the before-state, Desktop relaunched normally
