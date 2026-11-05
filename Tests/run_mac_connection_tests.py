#!/usr/bin/env python3
"""Build production Swift networking and exercise it against a loopback TLS mock.

Run: PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python Tests/run_mac_connection_tests.py
Uses Xcode without changing xcode-select. No user keychain/data, LAN or downloads.
"""
import json
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from companion_security import CompanionConfig
from companion_pairing import pairing_qrcode


def main():
    environment = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
    with tempfile.TemporaryDirectory(prefix="mac-connection-tests-") as directory:
        folder = Path(directory)
        binary = folder / "check-mac-connection"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(folder / "modules"),
                        "OfflineMusic/MacCompanionClient.swift", "OfflineMusic/MacConnectionStore.swift", "OfflineMusic/MacTransferAPI.swift", "Tests/check_mac_connection.swift", "-o", str(binary)],
                       cwd=ROOT, env=environment, check=True)
        identity = CompanionConfig.initialize(folder / "server")
        cert, key = identity.cert, identity.key
        der = ssl.PEM_cert_to_DER_cert(cert.read_text())
        (folder / "cert.der").write_bytes(der)
        import hashlib
        fingerprint = hashlib.sha256(der).hexdigest()
        import time
        qr = folder / "pairing.png"
        pairing_qrcode({"url": "https://192.168.178.40:8765", "secret": "s" * 43,
                        "expires_at": time.time() + 300, "server_certificate_sha256": fingerprint}).save(qr, scale=8, border=4)
        devices, requests, consumed = {}, [], set()
        file_bytes = b"transport test bytes\0" * 16384
        file_hash = hashlib.sha256(file_bytes).hexdigest()
        manifest = folder / "download-manifest.json"
        manifest.write_text(json.dumps({"format": "mp3", "duration": 1, "size": len(file_bytes), "sha256": file_hash, "metadata": {}}))

        class MockServer(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def respond(self, status, data=None, headers=None):
                body = json.dumps(data).encode() if data is not None else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                for name, value in (headers or {}).items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                requests.append(self.path)
                assert self.path == "/v1/pair" and self.headers.get("Authorization") is None
                secret = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["secret"]
                if secret in consumed:
                    return self.respond(401)
                assert secret in {"s" * 43, "R" * 43}
                consumed.add(secret)
                token = "omc_" + ("R" if secret[0] == "R" else "t") * 43
                device = {"device_id": str(uuid.uuid4()), "name": "TLS iPhone", "token": token, "token_type": "Bearer", "server_certificate_sha256": fingerprint}
                devices[token] = device
                self.respond(200, device)

            def do_GET(self):
                requests.append(self.path)
                token = self.headers.get("Authorization", "").removeprefix("Bearer ")
                if token not in devices:
                    return self.respond(401)
                if self.path.startswith("/v1/jobs/") and self.path.endswith("/file"):
                    item = self.path.split("/")[-2]
                    if item.endswith("0003"):
                        return self.respond(302, headers={"Location": f"https://127.0.0.1:{self.server.server_port}/leak"})
                    length = len(file_bytes) + (1 if item.endswith("0004") else 0)
                    self.send_response(200)
                    for name, value in {"Content-Type": "audio/mpeg", "Content-Length": str(length),
                        "X-Content-SHA256": file_hash, "ETag": f'"{file_hash}"', "Connection": "close"}.items():
                        self.send_header(name, value)
                    self.end_headers()
                    try:
                        self.wfile.write(file_bytes[:len(file_bytes)//2] if item.endswith("0002") else file_bytes)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                if token == "omc_" + "R" * 43:
                    return self.respond(302, headers={"Location": f"https://127.0.0.1:{self.server.server_port}/leak"})
                self.respond(200, {"status": "ok", "api_version": 1, "device_id": devices[token]["device_id"]})

            def do_DELETE(self):
                requests.append(self.path)
                token = self.headers.get("Authorization", "").removeprefix("Bearer ")
                assert self.path == "/v1/device" and token in devices
                del devices[token]
                self.respond(204)

        server = ThreadingHTTPServer(("127.0.0.1", 0), MockServer)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            subprocess.run([str(binary), f"https://127.0.0.1:{server.server_port}", str(folder / "cert.der"), str(qr), str(manifest)], cwd=ROOT, env=environment, check=True)
            assert requests.count("/v1/pair") == 2, "Wrong TLS pin must fail before sending a pairing secret"
            assert "/leak" not in requests, "Redirect leaked a request"
            print("PASS: mock server received no secrets for a rejected TLS pin and no redirected bearer request", flush=True)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=3)


if __name__ == "__main__":
    main()
