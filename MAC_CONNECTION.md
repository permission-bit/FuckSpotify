# Pair the iPhone with the local Mac Companion

The connection uses local HTTPS, a short-lived pairing secret and an exact
certificate fingerprint. See [MAC_IMPORT.md](MAC_IMPORT.md) for automatic file
import and [YOUTUBE_IMPORT.md](YOUTUBE_IMPORT.md) for YouTube/search behavior.

## Start the Companion on the home network

`127.0.0.1` is reachable only from the Mac. For a new LAN instance use a fresh
work directory and replace the example address with the Mac's private IPv4:

```sh
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" init --host 192.168.1.23
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" serve --bonjour
```

Leave the terminal open. `serve --bonjour` displays a QR code automatically.
On the iPhone choose **Home → Mac icon → Scan Mac QR code**, scan the code from
the Mac and confirm. The code is single-use and expires after five minutes.

For an additional device, use a second terminal:

```sh
./start-companion.sh --root "$HOME/Music/OfflineMusicCompanion" pair --name "My iPhone" --qr
```

Never expose the service publicly. Do not use a tunnel, reverse proxy or port
forwarding. Bonjour is discovery only; the URL and certificate fingerprint in
the pairing payload remain authoritative.

## Pair in the iPhone app

1. Open the Mac connection screen from **Home** and allow Local Network access.
2. Choose **Scan Mac QR code** and scan a code directly displayed by your Mac.
3. Compare and confirm the certificate identity, then tap **Connect**.

Manual pairing remains available. Run `pair` without `--qr`, paste the complete
JSON payload into **Paste pairing data**, compare the fingerprint shown on the
Mac and confirm **Secure pairing**. Never accept an unknown fingerprint or use
an accept-all TLS setting.

## Manage the connection

The app retries healthy local connections in the foreground, with backoff up to
60 seconds. Identity and credential errors require an explicit correction.

**Revoke on Mac and remove** revokes the device before deleting its local
Keychain entry. **Remove on this iPhone only** deletes the local entry; revoke
the device on the Mac separately if necessary.

The app stores the endpoint, certificate pin and device token in the Keychain.
Tokens are not placed in URLs, UserDefaults or diagnostic output. Only HTTPS
and private IPv4 addresses are accepted.

## Tests

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python Tests/run_mac_connection_tests.py
```

The test uses URLProtocol mocks, a localhost TLS server, temporary certificates
and a Keychain mock. It does not change personal music, Keychain data or the
real iOS permission dialogs.

