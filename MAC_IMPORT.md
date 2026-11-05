# Import finished Mac files on the iPhone

After updating both the iOS app and the Companion, open **Home → Mac icon →
Music from Mac**. The app can fetch finished files while it is in the
foreground and shows progress per item: imported, already present, pending,
failed or unavailable on the Mac.

An import can target the library, a new playlist per job or an existing regular
playlist. One song goes to the library by default. Multiple songs keep the
original job order. An unavailable item does not block the remaining items.
Existing playlist membership is not duplicated or silently reordered.

## Register local files

Use only files you own or are authorized to process. In a second terminal,
find the paired device:

```sh
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" devices
```

Register two files in order:

```sh
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" submit-files \
  --device DEVICE_UUID --authorized --quality 192K \
  "/path/01 Recording.mp3" "/path/02 Recording.mp3"
```

Metadata and embedded artwork are preserved when available. The Mac copies the
source into its private work area; originals are never changed or deleted.

On the iPhone choose **YouTube & Import → Imports → Select shared Mac files**,
choose a quality and destination, then start the import. Failed items can be
retried individually. The completed-file feed is authenticated, hash-checked
and idempotent, so repeating a request does not create duplicate songs or
playlists.

## Foreground and recovery limits

Downloads use the existing HTTPS client and verified staging. Size, ETag,
SHA-256, audio format, duration and full decode are checked before a file is
published to the library. Import receipts survive app restarts. If the app
enters the background, the operation pauses and is resumed or retried on the
next foreground launch; continuous daemon-style background transfer is not
promised.

## Tests

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python Tests/run_mac_import_tests.py
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python Tests/run_mac_connection_tests.py
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python -m unittest discover -s Tests -p 'test_*.py' -v
```

