# YouTube and local import

Open **Home → YouTube & Import**. The screen contains Search, Paste link,
Playlists, Imports and Connection.

## Search and preview

Add your own **YouTube Data API v3** key from the gear button. Enable the API
in your Google Cloud project and restrict the key to that API. The key is stored
in the iOS Keychain, sent in the `x-goog-api-key` header and never sent to the
Mac.

Search is user-triggered and paginated. Video and public playlist results show
title, channel, artwork and available duration. Public video and playlist links
can also be opened without an API key, with limited metadata. Preview uses the
official YouTube player in a WKWebView with visible standard controls.

YouTube results have no import/download action. The Data API does not grant a
general audio-extraction right. The local import screen accepts only files
explicitly shared from the paired Mac.

## Import authorized local files

Restart the Companion after updating it so the current endpoints are available:

```sh
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" serve --bonjour
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" devices
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" add-file \
  --device DEVICE_UUID "/path/Your recording.wav"
```

On the iPhone select **Imports → Select shared Mac files**, choose a bitrate and
destination, and start the job. The app preserves metadata, artwork, source
order and playlist targets. A failed item does not block the others.

## Tests and references

```sh
python3 Tests/run_youtube_tests.py
```

The tests use URLProtocol mocks and never use a real Google key or external
media download. Live search, quota behavior and actual iPhone playback still
require a device test.

Official references: [YouTube Search API](https://developers.google.com/youtube/v3/docs/search/list),
[Playlist Items API](https://developers.google.com/youtube/v3/docs/playlistItems/list),
[YouTube policies](https://www.youtube.com/yt/about/policies/).

