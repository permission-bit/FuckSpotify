# OfflineMusic

OfflineMusic is a native offline music player for iPhone, built with SwiftUI, SwiftData, and AVFoundation. It has no server, account, analytics, or internet requirement.

## Features

- Import individual audio files or an entire folder from the Files app
- Recursive folder import with metadata and artwork extraction
- Local storage in Application Support
- Songs, albums, artists, search, favorites, and playlists
- Native mini-player and Now Playing screen
- Play, pause, seek, next, previous, shuffle, and repeat
- Background playback, Control Center, lock-screen controls, AirPods, Bluetooth, and car audio
- Automatic pause when an audio route disconnects
- Native light/dark mode and Dynamic Type support

## Requirements

- macOS with Xcode 16 or later
- iOS 17 or later
- An Apple Developer account for installing on a physical iPhone

## Build and install

1. Open `OfflineMusic.xcodeproj` in Xcode.
2. Select the `OfflineMusic` target and choose your Apple Developer Team under **Signing & Capabilities**.
3. Keep **Automatically manage signing** enabled.
4. Use a unique bundle identifier, for example `rocks.braxton.offlinemusic`.
5. Connect an iPhone, select it as the run destination, and press **Run**.

The app stores imported music locally on the device. Removing the app removes its local library.

## Project structure

- `OfflineMusic/OfflineMusicApp.swift` — app entry point, SwiftData models, and audio engine
- `OfflineMusic/Views.swift` — SwiftUI screens and playback controls
- `OfflineMusic/FolderImporter.swift` — recursive folder import
- `convert.py` — optional music conversion helper

## Music conversion helper

The optional helper converts an existing music folder recursively with `ffmpeg`. The app itself does not require conversion and can import supported files directly.

```bash
brew install ffmpeg
python3 convert.py ./music ./converted --format m4a
```

Supported output formats are `m4a`, `mp3`, and `wav`. Metadata is preserved when supported by the selected format.

## License

Add the license of your choice before publishing this repository.
