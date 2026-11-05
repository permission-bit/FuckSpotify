# Quality check

This report summarizes the automated checks recorded for the current feature
set. Tests use temporary libraries, generated test media and local mock/TLS
servers. They do not use personal music, a real Google API key or external
media downloads.

## Recorded results

| Area | Result |
| --- | --- |
| Python service | 48 tests covering authentication, one-time pairing, revocation, device isolation, input/path validation, quotas, durable jobs, progress, cancellation, retries, metadata, artwork, checksums and safe file delivery. |
| Connection | Production Swift client against URLProtocol mocks and a localhost TLS server, including pairing, reconnect, foreground/background transitions, invalid credentials, revocation and Keychain mocks. |
| TLS | Exact certificate pinning, hostname and validity checks; wrong, expired and not-yet-valid certificates are rejected before a pairing secret is sent. |
| Transfer/import | Real HTTPS and `URLSessionDownloadTask` with local MP3 fixtures; single/multi-file import, metadata, artwork, playlists, order, integrity checks and restart recovery. |
| Data migration | Existing SwiftData libraries retain metadata, favorites, genre overrides, playlist IDs, order and manual playlist changes. |
| YouTube/UI logic | Official endpoint mocks, link validation, pagination, metadata, duration, selection order, unavailable entries, API errors and stale/cancelled requests. No real API key is used. |
| Swift regressions | Seven recorded regression checks for catalog/genres, duplicate protection, library transactions, session persistence, smart playlists, playback and native audio APIs. |
| Xcode | The recorded simulator build succeeded without code signing. A current verification requires full Xcode, not only the Command Line Tools. |
| Static checks | Python and shell syntax, project/Info plists and `git diff --check`. |

## Security and resource behavior

- Conversion is limited to a worker subprocess; queue and transfer limits remain
  bounded.
- Hashing and file registration use bounded chunks. Downloads are checked for
  size, ETag, SHA-256, valid audio and complete decoding before publication.
- Existing files are never overwritten or deleted by a failed import.
- Pairing secrets are short-lived and tokens are stored as hashes by the
  Companion; the iOS token is kept in the Keychain.
- Polling and reconnect work follow the app lifecycle. No search or import
  polling continues in the background.

## Device checks still required

The following require a real iPhone and a real home network:

1. First-run Local Network permission, camera QR scanning, Bonjour behavior and
   locked-device Keychain behavior.
2. Wi-Fi changes, Mac sleep, service restart and reconnect with the same
   certificate identity.
3. Real UI interaction, navigation, sheets, Dynamic Type, VoiceOver and dark
   mode.
4. Live YouTube search, API quotas, regional restrictions and official player
   behavior.
5. Lock-screen playback, Control Center, Bluetooth/AirPlay, interruptions,
   crossfade and codec-specific gapless playback.
6. App termination during every transfer and commit phase on a full device.

The Mac import intentionally runs in the foreground. Verified staging files and
import receipts survive restarts, but uninterrupted daemon-style background
transfer is not promised.

## Reproduce the checks

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python -m unittest discover -s Tests -p 'test_*.py' -v
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python Tests/run_mac_connection_tests.py
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python Tests/run_mac_import_tests.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/run_youtube_tests.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/run_swift_regressions.py
```

For an unsigned simulator build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project OfflineMusic.xcodeproj -scheme OfflineMusic \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```
