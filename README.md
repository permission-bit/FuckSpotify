# OfflineMusic

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-0a84ff)](https://developer.apple.com/ios/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-orange)](https://developer.apple.com/xcode/swiftui/)
[![License: not yet selected](https://img.shields.io/badge/license-not%20yet%20selected-lightgrey)](#license)

OfflineMusic is a native offline music player for iPhone, built with SwiftUI,
SwiftData and AVFoundation. Your library stays on the device: there is no
account, analytics, public server or required internet connection.

The repository also contains an optional local Mac Companion. It can convert
and transfer audio files from a Mac to a paired iPhone over local HTTPS. The
Companion is not a public server and does not configure port forwarding,
firewall rules or a login item automatically.

## Documentation languages

The full documentation is maintained in English. Short project summaries are
available in the supported app languages:

[Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) ·
[Italiano](README.it.md) · [Português](README.pt-BR.md) ·
[Nederlands](README.nl.md) · [Polski](README.pl.md) · [Türkçe](README.tr.md) ·
[日本語](README.ja.md) · [한국어](README.ko.md) · [简体中文](README.zh-Hans.md)

## Features

- Import individual audio files or complete folders from the iOS Files app
- Recursive folder import with metadata and embedded artwork
- Local storage in Application Support
- Songs, albums, artists, search, favorites and playlists
- Native mini-player, Now Playing screen and lock-screen controls
- Background playback, Control Center, AirPods, Bluetooth and car audio
- Shuffle, repeat, crossfade, gapless playback and a sleep timer
- Genre and artist profiles with offline matching
- Optional official YouTube search and preview using the user's own API key
- Optional local Mac Companion for authorized files and automatic import
- App language selection from Settings
- Shared dark design system with a fresh green accent and native glass on iOS 26
- Complete German and English UI, including plurals, errors and accessibility labels;
  the existing additional language translations remain partial

Design details, changed files and verification limits: [UI_DESIGN.md](UI_DESIGN.md).

## Requirements

- macOS with Xcode 16 or later for the iOS app
- iOS 17 or later
- macOS 14 or later for the packaged Mac Companion
- An Apple Developer account for installing the iOS app on a physical device

## Build the iOS app

1. Open `OfflineMusic.xcodeproj` in Xcode.
2. Select the `OfflineMusic` target and choose your own Apple Developer Team
   under **Signing & Capabilities**.
3. Keep **Automatically manage signing** enabled.
4. Choose a unique bundle identifier for your own installation.
5. Select an iPhone or iOS Simulator and press **Run**.

The project does not contain signing credentials. Xcode may require you to
replace the bundle identifier with one registered to your developer account.

## Mac Companion

The easiest route is to open GitHub **Releases** and download the matching
Companion ZIP: `arm64` for Apple silicon or `x86_64` for Intel. Setup details:

- [Download and start the Mac Companion](MAC_APP.md)
- [Pair an iPhone with the Mac](MAC_CONNECTION.md)
- [Import finished Mac files on the iPhone](MAC_IMPORT.md)
- [Companion API and security details](COMPANION.md)
- [Converter API](CONVERTER.md)

For local development:

```sh
python3 -m venv .venv-companion
.venv-companion/bin/python -m pip install -r requirements-companion.txt
./start-companion.sh init
./start-companion.sh serve
```

The default library is `~/Music/YouTube`. Use `--root /absolute/path` before
the command to choose another library. The service listens on local HTTPS and
requires explicit pairing before an iPhone can access it.

## YouTube and copyright

The iOS YouTube feature uses the official YouTube Data API and official player
preview. It does not provide a download button. The Companion accepts only
explicitly authorized local files or sources, and the caller must have the
necessary rights. Do not download or import copyrighted material without
permission. See [YouTube and Import](YOUTUBE_IMPORT.md) for the exact behavior.

The legacy `playlist.py` command-line tool remains available. The reusable
conversion implementation is in `converter_core.py`; there is no `convert.py`
or `converter.py` entry point.

## Tests

Python tests use temporary libraries and local test servers. They do not need
real media downloads or a Google API key:

```sh
python3 -m unittest discover -s Tests -p 'test_*.py' -v
python3 Tests/run_mac_connection_tests.py
python3 Tests/run_mac_import_tests.py
python3 Tests/run_youtube_tests.py
python3 Tests/run_swift_regressions.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 Tests/check_localization.py
```

An Xcode build requires a full Xcode installation, not only the Command Line
Tools:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project OfflineMusic.xcodeproj -scheme OfflineMusic \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

See [QUALITY_CHECK.md](QUALITY_CHECK.md) for the latest test scope and the
device-level checks that still require a real iPhone.

## Repository layout

| Path | Purpose |
| --- | --- |
| `OfflineMusic/` | SwiftUI iOS app, audio engine and local library |
| `MacCompanion/` | Packaged macOS Companion build scripts and runtime |
| `companion_*.py` | Local HTTPS service, pairing and security |
| `converter_core.py` | Durable conversion and validation engine |
| `playlist.py` | Legacy interactive converter CLI |
| `Tests/` | Python, Swift and integration tests |
| `.github/workflows/` | GitHub Actions workflow for Companion artifacts/releases |

## Privacy and security

- Music and library metadata remain local unless the user explicitly transfers
  a file to a paired iPhone.
- The Companion uses local HTTPS, certificate pinning and one-time pairing
  secrets.
- Long-lived device tokens are stored in the iOS Keychain and only hashes are
  stored by the Companion.
- No API key, token, certificate private key or personal music file belongs in
  this repository.

## Releases

The workflow **Download Mac Companion** builds Apple-silicon and Intel ZIPs.
Running it manually creates artifacts. Pushing a tag matching
`companion-v*` creates a draft GitHub release for review.

The generated Companion is ad-hoc signed and not Apple-notarized. A normal
public distribution requires the maintainer's own Developer ID certificate and
Apple notarization; no signing credentials are included here.

## License

No open-source license has been selected yet. Until a `LICENSE` file is added,
the repository should be treated as “all rights reserved”. Add a license before
accepting external contributions or redistributing the project.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
Security issues should be reported privately as described in
[SECURITY.md](SECURITY.md).
