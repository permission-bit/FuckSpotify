#!/usr/bin/env python3
"""Production YouTube API/store against an in-process URLProtocol mock only."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
environment = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
with tempfile.TemporaryDirectory(prefix="youtube-ui-tests-") as directory:
    binary = Path(directory) / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(Path(directory) / "modules"),
                    "OfflineMusic/MacCompanionClient.swift", "OfflineMusic/YouTubeAPI.swift", "OfflineMusic/YouTubeSearchStore.swift", "Tests/check_youtube.swift", "-o", str(binary)],
                   cwd=ROOT, env=environment, check=True)
    subprocess.run([str(binary)], cwd=ROOT, env=environment, check=True, timeout=30)
