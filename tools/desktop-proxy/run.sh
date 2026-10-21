#!/bin/sh
# Start the audit proxy on 127.0.0.1 only. It changes no system setting; only an app launched
# with --proxy-server=http://127.0.0.1:PORT uses it. Ctrl-C stops it. See README.md.
#
# Usage: run.sh CONFIG.json [PORT]
#   Config with "hosts": []  -> tunnel-only: nothing is decrypted; a throwaway confdir is used.
#   Config with hosts        -> field audit for those hosts; needs the CA from make-ca.sh in
#                               $CLA_CA_DIR (default ~/creds/claude-locale-kit/audit-ca).
# The only record kept is the add-on's sanitized JSONL (in $CLA_OUT_DIR, default
# scratch/data/desktop-proxy). mitmproxy's own output is not sanitized (errors can name hosts or
# URLs), so it is discarded unless CLA_RAW_FRAMEWORK_LOG=1 is set for a debugging run.
# Exit status: mitmproxy's own; 1 for a missing CA; 2 for usage errors.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: run.sh CONFIG.json [PORT]" >&2; exit 2; }
config="$1"
port="${2:-18080}"
ca="${CLA_CA_DIR:-$HOME/creds/claude-locale-kit/audit-ca}"
outdir="${CLA_OUT_DIR:-$root/scratch/data/desktop-proxy}"
mitm="mitmproxy==12.2.3"

hosts=$(uv run --no-project --quiet --python 3.14 python -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["hosts"]))' "$config" 2>/dev/null) \
  || { echo "run.sh: cannot read \"hosts\" from $config" >&2; exit 2; }
tmp=""
cleanup() { if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; return 0; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$hosts" = "0" ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-locale-audit.XXXXXX")
  confdir="$tmp"
  echo "tunnel-only: no host is decrypted"
else
  [ -s "$ca/mitmproxy-ca.pem" ] || { echo "run.sh: no CA in $ca. Create it with make-ca.sh (README.md)." >&2; exit 1; }
  confdir="$ca"
fi
mkdir -p "$outdir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$outdir/audit-$stamp.jsonl"
framework=/dev/null
if [ "${CLA_RAW_FRAMEWORK_LOG:-0}" = "1" ]; then
  framework="$outdir/mitmproxy-raw-$stamp.log"
  ( umask 077; : > "$framework" )
  echo "WARNING: raw mitmproxy output (may contain host names and URLs) goes to $framework; delete it after debugging" >&2
fi
echo "listening on 127.0.0.1:$port; audit log: $out. Ctrl-C stops."
status=0
# upstream_cert=false: the generated leaf names only the requested host, never the upstream
# certificate's other names (which would also violate the CA's name constraints).
uv run --no-project --quiet --python 3.14 --with "$mitm" mitmdump -q \
  --listen-host 127.0.0.1 --listen-port "$port" \
  --set confdir="$confdir" --set ssl_insecure=false --set upstream_cert=false --set flow_detail=0 \
  -s "$here/locale_audit.py" --set cla_config="$config" --set cla_out="$out" >>"$framework" 2>&1 || status=$?
echo "proxy stopped (exit status $status)"
exit "$status"
