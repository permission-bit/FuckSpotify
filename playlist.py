
#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from converter_core import Converter, MediaSource, clean_name, valid_url, missing_dependencies, metadata_options
from conversion_worker import ConversionError, ConversionWorker

BASE_DIR = Path.home() / "Music" / "YouTube"
SINGLES_DIR = BASE_DIR / "Singles"
PLAYLISTS_DIR = BASE_DIR / "Playlists"
BATCH_DIR = BASE_DIR / "Batch"

AUDIO_QUALITY = "320K"  # Encoding bitrate cannot improve a lossy source.

FRAGMENTS = 4


def dependencies_ready():
    missing = missing_dependencies()
    for program in missing:
        print(f"Missing dependency: {program}")
    if missing:
        print("Install with: brew install yt-dlp ffmpeg")
    return not missing


def download(url, output, archive, playlist=False,
             artist="", album="", *, authorized=False, quality=AUDIO_QUALITY):
    """Compatibility CLI helper. Old archive files remain untouched.

    SQLite results replace archive-only skipping, which cannot prove that a
    usable, validated file still exists. Callers must explicitly authorize media.
    """

    if not valid_url(url):
        print(f"Skipping invalid YouTube URL: {url}")
        return False

    try:
        converter = Converter(BASE_DIR, worker=ConversionWorker(fragments=FRAGMENTS))
        job = converter.submit(MediaSource(url, "playlist" if playlist else "video", authorized=authorized),
                               quality=quality, artist=artist, album=album, output_template=output)
        print(f"\nJob: {job['id']}\nProcessing: {url}\n")
        result = converter.run(job["id"], _print_progress)
        print(f"Result: {result['status']} · {result['counts']}")
        return result["status"] == "completed"
    except (ValueError, OSError, ConversionError) as error:
        print(f"Cannot process source: {error}")
        return False


def _print_progress(event):
    if event.get("status") == "failed":
        print(f"Failed: {event['error']['message']}")
    elif event.get("phase"):
        fraction = event.get("fraction")
        suffix = f" {fraction:.0%}" if fraction is not None else ""
        print(f"{event['item_id']}: {event['phase']}{suffix}")
    elif event.get("result"):
        print(f"{event.get('status')}: {event['result']['path']}")


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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Authorized-media MP3 converter; no network server")
    parser.add_argument("--status", metavar="JOB_ID", help="Print a persisted job as JSON")
    parser.add_argument("--cancel", metavar="JOB_ID", help="Request cancellation, including from another terminal")
    parser.add_argument("--retry", metavar="JOB_ID", help="Retry failed/cancelled/interrupted items")
    parser.add_argument("--json", action="store_true", help="Use JSON output for retry progress/results")
    args = parser.parse_args(argv)
    job_id = args.status or args.cancel or args.retry
    if job_id:
        converter = Converter(BASE_DIR)
        if args.cancel:
            result = converter.cancel(job_id)
        elif args.retry:
            converter.retry(job_id)
            callback = (lambda event: print(json.dumps(event, ensure_ascii=False))) if args.json else _print_progress
            result = converter.run(job_id, callback)
        else:
            result = converter.get_job(job_id)
        print(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))
        return
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

    authorized = input("Do you have permission for every selected download, including platform permissions? [y/N]: ").strip().lower() in {"y", "yes", "j", "ja"}
    if not authorized:
        print("No authorization confirmed. Nothing will be downloaded.")
        return
    quality = input(f"MP3 quality (64–320K or VBR 0–10; Enter for {AUDIO_QUALITY}): ").strip() or AUDIO_QUALITY

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
            album=album,
            authorized=True,
            quality=quality
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
            album=album,
            authorized=True,
            quality=quality
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
                album=album,
                authorized=True,
                quality=quality
            )

    print("\nRequested jobs processed; check the result/error summary above.")
    print(f"Output directory: {BASE_DIR}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
    except (KeyError, ValueError, OSError, ConversionError) as error:
        print(f"\nError: {error}")
