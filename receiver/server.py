#!/usr/bin/env python3
"""WorkoutRescue receiver: stores workout exports sent directly by the Apple Watch.

Standard library only (Python 3.9+). Intended to run on loopback behind an HTTPS reverse
proxy/tunnel, or directly with TLS (WR_TLS_CERT / WR_TLS_KEY).

API (all /api routes need "Authorization: Bearer <WR_TOKEN>"):
  GET  /health                          liveness, no auth, no information
  GET  /api/ping                        token check used by "Test Connection"
  GET  /api/workouts                    list stored workouts (for checks from the Mac)
  POST /api/workouts/{uuid}/metadata    body = workout.json  (application/json)
  POST /api/workouts/{uuid}/route       body = route.gpx     (application/gpx+xml)

Uploads must send X-WorkoutRescue-SHA256 (hex digest of the body). The body is streamed to a
temporary file, hashed, checked, then published atomically with os.link (never overwrites):
  - same file already stored  -> 200 {"status": "duplicate"}
  - different file exists     -> 201 {"status": "stored_revision"} (stored next to it)
  - new                       -> 201 {"status": "stored"}
Bytes are stored exactly as received. Every accepted file is appended to receipts.jsonl.
"""
import argparse
import hashlib
import hmac
import json
import logging
import os
import re
import ssl
import sys
import tempfile
import threading
import time
import uuid as uuidlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROTOCOL_VERSION = 1
KINDS = {
    "metadata": ("workout", ".json", ("application/json",)),
    "route": ("route", ".gpx", ("application/gpx+xml", "application/xml", "text/xml")),
}
UPLOAD_PATH = re.compile(r"^/api/workouts/([0-9A-Fa-f-]{36})/(metadata|route)$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
log = logging.getLogger("workoutrescue.receiver")


def normalize_token(value):
    """Tokens are compared case-insensitively, ignoring spaces and dashes (typed on a watch)."""
    return re.sub(r"[\s-]", "", value or "").upper()


def utc_stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fsync_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


class Config:
    def __init__(self, token, export_dir, max_bytes=64 * 1024 * 1024, max_failures=10, lockout_seconds=600):
        self.token = normalize_token(token)
        if len(self.token) < 10:
            raise ValueError("WR_TOKEN must contain at least 10 characters (use scripts/gen_token.py).")
        self.export_dir = Path(export_dir).resolve()
        self.max_bytes = int(max_bytes)
        self.max_failures = int(max_failures)
        self.lockout_seconds = int(lockout_seconds)


class Store:
    """Write-once file store. Files are never modified or deleted by the server."""

    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.incoming = self.root / ".incoming"
        self.incoming.mkdir(exist_ok=True, mode=0o700)
        self.lock = threading.Lock()

    def workout_dir(self, workout_uuid):
        path = self.root / workout_uuid  # workout_uuid is a canonical UUID string: no traversal possible
        path.mkdir(exist_ok=True, mode=0o700)
        return path

    def new_temp(self):
        handle, name = tempfile.mkstemp(dir=self.incoming, prefix="upload-", suffix=".part")
        return os.fdopen(handle, "wb"), Path(name)

    def publish(self, temp_path, workout_uuid, kind, digest):
        """Returns (status, relative_path). Atomic, never overwrites."""
        stem, ext, _ = KINDS[kind]
        folder = self.workout_dir(workout_uuid)
        final = folder / (stem + ext)
        with self.lock:
            try:
                os.link(temp_path, final)
                status = "stored"
            except FileExistsError:
                if sha256_file(final) == digest:
                    status = "duplicate"
                else:
                    final = None
                    for candidate in sorted(folder.glob(stem + ".rev-*" + ext)):
                        if candidate.name.endswith("-" + digest[:16] + ext) and sha256_file(candidate) == digest:
                            final, status = candidate, "duplicate"
                            break
                    if final is None:
                        final = folder / "{}.rev-{}-{}{}".format(stem, utc_stamp(), digest[:16], ext)
                        os.link(temp_path, final)
                        status = "stored_revision"
            fsync_dir(folder)
        return status, final.relative_to(self.root).as_posix()

    def append_receipt(self, workout_uuid, record):
        line = json.dumps(record, sort_keys=True) + "\n"
        with self.lock:
            for path in (self.root / workout_uuid / "receipts.jsonl", self.root / "receipts.jsonl"):
                with open(path, "a", encoding="utf-8") as handle:
                    handle.write(line)
                    handle.flush()
                    os.fsync(handle.fileno())

    def list_workouts(self):
        result = []
        for folder in sorted(p for p in self.root.iterdir() if p.is_dir() and not p.name.startswith(".")):
            files = sorted(f.name for f in folder.iterdir() if f.is_file() and f.name != "receipts.jsonl")
            result.append({"uuid": folder.name, "files": files})
        return result


class AuthGuard:
    """Counts failed authentications per client and locks the client out after too many."""

    def __init__(self, max_failures, lockout_seconds):
        self.max_failures = max_failures
        self.lockout_seconds = lockout_seconds
        self.failures = {}
        self.lock = threading.Lock()

    def locked(self, client):
        with self.lock:
            now = time.monotonic()
            recent = [t for t in self.failures.get(client, []) if now - t < self.lockout_seconds]
            self.failures[client] = recent
            return len(recent) >= self.max_failures

    def fail(self, client):
        with self.lock:
            self.failures.setdefault(client, []).append(time.monotonic())

    def succeed(self, client):
        with self.lock:
            self.failures.pop(client, None)


class Handler(BaseHTTPRequestHandler):
    server_version = "WorkoutRescueReceiver/1"
    sys_version = ""
    timeout = 120  # socket timeout: a stalled upload cannot hold a thread forever
    protocol_version = "HTTP/1.1"

    # -- helpers -----------------------------------------------------------------
    @property
    def cfg(self):
        return self.server.cfg

    def log_message(self, fmt, *args):
        log.info("%s %s", self.client_address[0], fmt % args)

    def reply(self, status, payload, close=False):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, code, close=False):
        self.reply(status, {"error": code}, close=close)

    def authorized(self):
        client = self.client_address[0]
        if self.server.guard.locked(client):
            log.warning("auth locked out for %s", client)
            self.error(429, "too_many_failed_attempts", close=True)
            return False
        header = self.headers.get("Authorization", "")
        supplied = normalize_token(header[7:]) if header[:7].lower() == "bearer " else ""
        if supplied and hmac.compare_digest(supplied.encode(), self.cfg.token.encode()):
            self.server.guard.succeed(client)
            return True
        self.server.guard.fail(client)
        log.warning("rejected credentials from %s for %s", client, self.path)
        self.error(401, "unauthorized", close=True)
        return False

    # -- routes ------------------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self.reply(200, {"status": "ok"})
        if path == "/api/ping":
            if self.authorized():
                self.reply(200, {"ok": True, "service": "workoutrescue-receiver", "protocol_version": PROTOCOL_VERSION,
                                 "max_bytes": self.cfg.max_bytes})
            return None
        if path == "/api/workouts":
            if self.authorized():
                self.reply(200, {"workouts": self.server.store.list_workouts()})
            return None
        return self.error(404, "not_found")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        match = UPLOAD_PATH.match(path)
        if not match:
            return self.error(404, "not_found", close=True)
        if not self.authorized():
            return None
        try:
            workout_uuid = str(uuidlib.UUID(match.group(1))).upper()
        except ValueError:
            return self.error(404, "not_found", close=True)
        kind = match.group(2)
        _, _, content_types = KINDS[kind]
        content_type = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if content_type not in content_types:
            return self.error(415, "unsupported_content_type", close=True)
        expected = self.headers.get("X-WorkoutRescue-SHA256", "").strip().lower()
        if not HEX64.match(expected):
            return self.error(400, "missing_or_invalid_sha256_header", close=True)
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            return self.error(411, "content_length_required", close=True)
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.error(411, "content_length_required", close=True)
        if length <= 0:
            return self.error(400, "empty_body", close=True)
        if length > self.cfg.max_bytes:
            return self.error(413, "payload_too_large", close=True)
        self.receive(workout_uuid, kind, length, expected)
        return None

    def do_PUT(self):
        self.error(405, "method_not_allowed", close=True)

    do_DELETE = do_PATCH = do_PUT

    def receive(self, workout_uuid, kind, length, expected):
        store = self.server.store
        handle, temp_path = store.new_temp()
        digest = hashlib.sha256()
        received = 0
        try:
            with handle:
                while received < length:
                    chunk = self.rfile.read(min(1 << 20, length - received))
                    if not chunk:
                        break
                    digest.update(chunk)
                    handle.write(chunk)
                    received += len(chunk)
                handle.flush()
                os.fsync(handle.fileno())
            actual = digest.hexdigest()
            if received != length:
                log.error("incomplete upload %s/%s: %d of %d bytes", workout_uuid, kind, received, length)
                return self.error(400, "incomplete_body", close=True)
            if actual != expected:
                log.error("sha256 mismatch %s/%s: header %s body %s", workout_uuid, kind, expected, actual)
                return self.error(400, "sha256_mismatch", close=True)
            if kind == "metadata":
                problem = validate_metadata(temp_path, workout_uuid)
                if problem:
                    log.error("rejected metadata %s: %s", workout_uuid, problem)
                    return self.error(400, problem, close=True)
            status, relative = store.publish(temp_path, workout_uuid, kind, actual)
            store.append_receipt(workout_uuid, {
                "received_at": datetime.now(timezone.utc).isoformat(), "uuid": workout_uuid, "kind": kind, "status": status,
                "file": relative, "sha256": actual, "bytes": received, "client": self.client_address[0],
                "user_agent": self.headers.get("User-Agent", ""), "schema": self.headers.get("X-WorkoutRescue-Schema", ""),
            })
            log.info("%s %s/%s %d bytes sha256 %s -> %s", status, workout_uuid, kind, received, actual[:16], relative)
            self.reply(200 if status == "duplicate" else 201, {"status": status, "uuid": workout_uuid, "kind": kind,
                                                               "sha256": actual, "bytes": received, "path": relative})
        except Exception:  # never leave the client without an answer, never leak details
            log.exception("failed to store %s/%s", workout_uuid, kind)
            self.error(500, "storage_error", close=True)
        finally:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass


