import hashlib
import http.client
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server  # noqa: E402
import verify  # noqa: E402

TOKEN = "ABCD-EFGH-JKMN-PQRS"
UUID = "D3E00000-0000-4000-8000-0000000000AA"


def workout_json(uuid=UUID, extra=""):
    doc = {"format": "workoutrescue.workout", "schemaVersion": 2, "workout": {"uuid": uuid, "activityType": {"name": "Cycling"}},
           "routes": [{"uuid": "R", "expectedPointCount": 2, "points": [{}, {}]}], "quantityTypes": [], "note": extra}
    return json.dumps(doc).encode()


GPX = (b'<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">'
       b'<trk><trkseg><trkpt lat="45.0" lon="6.0"><time>2026-09-12T07:30:00.000Z</time></trkpt></trkseg></trk></gpx>\n')


class ReceiverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        cfg = server.Config(TOKEN, self.root, max_bytes=200_000, max_failures=5, lockout_seconds=60)
        self.httpd = server.Receiver(("127.0.0.1", 0), cfg)
        self.port = self.httpd.server_port
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def request(self, method, path, body=None, token=TOKEN, headers=None, sha=None, content_type="application/json"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {}
        if token is not None:
            h["Authorization"] = "Bearer " + token
        if body is not None:
            h["Content-Type"] = content_type
            h["X-WorkoutRescue-SHA256"] = sha if sha is not None else hashlib.sha256(body).hexdigest()
        h.update(headers or {})
        conn.request(method, path, body=body, headers=h)
        response = conn.getresponse()
        data = response.read()
        conn.close()
        try:
            payload = json.loads(data) if data else None
        except ValueError:
            payload = data
        return response.status, payload

    def upload(self, kind="metadata", body=None, **kw):
        body = workout_json() if body is None and kind == "metadata" else (GPX if body is None else body)
        ctype = "application/json" if kind == "metadata" else "application/gpx+xml"
        return self.request("POST", "/api/workouts/{}/{}".format(kw.pop("uuid", UUID), kind), body=body, content_type=kw.pop("content_type", ctype), **kw)

    # --- health / auth -------------------------------------------------------------
    def test_health_needs_no_auth_and_leaks_nothing(self):
        status, payload = self.request("GET", "/health", token=None)
        self.assertEqual((status, payload), (200, {"status": "ok"}))

    def test_ping_requires_token(self):
        self.assertEqual(self.request("GET", "/api/ping")[0], 200)
        self.assertEqual(self.request("GET", "/api/ping", token="abcd efgh jkmn pqrs")[0], 200)  # forgiving typing
        self.assertEqual(self.request("GET", "/api/ping", token="WRONG-TOKEN-0000")[0], 401)
        self.assertEqual(self.request("GET", "/api/ping", token=None)[0], 401)

    def test_lockout_after_repeated_failures(self):
        for _ in range(5):
            self.assertEqual(self.request("GET", "/api/ping", token="nope-nope-nope")[0], 401)
        self.assertEqual(self.request("GET", "/api/ping")[0], 429)  # even the right token is refused while locked

    def test_upload_without_token_writes_nothing(self):
        status, _ = self.upload(token=None)
        self.assertEqual(status, 401)
        self.assertFalse((self.root / UUID).exists())

    # --- storage -------------------------------------------------------------------
    def test_store_then_duplicate_then_revision_never_overwrites(self):
        body = workout_json()
        status, receipt = self.upload(body=body)
        self.assertEqual(status, 201)
        self.assertEqual(receipt["status"], "stored")
        self.assertEqual(receipt["sha256"], hashlib.sha256(body).hexdigest())
        stored = self.root / UUID / "workout.json"
        self.assertEqual(stored.read_bytes(), body)  # byte-for-byte

        status, receipt = self.upload(body=body)
        self.assertEqual((status, receipt["status"]), (200, "duplicate"))

        changed = workout_json(extra="second export")
        status, receipt = self.upload(body=changed)
        self.assertEqual((status, receipt["status"]), (201, "stored_revision"))
        self.assertEqual(stored.read_bytes(), body)  # original untouched
        self.assertEqual((self.root / receipt["path"]).read_bytes(), changed)
        status, receipt = self.upload(body=changed)
        self.assertEqual((status, receipt["status"]), (200, "duplicate"))  # revision retry is idempotent too

        lines = (self.root / UUID / "receipts.jsonl").read_text().splitlines()
        self.assertEqual([json.loads(l)["status"] for l in lines], ["stored", "duplicate", "stored_revision", "duplicate"])

    def test_route_upload_and_listing_and_verify(self):
        self.assertEqual(self.upload()[0], 201)
        self.assertEqual(self.upload("route")[0], 201)
        status, listing = self.request("GET", "/api/workouts")
        self.assertEqual(listing["workouts"], [{"uuid": UUID, "files": ["route.gpx", "workout.json"]}])
        report, failures = verify.verify(self.root)
        self.assertEqual(failures, 0, report)
        gpx = next(e for e in report if e["file"].endswith(".gpx"))
        self.assertEqual(gpx["points"], 1)

    def test_verify_detects_tampering(self):
        self.upload()
        (self.root / UUID / "workout.json").write_bytes(workout_json(extra="tampered"))
        _, failures = verify.verify(self.root)
        self.assertEqual(failures, 1)

    def test_lowercase_uuid_is_canonicalized(self):
        status, receipt = self.upload(uuid=UUID.lower())
        self.assertEqual(status, 201)
        self.assertEqual(receipt["uuid"], UUID)

    # --- validation / security -----------------------------------------------------
    def test_sha_mismatch_is_rejected_and_not_stored(self):
        status, payload = self.upload(sha="0" * 64)
        self.assertEqual((status, payload), (400, {"error": "sha256_mismatch"}))
        self.assertFalse((self.root / UUID / "workout.json").exists())
        self.assertEqual(list((self.root / ".incoming").iterdir()), [])

    def test_missing_sha_header(self):
        status, payload = self.upload(sha="")
        self.assertEqual(payload, {"error": "missing_or_invalid_sha256_header"})

    def test_size_limit(self):
        status, payload = self.upload("route", body=b"<gpx>" + b" " * 300_000)
        self.assertEqual((status, payload), (413, {"error": "payload_too_large"}))

    def test_wrong_content_type(self):
        self.assertEqual(self.upload(content_type="text/plain")[0], 415)

    def test_metadata_must_be_a_workoutrescue_archive_for_that_uuid(self):
        self.assertEqual(self.upload(body=b"not json")[1], {"error": "invalid_json"})
        self.assertEqual(self.upload(body=b"{}")[1], {"error": "unexpected_json_format"})
        other = workout_json(uuid="D3E00000-0000-4000-8000-0000000000BB")
        self.assertEqual(self.upload(body=other)[1], {"error": "uuid_mismatch"})

    def test_path_traversal_and_unknown_routes(self):
        for path in ["/api/workouts/../../etc/route", "/api/workouts/..%2F..%2Fx/route", "/api/workouts/{}/../../x".format(UUID),
                     "/api/workouts/{}/passwd".format(UUID), "/api/workouts/not-a-uuid-not-a-uuid-not-a-uuid-xxxxxx/route"]:
            status, _ = self.request("POST", path, body=GPX, content_type="application/gpx+xml")
            self.assertEqual(status, 404, path)
        self.assertEqual([p.name for p in self.root.iterdir()], [".incoming"])

    def test_methods_not_allowed(self):
        self.assertEqual(self.request("DELETE", "/api/workouts/{}/route".format(UUID))[0], 405)
        self.assertEqual(self.request("PUT", "/api/workouts/{}/route".format(UUID), body=GPX)[0], 405)

    def test_interrupted_upload_leaves_no_file(self):
        body = workout_json()
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        head = ("POST /api/workouts/{}/metadata HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\n"
                "X-WorkoutRescue-SHA256: {}\r\nContent-Length: {}\r\n\r\n").format(UUID, TOKEN, hashlib.sha256(body).hexdigest(), len(body))
        sock.sendall(head.encode() + body[: len(body) // 2])
        sock.shutdown(socket.SHUT_WR)  # connection lost mid-body
        response = sock.recv(4096)
        sock.close()
        self.assertIn(b"incomplete_body", response)
        self.assertFalse((self.root / UUID / "workout.json").exists())
        self.assertEqual(list((self.root / ".incoming").iterdir()), [])
        # The retry then succeeds.
        self.assertEqual(self.upload(body=body)[0], 201)

    def test_short_token_refused_at_startup(self):
        with self.assertRaises(ValueError):
            server.Config("short", self.root)


if __name__ == "__main__":
    unittest.main()
