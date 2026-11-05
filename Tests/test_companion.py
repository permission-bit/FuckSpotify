"""Private API tests. No external media requests, LAN/public listeners or login items."""

import asyncio
import errno
import hashlib
import io
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import wave
import uuid
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from companion_api import MAX_REQUEST_BYTES, VerifiedStreamingResponse, create_app
from companion_security import CompanionConfig, local_address
from companion_service import CompanionService
from companion_pairing import pairing_payload, pairing_qrcode, terminal_qr, TerminalPairingDisplay
from conversion_worker import Cancelled
from Tests.test_converter import FakeWorker
from companion import main as companion_main


class CompanionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tls_temp = tempfile.TemporaryDirectory()
        cls.template = CompanionConfig.initialize(Path(cls.tls_temp.name) / "template")

    @classmethod
    def tearDownClass(cls):
        cls.tls_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "library"
        self.root.mkdir()
        shutil.copytree(self.template.state, self.root / ".companion")
        self.config = CompanionConfig(self.root)
        self.service = CompanionService(self.config, start_worker=False)
        self.service.converter.worker = FakeWorker()
        self.app = create_app(self.config, self.service)
        self.client = TestClient(self.app, base_url=self.config.url, client=("127.0.0.1", 50000), raise_server_exceptions=False)
        self.client.__enter__()
        self.addCleanup(self.client.__exit__, None, None, None)

    def pair(self, name="iPhone"):
        secret = self.service.security.pairing(name)["secret"]
        response = self.client.post("/v1/pair", json={"secret": secret})
        self.assertEqual(response.status_code, 200, response.text)
        device = response.json()
        return device, {"Authorization": "Bearer " + device["token"]}

    def asset(self, device):
        source = Path(self.temp.name) / "owned.wav"
        with wave.open(str(source), "wb") as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(8000)
            stream.writeframes(b"\0\0" * 8000)
        return self.service.register_asset(device["device_id"], source)["asset_id"]

    def submit(self, headers, asset=None, count=1):
        source = {"kind": "asset", "id": asset, "authorized": True} if asset else {"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": True}
        response = self.client.post("/v1/jobs", headers=headers, json={"sources": [source] * count, "quality": "128K"})
        self.assertEqual(response.status_code, 202, response.text)
        return response.json()

    def completed(self):
        device, headers = self.pair()
        job = self.submit(headers, self.asset(device))
        result = self.service.converter.run(job["id"])
        self.assertEqual(result["status"], "completed", result)
        item = result["items"][0]
        url = f"/v1/jobs/{job['id']}/items/{item['id']}"
        return device, headers, result, item, url

    def test_authentication_one_use_and_hashed_storage(self):
        self.assertEqual(self.client.get("/v1/health").status_code, 401)
        secret = self.service.security.pairing("Phone")["secret"]
        response = self.client.post("/v1/pair", json={"secret": secret})
        token = response.json()["token"]
        self.assertEqual(self.client.post("/v1/pair", json={"secret": secret}).status_code, 401)
        self.assertEqual(self.client.get("/v1/health", headers={"Authorization": "Bearer " + token}).status_code, 200)
        with self.service.converter.store._connection() as db:
            stored = db.execute("SELECT token_hash FROM companion_devices").fetchone()[0]
            pairing = db.execute("SELECT hash FROM companion_pairings").fetchone()[0]
        self.assertEqual(stored, hashlib.sha256(token.encode()).hexdigest())
        self.assertNotEqual(pairing, secret)
        self.assertNotIn(token, str(self.service.security.devices()))
        self.assertEqual(self.config.key.stat().st_mode & 0o077, 0)

    def test_pair_expiry_and_rate_limit(self):
        secret = self.service.security.pairing("Expired")["secret"]
        with self.service.converter.store._connection() as db:
            db.execute("UPDATE companion_pairings SET expires_at=0")
        self.assertEqual(self.client.post("/v1/pair", json={"secret": secret}).status_code, 401)
        for _ in range(4):
            self.assertEqual(self.client.post("/v1/pair", json={"secret": "x" * 43}).status_code, 401)
        self.assertEqual(self.client.post("/v1/pair", json={"secret": "x" * 43}).status_code, 429)

    def test_terminal_qr_contains_only_short_lived_pairing_data(self):
        payload = pairing_payload(self.config, self.service.security, "QR iPhone")
        text = terminal_qr(payload)
        self.assertNotIn(payload["secret"], text)
        self.assertNotIn("omc_", text)
        self.assertNotIn(str(self.config.key), text)
        block = text.split("\033[97;40m", 1)[1].split("\033[0m", 1)[0]
        halves = {" ": (1, 1), "▀": (0, 1), "▄": (1, 0), "█": (0, 0)}
        decoded = []
        for line in block.splitlines():
            decoded.append(tuple(halves[char][0] for char in line))
            decoded.append(tuple(halves[char][1] for char in line))
        rows = list(pairing_qrcode(payload).matrix_iter(border=4))
        self.assertEqual(decoded[:len(rows)], rows)
        self.assertLessEqual(len(rows[0]), 80, "The code should fit a normal terminal without wrapping")
        response = self.client.post("/v1/pair", json={"secret": payload["secret"]})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.post("/v1/pair", json={"secret": payload["secret"]}).status_code, 401)

    def test_qr_refuses_redirected_output_and_json_pairing_still_works(self):
        output = io.StringIO()
        with redirect_stdout(output):
            with self.assertRaisesRegex(ValueError, "interactive terminal"):
                companion_main(["--root", str(self.root), "pair", "--name", "QR iPhone", "--qr"])
        self.assertEqual(output.getvalue(), "")
        with self.service.converter.store._connection() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM companion_pairings").fetchone()[0], 0)
        # The existing JSON CLI does not need to render/import a QR encoder.
        with redirect_stdout(output), patch.dict(sys.modules, {"segno": None}):
            companion_main(["--root", str(self.root), "pair", "--name", "JSON iPhone"])
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["url"], self.config.url)
        self.assertEqual(payload["server_certificate_sha256"], self.config.fingerprint)
        self.assertEqual(self.client.post("/v1/pair", json={"secret": payload["secret"]}).status_code, 200)

    def test_terminal_qr_stop_invalidates_unused_code(self):
        output = io.StringIO()
        display = TerminalPairingDisplay(self.config, self.service.security, output)
        display.start()
        try:
            deadline = time.monotonic() + 3
            while display.payload is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertIsNotNone(display.payload)
            secret = display.payload["secret"]
        finally:
            display.stop()
        self.assertFalse(display.thread.is_alive())
        self.assertEqual(self.client.post("/v1/pair", json={"secret": secret}).status_code, 401)

    def test_terminal_qr_refreshes_then_stops_after_pairing(self):
        output = io.StringIO()
        display = TerminalPairingDisplay(self.config, self.service.security, output)
        display.start()
        try:
            deadline = time.monotonic() + 3
            while display.payload is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertIsNotNone(display.payload)
            original = display.payload["secret"]
            with self.service.converter.store._connection() as db:
                db.execute("UPDATE companion_pairings SET expires_at=0")
            display.payload["expires_at"] = 0
            deadline = time.monotonic() + 4
            while display.payload["secret"] == original and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertNotEqual(display.payload["secret"], original)
            self.assertEqual(self.client.post("/v1/pair", json={"secret": original}).status_code, 401)
            self.assertEqual(self.client.post("/v1/pair", json={"secret": display.payload["secret"]}).status_code, 200)
            display.thread.join(timeout=3)
            self.assertFalse(display.thread.is_alive())
            self.assertIn("Kopplung erfolgreich", output.getvalue())
        finally:
            display.stop()

    def test_revoke_blocks_token_and_cancels_queued_jobs(self):
        device, headers = self.pair()
        job = self.submit(headers)
        self.assertEqual(self.client.delete("/v1/device", headers=headers).status_code, 204)
        self.assertEqual(self.client.get("/v1/health", headers=headers).status_code, 401)
        self.assertEqual(self.service.converter.get_job(job["id"])["status"], "cancelled")

    def test_device_isolation_for_jobs_assets_and_files(self):
        device, headers, result, item, url = self.completed()
        other, other_headers = self.pair("Other")
        for path in (f"/v1/jobs/{result['id']}", url + "/file", url + "/metadata"):
            self.assertEqual(self.client.get(path, headers=other_headers).status_code, 404)
        self.assertEqual(self.client.post(f"/v1/jobs/{result['id']}/cancel", headers=other_headers).status_code, 404)
        self.assertEqual(self.client.get("/v1/jobs", headers=other_headers).json()["jobs"], [])
        asset_id = self.asset(device)
        response = self.client.post("/v1/jobs", headers=other_headers, json={"sources": [{"kind": "asset", "id": asset_id, "authorized": True}]})
        self.assertEqual(response.status_code, 404)

    def test_registered_source_list_is_owned_and_missing_files_are_not_importable(self):
        device, headers = self.pair()
        first = self.asset(device)
        second = self.asset(device)
        self.assertEqual(self.client.get("/v1/assets").status_code, 401)
        page = self.client.get("/v1/assets?limit=1", headers=headers).json()
        self.assertEqual(page["assets"][0]["id"], first)
        self.assertTrue(page["assets"][0]["can_import"])
        self.assertEqual(page["next_offset"], 1)
        self.assertNotIn(str(self.root), json.dumps(page))
        _, other_headers = self.pair("Other")
        self.assertEqual(self.client.get("/v1/assets", headers=other_headers).json()["assets"], [])
        path, _ = self.service.asset_path(device["device_id"], second)
        path.unlink()  # Only a generated test-fixture copy.
        missing = self.client.get("/v1/assets?offset=1", headers=headers).json()["assets"][0]
        self.assertFalse(missing["available"])
        self.assertFalse(missing["can_import"])

    def test_ui_request_id_is_durable_and_does_not_enqueue_twice(self):
        device, headers = self.pair()
        asset = self.asset(device)
        request_id = str(uuid.uuid4())
        body = {"sources": [{"kind": "asset", "id": asset, "authorized": True}], "quality": "128K", "request_id": request_id}
        initial = self.client.post("/v1/jobs?limit=1", headers=headers, json=body)
        self.assertEqual(initial.status_code, 202, initial.text)
        self.assertEqual(initial.json()["request_id"], request_id)
        self.submit(headers); self.submit(headers)  # Device queue is now full.
        duplicate = self.client.post("/v1/jobs?limit=1", headers=headers, json=body)
        self.assertEqual(duplicate.status_code, 202)
        self.assertEqual(duplicate.json()["id"], initial.json()["id"])
        self.assertEqual(len(self.service.security.owned_ids(device["device_id"])), 3)
        reopened = CompanionService(self.config, start_worker=False)
        from companion_api import JobRequest
        restored = reopened.submit(device["device_id"], JobRequest(**body))
        self.assertEqual(restored["id"], initial.json()["id"])
        changed = self.client.post("/v1/jobs", headers=headers, json={**body, "quality": "192K"})
        self.assertEqual(changed.status_code, 409)

    def test_bulk_registered_files_keep_order_and_remote_source_limit(self):
        device, headers = self.pair()
        asset = self.asset(device)
        source = {"kind": "asset", "id": asset, "authorized": True}
        response = self.client.post("/v1/jobs?limit=1", headers=headers, json={"sources": [source] * 1000})
        self.assertEqual(response.status_code, 202, response.text)
        self.assertEqual(response.json()["total_items"], 1000)
        self.assertEqual(len(response.json()["items"]), 1)
        job = self.service.converter.get_job(response.json()["id"])
        self.assertEqual([item["position"] for item in job["items"]], list(range(1, 1001)))
        remote = {"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": True}
        self.assertEqual(self.client.post("/v1/jobs", headers=headers, json={"sources": [remote] * 101}).status_code, 422)

    def test_tls_peer_origin_and_host_guards(self):
        self.assertEqual(self.client.get("http://127.0.0.1/v1/health", headers={"X-Forwarded-Proto": "https"}).status_code, 426)
        self.assertEqual(self.client.get("/v1/health", headers={"Host": "evil.example"}).status_code, 403)
        self.assertEqual(self.client.get("/v1/health", headers={"Origin": "https://evil.example"}).status_code, 403)
        with TestClient(self.app, base_url=self.config.url, client=("203.0.113.10", 9000), raise_server_exceptions=False) as public:
            self.assertEqual(public.get("/v1/health").status_code, 403)
        for host in ("0.0.0.0", "8.8.8.8", "::", "localhost"):
            self.assertFalse(local_address(host))
            with self.assertRaises(ValueError):
                CompanionConfig.initialize(Path(self.temp.name) / "forbidden", host)

    def test_strict_input_and_no_shell_or_local_paths(self):
        _, headers = self.pair()
        bad_sources = [
            {"kind": "file", "id": "/etc/passwd", "authorized": True},
            {"kind": "youtube_video", "id": "../../secret", "authorized": True},
            {"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": False},
            {"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": "true"},
            {"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": True, "command": "rm -rf"},
            {"kind": "direct", "id": "https://127.0.0.1/private", "authorized": True},
        ]
        for source in bad_sources:
            response = self.client.post("/v1/jobs", headers=headers, json={"sources": [source]})
            self.assertEqual(response.status_code, 422, response.text)
            self.assertNotIn("/etc/passwd", response.text)
        response = self.client.post("/v1/jobs", headers=headers, content=b"x" * (MAX_REQUEST_BYTES + 1))
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.client.get("/openapi.json").status_code, 404)

    def test_quota_and_ordered_pagination(self):
        device, headers = self.pair()
        job = self.submit(headers, self.asset(device), count=3)
        self.submit(headers); self.submit(headers)
        full = self.client.post("/v1/jobs", headers=headers, json={"sources": [{"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": True}]})
        self.assertEqual(full.status_code, 429)
        page = self.client.get(f"/v1/jobs/{job['id']}?limit=2", headers=headers).json()
        self.assertEqual([item["position"] for item in page["items"]], [1, 2])
        self.assertEqual(page["next_offset"], 2)
        page = self.client.get(f"/v1/jobs/{job['id']}?limit=2&offset=2", headers=headers).json()
        self.assertEqual([item["position"] for item in page["items"]], [3])

    def test_credentials_jobs_and_identity_survive_reopening(self):
        device, headers = self.pair()
        job = self.submit(headers, self.asset(device), count=2)
        reopened = CompanionService(CompanionConfig(self.root), start_worker=False)
        with TestClient(create_app(self.config, reopened), base_url=self.config.url, client=("127.0.0.1", 50002)) as client:
            self.assertEqual(client.get("/v1/device", headers=headers).json()["id"], device["device_id"])
            restored = client.get(f"/v1/jobs/{job['id']}", headers=headers).json()
            self.assertEqual(restored["status"], "queued")
            self.assertEqual([item["id"] for item in restored["items"]], [item["id"] for item in job["items"]])
            self.assertEqual(reopened.config.fingerprint, self.config.fingerprint)
        self.assertEqual(self.service.converter.store.path.stat().st_mode & 0o077, 0)

    def test_global_queue_limit_and_retry_admission(self):
        phones = [self.pair(f"Phone {index}") for index in range(3)]
        jobs = []
        for index, count in enumerate((3, 3, 2)):
            for _ in range(count):
                jobs.append(self.submit(phones[index][1]))
        headers = phones[2][1]
        response = self.client.post("/v1/jobs", headers=headers, json={"sources": [{"kind": "youtube_video", "id": "aaaaaaaaaaa", "authorized": True}]})
        self.assertEqual(response.status_code, 429)
        cancelled = jobs[-1]["id"]
        self.client.post(f"/v1/jobs/{cancelled}/cancel", headers=headers)
        self.submit(headers)
        retry = self.client.post(f"/v1/jobs/{cancelled}/retry", json={}, headers=headers)
        self.assertEqual(retry.status_code, 429)
        self.assertEqual(self.service.converter.get_job(cancelled)["status"], "cancelled")

    def test_retry_preserves_completed_items(self):
        device, headers = self.pair()
        job = self.submit(headers, self.asset(device), count=2)
        result = self.service.converter.run(job["id"])
        first, second = result["items"]
        original = Path(first["output_path"]).read_bytes()
        self.service.converter.store.update_item(second["id"], status="failed", error={"code": "test_failure"})
        self.service.converter.store.update_job(job["id"], "partial")
        response = self.client.post(f"/v1/jobs/{job['id']}/retry", json={"item_ids": [second["id"]]}, headers=headers)
        self.assertEqual(response.status_code, 202)
        self.assertEqual([item["status"] for item in response.json()["items"]], [first["status"], "pending"])
        self.assertEqual(Path(first["output_path"]).read_bytes(), original)

    def test_download_concurrency_is_bounded_and_released(self):
        device, headers, result, item, url = self.completed()
        held = [self.service.verified_file(device["device_id"], result["id"], item["id"]) for _ in range(2)]
        try:
            self.assertEqual(self.client.get(url + "/file", headers=headers).status_code, 429)
        finally:
            for artifact in held:
                artifact.close()
        self.assertEqual(self.client.get(url + "/file", headers=headers).status_code, 200)

    def test_disconnected_download_releases_descriptor_and_slot(self):
        device, headers, result, item, url = self.completed()
        verified = self.service.verified_file(device["device_id"], result["id"], item["id"])
        response = VerifiedStreamingResponse(verified, 0, verified.result["size"])
        async def broken_send(event):
            raise RuntimeError("Connection lost before body iteration")
        async def receive():
            return {"type": "http.disconnect"}
        with self.assertRaises(RuntimeError):
            asyncio.run(response({"type": "http", "asgi": {"spec_version": "2.4"}}, receive, broken_send))
        self.assertTrue(verified.stream.closed)
        self.assertEqual(self.client.get(url + "/file", headers=headers).status_code, 200)

    def test_verified_download_metadata_ranges_and_privacy(self):
        _, headers, result, item, url = self.completed()
        self.assertEqual(self.client.get(url + "/file").status_code, 401)
        response = self.client.get(url + "/file", headers=headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(hashlib.sha256(response.content).hexdigest(), response.headers["x-content-sha256"])
        self.assertIn("no-store", response.headers["cache-control"])
        partial = self.client.get(url + "/file", headers={**headers, "Range": "bytes=0-3"})
        self.assertEqual(partial.status_code, 206)
        self.assertEqual(partial.content, response.content[:4])
        self.assertNotIn("content-digest", partial.headers)
        self.assertEqual(self.client.get(url + "/file", headers={**headers, "Range": "bytes=1-2,4-5"}).status_code, 416)
        self.assertEqual(self.client.head(url + "/file", headers=headers).content, b"")
        manifest = self.client.get(url + "/metadata", headers=headers)
        self.assertEqual(manifest.json()["sha256"], item["result"]["sha256"])
        snapshot = self.client.get(f"/v1/jobs/{result['id']}", headers=headers)
        for body in (snapshot.text, manifest.text):
            self.assertNotIn(str(self.root), body)
            self.assertNotIn("output_path", body)

    def test_delivery_feed_is_owned_ordered_persistent_and_retried(self):
        device, headers, result, item, url = self.completed()
        self.assertEqual(self.client.get("/v1/deliveries").status_code, 401)
        page = self.client.get("/v1/deliveries?after=0&limit=1", headers=headers)
        self.assertEqual(page.status_code, 200, page.text)
        delivery = page.json()["deliveries"][0]
        sequence = delivery["sequence"]
        self.assertEqual(delivery["item"]["id"], item["id"])
        self.assertEqual(delivery["item"]["result"]["sha256"], item["result"]["sha256"])
        self.assertEqual(delivery["job"]["id"], result["id"])
        self.assertNotIn(str(self.root), page.text)
        _, other_headers = self.pair("Other")
        self.assertEqual(self.client.get("/v1/deliveries", headers=other_headers).json()["deliveries"], [])
        self.assertEqual(self.client.get(f"/v1/deliveries?after={sequence}", headers=headers).json()["deliveries"], [])
        reopened = CompanionService(self.config, start_worker=False)
        self.assertEqual(reopened.security.deliveries(device["device_id"], 0, 10)[0]["sequence"], sequence)
        self.service.converter.store.update_item(item["id"], status="failed")
        self.service.converter.store.update_job(result["id"], "partial")
        self.assertEqual(self.client.post(f"/v1/jobs/{result['id']}/retry", json={}, headers=headers).status_code, 202)
        self.service.converter.run(result["id"])
        redelivery = self.client.get(f"/v1/deliveries?after={sequence}", headers=headers).json()
        self.assertGreater(redelivery["next_after"], sequence)
        self.assertEqual(redelivery["deliveries"][0]["item"]["id"], item["id"])

    def test_delivery_feed_backfills_existing_completed_jobs(self):
        device, headers, result, item, _ = self.completed()
        with self.service.converter.store._connection() as db:
            db.execute("DELETE FROM companion_deliveries")
        reopened = CompanionService(self.config, start_worker=False)
        recovered = reopened.security.deliveries(device["device_id"], 0, 10)
        self.assertEqual([row["item_id"] for row in recovered], [item["id"]])

    def test_file_integrity_and_symlink_escape_are_blocked(self):
        _, headers, result, item, url = self.completed()
        output = Path(item["output_path"])
        original = output.read_bytes()
        output.write_bytes(original[::-1])
        self.assertEqual(self.client.get(url + "/file", headers=headers).status_code, 409)
        self.assertEqual(self.client.get(url + "/metadata", headers=headers).status_code, 409)
        secret = Path(self.temp.name) / "secret.txt"
        secret.write_text("private data")
        output.unlink(); output.symlink_to(secret)
        self.assertEqual(self.client.get(url + "/file", headers=headers).status_code, 409)
        tampered = {**item["result"], "path": str(secret)}
        self.service.converter.store.update_item(item["id"], result=tampered)
        self.assertEqual(self.client.get(url + "/file", headers=headers).status_code, 409)

    def test_unfinished_file_error_retry_and_api_cancellation(self):
        device, headers = self.pair()
        job = self.submit(headers, self.asset(device))
        item = job["items"][0]
        url = f"/v1/jobs/{job['id']}/items/{item['id']}/file"
        self.assertEqual(self.client.get(url, headers=headers).status_code, 409)
        self.service.converter.worker.invalid = True
        self.service.converter.run(job["id"])
        response = self.client.get(f"/v1/jobs/{job['id']}/progress", headers=headers)
        self.assertEqual(response.json()["items"][0]["error"], {"code": "invalid_format"})
        self.assertEqual(self.client.post(f"/v1/jobs/{job['id']}/retry", json={}, headers=headers).status_code, 202)
        started = threading.Event()
        class BlockingWorker(FakeWorker):
            def convert(self, source, info, workspace, quality, metadata, arguments, cancelled, progress):
                started.set()
                while not cancelled():
                    time.sleep(0.02)
                raise Cancelled()
        self.service.converter.worker = BlockingWorker()
        thread = threading.Thread(target=self.service.converter.run, args=(job["id"],))
        thread.start()
        try:
            self.assertTrue(started.wait(3))
            self.assertEqual(self.client.post(f"/v1/jobs/{job['id']}/cancel", headers=headers).status_code, 200)
        finally:
            self.service.converter.cancel(job["id"])
            thread.join(timeout=4)
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.service.converter.get_job(job["id"])["status"], "cancelled")

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "Native tools unavailable")
    def test_restart_during_conversion_retains_queue_credentials_and_retry_order(self):
        device, headers = self.pair()
        asset_id = self.asset(device)
        first = self.submit(headers, asset_id, count=2)
        folder = Path(self.temp.name) / "slow-tools"
        folder.mkdir()
        gate, entered = folder / "hold", folder / "entered"
        gate.touch()
        ffmpeg = shutil.which("ffmpeg")
        wrapper = folder / "ffmpeg"
        wrapper.write_text(f"#!{sys.executable}\n" +
            "import os, pathlib, sys, time\n" +
            f"gate = pathlib.Path({str(gate)!r})\n" +
            "if '-progress' in sys.argv:\n" +
            f"    pathlib.Path({str(entered)!r}).write_text('ready')\n" +
            "    while gate.exists(): time.sleep(0.02)\n" +
            f"os.execv({ffmpeg!r}, [{ffmpeg!r}, *sys.argv[1:]])\n")
        wrapper.chmod(0o700)
        native = CompanionService(self.config)
        with patch.dict(os.environ, {"PATH": str(folder) + os.pathsep + os.environ["PATH"]}):
            native.start()
            try:
                deadline = time.monotonic() + 8
                while not entered.exists() and time.monotonic() < deadline:
                    time.sleep(0.03)
                self.assertTrue(entered.exists(), "Actual FFmpeg conversion must be active before stopping")
                queued = self.submit(headers, asset_id)
                other = CompanionService(self.config)
                with self.assertRaisesRegex(RuntimeError, "already running"):
                    other.start()
            finally:
                native.close()
        self.assertFalse(native.thread.is_alive())
        stopped = self.service.converter.get_job(first["id"])
        self.assertEqual(stopped["status"], "cancelled")
        self.assertEqual(self.service.converter.get_job(queued["id"])["status"], "queued")
        self.assertTrue(self.service.asset_path(device["device_id"], asset_id)[0].is_file())
        gate.unlink()
        restarted = CompanionService(self.config)
        self.assertEqual(self.client.get("/v1/health", headers=headers).status_code, 200)
        retry = self.client.post(f"/v1/jobs/{first['id']}/retry", headers=headers, json={})
        self.assertEqual(retry.status_code, 202, retry.text)
        restarted.start()
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                jobs = [restarted.converter.get_job(job["id"]) for job in (first, queued)]
                if all(job["status"] == "completed" for job in jobs):
                    break
                time.sleep(0.05)
            self.assertTrue(all(job["status"] == "completed" for job in jobs), jobs)
            self.assertEqual([item["position"] for item in jobs[0]["items"]], [1, 2])
            self.assertEqual([item["id"] for item in jobs[0]["items"]], [item["id"] for item in first["items"]])
        finally:
            restarted.close()

    def test_registration_failure_removes_only_its_unpublished_copy(self):
        device, _ = self.pair()
        asset_id = self.asset(device)
        folder = self.config.state / "assets"
        existing = set(folder.iterdir())
        source = Path(self.temp.name) / "owned.wav"
        original = source.read_bytes()
        with patch("companion_service.os.fsync", side_effect=OSError(errno.ENOSPC, "Test disk full")):
            with self.assertRaises(OSError):
                self.service.register_asset(device["device_id"], source)
        self.assertEqual(set(folder.iterdir()), existing)
        self.assertEqual(source.read_bytes(), original)
        with patch.object(self.service.security, "devices", return_value=[{"id": device["device_id"], "revoked_at": None}]), \
             patch.object(self.service.converter.store, "_connection", side_effect=OSError("Test database failure")):
            with self.assertRaises(OSError):
                self.service.register_asset(device["device_id"], source)
        self.assertEqual(set(folder.iterdir()), existing)
        def changed(_):
            with source.open("ab") as output:
                output.write(b"changed during registration")
        with patch("companion_service.os.fsync", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "changed during registration"):
                self.service.register_asset(device["device_id"], source)
        self.assertEqual(set(folder.iterdir()), existing)
        self.assertTrue(source.is_file())
        self.assertTrue(self.service.asset_path(device["device_id"], asset_id)[0].is_file())

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "Native tools unavailable")
    def test_real_dispatcher_subprocess_local_media(self):
        device, headers = self.pair()
        asset_id = self.asset(device)
        native = CompanionService(self.config)
        with TestClient(create_app(self.config, native), base_url=self.config.url, client=("127.0.0.1", 50001)) as client:
            response = client.post("/v1/jobs", headers=headers, json={"sources": [{"kind": "asset", "id": asset_id, "authorized": True}]})
            self.assertEqual(response.status_code, 202)
            job_id = response.json()["id"]
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                job = client.get(f"/v1/jobs/{job_id}", headers=headers).json()
                if job["status"] not in {"queued", "running"}:
                    break
                time.sleep(0.15)
            self.assertEqual(job["status"], "completed", job)
            item = job["items"][0]
            audio = client.get(item["download_url"], headers=headers)
            self.assertEqual(audio.status_code, 200)
            self.assertEqual(hashlib.sha256(audio.content).hexdigest(), item["result"]["sha256"])


