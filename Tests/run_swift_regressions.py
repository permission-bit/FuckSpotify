#!/usr/bin/env python3
"""Run existing Swift regression suites sequentially with temporary caches."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SUITES = (
    "check_catalog.swift", "check_duplicates.swift", "check_library_transactions.swift",
    "check_playback_session.swift", "check_smart_playlists.swift",
    "check_audio_playback.swift", "check_native_audio.swift",
)


def main():
    with tempfile.TemporaryDirectory(prefix="offline-music-regressions-") as directory:
        environment = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                       "CLANG_MODULE_CACHE_PATH": str(Path(directory) / "clang"),
                       "SWIFT_MODULECACHE_PATH": str(Path(directory) / "swift")}
        for suite in SUITES:
            print(f"Running {suite}", flush=True)
            subprocess.run(["xcrun", "swift", "Tests/" + suite], cwd=ROOT,
                           env=environment, check=True, timeout=240)
        print(f"PASS: {len(SUITES)} Swift regression suites", flush=True)


if __name__ == "__main__":
    main()
