"""run.sh launcher: exit status, cleanup and the no-raw-output default. Local only."""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import time
from pathlib import Path

RUN = Path(__file__).resolve().parent.parent / "run.sh"


def _env(tmp_path, **extra):
    (tmp_path / "t").mkdir(exist_ok=True)
    return {**os.environ, "TMPDIR": str(tmp_path / "t"), "CLA_OUT_DIR": str(tmp_path / "out"),
            "CLA_CA_DIR": str(tmp_path / "no-ca"), **extra}


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_failed_start_keeps_status_cleans_up_and_prints_no_framework_output(tmp_path):
    cfg = tmp_path / "bad.json"
    cfg.write_text(json.dumps({"mode": "rewrite", "hosts": [], "comment": "URL0SECRET https://claude.ai/api/x"}))
    r = subprocess.run(["sh", str(RUN), str(cfg), str(_free_port())], env=_env(tmp_path), capture_output=True, text=True, timeout=120)
    assert r.returncode != 0
    assert f"exit status {r.returncode}" in r.stdout
    assert not any((tmp_path / "t").iterdir()), "throwaway confdir must be removed"
    assert sorted(p.name.split("-")[0] for p in (tmp_path / "out").iterdir()) == [], "no audit or raw log without a started add-on"
    for s in ("Traceback", "ConfigError", "URL0SECRET", "claude.ai"):
        assert s not in r.stdout + r.stderr


def test_field_audit_without_ca_exits_1(tmp_path):
    cfg = tmp_path / "c.json"
    cfg.write_text(json.dumps({"mode": "audit", "hosts": ["claude.ai"], "paths": []}))
    r = subprocess.run(["sh", str(RUN), str(cfg)], env=_env(tmp_path), capture_output=True, text=True, timeout=120)
    assert r.returncode == 1 and "no CA" in r.stderr


def test_usage_errors_exit_2(tmp_path):
    assert subprocess.run(["sh", str(RUN)], env=_env(tmp_path), capture_output=True).returncode == 2
    assert subprocess.run(["sh", str(RUN), str(tmp_path / "missing.json")], env=_env(tmp_path), capture_output=True).returncode == 2


def test_interrupt_stops_and_cleans_up(tmp_path):
    cfg = tmp_path / "ok.json"
    cfg.write_text(json.dumps({"mode": "audit", "hosts": [], "systemZone": "UTC", "systemLocale": "en-US"}))
    port = _free_port()
    p = subprocess.Popen(["sh", str(RUN), str(cfg), str(port)], env=_env(tmp_path), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    for _ in range(600):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.1).close()
            break
        except OSError:
            assert p.poll() is None, p.communicate()
            time.sleep(0.1)
    assert any((tmp_path / "t").iterdir())
    os.killpg(p.pid, signal.SIGINT)  # what Ctrl-C does
    out, err = p.communicate(timeout=30)
    assert not any((tmp_path / "t").iterdir()), "throwaway confdir must be removed"
    logs = list((tmp_path / "out").iterdir())
    assert [x.name.startswith("audit-") for x in logs] == [True], "only the sanitized audit log is kept"
    assert [json.loads(line)["event"] for line in logs[0].read_text().splitlines()][0] == "start"
    assert p.returncode == 130, (p.returncode, out, err)