def validate_metadata(path, workout_uuid):
    try:
        with open(path, "rb") as handle:
            document = json.load(handle)
    except (ValueError, UnicodeDecodeError):
        return "invalid_json"
    if not isinstance(document, dict) or document.get("format") != "workoutrescue.workout":
        return "unexpected_json_format"
    inner = document.get("workout") if isinstance(document.get("workout"), dict) else {}
    if str(inner.get("uuid", "")).upper() != workout_uuid:
        return "uuid_mismatch"
    return None


class Receiver(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, cfg):
        self.cfg = cfg
        self.store = Store(cfg.export_dir)
        self.guard = AuthGuard(cfg.max_failures, cfg.lockout_seconds)
        super().__init__(address, Handler)


def main(argv=None):
    parser = argparse.ArgumentParser(description="WorkoutRescue receiver")
    parser.add_argument("--host", default=os.environ.get("WR_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("WR_PORT", "8787")))
    parser.add_argument("--export-dir", default=os.environ.get("WR_EXPORT_DIR", str(Path(__file__).with_name("exports"))))
    parser.add_argument("--max-bytes", type=int, default=int(os.environ.get("WR_MAX_BYTES", str(64 * 1024 * 1024))))
    parser.add_argument("--tls-cert", default=os.environ.get("WR_TLS_CERT"))
    parser.add_argument("--tls-key", default=os.environ.get("WR_TLS_KEY"))
    parser.add_argument("--log-file", default=os.environ.get("WR_LOG_FILE"))
    args = parser.parse_args(argv)

    handlers = [logging.StreamHandler(sys.stderr)]
    if args.log_file:
        handlers.append(logging.FileHandler(args.log_file))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=handlers)

    token = os.environ.get("WR_TOKEN", "")
    try:
        cfg = Config(token, args.export_dir, args.max_bytes)
    except ValueError as exc:
        log.error("%s", exc)
        return 2
    server = Receiver((args.host, args.port), cfg)
    scheme = "http"
    if args.tls_cert and args.tls_key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    log.info("WorkoutRescue receiver on %s://%s:%d, storing in %s (max %d bytes)", scheme, args.host, server.server_port,
             cfg.export_dir, cfg.max_bytes)
    if scheme == "http" and args.host not in ("127.0.0.1", "localhost", "::1"):
        log.warning("Plain HTTP on a non-loopback address: put an HTTPS proxy/tunnel in front (the watch only speaks HTTPS).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
