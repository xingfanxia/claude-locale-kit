"""Fixture-only tests for locale_audit.py. No real host, account or system trust store is used:
certificates are generated in a temporary directory and trusted only by the test's own clients
and by mitmproxy through ssl_verify_upstream_trusted_ca. TLS verification stays on everywhere."""
from __future__ import annotations

import datetime as dt
import hashlib
import http.client
import http.server
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent
sys.path.insert(0, str(TOOL))
import locale_audit as la  # noqa: E402

SECRETS = ["SECRET-PROMPT-TEXT", "ORG0SECRET", "COOKIE0SECRET", "TOKEN0SECRET", "CONV0SECRET", "QUERY0SECRET", "Asia/Shanghai", "zh-CN"]


# ---- unit ----------------------------------------------------------------------------------

def test_config_is_strict():
    ok = {"mode": "audit", "hosts": ["claude.ai"], "paths": ["/api/x/{id}/y"]}
    assert la.load_config(ok, detect=False).hosts == frozenset({"claude.ai"})
    for bad in [{**ok, "mode": "rewrite"}, {**ok, "mode": None}, {**ok, "extra": 1}, {**ok, "hosts": ["*.claude.ai"]},
                {**ok, "hosts": ["claude.ai:443"]}, {**ok, "hosts": ["https://claude.ai"]}, {**ok, "paths": ["api/x"]},
                {**ok, "paths": ["/api/x?y=1"]}, {**ok, "paths": ["/api/*"]}, {**ok, "hosts": [], "paths": ["/a"]},
                {**ok, "systemZone": "Mars/Base"}, {**ok, "profileLocale": "english"}, [], {**ok, "discoverPathShapes": True}]:
        with pytest.raises(la.ConfigError):
            la.load_config(bad, detect=False)


def test_templates():
    t = la.load_config({"mode": "audit", "hosts": ["claude.ai"], "paths": ["/api/o/{id}/c/{id}/completion"]}, detect=False).paths
    assert la.match_template("/api/o/abc/c/def/completion?x=1", t) == "/api/o/{id}/c/{id}/completion"
    assert la.match_template("/api/o//c/def/completion", t) is None
    assert la.match_template("/api/o/abc/c/def/completion/extra", t) is None


REFS = {"system_zone": "Asia/Shanghai", "profile_zone": "America/Los_Angeles", "system_locale": "zh-CN", "profile_locale": "en-US"}


def test_only_known_names_under_known_containers():
    cls = la.Classifier(REFS, now=dt.datetime(2026, 10, 21, 18, 0, tzinfo=dt.timezone.utc))
    doc = {"timezone": "Asia/Shanghai", "locale": "zh-CN", "tz_offset": -480,
           "prompt": "SECRET-PROMPT-TEXT Asia/Shanghai", "KEY0SECRET": "Asia/Shanghai", "rendering_mode": "messages",
           "messages": [{"content": "SECRET-PROMPT-TEXT", "timezone": "Asia/Shanghai", "KEY0SECRET": 1}],
           "metadata": {"timezone": "America/Los_Angeles", "KEY0SECRET": {"timezone": "UTC"}, "client": {"locale": "en-US"}},
           "tools": [{"name": "TOOL0SECRET", "input_schema": {"timezone": {"type": "string"}}}],
           "secret_container": {"timezone": "Asia/Shanghai"}}
    r = la.json_signals(doc, cls)
    got = {f["at"]: f for f in r["fields"]}
    assert set(got) == {"$.timezone", "$.locale", "$.tz_offset", "$.metadata.timezone", "$.metadata.client.locale"}
    assert got["$.timezone"]["kind"] == "iana_zone" and got["$.timezone"]["matches"] == ["system_zone"]
    assert got["$.locale"]["matches"] == ["system_locale"]
    assert got["$.tz_offset"]["kind"] == "number" and got["$.tz_offset"]["matches"] == ["system_offset"]
    assert got["$.metadata.timezone"]["matches"] == ["profile_zone"]
    assert got["$.metadata.client.locale"]["matches"] == ["profile_locale"]
    assert r["skipped_containers"] == 3 and r["other_keys"] == 4
    assert r["unlisted_exact_value_matches"] == {"system_zone": 1}
    dumped = json.dumps(r)
    for s in SECRETS + ["KEY0SECRET", "TOOL0SECRET", "secret_container", "rendering_mode", "prompt", "messages", "-480"]:
        assert s not in dumped


