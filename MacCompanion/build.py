#!/usr/bin/env python3
"""Build a self-contained native Mac app; run separately on Intel and Apple Silicon."""
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    app = output / "OfflineMusic Companion.app"
    if app.exists():
        raise SystemExit("dist/OfflineMusic Companion.app already exists; move it before rebuilding")
    tools = {}
    for name in ("ffmpeg", "ffprobe", "openssl"):
        path = shutil.which(name)
        if not path:
            raise SystemExit(f"Build dependency missing: {name}")
        tools[name] = str(Path(path).resolve())
    command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir",
               "--name", "companion-runtime", "--paths", str(ROOT),
               "--distpath", str(output / "runtime-build"), "--workpath", str(ROOT / "build/mac-runtime"),
               "--specpath", str(ROOT / "build"), "--collect-all", "uvicorn", "--collect-all", "segno",
               "--hidden-import", "companion_worker", "--hidden-import", "companion_api"]
    for path in tools.values():
        command += ["--add-binary", path + ":tools"]
    command.append(str(ROOT / "MacCompanion/runtime.py"))
    environment = {**os.environ, "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
                   "PYINSTALLER_CONFIG_DIR": str(ROOT / "build/pyinstaller-cache")}
    subprocess.run(command, cwd=ROOT, env=environment, check=True)
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    shutil.copytree(output / "runtime-build/companion-runtime", resources / "runtime", symlinks=True)
    info = {"CFBundleExecutable": "OfflineMusicCompanion", "CFBundleIdentifier": "local.offlinemusic.companion.desktop",
            "CFBundleName": "OfflineMusic Companion", "CFBundleDisplayName": "OfflineMusic Companion",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
            "NSLocalNetworkUsageDescription": "Verbinde dein iPhone sicher mit deinem Mac und übertrage deine eigene Musik.",
            "NSBonjourServices": ["_offlinemusic._tcp"]}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                    "-module-cache-path", str(ROOT / "build/swift-modules"),
                    "-target", platform.machine() + "-apple-macos14.0", "MacCompanion/App.swift",
                    "-o", str(contents / "MacOS/OfflineMusicCompanion")], cwd=ROOT, env=environment, check=True)
    notices = resources / "ThirdParty"
    notices.mkdir()
    with (notices / "FFmpeg-license.txt").open("wb") as stream:
        subprocess.run([tools["ffmpeg"], "-L"], stdout=stream, stderr=subprocess.STDOUT, check=True)
    # Preserve Python dependency copyright/license notices in the bundled runtime.
    shutil.copy(ROOT / "MAC_APP.md", resources / "Anleitung.md")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    archive = output / ("OfflineMusic-Companion-" + platform.machine() + ".zip")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    print(archive)


if __name__ == "__main__":
    main()
