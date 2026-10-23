"""live-audit.sh: input validation and cleanup, with a fake `security`, app and `open`. Never
touches the real keychain, trust settings or Claude Desktop. Local only."""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
from pathlib import Path

import pytest

LIVE = Path(__file__).resolve().parent.parent / "live-audit.sh"

FAKE_SECURITY = r"""#!/bin/sh
# Fake macOS `security`: state lives in $FAKE_STATE; every call is logged. FAKE_READ_FAIL=keychain
# or =trust makes that verification query fail the way an unreadable keychain or export would.
echo "$*" >> "$FAKE_STATE/calls"
case "$1" in
  add-trusted-cert)
    [ "${FAKE_ADD_FAIL:-0}" = 1 ] && exit 1
    cert="$(eval echo \${$#})"
    openssl x509 -in "$cert" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' > "$FAKE_STATE/cert"
    cp "$FAKE_STATE/cert" "$FAKE_STATE/trust" ;;
  remove-trusted-cert) [ "${FAKE_REMOVE_FAIL:-0}" = 1 ] && exit 1; rm -f "$FAKE_STATE/trust" ;;
  delete-certificate) [ "${FAKE_REMOVE_FAIL:-0}" = 1 ] && exit 1; rm -f "$FAKE_STATE/cert" ;;
  show-keychain-info) [ "${FAKE_READ_FAIL:-}" = keychain ] && { echo "keychain could not be found" >&2; exit 50; }; exit 0 ;;
  # Like the real tool: exit 0 whatever happens, part of the listing on stderr.
  find-certificate) [ -f "$FAKE_STATE/cert" ] && echo "SHA-1 hash: $(cat "$FAKE_STATE/cert")" >&2; exit 0 ;;
  trust-settings-export)
    [ "${FAKE_READ_FAIL:-}" = trust ] && { echo "SecTrustSettingsCreateExternalRepresentation: denied" >&2; exit 1; }
    [ -f "$FAKE_STATE/trust" ] || { echo "SecTrustSettingsCreateExternalRepresentation: No Trust Settings were found." >&2; exit 1; }
    printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>trustList</key><dict><key>%s</key><dict/></dict></dict></plist>' \
      "$(cat "$FAKE_STATE/trust")" > "$2" ;;
esac
"""


def _port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _listening(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


@pytest.fixture
def env(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "security").write_text(FAKE_SECURITY)
    (bin_dir / "open").write_text('#!/bin/sh\necho "$*" >> "$FAKE_STATE/open"\n')
    for f in bin_dir.iterdir():
        f.chmod(0o755)
    app = tmp_path / "Fake Claude.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy("/bin/sleep", app / "Contents/MacOS/Claude")
    return {
        **os.environ, "FAKE_STATE": str(state), "CLA_APP": str(app), "CLA_SECURITY": str(bin_dir / "security"),
        "CLA_OPEN": str(bin_dir / "open"), "CLA_KEYCHAIN": str(tmp_path / "fake.keychain-db"),
        "CLA_CA_DIR": str(tmp_path / "ca"), "CLA_WORK": str(tmp_path / "work"),
        "CLA_CLI": "",  # never the real claude-locale: it targets the real Claude Desktop by bundle ID
        "CLA_QUIT_TIMEOUT": "2", "CLA_CHAT_TIMEOUT": "2",
    }


def _run(env, *args, timeout=240):
    return subprocess.run(["sh", str(LIVE), *args], env=env, capture_output=True, text=True, timeout=timeout)


@pytest.mark.parametrize("zone,locale", [("../../etc/passwd", "en-GB"), ("Mars/Olympus", "en-GB"),
                                         ("Asia/Tokyo", "xx-YY"), ("Asia/Tokyo", "en-GB; rm -rf /")])
def test_rejects_zone_or_locale_outside_the_catalog(env, zone, locale):
    r = _run(env, zone, locale, str(_port()))
    assert r.returncode == 2, r.stderr
    assert not Path(env["CLA_CA_DIR"]).exists()
    assert not (Path(env["FAKE_STATE"]) / "calls").exists()


def test_cancelled_trust_prompt_removes_the_ca_and_starts_nothing(env):
    port = _port()
    r = _run({**env, "FAKE_ADD_FAIL": "1"}, "Asia/Tokyo", "en-GB", str(port))
    assert r.returncode == 1, r.stdout + r.stderr
    assert not Path(env["CLA_CA_DIR"]).exists()
    restore = (Path(env["CLA_WORK"]) / "restore.txt").read_text()
    assert "in keychain: 0; trust settings for it: 0" in restore and "CA folder removed" in restore
    assert not (Path(env["CLA_WORK"]) / "config.json").exists(), "no proxy config before trust succeeds"
    assert not (Path(env["FAKE_STATE"]) / "open").exists()


def _with_running_app(env, port, **extra):
    app = subprocess.Popen([f"{env['CLA_APP']}/Contents/MacOS/Claude", "300"])
    try:
        return _run({**env, **extra}, "Asia/Tokyo", "en-GB", str(port))
    finally:
        app.kill()
        app.wait()


def test_desktop_not_quit_stops_only_the_owned_proxy_and_removes_the_ca(env):
    port, other = _port(), socket.socket()
    other.bind(("127.0.0.1", 0))
    other.listen()
    try:
        r = _with_running_app(env, port)
        assert r.returncode == 1, r.stdout + r.stderr
        assert "Desktop was not quit" in r.stderr
        assert not _listening(port), "the owned proxy is stopped"
        assert _listening(other.getsockname()[1]), "an unrelated listener is untouched"
    finally:
        other.close()
    restore = (Path(env["CLA_WORK"]) / "restore.txt").read_text()
    assert "proxy: stopped" in restore and "CA folder removed" in restore
    assert not Path(env["CLA_CA_DIR"]).exists()
    assert not (Path(env["FAKE_STATE"]) / "open").exists(), "Desktop was never quit, so it is not relaunched"


def test_failed_removal_keeps_recovery_material_and_exits_3(env):
    port = _port()
    r = _with_running_app(env, port, FAKE_REMOVE_FAIL="1")
    assert r.returncode == 3, r.stdout + r.stderr
    assert "CLEANUP INCOMPLETE" in r.stdout and "NOT REMOVED OR NOT VERIFIED" in r.stdout
    ca = Path(env["CLA_CA_DIR"])
    assert sorted(p.name for p in ca.iterdir()) == ["mitmproxy-ca-cert.pem", "sha1.txt"], "key deleted, public cert kept"
    sha = (ca / "sha1.txt").read_text().strip()
    assert f"delete-certificate -Z {sha}" in r.stdout
    assert not _listening(port)


@pytest.mark.parametrize("which", ["keychain", "trust"])
def test_unreadable_verification_is_never_counted_as_removed(env, which):
    port = _port()
    r = _with_running_app(env, port, FAKE_READ_FAIL=which)
    assert r.returncode == 3, r.stdout + r.stderr
    assert "unverified" in r.stdout and "CLEANUP INCOMPLETE" in r.stdout
    ca = Path(env["CLA_CA_DIR"])
    assert sorted(p.name for p in ca.iterdir()) == ["mitmproxy-ca-cert.pem", "sha1.txt"]
    assert not list(Path(env["CLA_WORK"]).glob("trust-settings-export*")), "the export is not left behind"
