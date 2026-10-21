#!/bin/sh
# One supervised Desktop Chat field-audit run (README.md, "Supervised live run"). It runs the
# manual steps in order and waits, with time limits, for the steps only the user can take:
# authenticating the macOS trust prompt, quitting Claude Desktop, and sending `test` in a new chat.
#
# On exit, also after a failure or Ctrl-C, it tries to undo what it changed and reports what it
# verified: it stops the proxy it started (by process ID, never by port), removes the CA's trust
# setting and certificate, checks the keychain and trust settings for both, and starts Claude
# Desktop again without the proxy if it had been running. The CA private key is always deleted. If
# the certificate or its trust setting is still present (for example, the removal prompt was
# cancelled), the public certificate and its SHA-1 are kept in the CA folder with recovery
# commands, and the exit status is 3. A prompt or a user step can block; every wait has a limit.
#
# Usage: live-audit.sh ZONE LOCALE [PORT]      e.g. live-audit.sh Asia/Tokyo en-GB
#   ZONE and LOCALE must be in the project catalog. Desktop is started with TZ=ZONE and
#   -AppleLanguages (LOCALE); the audit reports whether each observed field equals the system or
#   this profile. Paths in the config are candidates until matching requests are observed.
# Output: scratch/data/desktop-proxy/live-<time>/: app.txt (Desktop version and app.asar SHA-256
# of the build that ran), the sanitized audit JSONL, summary.md, restore.txt.
# Exit status: 0 ok; 1 a step failed; 2 usage; 3 cleanup could not verify removal; 130/143 signal.
# Test hooks (tests/test_live_audit.py): CLA_APP, CLA_SECURITY, CLA_KEYCHAIN, CLA_OPEN, CLA_WORK,
# CLA_QUIT_TIMEOUT, CLA_CHAT_TIMEOUT, CLA_CA_DIR.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: live-audit.sh ZONE LOCALE [PORT]" >&2; exit 2; }
zone="$1"
locale="$2"
port="${3:-18080}"
case "$port" in ''|*[!0-9]*) echo "live-audit.sh: PORT must be a number" >&2; exit 2 ;; esac
node --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const { loadCatalog } = await import(pathToFileURL(process.argv[1]).href);
  const { zones, locales } = loadCatalog();
  if (!zones.includes(process.argv[2])) { console.error("live-audit.sh: zone not in the catalog"); process.exit(2); }
  if (!locales.includes(process.argv[3])) { console.error("live-audit.sh: locale not in the catalog"); process.exit(2); }
' "$root/scripts/catalog.mjs" "$zone" "$locale" || exit 2

app="${CLA_APP:-/Applications/Claude.app}"
security="${CLA_SECURITY:-/usr/bin/security}"
keychain="${CLA_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
opener="${CLA_OPEN:-/usr/bin/open}"
ca="${CLA_CA_DIR:-$HOME/creds/claude-locale-kit/audit-ca}"
quit_timeout="${CLA_QUIT_TIMEOUT:-600}"
chat_timeout="${CLA_CHAT_TIMEOUT:-900}"
uvpy="uv run --no-project --quiet --python 3.14 python -I"
[ -x "$app/Contents/MacOS/Claude" ] || { echo "live-audit.sh: $app not found" >&2; exit 1; }
[ ! -e "$ca" ] || { echo "live-audit.sh: $ca exists; finish or remove the previous run first (README.md, Restore)" >&2; exit 1; }
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "live-audit.sh: port $port is in use" >&2; exit 1; fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
work="${CLA_WORK:-$root/scratch/data/desktop-proxy/live-$stamp}"
( umask 077; mkdir -p "$work" )
say() { printf '\n==> %s\n' "$*"; }
desktop_running() { pgrep -f "^$app/Contents/MacOS/Claude( |\$)" >/dev/null 2>&1; }
# wait_until_quit SECONDS: 0 once Desktop is not running, 1 at the limit.
wait_until_quit() {
  n=0
  while desktop_running; do
    [ "$n" -lt "$1" ] || return 1
    sleep 1; n=$((n + 1))
  done
}
descendants() { for c in $(pgrep -P "$1"); do descendants "$c"; echo "$c"; done; }
record_app() {
  # A staged Squirrel update installs when Desktop quits; wait for it (at most 300 s), then record.
  n=0; while pgrep -f "com.anthropic.claudefordesktop.ShipIt" >/dev/null 2>&1 && [ $n -lt 300 ]; do sleep 1; n=$((n + 1)); done
  printf 'version %s\napp.asar sha256 %s\n' "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" \
    "$(shasum -a 256 "$app/Contents/Resources/app.asar" 2>/dev/null | cut -d' ' -f1)" > "$work/app.txt"
  cat "$work/app.txt"
}

