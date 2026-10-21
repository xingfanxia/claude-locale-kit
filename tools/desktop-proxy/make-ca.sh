#!/bin/sh
# Create a short-lived, name-constrained CA for the Desktop Chat audit proxy.
# It only writes files. It never installs or trusts anything; trusting it is a separate,
# explicit user step (README.md, live validation step 3).
#
# Usage: make-ca.sh [--out DIR] [--days N] HOST...
#   DIR defaults to ~/creds/claude-locale-kit/audit-ca (private keys never go in the repo).
#   N defaults to 1 day (one test run); at most 30.
#   HOSTs are the exact names permitted by the CA's nameConstraints, e.g. claude.ai.
# Name constraints limit what the CA may sign for verifiers that enforce them; enforcement by
# macOS/Chromium for user-trusted roots has not been tested by this project.
set -eu

out="${HOME}/creds/claude-locale-kit/audit-ca"
days=1
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --days) days="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "make-ca.sh: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "make-ca.sh: name at least one permitted HOST (e.g. claude.ai)" >&2; exit 2; }
case "$days" in ''|*[!0-9]*) echo "make-ca.sh: --days must be a number" >&2; exit 2 ;; esac
[ "$days" -ge 1 ] && [ "$days" -le 30 ] || { echo "make-ca.sh: --days must be 1..30" >&2; exit 2; }

permitted=""
for h in "$@"; do
  printf '%s' "$h" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
    || { echo "make-ca.sh: not an exact lowercase host name: $h" >&2; exit 2; }
  permitted="${permitted:+$permitted,}permitted;DNS:$h"
done

if [ -e "$out/mitmproxy-ca.pem" ]; then
  echo "make-ca.sh: $out already holds a CA; remove it first (see README.md, Restore)" >&2
  exit 1
fi
umask 077
mkdir -p "$out"
cfg="$out/ca.cnf"
cat > "$cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = claude-locale-kit audit CA (temporary, $(date -u +%Y-%m-%d))
O = claude-locale-kit local test
[ext]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,$permitted
EOF
openssl ecparam -name prime256v1 -genkey -noout -out "$out/ca.key"
openssl req -new -x509 -sha256 -days "$days" -key "$out/ca.key" -config "$cfg" -out "$out/mitmproxy-ca-cert.pem"
cat "$out/ca.key" "$out/mitmproxy-ca-cert.pem" > "$out/mitmproxy-ca.pem"
rm -f "$out/ca.key" "$cfg"
chmod 600 "$out/mitmproxy-ca.pem" "$out/mitmproxy-ca-cert.pem"
# Restore deletes this exact certificate by hash, never by name.
openssl x509 -in "$out/mitmproxy-ca-cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' > "$out/sha1.txt"
chmod 600 "$out/sha1.txt"
echo "wrote $out/mitmproxy-ca.pem (key + cert, mitmproxy confdir) and $out/mitmproxy-ca-cert.pem (cert only)"
echo "SHA-1 (for restore): $(cat "$out/sha1.txt")  saved in $out/sha1.txt"
openssl x509 -in "$out/mitmproxy-ca-cert.pem" -noout -subject -enddate
