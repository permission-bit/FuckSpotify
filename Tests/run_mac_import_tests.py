#!/usr/bin/env python3
"""Real local WAV/MP3 -> companion HTTPS -> production Swift importer/SwiftData.

No external downloads or user library/keychain access. Run using .venv-companion.
"""
import json
import math
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from companion_security import CompanionConfig
from companion_service import CompanionService
from companion_api import JobRequest


def between(text, start, end):
    return text[text.index(start):text.index(end)]


def main():
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "PYTHONDONTWRITEBYTECODE": "1"}
    with tempfile.TemporaryDirectory(prefix="mac-import-test-") as directory:
        root = Path(directory)
        library = root / "phone-library"
        library.mkdir()
        sources = []
        for index in (1, 2):
            wav = root / f"owned-{index}.wav"
            with wave.open(str(wav), "wb") as output:
                output.setnchannels(1); output.setsampwidth(2); output.setframerate(44100)
                output.writeframes(b"".join(struct.pack("<h", int(1000 * math.sin(frame * 2 * math.pi * (220 * index) / 44100))) for frame in range(88200)))
            cover = root / f"cover-{index}.ppm"
            cover.write_bytes(b"P6\n32 32\n255\n" + bytes((index * 80, 30, 150)) * 1024)
            source = root / f"input-{index}.mp3"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(wav), "-i", str(cover), "-map", "0:a", "-map", "1:v",
                            "-c:a", "libmp3lame", "-b:a", "128k", "-c:v", "mjpeg", "-disposition:v", "attached_pic", "-id3v2_version", "3",
                            "-metadata", f"title={'First' if index == 1 else 'Second'} local fixture", "-metadata", "artist=Fixture Artist",
                            "-metadata", "album=Transfer fixture", "-metadata", "genre=Rock", "-metadata", f"track={index + 1}/9", "-n", str(source)], check=True)
            sources.append(source)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
        config = CompanionConfig.initialize(root / "mac-library", port=port)
        service = CompanionService(config, start_worker=False)
        paired = service.security.pair(service.security.pairing("Import test iPhone")["secret"])
        assets = [service.register_asset(paired["device_id"], source) for source in sources]
        job = service.submit(paired["device_id"], JobRequest(sources=[{"kind": "asset", "id": asset["asset_id"], "authorized": True} for asset in assets], quality="128K"))
        completed = service.converter.run(job["id"])
        assert completed["status"] == "completed", completed
        first = completed["items"][0]["result"]
        assert first["metadata"]["title"] == "First local fixture", "Local import must retain embedded title instead of replacing it with the filename"
        shutil.copyfile(first["path"], library / "manual.mp3")
        (root / "manifest.json").write_text(json.dumps(service.public_result(first)))
        credentials = root / "credentials.json"
        credentials.write_text(json.dumps({"endpoint": {"url": config.url}, "fingerprint": config.fingerprint,
            "deviceID": paired["device_id"], "name": paired["name"], "token": paired["token"]}))
        credentials.chmod(0o600)

        app = (ROOT / "OfflineMusic/OfflineMusicApp.swift").read_text()
        models = between(app, "@Model final class Song", "enum LibraryStore")
        old_app = subprocess.check_output(["git", "show", "HEAD:OfflineMusic/OfflineMusicApp.swift"], cwd=ROOT, text=True)
        old_models = between(old_app, "@Model final class Song", "enum LibraryStore")
        support = 'enum LibraryStore { static var musicURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAC_IMPORT_TEST_LIBRARY"]!, isDirectory: true) } }\n'
        env["MAC_IMPORT_TEST_LIBRARY"] = str(library)
        old = root / "old.swift"
        old.write_text("import Foundation\nimport SwiftData\n" + old_models + support + '''
@main struct SeedOldLibrary {
 @MainActor static func main() throws {
  let configuration = ModelConfiguration(url: LibraryStore.musicURL.appendingPathComponent("library.store"))
  let container = try ModelContainer(for: Song.self, Playlist.self, MusicGenre.self, ArtistProfile.self, configurations: configuration)
  let context = container.mainContext
  let genre = MusicGenre(name: "My manual genre"); context.insert(genre)
  let song = Song(title: "My edited name", artist: "Manual artist", album: "Manual album", duration: 2, fileName: "manual.mp3", importedGenre: "Original genre")
  song.isFavorite = true; song.genreOverrideID = genre.id; song.genreIDs = [genre.id]; context.insert(song)
  let missing = Song(title: "Missing file", fileName: "not-present.mp3"); context.insert(missing)
  let playlist = Playlist(name: "Manual order"); playlist.songIDs = [missing.id, song.id]; context.insert(playlist)
  try context.save()
 }
}
''')
        common = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-name", "MacImportChecks", "-module-cache-path", str(root / "modules")]
        subprocess.run([*common, str(old), "-o", str(root / "seed")], cwd=ROOT, env=env, check=True)
        subprocess.run([str(root / "seed")], cwd=ROOT, env=env, check=True)
        management = (ROOT / "OfflineMusic/LibraryManagement.swift").read_text()
        catalog = (ROOT / "OfflineMusic/MusicCatalog.swift").read_text()
        views = (ROOT / "OfflineMusic/Views.swift").read_text()
        pure = root / "library.swift"
        pure.write_text("import Foundation\nimport SwiftData\nimport AVFoundation\nimport CryptoKit\nimport UniformTypeIdentifiers\n" + models + support
                       + between(management, "enum DuplicateKind", "struct DuplicateManagerView")
                       + between(catalog, "@MainActor", "struct GenreLibraryView")
                       + "\n" + views[views.index("@MainActor\nenum Importer"):])
        files = ["OfflineMusic/MacCompanionClient.swift", "OfflineMusic/MacConnectionStore.swift", "OfflineMusic/MacTransferAPI.swift",
                 "OfflineMusic/ImportHubAPI.swift", "OfflineMusic/ImportHubStore.swift",
                 "OfflineMusic/MacImportModels.swift", "OfflineMusic/MacImportLibrary.swift", "OfflineMusic/MacImportCoordinator.swift",
                 "OfflineMusic/FolderImporter.swift", "Tests/check_import_hub.swift", "Tests/check_mac_import.swift"]
        binary = root / "checks"
        subprocess.run([*common, str(pure), *files, "-o", str(binary)], cwd=ROOT, env=env, check=True)
        server = subprocess.Popen([sys.executable, "companion.py", "--root", str(config.root), "serve"], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            context = ssl.create_default_context(cafile=str(config.cert))
            deadline = time.monotonic() + 10
            while True:
                try:
                    urllib.request.urlopen(config.url + "/v1/health", context=context, timeout=1)
                except urllib.error.HTTPError as error:
                    assert error.code == 401
                    error.close(); break
                except OSError:
                    if server.poll() is not None:
                        raise RuntimeError(server.stderr.read().decode())
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Temporary companion did not start")
                    time.sleep(0.1)
            subprocess.run([str(binary), str(credentials), str(root / "manifest.json")], cwd=ROOT, env=env, check=True, timeout=90)
        finally:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            server.stderr.close()


if __name__ == "__main__":
    main()