def test_node_budget_is_bounded():
    r = la.json_signals({"metadata": [{"context": {}}] * (la.MAX_NODES + 10)}, la.Classifier({}))
    assert r["status"] == "truncated" and r["fields"] == []


# ---- end to end ----------------------------------------------------------------------------

def _key():
    return ec.generate_private_key(ec.SECP256R1())


def _pem(obj) -> bytes:
    if isinstance(obj, x509.Certificate):
        return obj.public_bytes(serialization.Encoding.PEM)
    return obj.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def _cert(subject_key, cn, issuer=None, issuer_key=None, ca=False, sans=()):
    now = dt.datetime.now(dt.timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    b = (x509.CertificateBuilder().subject_name(name).issuer_name(issuer.subject if issuer else name)
         .public_key(subject_key.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(now - dt.timedelta(minutes=5)).not_valid_after(now + dt.timedelta(hours=2))
         .add_extension(x509.BasicConstraints(ca=ca, path_length=0 if ca else None), critical=True))
    b = b.add_extension(x509.SubjectKeyIdentifier.from_public_key(subject_key.public_key()), critical=False)
    b = b.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key((issuer_key or subject_key).public_key()), critical=False)
    if ca:
        b = b.add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
    if sans:
        b = b.add_extension(x509.SubjectAlternativeName([x509.DNSName(s) for s in sans]), critical=False)
    return b.sign(issuer_key or subject_key, hashes.SHA256())


class Fixture(http.server.BaseHTTPRequestHandler):
    """Upstream stand-in. The completion route answers with server-sent events: one event, then it
    blocks until the test releases it, so the test can see whether the proxy buffers."""
    received: list = []
    release = threading.Event()
    cancelled = threading.Event()
    sent: list = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        Fixture.received.append({"path": self.path, "sha": hashlib.sha256(body).hexdigest(), "headers": {k.lower(): v for k, v in self.headers.items()}})
        if self.path.split("?")[0].endswith("/completion"):
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.end_headers()
            first = b"event: message\ndata: {\"n\":1}\n\n"
            self.wfile.write(first)
            self.wfile.flush()
            sent = [first]
            Fixture.release.wait(10)
            try:
                deadline = time.time() + 5
                while time.time() < deadline:
                    chunk = b"data: {\"n\":2}\n\n"
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent.append(chunk)
                    if self.headers.get("x-test-mode") != "cancel":
                        break
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
                Fixture.cancelled.set()
            Fixture.sent.append(b"".join(sent))
            return
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", "11")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a):
        pass


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture()
def world(tmp_path):
    # Throwaway fixture upstream CA + one leaf for all test host names. Trusted only by this
    # test's clients and by mitmproxy via ssl_verify_upstream_trusted_ca; never by the system.
    up_key = _key()
    up_ca = _cert(up_key, "fixture upstream CA", ca=True)
    leaf_key = _key()
    leaf = _cert(leaf_key, "claude.ai", up_ca, up_key, sans=["claude.ai", "other.example", "sni0secret.example"])
    (tmp_path / "up-ca.pem").write_bytes(_pem(up_ca))
    (tmp_path / "leaf.pem").write_bytes(_pem(leaf) + _pem(leaf_key))
    # Audit CA from the real make-ca.sh, written to the temporary directory only.
    subprocess.run(["sh", str(TOOL / "make-ca.sh"), "--out", str(tmp_path / "ca"), "--days", "1", "claude.ai"], check=True,
                   capture_output=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    sctx.load_cert_chain(tmp_path / "leaf.pem")
    server.socket = sctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    Fixture.received, Fixture.sent = [], []
    Fixture.release.clear()
    Fixture.cancelled.clear()
    yield tmp_path, server.server_address[1]
    Fixture.release.set()
    server.shutdown()


def _start_proxy(tmp_path, fixture_port, cfg):
    (tmp_path / "config.json").write_text(json.dumps(cfg))
    port = _free_port()
    log = tmp_path / "audit.jsonl"
    proc = subprocess.Popen(
        [sys.executable, "-c", "from mitmproxy.tools.main import mitmdump; mitmdump()", "-q", "--listen-host", "127.0.0.1",
         "--listen-port", str(port), "--set", f"confdir={tmp_path / 'ca'}", "--set", "ssl_insecure=false", "--set", "upstream_cert=false",
         "--set", f"ssl_verify_upstream_trusted_ca={tmp_path / 'up-ca.pem'}", "--set", "flow_detail=0", "-s", str(TOOL / "locale_audit.py"), "-s", str(HERE / "fixture_redirect.py"),
         "--set", f"fixture_port={fixture_port}", "--set", f"cla_config={tmp_path / 'config.json'}", "--set", f"cla_out={log}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for _ in range(200):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.1).close()
            return proc, port, log
        except OSError:
            if proc.poll() is not None:
                raise RuntimeError(proc.stderr.read().decode())
            time.sleep(0.05)
    raise RuntimeError("proxy did not start")


def _connect(port, host, cafile):
    ctx = ssl.create_default_context(cafile=str(cafile))  # verification on, host name checked
    conn = http.client.HTTPSConnection("127.0.0.1", port, context=ctx, timeout=10)
    conn.set_tunnel(host, 443)
    return conn


def _issuer(conn):
    return dict(x[0] for x in conn.sock.getpeercert()["issuer"])["commonName"]


def _post(port, host, path, body, headers, cafile):
    conn = _connect(port, host, cafile)
    conn.request("POST", path, body=body, headers=headers)
    issuer = _issuer(conn)
    r = conn.getresponse()
    data = r.read()
    conn.close()
    return r.status, data, issuer


def _stop(proc):
    proc.terminate()
    out, err = proc.communicate(timeout=20)
    return (out + err).decode("utf-8", "replace")


BODY = json.dumps({"prompt": "SECRET-PROMPT-TEXT “hi” Asia/Shanghai", "timezone": "Asia/Shanghai", "locale": "zh-CN",
                   "KEY0SECRET": "Asia/Shanghai", "messages": [{"content": "SECRET-PROMPT-TEXT", "timezone": "UTC"}]},
                  ensure_ascii=False).encode()
HEADERS = {"content-type": "application/json", "cookie": "sessionKey=COOKIE0SECRET", "authorization": "Bearer TOKEN0SECRET",
           "accept-language": "zh-CN,zh;q=0.9", "x-header0secret": "Asia/Shanghai"}
COMPLETION = "/api/organizations/ORG0SECRET/chat_conversations/CONV0SECRET/completion"
QUERY = "?tz=Asia/Shanghai&QKEY0SECRET=QUERY0SECRET"
TEMPLATE = "/api/organizations/{id}/chat_conversations/{id}/completion"
CFG = {"mode": "audit", "hosts": ["claude.ai"], "paths": [TEMPLATE], "systemZone": "Asia/Shanghai", "systemLocale": "zh-CN",
       "profileZone": "America/Los_Angeles", "profileLocale": "en-US"}


def test_audit_end_to_end(world):
    tmp_path, fport = world
    proc, port, log = _start_proxy(tmp_path, fport, CFG)
    audit_ca = tmp_path / "ca" / "mitmproxy-ca-cert.pem"
    big = json.dumps({"timezone": "Asia/Shanghai", "attachments": ["x" * (la.MAX_AUDIT_BYTES + 1024)]}).encode()
    try:
        # 1. Streaming: the first SSE event must arrive while the upstream is still holding the stream open.
        conn = _connect(port, "claude.ai", audit_ca)
        conn.request("POST", COMPLETION + QUERY, body=BODY, headers=HEADERS)
        # (method sentinel below: a non-standard method name must map to OTHER)
        assert _issuer(conn).startswith("claude-locale-kit audit CA")
        r = conn.getresponse()
        assert r.status == 200
        first = r.readline() + r.readline() + r.readline()
        assert first == b"event: message\ndata: {\"n\":1}\n\n"
        assert not Fixture.release.is_set(), "first event arrived only after upstream release: response was buffered"
        Fixture.release.set()
        rest = r.read()
        conn.close()
        assert first + rest == Fixture.sent[0], "streamed response bytes must be identical"
        # 2. Cancellation: the app closes mid-stream; the upstream must see the disconnect.
        Fixture.release.clear()
        conn = _connect(port, "claude.ai", audit_ca)
        conn.request("POST", COMPLETION, body=BODY, headers={**HEADERS, "x-test-mode": "cancel"})
        sock = conn.sock
        r = conn.getresponse()
        assert r.readline().startswith(b"event: message")
        r.close()
        sock.close()
        conn.close()
        Fixture.release.set()
        assert Fixture.cancelled.wait(8), "upstream never saw the client's cancellation"
        # 3. A non-template route on the allowlisted host: counted, nothing else.
        assert _post(port, "claude.ai", "/api/SLUG0SECRET/x?QKEY0SECRET=QUERY0SECRET", BODY, HEADERS, audit_ca)[0] == 200
        # 4. Oversized body on the template: streamed through, not read.
        Fixture.release.set()
        status, _, _ = _post(port, "claude.ai", COMPLETION, big, {**HEADERS, "x-test-mode": "big"}, audit_ca)
        assert status == 200
        # Caller-controlled method names never reach the log.
        conn = _connect(port, "claude.ai", audit_ca)
        conn.request("METHOD0SECRET", COMPLETION, body=b"", headers={})
        assert conn.getresponse().status in (200, 501)
        conn.close()
        # 5. Not allowlisted: opaque tunnel; the client sees the upstream's own certificate.
        status, _, issuer = _post(port, "sni0secret.example", "/x?QKEY0SECRET=QUERY0SECRET", BODY, HEADERS, tmp_path / "up-ca.pem")
        assert status == 200 and issuer == "fixture upstream CA"
    finally:
        output = _stop(proc)

    sha = hashlib.sha256(BODY).hexdigest()
    assert [r["sha"] for r in Fixture.received if r["path"].startswith(COMPLETION)][:2] == [sha, sha]
    assert Fixture.received[-2]["sha"] == hashlib.sha256(big).hexdigest()
    assert Fixture.received[-1]["sha"] == sha
    for r in Fixture.received:
        assert r["headers"]["cookie"] == HEADERS["cookie"] and r["headers"]["x-header0secret"] == "Asia/Shanghai"
    text = log.read_text()
    recs = [json.loads(line) for line in text.splitlines()]
    events = [r["event"] for r in recs]
    assert events[0] == "start" and events[-1] == "stop" and events.count("tunnel") == 1
    assert events.count("unmatched_route") >= 1
    reqs = [r for r in recs if r["event"] == "request"]
    assert len(reqs) == 4 and reqs[0]["method"] == "POST" and reqs[3]["method"] == "OTHER"
    req = reqs[0]
    assert req["template"] == TEMPLATE
    assert req["headers"] == [{"at": "accept-language", "kind": "locale_list", "matches": ["system_locale"]}]
    assert req["other_headers"] >= 4 and req["unlisted_exact_value_matches"] == {"system_zone": 1}
    assert req["query"] == [{"at": "tz", "kind": "iana_zone", "matches": ["system_zone"]}] and req["other_query"] == 1
    body = req["body"]
    assert body["status"] == "inspected" and body["skipped_containers"] == 2 and body["other_keys"] == 1
    assert {f["at"]: f["matches"] for f in body["fields"]} == {"$.timezone": ["system_zone"], "$.locale": ["system_locale"]}
    assert reqs[2]["body"] == {"status": "skipped_too_large"} and reqs[3]["body"] == {"status": "empty"}
    for s in SECRETS + ["KEY0SECRET", "SLUG0SECRET", "QKEY0SECRET", "HEADER0SECRET", "header0secret", "sni0secret", "sessionKey",
                        "Bearer", "x-test-mode", "METHOD0SECRET", "cookie", "authorization", "prompt", "messages", "?", "“"]:
        assert s not in text, f"log leaked {s!r}"
        assert s not in output, f"proxy output leaked {s!r}"
    assert oct(os.stat(log).st_mode & 0o777) == "0o600"


def test_tunnel_only_decrypts_nothing(world):
    tmp_path, fport = world
    proc, port, log = _start_proxy(tmp_path, fport, {"mode": "audit", "hosts": [], "systemZone": "UTC", "systemLocale": "en-US"})
    try:
        Fixture.release.set()
        status, _, issuer = _post(port, "claude.ai", COMPLETION, BODY, HEADERS, tmp_path / "up-ca.pem")
        assert status == 200 and issuer == "fixture upstream CA"
    finally:
        _stop(proc)
    assert [json.loads(line)["event"] for line in log.read_text().splitlines()] == ["start", "tunnel", "stop"]
    assert Fixture.received[0]["sha"] == hashlib.sha256(BODY).hexdigest()


def test_make_ca_constrains_names(tmp_path):
    subprocess.run(["sh", str(TOOL / "make-ca.sh"), "--out", str(tmp_path / "ca"), "--days", "2", "claude.ai"], check=True,
                   capture_output=True)
    pem = (tmp_path / "ca" / "mitmproxy-ca-cert.pem").read_bytes()
    ca = x509.load_pem_x509_certificate(pem)
    nc = ca.extensions.get_extension_for_class(x509.NameConstraints)
    assert nc.critical and [n.value for n in nc.value.permitted_subtrees] == ["claude.ai"]
    assert ca.extensions.get_extension_for_class(x509.BasicConstraints).value.path_length == 0
    assert ca.not_valid_after_utc - ca.not_valid_before_utc <= dt.timedelta(days=2)
    assert oct(os.stat(tmp_path / "ca" / "mitmproxy-ca.pem").st_mode & 0o777) == "0o600"
    # OpenSSL (this test's verifier) enforces the constraint. macOS/Chromium enforcement is untested.
    key = serialization.load_pem_private_key((tmp_path / "ca" / "mitmproxy-ca.pem").read_bytes(), None)
    for host, ok in [("claude.ai", True), ("api.claude.ai", True), ("example.com", False)]:
        leaf = _cert(_key(), host, ca, key, sans=[host])
        (tmp_path / "leaf.pem").write_bytes(_pem(leaf))
        r = subprocess.run(["openssl", "verify", "-CAfile", str(tmp_path / "ca" / "mitmproxy-ca-cert.pem"), str(tmp_path / "leaf.pem")],
                           capture_output=True, text=True)
        assert (r.returncode == 0) == ok, (host, r.stdout, r.stderr)
    sha1 = (tmp_path / "ca" / "sha1.txt").read_text().strip()
    assert sha1 == ca.fingerprint(hashes.SHA1()).hex().upper()
    subprocess.run(["sh", str(TOOL / "make-ca.sh"), "--out", str(tmp_path / "d"), "claude.ai"], check=True, capture_output=True)
    d = x509.load_pem_x509_certificate((tmp_path / "d" / "mitmproxy-ca-cert.pem").read_bytes())
    assert d.not_valid_after_utc - d.not_valid_before_utc <= dt.timedelta(days=1), "default validity is one day"
    again = subprocess.run(["sh", str(TOOL / "make-ca.sh"), "--out", str(tmp_path / "ca"), "claude.ai"], capture_output=True)
    assert again.returncode == 1, "must refuse to overwrite an existing CA"
    for bad in [["*.claude.ai"], ["--days", "90", "claude.ai"], []]:
        assert subprocess.run(["sh", str(TOOL / "make-ca.sh"), "--out", str(tmp_path / "x"), *bad], capture_output=True).returncode == 2


def test_summarize_builds_tables_from_log_records():
    import summarize
    lines = [json.dumps(r) for r in [
        {"event": "start"}, {"event": "tunnel"}, {"event": "unmatched_route", "host": "claude.ai"},
        {"event": "request", "template": TEMPLATE, "method": "POST",
         "headers": [{"at": "accept-language", "kind": "locale_list", "matches": ["system_locale"]}],
         "query": [], "unlisted_exact_value_matches": {"system_zone": 1},
         "body": {"status": "inspected", "fields": [{"at": "$.timezone", "kind": "iana_zone", "matches": ["system_zone"], "count": 1}]}},
        {"event": "stop"}]]
    md = summarize.summarize(lines)
    assert f"| `{TEMPLATE}` | `header accept-language` | locale_list | system_locale | 1 |" in md
    assert f"| `{TEMPLATE}` | `body $.timezone` | iana_zone | system_zone | 1 |" in md
    assert f"| `{TEMPLATE}` | inspected | 1 |" in md and "| tunnel | 1 |" in md