was_running=0; desktop_running && was_running=1
scutil --proxy > "$work/proxy-before.txt"
made_ca=0; proxy_pid=""; quit_seen=0; launched=0

stop_proxy() {
  [ -n "$proxy_pid" ] || return 0
  # Background jobs of a non-interactive shell ignore SIGINT, so TERM (then KILL) the owned tree.
  pids="$(descendants "$proxy_pid") $proxy_pid"
  kill -TERM $pids 2>/dev/null
  n=0; while kill -0 $pids 2>/dev/null && [ $n -lt 15 ]; do sleep 1; n=$((n + 1)); done
  kill -KILL $pids 2>/dev/null && sleep 1
  if kill -0 $pids 2>/dev/null; then echo "proxy: still running ($pids)"; return 1; fi
  echo "proxy: stopped"
}

# Removal is judged by what the keychain and the exported trust settings show afterwards, not by
# exit codes: a cancelled add leaves nothing to remove, a cancelled removal leaves both in place.
# A query that fails or cannot be read counts as unverified, never as zero.
remove_ca() {
  [ "$made_ca" = 1 ] || return 0
  # Recovery needs only the public certificate and its hash. Everything else goes, including the
  # private key and any file mitmproxy added to the folder.
  find "$ca" -mindepth 1 ! -name mitmproxy-ca-cert.pem ! -name sha1.txt -exec rm -rf {} +
  sha=$(cat "$ca/sha1.txt")
  echo "removing the trust setting (macOS may ask for your password)"
  "$security" remove-trusted-cert "$ca/mitmproxy-ca-cert.pem" >/dev/null 2>&1
  "$security" delete-certificate -Z "$sha" "$keychain" >/dev/null 2>&1
  verified=1
  # find-certificate exits 0 even for a missing keychain, so the keychain is checked first. Its
  # listing goes partly to stderr, so both streams are searched.
  if "$security" show-keychain-info "$keychain" >/dev/null 2>&1 \
     && listing=$("$security" find-certificate -a -Z "$keychain" 2>&1); then
    certs=$(printf '%s\n' "$listing" | grep -c "SHA-1 hash: $sha")
  else
    certs="unverified (keychain query failed)"; verified=0
  fi
  # trust-settings-export keys trustList by each certificate's SHA-1: an exact-hash check.
  export_file="$work/trust-settings-export.plist"
  rm -f "$export_file"
  if err=$("$security" trust-settings-export "$export_file" 2>&1); then
    if dump=$(plutil -p "$export_file" 2>/dev/null); then
      trusts=$(printf '%s\n' "$dump" | grep -c "\"$sha\" =>")
    else
      trusts="unverified (export unreadable)"; verified=0
    fi
  elif printf '%s' "$err" | grep -q "No Trust Settings were found"; then
    trusts=0
  else
    trusts="unverified (export failed)"; verified=0
  fi
  rm -f "$export_file"
  echo "certificate $sha in keychain: $certs; trust settings for it: $trusts"
  if [ "$verified" = 1 ] && [ "$certs" = 0 ] && [ "$trusts" = 0 ]; then
    rm -rf "$ca"
    echo "CA folder removed"
    return 0
  fi
  cat <<EOF
NOT REMOVED OR NOT VERIFIED. Kept $ca/mitmproxy-ca-cert.pem and sha1.txt (private key and all other files deleted). Recover with:
  security remove-trusted-cert "$ca/mitmproxy-ca-cert.pem"
  security delete-certificate -Z $sha "$keychain"
  security find-certificate -a -Z "$keychain" 2>&1 | grep -c "SHA-1 hash: $sha"    # expect 0
then delete $ca.
EOF
  return 1
}

