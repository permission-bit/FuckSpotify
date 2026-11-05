"""Smoke-test only a built bundle; no user data or personal service touched."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import socket
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave

app = Path(sys.argv[1]).resolve()
runtime = app / "Contents/Resources/runtime/companion-runtime"
with tempfile.TemporaryDirectory(prefix="mac-app-bundle-") as directory:
    root = Path(directory) / "test-library"
    env = {**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    def call(*arguments):
        return subprocess.check_output([str(runtime), *arguments], env=env, text=True, timeout=30)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
    info = json.loads(call("--root", str(root), "init", "--port", str(port)))
    assert info["url"] == f"https://127.0.0.1:{port}"
    assert json.loads(call("--root", str(root), "devices")) == []
    pairing = json.loads(call("--root", str(root), "pair", "--name", "Bundle test"))
    assert pairing["secret"]
    assert json.loads(call("--desktop-status", str(root)))["ready"] is False
    # The frozen process must dispatch the worker, not recursively start the GUI/CLI.
    worker = subprocess.run([str(runtime), "--worker", "--help"], env=env, capture_output=True, text=True, timeout=30)
    assert worker.returncode == 0 and "--job" in worker.stdout
    tools = runtime.parent / "_internal/tools"
    for name in ("ffmpeg", "ffprobe", "openssl"):
        result = subprocess.run([str(tools / name), "version" if name == "openssl" else "-version"], env=env, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr
    context = ssl.create_default_context(cafile=info["certificate"])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    server = subprocess.Popen([str(runtime), "--root", str(root), "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if json.loads(call("--desktop-status", str(root)))["ready"]:
                break
            assert server.poll() is None, "Packaged server exited"
            time.sleep(0.1)
        else:
            raise AssertionError("Packaged server did not become ready")
        request = urllib.request.Request(info["url"] + "/v1/pair", data=json.dumps({"secret": pairing["secret"]}).encode(), headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=10) as response:
            credentials = json.load(response)
        source = Path(directory) / "owned-test.wav"
        with wave.open(str(source), "wb") as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(8000); stream.writeframes(b"\0\0" * 8000)
        job = json.loads(call("--root", str(root), "submit-files", "--device", credentials["device_id"], "--authorized", "--quality", "128K", str(source)))
        headers = {"Authorization": "Bearer " + credentials["token"]}
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            with opener.open(urllib.request.Request(info["url"] + "/v1/jobs/" + job["job_id"], headers=headers), timeout=5) as response:
                result = json.load(response)
            if result["status"] not in ("queued", "running", "expanding"):
                break
            time.sleep(0.1)
        assert result["status"] == "completed", result
        item = result["items"][0]
        with opener.open(urllib.request.Request(info["url"] + item["download_url"], headers=headers), timeout=5) as response:
            audio = response.read()
        assert hashlib.sha256(audio).hexdigest() == item["result"]["sha256"]
        assert source.exists()
    finally:
        server.terminate()
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait()
print("PASS: self-contained bundle without Homebrew PATH: TLS, pairing, devices, frozen worker, real FFmpeg conversion, verified download and orderly shutdown")
