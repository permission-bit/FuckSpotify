# jox

A local music player for iPhone. Bring your own audio files, build playlists from your favorites, and cut an intro or a section out of the middle of a track right from Now Playing. Once your music is imported, you can listen offline without an account.

**iOS 17+** · **SwiftUI** · **12 app languages**

[Install on iPhone](#install-on-iphone) · [Import music](#import-and-play) · [Prepare MP3s on your Mac](#prepare-mp3s-on-your-mac) · [Mac Companion](#mac-companion)

<p align="center">
  <img src="design/jox_demo.gif" alt="jox on iPhone showing the library, waveform editor, playlists, and duplicate review" width="300">
</p>

## Install on iPhone

Build jox from source with **Xcode 26.1 or later** on a Mac.

```sh
git clone https://github.com/permission-bit/FuckSpotify.git
cd FuckSpotify
open OfflineMusic.xcodeproj
```

1. Connect and unlock your iPhone. Accept the trust prompt if it appears, then sign in under **Xcode → Settings → Apple Accounts**.
2. In the **OfflineMusic** target, open **Signing & Capabilities**. Enable **Automatically manage signing**, select your team, and enter a unique bundle identifier, such as `com.yourname.jox`.
3. Select the **OfflineMusic** scheme and your iPhone as the run destination. If prompted, enable **Settings → Privacy & Security → Developer Mode** on the iPhone and confirm after it restarts.
4. Press **⌘R** to build and install. You can also select an iPhone simulator to try the app on your Mac.

[Apple’s Xcode installation and signing guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## Import and play

1. Make your audio available in the iPhone’s **Files** app. AirDrop individual files or put a folder in iCloud Drive.
2. In jox, open **Home → + → Import files** or **Import folder**. Folder import includes subfolders, and embedded tags and artwork carry over when available.
3. Tap a song to play it. Tap the mini-player to open **Now Playing**, or use the lock-screen controls. Heart a track, then open **Library → Artists → Favorites** to browse liked songs by artist.

## What you can do with jox

- **Organize your collection.** Browse songs, albums, artists, and genres. Build playlists by hand or use smart playlists for favorites, recently added, recently played, most played, and never played. Review suspected duplicates and preview each version before deciding what to keep.
- **Keep the music going.** Queue a song with **Play Next**, turn on shuffle, or set a sleep timer. Playback loops back to the start of the list, and **Repeat One** loops the current track. Gapless playback and adjustable crossfade are available in playback settings.
- **Edit a track while you’re listening.** Open **Now Playing → sliders button → Trim Audio**. Drag the waveform handles and choose **Keep Selection** to make a clip or **Remove selection** to cut a section and join the audio on either side. Preview the edit, fine-tune it, or use undo and redo. Save as **Create New Clip** or choose **Trim Original** to update the existing library entry.
- **Preview YouTube links.** Open **Home → YouTube & Import** to preview public videos or playlists in the official player. To search from jox, add your own YouTube Data API v3 key in the import screen’s settings. [YouTube setup and import guide](YOUTUBE_IMPORT.md)

Choose the app language under **Settings → Language**. [Translated project summaries](README-translations/README.md)

## Prepare MP3s on your Mac

[`download.py`](download.py) is a separate terminal tool for YouTube recordings you have permission to download. It converts one item at a time to MP3, with tags and cover art when available. If your music is already in Files, you can go straight to [Import and play](#import-and-play).

With Homebrew installed, run these commands from the repository folder. [Homebrew package details](https://formulae.brew.sh/formula/yt-dlp)

```sh
brew install yt-dlp ffmpeg
nice -n 10 python3 download.py
```

Enter a video URL, a playlist URL, or the path to a text file with one video URL per line. Press **Return** to skip any unused prompt or leave the artist and album tags as supplied. A text file can contain blank lines and comments beginning with `#`.

| Input | Saved under `~/Music/YouTube/` |
| --- | --- |
| Video URL | `Singles/` |
| Playlist URL | `Playlists/<playlist title>/`, with numbered filenames |
| Text file | `Batch/` |

For a lighter run, start with a few links. The script downloads one fragment at a time, and `nice` gives other work on the Mac priority when it needs CPU time. Keep the archive files in the output folder so reruns skip items already recorded for that mode. When a folder is ready, send it to Files or use the Companion to share the finished MP3s.

## Mac Companion

Use **OfflineMusic Companion** to share audio files over your local network. On [GitHub Releases](https://github.com/permission-bit/FuckSpotify/releases), choose the `arm64` ZIP for Apple silicon or `x86_64` for Intel when a release is available. The packaged app requires **macOS 14+** and includes Python and FFmpeg. For a source setup, see the [Mac Companion guide](MAC_APP.md).

1. Open the Companion and click **Start Mac service**. Keep the Mac and iPhone on the same network.
2. In jox, tap **Home → Mac icon**, scan the QR code, and confirm the certificate identity.
3. Select the iPhone in the Companion and share files. On the iPhone, open **YouTube & Import → Imports** and choose a quality and playlist destination.

The connection uses local HTTPS with certificate pinning. [Pairing guide](MAC_CONNECTION.md) · [Import guide](MAC_IMPORT.md) · [Companion API](COMPANION.md)

## Development

The iOS app is in [`OfflineMusic/`](OfflineMusic/), the Mac app build scripts are in [`MacCompanion/`](MacCompanion/), and the regression suites are in [`Tests/`](Tests/).

```sh
python3 Tests/run_swift_regressions.py
```

See [Quality checks](QUALITY_CHECK.md) for the simulator build and integration tests, [Contributing](CONTRIBUTING.md) for pull requests, and [Security](SECURITY.md) for private reports.

## License

The repository does not currently include an open-source license.
