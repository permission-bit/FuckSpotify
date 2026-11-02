#!/usr/bin/env python3

import subprocess
import shutil
import re
from pathlib import Path

OUTPUT_DIR = Path.home() / "Music" / "YouTube"


def main():
    print("\n=== YouTube MP3 Converter ===\n")

    for program in ("yt-dlp", "ffmpeg", "ffprobe"):
        if not shutil.which(program):
            print(f"Error: {program} is not installed.")
            print("Installation: brew install yt-dlp ffmpeg")
            return

    url = input("YouTube URL: ").strip()
    if not url:
        print("No URL provided.")
        return

    name = input("Filename (without .mp3): ").strip()
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    name = name.strip(" .")

    if not name or name in (".", ".."):
        print("Invalid filename.")
        return

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    output = OUTPUT_DIR / f"{name}.mp3"

    if output.exists():
        print(f"\nFile already exists: {output}")
        print("Cancelled to prevent overwriting.")
        return

    command = [
        "yt-dlp",
        "--no-playlist",
        "--no-overwrites",
        "-f", "bestaudio/best",
        "-x",
        "--audio-format", "mp3",
        "--audio-quality", "320K",
        "--embed-metadata",
        "-o", str(OUTPUT_DIR / f"{name}.%(ext)s"),
        url,
    ]

    print("\nStarting download and conversion...\n")

    try:
        subprocess.run(command, check=True)

        if output.exists():
            print("\nSuccess!")
            print(f"Saved to: {output}")
        else:
            print("\nProcess completed. Please check the output.")

    except subprocess.CalledProcessError:
        print("\nDownload or conversion failed.")
    except KeyboardInterrupt:
        print("\nCancelled.")


if __name__ == "__main__":
    main()