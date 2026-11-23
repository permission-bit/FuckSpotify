#!/usr/bin/env python3
"""Parallel YouTube-to-MP3 downloader for single videos, playlists and TXT batches."""

import json
import re
import shutil
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE_DIR = Path.home() / "Music" / "YouTube"
SINGLES_DIR = BASE_DIR / "Singles"
PLAYLISTS_DIR = BASE_DIR / "Playlists"
BATCH_DIR = BASE_DIR / "Batch"

WORKERS = 3                  # On an M1 with 8 GB RAM: start with 3; try 2-4
FRAGMENTS = 2                # Only helps for fragmented DASH/HLS streams
AUDIO_QUALITY = "320K"       # MP3 output bitrate, not original YouTube quality
EMBED_THUMBNAIL = True      # False saves thumbnail conversion / embedding time

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def clean_name(value):
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value)
    return value.strip(" .")


def valid_url(value):
    try:
        parsed = urlparse(value)
        host = (parsed.hostname or "").lower()
        return parsed.scheme in ("https", "http") and (
            host in ("youtube.com", "youtu.be")
            or host.endswith(".youtube.com")
        )
    except ValueError:
        return False


def video_id_from_url(url):
    """Identify standard YouTube video URLs for safe, thread-locked archiving."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    parts = [p for p in parsed.path.split("/") if p]

    if host == "youtu.be" and parts:
        candidate = parts[0]
    elif parts and parts[0] in ("shorts", "live", "embed", "v") and len(parts) > 1:
        candidate = parts[1]
    else:
        candidate = parse_qs(parsed.query).get("v", [""])[0]

    return candidate if VIDEO_ID_RE.fullmatch(candidate) else None


def dependencies_ready():
    missing = [p for p in ("yt-dlp", "ffmpeg", "ffprobe") if not shutil.which(p)]
    if missing:
        print("Fehlende Programme:", ", ".join(missing))
        print("Installieren: brew install yt-dlp ffmpeg")
        return False
    return True


def metadata_options(artist="", album="", track_number=None):
    options = []
    if artist:
        for tag in ("meta_artist", "meta_album_artist"):
            options.extend(("--parse-metadata", f"{artist}:%({tag})s"))
    if album:
        options.extend(("--parse-metadata", f"{album}:%(meta_album)s"))
    if track_number is not None:
        options.extend(("--parse-metadata", f"{track_number}:%(meta_track)s"))
    return options


class DownloadArchive:
    """Reads previous yt-dlp archives, prevents duplicate concurrent jobs,
    and serializes new archive writes in the original yt-dlp format.
    """

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.completed = set()
        self.in_progress = set()
        if path.is_file():
            self.completed = set(path.read_text(encoding="utf-8-sig").splitlines())

    def reserve(self, video_id):
        if not video_id:
            return True
        key = f"youtube {video_id}"
        with self.lock:
            if key in self.completed or key in self.in_progress:
                return False
            self.in_progress.add(key)
            return True

    def finish(self, video_id, success):
        if not video_id:
            return
        key = f"youtube {video_id}"
        with self.lock:
            self.in_progress.discard(key)
            if success and key not in self.completed:
                with self.path.open("a", encoding="utf-8") as f:
                    f.write(key + "\n")
                self.completed.add(key)


def download(url, output, archive, artist="", album="", track_number=None):
    if not valid_url(url):
        return "FEHLER", f"Ungueltige URL: {url}"

    video_id = video_id_from_url(url)
    if not archive.reserve(video_id):
        return "SKIP", url

    command = [
        "yt-dlp",
        "--no-playlist",
        "--no-progress",
        "--no-overwrites",
        "--no-post-overwrites",
        "--continue",
        "--retries", "5",
        "--fragment-retries", "5",
        "--concurrent-fragments", str(FRAGMENTS),
        "-f", "bestaudio/best",
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", AUDIO_QUALITY,
        "--embed-metadata",
        "--no-embed-chapters",
        "--no-embed-info-json",
    ]
    if EMBED_THUMBNAIL:
        command += ["--embed-thumbnail", "--convert-thumbnails", "jpg"]

    command += metadata_options(artist, album, track_number)
    command += ["-o", str(output), url]

    success = False
    message = url
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        success = result.returncode == 0
        if not success:
            message = (result.stderr or result.stdout or "Unbekannter Fehler").strip()[-1200:]
    except OSError as exc:
        message = str(exc)
    finally:
        archive.finish(video_id, success)

    return ("OK" if success else "FEHLER"), message


def run_jobs(jobs, archive):
    if not jobs:
        print("Keine Titel gefunden.")
        return

    print(f"\n{len(jobs)} Titel, bis zu {min(WORKERS, len(jobs))} gleichzeitig...\n")
    counts = {"OK": 0, "SKIP": 0, "FEHLER": 0}
    with ThreadPoolExecutor(max_workers=WORKERS) as executor:
        futures = {
            executor.submit(download, job["url"], job["output"], archive,
                            job.get("artist", ""), job.get("album", ""),
                            job.get("track_number")): job
            for job in jobs
        }
        for done, future in enumerate(as_completed(futures), start=1):
            job = futures[future]
            try:
                status, info = future.result()
            except Exception as exc:
                status, info = "FEHLER", str(exc)
            counts[status] += 1
            label = job.get("label", job["url"])
            print(f"[{done}/{len(jobs)}] {status}: {label}")
            if status == "FEHLER":
                print("   ", info)

    print(f"\nErgebnis: {counts['OK']} OK, {counts['SKIP']} bereits archiviert, "
          f"{counts['FEHLER']} Fehler.")


def get_playlist(url):
    """Fast playlist overview; full extraction happens in parallel per song."""
    if not valid_url(url):
        print("Ungueltige Playlist-URL.")
        return None

    print("\nLese Playlist-Titel und Video-IDs ...")
    cmd = ["yt-dlp", "--flat-playlist", "--dump-single-json",
           "--yes-playlist", "--ignore-errors", url]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        data = json.loads(proc.stdout)
    except (OSError, json.JSONDecodeError) as exc:
        print("Playlist konnte nicht gelesen werden:", exc)
        return None

    entries = []
    for index, entry in enumerate(data.get("entries") or [], start=1):
        if not isinstance(entry, dict):
            continue
        video_id = entry.get("id")
        if isinstance(video_id, str) and VIDEO_ID_RE.fullmatch(video_id):
            entries.append((index, f"https://www.youtube.com/watch?v={video_id}"))

    if not entries:
        print("Keine verfuegbaren Video-IDs gefunden.")
        if proc.stderr:
            print(proc.stderr.strip()[-800:])
        return None

    title = clean_name(str(data.get("title") or "Playlist")) or "Playlist"
    return title[:130], entries


def read_links(filename):
    path = Path(filename).expanduser()
    if not path.is_file():
        print("Datei nicht gefunden:", path)
        return []

    seen = set()
    links = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        url = line.strip()
        if not url or url.startswith("#"):
            continue
        if not valid_url(url):
            print("Ungueltige URL uebersprungen:", url)
            continue
        if url not in seen:
            seen.add(url)
            links.append(url)
    return links


def main():
    print("\n=== YouTube MP3 Fast Downloader ===\n")
    if not dependencies_ready():
        return

    BASE_DIR.mkdir(parents=True, exist_ok=True)
    single_url = input("Video-URL (Enter zum Ueberspringen): ").strip()
    playlist_url = input("Playlist-URL (Enter zum Ueberspringen): ").strip()
    batch_file = input("Batch-TXT-Datei (Enter zum Ueberspringen): ").strip()
    if not any((single_url, playlist_url, batch_file)):
        print("Keine Eingabe.")
        return

    artist = input("Kuenstler (Enter = automatisch): ").strip()
    album = input("Album (Enter = automatisch): ").strip()

    if single_url:
        custom = clean_name(input("Dateiname (Enter = YouTube-Titel): ").strip())
        SINGLES_DIR.mkdir(parents=True, exist_ok=True)
        output = SINGLES_DIR / (
            f"{custom}.%(ext)s" if custom else "%(title).180B [%(id)s].%(ext)s"
        )
        run_jobs([{"url": single_url, "output": output, "artist": artist,
                   "album": album}], DownloadArchive(BASE_DIR / "singles_archive.txt"))

    if playlist_url:
        playlist = get_playlist(playlist_url)
        if playlist:
            title, entries = playlist
            directory = PLAYLISTS_DIR / title
            directory.mkdir(parents=True, exist_ok=True)
            jobs = [
                {"url": url,
                 "output": directory / f"{index:03d} - %(title).150B [%(id)s].%(ext)s",
                 "artist": artist,
                 "album": album or title,
                 "track_number": index,
                 "label": f"{index:03d} | {url}"}
                for index, url in entries
            ]
            run_jobs(jobs, DownloadArchive(BASE_DIR / "playlists_archive.txt"))

    if batch_file:
        urls = read_links(batch_file)
        BATCH_DIR.mkdir(parents=True, exist_ok=True)
        jobs = [
            {"url": url,
             "output": BATCH_DIR / "%(title).180B [%(id)s].%(ext)s",
             "artist": artist, "album": album}
            for url in urls
        ]
        run_jobs(jobs, DownloadArchive(BASE_DIR / "batch_archive.txt"))

    print("\nFertig. Ausgabe:", BASE_DIR)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAbgebrochen.")
