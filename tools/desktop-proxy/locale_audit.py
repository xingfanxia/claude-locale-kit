"""mitmproxy add-on: audit where time zone and locale appear in Claude Desktop Chat requests.

Audit only: requests and responses pass through unchanged, and responses are always streamed
(never buffered), so server-sent events reach the app as they arrive.

What it records, for allowlisted host + exact path templates only:
  - which of a FIXED list of candidate field names (KNOWN_FIELDS) occur, at body paths built only
    from FIXED container names (KNOWN_CONTAINERS); the value's *kind* (iana_zone, locale, ...) and
    whether it equals the configured system/profile zone, locale, date or offset;
  - the same for a FIXED list of headers (KNOWN_HEADERS) and query parameter names (KNOWN_FIELDS);
  - counts of everything else (other keys/headers/query names, unmatched routes, tunnels).
It never records values, unknown key/header/query names, URLs, paths outside the templates,
cookies, authorization, prompts or other content. Content containers (SKIP_CONTAINERS) are not
read at all. Connections to non-allowlisted hosts are opaque TLS tunnels, counted without a name.

Options: cla_config (JSON config, see config.example.json), cla_out (JSONL log, mode 0600).
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import subprocess
import zoneinfo
from typing import Any
from urllib.parse import parse_qsl

from mitmproxy import ctx, http, tls

# ---- fixed vocabularies: the only names that can ever appear in the log -----------------------
KNOWN_FIELDS = frozenset({
    "timezone", "time_zone", "timeZone", "tz", "tzid", "tz_name", "timezone_name", "timezoneName", "iana_timezone",
    "client_timezone", "clientTimezone", "user_timezone", "userTimezone", "timezone_offset", "timezoneOffset",
    "tz_offset", "utc_offset", "utcOffset", "offset_minutes", "locale", "user_locale", "userLocale", "client_locale",
    "clientLocale", "language", "languages", "lang", "preferred_languages", "preferredLanguages", "accept_language",
    "region", "country", "country_code", "calendar", "hour_cycle", "hourCycle", "local_date", "localDate",
    "local_time", "localTime", "current_date", "currentDate", "now",
})
KNOWN_CONTAINERS = frozenset({
    "metadata", "client", "client_info", "clientInfo", "context", "client_context", "clientContext", "device",
    "environment", "settings", "preferences", "locale_settings", "user_context", "userContext", "intl",
})
SKIP_CONTAINERS = frozenset({
    "prompt", "messages", "message", "content", "contents", "text", "tools", "tool_results", "attachments", "files",
    "file", "documents", "parent_message_uuid", "personalized_styles", "style", "artifacts", "sync_sources", "images",
    "input", "system", "conversation", "history", "memory",
})
KNOWN_HEADERS = frozenset({
    "accept-language", "content-language", "timezone", "time-zone", "x-timezone", "x-time-zone", "x-client-timezone",
    "x-user-timezone", "x-locale", "x-client-locale", "x-user-locale", "x-language",
})

CONFIG_KEYS = {"mode", "hosts", "paths", "discoverRoutes", "systemZone", "systemLocale", "profileZone", "profileLocale",
               "comment"}
# Route-shape discovery keeps a path segment only if it is in this fixed vocabulary of structural
# route words; every other segment, lowercase or not, becomes {id}, so names and IDs never appear.
# Source: the claude.ai API path literals in Claude Desktop 3.6556.2's app.asar, plus the generic
# route words in the last line.
SHAPE_VOCAB = frozenset("""
account account_profile accounts api artifacts auth batch bootstrap browser_extension bundle call can_install
chat_conversations claude_cli claude_cli_feedback claude_code comments contents conversations cowork create_api_key cri
current_user_access db desktop domain_info dxt event_logging favorite features files frame graphql installed_check
internal library license local_pairing logout lti marketplace marketplaces mcp members memory memory_import
microsoft_entra_tenants model_selector npm oauth onboarding organizations plugins policy_limits profile projects
quick_write_requests remote_devices retitle roles rum scheduled_tasks self servers session_deletions settings
share_from_content skills start sync token trusted_devices update url_hash_check usage user web web_fetch wiggle
completion retry_completion messages message conversation chat chats new sessions session code watch v1 v2 v3 stream
""".split())
MAX_SHAPE_SEGMENTS = 12
HOST_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")
SEGMENT_RE = re.compile(r"^(?:\{id\}|[A-Za-z0-9_.~-]{1,64})$")
LOCALE_RE = re.compile(r"^[a-z]{2,3}(?:[-_][A-Z][a-z]{3})?(?:[-_](?:[A-Z]{2}|\d{3}))?$")
LOCALE_LIST_RE = re.compile(r"^\s*(?:[A-Za-z]{1,8}(?:[-_][A-Za-z0-9]{1,8})*|\*)(?:\s*;\s*q=[0-9.]+)?(?:\s*,\s*(?:[A-Za-z]{1,8}(?:[-_][A-Za-z0-9]{1,8})*|\*)(?:\s*;\s*q=[0-9.]+)?)+\s*$")
OFFSET_RE = re.compile(r"^(?:UTC|GMT)?[+-]\d{1,2}(?::?\d{2})?$")
DATETIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?P<zone>Z|[+-]\d{2}:?\d{2})?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
MAX_AUDIT_BYTES = 256 * 1024
MAX_NODES = 5000
MAX_DEPTH = 6
MAX_VALUE_LEN = 64
ZONES = zoneinfo.available_timezones() | {"UTC"}


class ConfigError(ValueError):
    pass


class Config:
    # A plain class: mitmproxy loads scripts outside sys.modules, which @dataclass cannot handle.
    def __init__(self, hosts: frozenset[str], paths: tuple[tuple[str, ...], ...], refs: dict[str, str],
                 discover: bool = False):
        self.discover = discover
        self.hosts = hosts
        self.paths = paths
        self.refs = refs  # label -> reference zone or locale


def _system_zone() -> str | None:
    try:
        target = os.readlink("/etc/localtime")
    except OSError:
        return None
    return target.split("zoneinfo/", 1)[1] if "zoneinfo/" in target else None


def _system_locale() -> str | None:
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLocale"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    value = out.stdout.strip().split("@", 1)[0]
    return value.replace("_", "-") if out.returncode == 0 and value else None


def load_config(raw: Any, detect: bool = True) -> Config:
    """Strict: unknown keys, any mode but "audit", wildcard hosts and malformed paths are rejected."""
    if not isinstance(raw, dict):
        raise ConfigError("config must be a JSON object")
    unknown = set(raw) - CONFIG_KEYS
    if unknown:
        raise ConfigError(f"unknown config keys: {sorted(unknown)}")
    if raw.get("mode") != "audit":
        raise ConfigError('"mode" must be "audit"; no rewrite mode exists until request evidence selects one')
    hosts = raw.get("hosts")
    if not isinstance(hosts, list) or not all(isinstance(h, str) and HOST_RE.match(h) for h in hosts):
        raise ConfigError('"hosts" must be a list of exact lowercase host names (no wildcards, ports or schemes)')
    paths = raw.get("paths", [])
    if not isinstance(paths, list):
        raise ConfigError('"paths" must be a list')
    templates = []
    for p in paths:
        if not isinstance(p, str) or not p.startswith("/") or "?" in p or "#" in p:
            raise ConfigError(f"bad path template {p!r}: must start with / and carry no query")
        segs = tuple(p.split("/")[1:])
        if not all(SEGMENT_RE.match(s) for s in segs):
            raise ConfigError(f"bad path template {p!r}: segments are literals or {{id}}")
        templates.append(segs)
    if templates and not hosts:
        raise ConfigError('"paths" needs at least one host')
    discover = raw.get("discoverRoutes", False)
    if not isinstance(discover, bool):
        raise ConfigError('"discoverRoutes" must be true or false')
    refs: dict[str, str] = {}
    for key, label, auto in (("systemZone", "system_zone", _system_zone), ("profileZone", "profile_zone", None),
                             ("systemLocale", "system_locale", _system_locale), ("profileLocale", "profile_locale", None)):
        value = raw.get(key)
        if value is None and detect and auto:
            value = auto()
        if value is None:
            continue
        if not isinstance(value, str) or not (value in ZONES if key.endswith("Zone") else LOCALE_RE.match(value)):
            raise ConfigError(f'"{key}" must be a {"time zone" if key.endswith("Zone") else "locale tag"}')
        refs[label] = value
    return Config(frozenset(hosts), tuple(templates), refs, discover)


def route_shape(path: str) -> str:
    """The path with every segment outside SHAPE_VOCAB replaced by {id}; no query."""
    segs = path.split("?", 1)[0].split("#", 1)[0].split("/")[1:]
    if len(segs) > MAX_SHAPE_SEGMENTS:
        return "{too_long}"
    return "/" + "/".join(s if s in SHAPE_VOCAB else "{id}" for s in segs)


def match_template(path: str, templates: tuple[tuple[str, ...], ...]) -> str | None:
    segs = path.split("?", 1)[0].split("/")[1:]
    for t in templates:
        if len(t) == len(segs) and all((a == "{id}" and b) or a == b for a, b in zip(t, segs)):
            return "/" + "/".join(t)
    return None


def _norm(s: str) -> str:
    return s.strip().lower().replace("_", "-")


class Classifier:
    """Value kind and equality with the configured references. Only short values are examined."""

    def __init__(self, refs: dict[str, str], now: _dt.datetime | None = None):
        self.refs = refs
        now = now or _dt.datetime.now(_dt.timezone.utc)
        self.dates: dict[str, str] = {}
        self.offsets: dict[str, int] = {}
        for label in ("system_zone", "profile_zone"):
            if label in refs:
                local = now.astimezone(zoneinfo.ZoneInfo(refs[label]))
                self.dates[label.replace("zone", "date")] = local.strftime("%Y-%m-%d")
                off = local.utcoffset()
                self.offsets[label.replace("zone", "offset")] = int(off.total_seconds() // 60) if off is not None else 0

    def kind(self, value: Any) -> str:
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "bool"
        if isinstance(value, (int, float)):
            return "number"
        if isinstance(value, (dict, list)):
            return "object" if isinstance(value, dict) else "array"
        v = str(value).strip()
        if len(v) > MAX_VALUE_LEN:
            return "long_string"
        if v in ZONES:
            return "iana_zone"
        if LOCALE_RE.match(v):
            return "locale"
        if LOCALE_LIST_RE.match(v):
            return "locale_list"
        if OFFSET_RE.match(v):
            return "utc_offset"
        m = DATETIME_RE.match(v)
        if m:
            return "datetime_with_offset" if m.group("zone") else "datetime_no_zone"
        return "date" if DATE_RE.match(v) else "string"

    def matches(self, value: Any) -> list[str]:
        if isinstance(value, bool) or value is None:
            return []
        if isinstance(value, (int, float)):
            return [label for label, m in self.offsets.items() if value in (m, -m)]
        if not isinstance(value, str) or len(value.strip()) > MAX_VALUE_LEN:
            return []
        v = _norm(value)
        out = []
        for label, ref in self.refs.items():
            r = _norm(ref)
            if label.endswith("locale"):
                first = _norm(value.split(",", 1)[0].split(";", 1)[0])
                if first in (r, r.split("-", 1)[0]):
                    out.append(label)
            elif v == r:
                out.append(label)
        out += [label for label, d in self.dates.items() if value.strip().startswith(d)]
        return sorted(out)

    def exact(self, value: Any) -> list[str]:
        """Labels whose reference zone/locale equals the whole value (for count-only tallies)."""
        if not isinstance(value, str) or len(value) > MAX_VALUE_LEN:
            return []
        return [label for label, ref in self.refs.items() if _norm(value) == _norm(ref)]


def json_signals(doc: Any, cls: Classifier) -> dict[str, Any]:
    """Known fields under known containers -> records; everything else -> counts only."""
    fields: dict[tuple[str, str, tuple[str, ...]], int] = {}
    other_keys = 0
    skipped = 0
    unlisted_exact: dict[str, int] = {}
    nodes = 0
    stack: list[tuple[Any, str, int]] = [(doc, "$", 0)]
    while stack:
        node, path, depth = stack.pop()
        nodes += 1
        if nodes > MAX_NODES:
            return {"status": "truncated", "fields": [], "other_keys": other_keys, "skipped_containers": skipped}
        if isinstance(node, list):
            if depth < MAX_DEPTH:
                stack.extend((v, path + "[]", depth + 1) for v in node)
            continue
        if not isinstance(node, dict):
            continue
        for k, v in node.items():
            if k in SKIP_CONTAINERS:
                skipped += 1
            elif k in KNOWN_FIELDS:
                key = (f"{path}.{k}", cls.kind(v), tuple(cls.matches(v)))
                fields[key] = fields.get(key, 0) + 1
            elif k in KNOWN_CONTAINERS and isinstance(v, (dict, list)) and depth < MAX_DEPTH:
                stack.append((v, f"{path}.{k}", depth + 1))
            else:
                other_keys += 1
                for label in cls.exact(v):
                    unlisted_exact[label] = unlisted_exact.get(label, 0) + 1
    return {"status": "inspected",
            "fields": [{"at": p, "kind": k, "matches": list(m), "count": n} for (p, k, m), n in sorted(fields.items())],
            "other_keys": other_keys, "skipped_containers": skipped, "unlisted_exact_value_matches": unlisted_exact}


# ---- protobuf bodies (Connect / gRPC): field numbers and match flags only ----------------------
CONTENT_CLASSES = {
    "application/json": "json", "application/proto": "proto", "application/x-protobuf": "proto",
    "application/protobuf": "proto", "application/connect+proto": "connect_proto", "application/grpc": "grpc",
    "application/grpc+proto": "grpc", "application/grpc-web+proto": "grpc_web",
    "application/x-www-form-urlencoded": "form", "text/plain": "text",
}
PROTO_CLASSES = frozenset({"proto", "connect_proto", "grpc", "grpc_web"})
ENVELOPED = frozenset({"connect_proto", "grpc", "grpc_web"})
# A protobuf string is recorded (path, kind, match flags; never the value) only if it classifies as one of these.
PROTO_KINDS = frozenset({"iana_zone", "locale", "locale_list", "utc_offset", "datetime_with_offset", "datetime_no_zone", "date"})


def content_class(ctype: str) -> str:
    """A fixed enum for a Content-Type; the raw header is never recorded."""
    if not ctype:
        return "none"
    if ctype.endswith("+json"):
        return "json"
    return CONTENT_CLASSES.get(ctype, "other")


def size_bucket(n: int | None) -> str:
    if n is None:
        return "unknown"
    for limit, label in ((0, "0"), (1024, "<1KiB"), (16 * 1024, "<16KiB"), (MAX_AUDIT_BYTES, "<256KiB")):
        if n <= limit:
            return label
    return "larger"


class _Budget(Exception):
    pass


def _varint(buf: bytes, i: int) -> tuple[int, int]:
    val, shift = 0, 0
    while True:
        if i >= len(buf) or shift > 63:
            raise ValueError("bad varint")
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def _proto_fields(buf: bytes) -> list[tuple[int, int, Any]]:
    """Every (field number, wire type, value) of one message, or ValueError if it is not one."""
    out, i = [], 0
    while i < len(buf):
        key, i = _varint(buf, i)
        num, wire = key >> 3, key & 7
        if num == 0:
            raise ValueError("field 0")
        if wire == 0:
            v, i = _varint(buf, i)
        elif wire == 1:
            v, i = buf[i:i + 8], i + 8
        elif wire == 5:
            v, i = buf[i:i + 4], i + 4
        elif wire == 2:
            n, i = _varint(buf, i)
            v, i = buf[i:i + n], i + n
        else:
            raise ValueError("unsupported wire type")
        if i > len(buf):
            raise ValueError("truncated")
        out.append((num, wire, v))
    return out


def proto_signals(raw: bytes, cls: Classifier, enveloped: bool) -> dict[str, Any]:
    """Protobuf counterpart of json_signals. Field paths are numbers (#1.4); a string field is
    recorded only when its value classifies as a zone/locale/offset/date or equals a reference, and
    an integer only when it equals a reference UTC offset in minutes. Values are never recorded."""
    frames = [raw]
    if enveloped:
        frames, i = [], 0
        while i < len(raw):
            if i + 5 > len(raw):
                return {"status": "invalid_proto"}
            flag, n = raw[i], int.from_bytes(raw[i + 1:i + 5], "big")
            if flag & 1:
                return {"status": "skipped_compressed"}
            frames.append(raw[i + 5:i + 5 + n])
            i += 5 + n
        if i != len(raw):
            return {"status": "invalid_proto"}
    fields: dict[tuple[str, str, tuple[str, ...]], int] = {}
    tally = {"nodes": 0, "other": 0}

    def walk(buf: bytes, prefix: str, depth: int) -> bool:
        try:
            items = _proto_fields(buf)
        except ValueError:
            return False
        for num, wire, v in items:
            tally["nodes"] += 1
            if tally["nodes"] > MAX_NODES:
                raise _Budget
            path = f"{prefix}.{num}"
            if wire == 0:
                signed = v - (1 << 64) if v >= 1 << 63 else v
                m = cls.matches(signed)
                if m:
                    key = (path, "number", tuple(m))
                    fields[key] = fields.get(key, 0) + 1
                    continue
            elif wire == 2:
                text = None
                if 0 < len(v) <= MAX_VALUE_LEN:
                    try:
                        text = v.decode("utf-8")
                    except UnicodeDecodeError:
                        text = None
                if text is not None and text.isprintable():
                    kind, m = cls.kind(text), cls.matches(text)
                    if kind in PROTO_KINDS or m:
                        key = (path, kind, tuple(m))
                        fields[key] = fields.get(key, 0) + 1
                        continue
                if v and depth < MAX_DEPTH and walk(v, path, depth + 1):
                    continue
            tally["other"] += 1
        return True

    try:
        for frame in frames:
            if not walk(frame, "#", 0):
                return {"status": "invalid_proto"}
    except _Budget:
        return {"status": "truncated", "fields": [], "other_fields": tally["other"]}
    return {"status": "inspected_proto",
            "fields": [{"at": p, "kind": k, "matches": list(m), "count": n} for (p, k, m), n in sorted(fields.items())],
            "other_fields": tally["other"]}


class LocaleAudit:
    def __init__(self) -> None:
        self.config: Config | None = None
        self.out = None

    def load(self, loader) -> None:
        loader.add_option("cla_config", str, "", "claude-locale-kit audit config (JSON)")
        loader.add_option("cla_out", str, "", "JSONL output path")

    def configure(self, updated) -> None:
        if "cla_config" not in updated and "cla_out" not in updated:
            return
        if not ctx.options.cla_config or not ctx.options.cla_out:
            raise ValueError("locale_audit needs --set cla_config=... and --set cla_out=...")
        with open(ctx.options.cla_config, encoding="utf-8") as f:
            self.config = load_config(json.load(f))
        fd = os.open(ctx.options.cla_out, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.out = os.fdopen(fd, "a", encoding="utf-8")
        self._write({"event": "start", "mode": "audit", "hosts": sorted(self.config.hosts),
                     "paths": ["/" + "/".join(t) for t in self.config.paths], "references": sorted(self.config.refs)})

    def done(self) -> None:
        if self.out:
            self._write({"event": "stop"})
            self.out.close()
            self.out = None

    def _write(self, record: dict[str, Any]) -> None:
        record = {"ts": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"), **record}
        self.out.write(json.dumps(record, sort_keys=True) + "\n")
        self.out.flush()

    # -- connections --------------------------------------------------------------------------
    def tls_clienthello(self, data: tls.ClientHelloData) -> None:
        if (data.client_hello.sni or "").lower() in self.config.hosts:
            return
        data.ignore_connection = True  # opaque tunnel: never decrypted, name not recorded
        self._write({"event": "tunnel"})

    # -- requests -----------------------------------------------------------------------------
    def requestheaders(self, flow: http.HTTPFlow) -> None:
        req = flow.request
        host = req.pretty_host.lower()
        if host not in self.config.hosts or req.scheme != "https":
            req.stream = True
            return
        template = match_template(req.path, self.config.paths)
        if template is None:
            req.stream = True
            record = {"event": "unmatched_route", "host": host}
            if self.config.discover:
                record["method"] = req.method if req.method in METHODS else "OTHER"
                record["shape"] = route_shape(req.path)
            self._write(record)
            return
        flow.metadata["cla_template"] = template
        ctype = (req.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
        length = req.headers.get("content-length")
        encoding = (req.headers.get("content-encoding") or "identity").strip().lower()
        cclass = content_class(ctype)
        flow.metadata["cla_class"] = cclass
        status = None
        if cclass != "json" and cclass not in PROTO_CLASSES:
            status = "not_json" if length not in (None, "0") or "transfer-encoding" in req.headers else "empty"
        elif encoding != "identity":
            status = "skipped_encoded"
        elif length is None or not length.isdigit():
            status = "skipped_unknown_length"
        elif int(length) > MAX_AUDIT_BYTES:
            status = "skipped_too_large"
        if status is not None:
            req.stream = True  # forwarded as it arrives, never buffered or read
            self._record(flow, {"status": status})

    def request(self, flow: http.HTTPFlow) -> None:
        if "cla_template" not in flow.metadata or flow.request.stream or "cla_logged" in flow.metadata:
            return
        raw = flow.request.raw_content or b""
        cls = Classifier(self.config.refs)
        if not raw:
            body: dict[str, Any] = {"status": "empty"}
        elif len(raw) > MAX_AUDIT_BYTES:
            body = {"status": "skipped_too_large"}
        elif flow.metadata.get("cla_class") in PROTO_CLASSES:
            body = proto_signals(raw, cls, flow.metadata["cla_class"] in ENVELOPED)
        else:
            try:
                body = json_signals(json.loads(raw), cls)
            except (ValueError, UnicodeDecodeError):
                body = {"status": "invalid_json"}
        self._record(flow, body, cls)

    def _record(self, flow: http.HTTPFlow, body: dict[str, Any], cls: Classifier | None = None) -> None:
        flow.metadata["cla_logged"] = True
        req = flow.request
        cls = cls or Classifier(self.config.refs)
        headers, other_headers = [], 0
        unlisted: dict[str, int] = {}
        for name, value in req.headers.items(multi=True):
            n = name.lower()
            if n in KNOWN_HEADERS:
                headers.append({"at": n, "kind": cls.kind(value), "matches": cls.matches(value)})
            else:
                other_headers += 1
                for label in cls.exact(value):
                    unlisted[label] = unlisted.get(label, 0) + 1
        query, other_query = [], 0
        for k, v in parse_qsl(req.path.split("?", 1)[1] if "?" in req.path else "", keep_blank_values=True):
            if k in KNOWN_FIELDS:
                query.append({"at": k, "kind": cls.kind(v), "matches": cls.matches(v)})
            else:
                other_query += 1
                for label in cls.exact(v):
                    unlisted[label] = unlisted.get(label, 0) + 1
        length = req.headers.get("content-length")
        self._write({"event": "request", "host": req.pretty_host.lower(), "method": req.method if req.method in METHODS else "OTHER",
                     "template": flow.metadata["cla_template"], "content": flow.metadata.get("cla_class", "none"),
                     "size": size_bucket(int(length) if length and length.isdigit() else None), "headers": headers, "other_headers": other_headers,
                     "query": query, "other_query": other_query, "unlisted_exact_value_matches": unlisted, "body": body})

    # -- responses: never read, always streamed -------------------------------------------------
    def responseheaders(self, flow: http.HTTPFlow) -> None:
        flow.response.stream = True

    def response(self, flow: http.HTTPFlow) -> None:
        """Runs once a streamed response has been forwarded in full. For template routes only, it
        records the status code and a fixed content class: a complete HTTP response, which by
        itself does not show that a chat reply succeeded. The body is never read."""
        template = flow.metadata.get("cla_template")
        if template is None:
            return
        code = flow.response.status_code
        ctype = (flow.response.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
        content = ("event_stream" if ctype == "text/event-stream" else "json" if ctype == "application/json"
                   else "none" if not ctype else "other")
        self._write({"event": "response", "template": template, "status": code if 100 <= code <= 599 else 0,
                     "content": content})


addons = [LocaleAudit()]
