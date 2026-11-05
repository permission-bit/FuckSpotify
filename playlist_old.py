
#!/usr/bin/env python3

import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlparse

BASE_DIR = Path.home() / "Music" / "YouTube"
SINGLES_DIR = BASE_DIR / "Singles"
PLAYLISTS_DIR = BASE_DIR / "Playlists"
BATCH_DIR = BASE_DIR / "Batch"

#AUDIO_QUALITY = "192K"
AUDIO_QUALITY = "320K" #320K is better

FRAGMENTS = 4


def clean_name(value):
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value)
    return value.strip(" .")


def valid_url(value):
    try:
        parsed = urlparse(value)
        host = (parsed.hostname or "").lower()
        return (
            parsed.scheme in ("http", "https")
            and (
                host in ("youtube.com", "youtu.be")
                or host.endswith(".youtube.com")
            )
        )
    except ValueError:
        return False


def dependencies_ready():
    for program in ("yt-dlp", "ffmpeg", "ffprobe"):
        if not shutil.which(program):
            print(f"Missing dependency: {program}")
            print("Install with: brew install yt-dlp ffmpeg")
            return False
    return True


def metadata_options(artist="", album="", playlist=False):
    options = []

    if artist:
        options += [
            "--parse-metadata",
            f"{artist}:%(meta_artist)s",
            "--parse-metadata",
            f"{artist}:%(meta_album_artist)s",
        ]

    if album:
        options += [
            "--parse-metadata",
            f"{album}:%(meta_album)s",
        ]
    elif playlist:
        options += [
            "--parse-metadata",
            "%(playlist_title|)s:%(meta_album)s",
        ]

    if playlist:
        options += [
            "--parse-metadata",
            "%(playlist_index|)s:%(meta_track)s",
        ]

    return options


def download(url, output, archive, playlist=False,
             artist="", album=""):

    if not valid_url(url):
        print(f"Skipping invalid YouTube URL: {url}")
        return False

    command = [
        "yt-dlp",
        "--yes-playlist" if playlist else "--no-playlist",
        "--ignore-errors",
        "--no-overwrites",
        "--continue",
        "--retries", "5",
        "--fragment-retries", "5",
        "--concurrent-fragments", str(FRAGMENTS),
        "--download-archive", str(archive),
        "-f", "bestaudio/best",
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", AUDIO_QUALITY,
        "--embed-metadata",
        "--embed-thumbnail",
        "--convert-thumbnails", "jpg",
        "--no-embed-chapters",
        "--no-embed-info-json",
    ]

    command += metadata_options(artist, album, playlist)
    command += ["-o", str(output), url]

    print(f"\nProcessing: {url}\n")

    try:
        result = subprocess.run(command, check=False)
        return result.returncode == 0
    except KeyboardInterrupt:
        print("\nInterrupted by user.")
        raise


def read_links(filename):
    path = Path(filename).expanduser()

    if not path.is_file():
        print(f"File not found: {path}")
        return []

    links = []
    seen = set()

    for line in path.read_text(encoding="utf-8-sig").splitlines():
        url = line.strip()

        if not url or url.startswith("#"):
            continue

        if not valid_url(url):
            print(f"Skipping invalid URL: {url}")
            continue

        if url not in seen:
            seen.add(url)
            links.append(url)

    return links


def main():
    print("\n=== YouTube MP3 Batch Converter ===\n")

    if not dependencies_ready():
        return

    BASE_DIR.mkdir(parents=True, exist_ok=True)

    single_url = input(
        "Single video URL (Enter to skip): "
    ).strip()

    playlist_url = input(
        "Playlist URL (Enter to skip): "
    ).strip()

    batch_file = input(
        "Batch TXT file (Enter to skip): "
    ).strip()

    if not any((single_url, playlist_url, batch_file)):
        print("No input provided. Exiting.")
        return

    artist = input(
        "Artist override (Enter for automatic): "
    ).strip()

    album = input(
        "Album override (Enter for automatic): "
    ).strip()

    if single_url:
        custom_name = clean_name(input(
            "Single filename (Enter for original title): "
        ).strip())

        SINGLES_DIR.mkdir(parents=True, exist_ok=True)

        filename = (
            f"{custom_name}.%(ext)s"
            if custom_name
            else "%(title).180B [%(id)s].%(ext)s"
        )

        download(
            single_url,
            SINGLES_DIR / filename,
            BASE_DIR / "singles_archive.txt",
            artist=artist,
            album=album
        )

    if playlist_url:
        PLAYLISTS_DIR.mkdir(parents=True, exist_ok=True)

        download(
            playlist_url,
            PLAYLISTS_DIR
            / "%(playlist_title|Playlist).150B"
            / "%(playlist_index|0)03d - %(title).150B [%(id)s].%(ext)s",
            BASE_DIR / "playlists_archive.txt",
            playlist=True,
            artist=artist,
            album=album
        )

    if batch_file:
        links = read_links(batch_file)
        print(f"\nFound {len(links)} unique valid URLs.")

        BATCH_DIR.mkdir(parents=True, exist_ok=True)

        for index, url in enumerate(links, start=1):
            print(f"\nSong {index}/{len(links)}")

            download(
                url,
                BATCH_DIR / "%(title).180B [%(id)s].%(ext)s",
                BASE_DIR / "batch_archive.txt",
                artist=artist,
                album=album
            )

    print("\nAll requested downloads processed.")
    print(f"Output directory: {BASE_DIR}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")