cleanup() {
  status=$?
  set +e
  trap - INT TERM
  failed=0
  say "Restoring"
  # Not piped, so the failure flag stays in this shell; restore.txt is shown afterwards.
  {
    stop_proxy || failed=1
    remove_ca || failed=1
    if scutil --proxy | diff "$work/proxy-before.txt" - >/dev/null; then echo "system proxy settings: unchanged"
    else echo "system proxy settings: DIFFER from the before-state"; failed=1; fi
  } > "$work/restore.txt" 2>&1
  cat "$work/restore.txt"
  if [ "$launched" = 1 ] && desktop_running; then
    say "Claude Desktop is still running with --proxy-server to the stopped proxy. Quit it (Cmd-Q); waiting up to ${quit_timeout}s."
    if ! wait_until_quit "$quit_timeout"; then
      echo "Desktop not quit: quit it and start it normally yourself" | tee -a "$work/restore.txt"; failed=1
    fi
  fi
  if [ "$was_running" = 1 ] && [ "$quit_seen" = 1 ] && ! desktop_running; then
    "$opener" -g -a "$app" && echo "Claude Desktop started again without the proxy" | tee -a "$work/restore.txt"
  fi
  for f in "$work"/audit-*.jsonl; do
    [ -s "$f" ] && $uvpy "$here/summarize.py" "$f" > "$work/summary.md" && say "Summary: $work/summary.md" && cat "$work/summary.md"
  done
  if [ "$failed" = 1 ]; then echo "run directory: $work; CLEANUP INCOMPLETE (see restore.txt)"; exit 3; fi
  echo "run directory: $work (exit status $status)"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

say "1/5 Creating a 1-day CA limited to claude.ai in $ca"
"$here/make-ca.sh" --out "$ca" claude.ai
made_ca=1

say "2/5 Trusting it for SSL in the login keychain. macOS asks for your password: that step is yours."
"$security" add-trusted-cert -r trustRoot -p ssl -k "$keychain" "$ca/mitmproxy-ca-cert.pem"

say "3/5 Starting the audit proxy on 127.0.0.1:$port"
$uvpy -c '
import json, sys
paths = ["/api/organizations/{id}/chat_conversations", "/api/organizations/{id}/chat_conversations/{id}",
         "/api/organizations/{id}/chat_conversations/{id}/completion",
         "/api/organizations/{id}/chat_conversations/{id}/retry_completion"]
json.dump({"comment": "live-audit.sh; paths are candidates until matching requests are observed",
           "mode": "audit", "hosts": ["claude.ai"], "paths": paths,
           "profileZone": sys.argv[2], "profileLocale": sys.argv[3]}, open(sys.argv[1], "w"), indent=2)
' "$work/config.json" "$zone" "$locale"
CLA_CA_DIR="$ca" CLA_OUT_DIR="$work" "$here/run.sh" "$work/config.json" "$port" > "$work/run-sh.txt" 2>&1 &
proxy_pid=$!
n=0; until lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
  kill -0 "$proxy_pid" 2>/dev/null || { echo "proxy exited at startup (see $work/run-sh.txt)" >&2; exit 1; }
  sleep 1; n=$((n + 1)); [ $n -lt 120 ] || { echo "proxy did not start within 120 s" >&2; exit 1; }
done

if desktop_running; then
  say "4/5 Quit Claude Desktop yourself (Cmd-Q in Claude). Save or finish anything open first. Waiting up to ${quit_timeout}s."
  wait_until_quit "$quit_timeout" || { echo "Desktop was not quit; stopping" >&2; exit 1; }
fi
quit_seen=1
record_app
"$opener" -a "$app" --env "TZ=$zone" --args --proxy-server="http://127.0.0.1:$port" -AppleLanguages "($locale)"
launched=1
sleep 10
desktop_running || { echo "Claude Desktop exited at startup with --proxy-server (recorded as the result)" | tee "$work/startup.txt"; exit 1; }

say "5/5 In Claude Desktop: start a new chat, send: test, wait for the reply, open Settings, then quit Claude Desktop (Cmd-Q). Waiting up to ${chat_timeout}s."
wait_until_quit "$chat_timeout" || { echo "Desktop still running at the time limit; stopping" >&2; exit 1; }
say "Desktop quit; finishing"