class NativeTLSTests(unittest.TestCase):
    def test_real_loopback_tls_identity_and_no_plaintext_access(self):
        with tempfile.TemporaryDirectory() as directory:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            config = CompanionConfig.initialize(directory, port=port)
            service = CompanionService(config, start_worker=False)
            secret = service.security.pairing("TLS test")["secret"]
            process = subprocess.Popen([sys.executable, "companion.py", "--root", directory, "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                context = ssl.create_default_context(cafile=str(config.cert))
                deadline = time.monotonic() + 8
                while True:
                    try:
                        with urllib.request.urlopen(config.url + "/v1/health", context=context, timeout=1):
                            self.fail("Missing token must not pass")
                    except urllib.error.HTTPError as error:
                        self.assertEqual(error.code, 401)
                        break
                    except OSError:
                        if process.poll() is not None:
                            self.fail("TLS service failed to start: " + process.stderr.read().decode())
                        if time.monotonic() > deadline:
                            self.fail("TLS service startup timed out")
                        time.sleep(0.1)
                with self.assertRaises(urllib.error.URLError):
                    urllib.request.urlopen(config.url + "/v1/health", timeout=1)
                with self.assertRaises(OSError):
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=1)
                request = urllib.request.Request(config.url + "/v1/pair", data=json.dumps({"secret": secret}).encode(), headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, context=context, timeout=2) as response:
                    paired = json.load(response)
                self.assertEqual(paired["server_certificate_sha256"], config.fingerprint)
                request = urllib.request.Request(config.url + "/v1/health", headers={"Authorization": "Bearer " + paired["token"]})
                with urllib.request.urlopen(request, context=context, timeout=2) as response:
                    self.assertEqual(json.load(response)["status"], "ok")
                with context.wrap_socket(socket.socket(), server_hostname="127.0.0.1") as connection:
                    connection.connect(("127.0.0.1", port))
                    self.assertEqual(hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest(), config.fingerprint)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
                process.stderr.close()


if __name__ == "__main__":
    unittest.main()
