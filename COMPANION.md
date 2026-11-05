# Local Mac companion — HTTPS only

The iOS connection/pairing UI is documented in [MAC_CONNECTION.md](MAC_CONNECTION.md).
Automatic import of completed files is documented in [MAC_IMPORT.md](MAC_IMPORT.md).
The native search/preview and authorized local-file import UI is documented in
[YOUTUBE_IMPORT.md](YOUTUBE_IMPORT.md). There is no public server,
port forwarding, firewall change or automatically installed login item.
`playlist.py` remains usable.

## Quick start

Install dependencies in an isolated `.venv-companion`, then initialize and start
the local service:

```sh
python3 -m venv .venv-companion
.venv-companion/bin/python -m pip install -r requirements-companion.txt
./start-companion.sh init
./start-companion.sh serve
```

Stop the service with Ctrl+C. In another terminal, create one-time pairing data:

```sh
./start-companion.sh pair --name "My iPhone"
```

The default setup is reachable only from the Mac. For iPhone access, initialize
once with the Mac's actual private IPv4 address, for example
`init --host 192.168.1.23`. Keep the same `--root` before the subcommand for all
later commands. The iOS app includes the pairing UI and QR scanner. Login
autostart is prepared but not enabled.

## Install and start

Run from this project directory. Dependencies are isolated; no global Python install:

```sh
python3 -m venv .venv-companion
.venv-companion/bin/python -m pip install -r requirements-companion.txt
./start-companion.sh init
./start-companion.sh serve
```

The default library is `~/Music/YouTube` and the default listener is
`https://127.0.0.1:8765`. For a separate library pass `--root /absolute/path` BEFORE
the command on every invocation.

For access from an iPhone, choose the Mac's actual private IPv4 when FIRST initializing:

```sh
./start-companion.sh --root /absolute/path/to/library init --host 192.168.1.23
./start-companion.sh --root /absolute/path/to/library serve
```

Only explicit RFC1918/loopback IPv4 addresses are allowed. Wildcards, public
addresses and IPv6 listeners are rejected. Binding also requires that the chosen
IP belongs to this Mac. Incoming public peer IPs, browser Origins and unexpected
Host headers are rejected. Proxy headers are ignored. Do not put the service
behind a tunnel/reverse proxy or forward its port; a router that masks Internet
clients as local peers cannot be detected reliably by an application alone.

`serve --bonjour` optionally uses the macOS `dns-sd` tool to announce
`_offlinemusic._tcp`. It is discovery only, not proof of identity; the paired URL
and certificate remain authoritative. Manual IP entry works without Bonjour.
Guest Wi-Fi/client isolation can prevent LAN connectivity. No network setting is
changed automatically.

## Pairing, identity and revocation

With `serve --bonjour` in an interactive terminal, a pairing QR appears
automatically. In the iOS app choose **Home → Mac icon → Scan Mac QR code**,
scan the terminal and confirm **Connect**. It carries the existing short-lived
JSON payload (URL, one-time secret, expiry, certificate fingerprint); it contains
no persistent bearer credential. Unused codes refresh after five minutes. The
display stops after successful pairing and invalidates an unused code on shutdown.
`--no-qr` disables this display. It is never automatically enabled in redirected
output or launchd logs. It does not send secrets over Bonjour or add an HTTP route.

For another device, run `pair --name "My iPhone" --qr` in a second interactive
terminal with the same `--root`. Widen the terminal if lines wrap. Plain `pair`
continues to output JSON for manual copying. The QR encoder is the small
[Segno](https://segno.readthedocs.io/en/stable/) package, isolated in the existing venv.

In a SECOND local terminal:

```sh
./start-companion.sh pair --name "My iPhone"
```

This prints JSON with the server URL, the SHA-256 fingerprint of its DER
certificate, and a random 256-bit one-use secret, valid for five minutes.
The iOS app obtains this payload through a trusted local channel (e.g.
scanning the Mac's screen) and verifies the TLS certificate against that fingerprint
BEFORE sending the pairing secret. Never trust a fingerprint fetched from an
unverified network endpoint, never use an accept-all TLS delegate or `curl -k`.

The operator can copy the PUBLIC `.companion/server-cert.pem` to a test client
and use `curl --cacert /trusted/path/server-cert.pem`. Pair over HTTPS:

```text
POST /v1/pair
{"secret":"ONE_TIME_SECRET"}
```

The response contains `device_id` and a 256-bit `token` returned only once.
The iOS app stores it in the Keychain. All other API endpoints require
`Authorization: Bearer TOKEN`. Tokens are durable until revoked; only SHA-256
hashes of tokens and pairing secrets are stored in SQLite. Token/secret values
never belong in URLs or logs. The database/TLS key use 0600, the state directory
0700. The private key never leaves the Mac.

```sh
./start-companion.sh devices
./start-companion.sh revoke DEVICE_UUID
```

Revocation denies subsequent requests and cancels queued/running jobs for that
device. A device can revoke itself with `DELETE /v1/device`. Already-started file
responses may finish; revocation is checked at the start of each request.

The self-signed certificate is valid for one year. Initialization preserves an
existing identity and refuses silent endpoint changes. Before expiry or after a
LAN-IP change, an explicit new identity/pairing setup is required. No system trust
store or profile is installed here. Background URLSession trust handling on iOS
still needs a device prototype; pinning alone does not guarantee background TLS.

## API v1

| Method / path | Purpose |
|---|---|
| `GET /v1/health`, `GET /v1/status` | Authenticated health/status |
| `POST /v1/pair` | Consume a locally issued one-time secret |
| `GET /v1/device`, `DELETE /v1/device` | Current device / revoke itself |
| `POST /v1/jobs` | Create a durable ordered job |
| `GET /v1/jobs?limit=20&offset=0` | This device's job summaries |
| `GET /v1/deliveries?after=0&limit=10` | Durable, device-owned ready-file feed and verified-file manifests |
| `GET /v1/jobs/JOB?limit=100&offset=0` | Ordered item page |
| `GET /v1/jobs/JOB/progress?limit=100&offset=0` | Progress page and whole-job counts |
| `POST /v1/jobs/JOB/cancel` | Persist cancellation request |
| `POST /v1/jobs/JOB/retry` | Retry failed/cancelled/interrupted entries |
| `GET /v1/jobs/JOB/items/ITEM/metadata` | Verified metadata, byte count and SHA-256 |
| `GET, HEAD /v1/jobs/JOB/items/ITEM/file` | Authenticated verified MP3; single Range supported |

Create-body example (only for content with all necessary permissions):

```json
{"quality":"192K","sources":[
  {"kind":"youtube_video","id":"VIDEO_ID_11","authorized":true},
  {"kind":"youtube_playlist","id":"PLAYLIST_ID","authorized":true}
]}
```

Use actual IDs. YouTube IDs retain case. No arbitrary URL, command, output path,
local filename, cookie, DRM option, or FFmpeg argument is accepted. The explicit
authorization assertion is not an automatic rights/YouTube-permission check.
Metadata overrides (`title`, `artist`, `album`, `genre`) are optional per source.
Quality accepts 64–320K supported bitrates and VBR 0–10.

Retry body: `{}` for all failed items, or `{"item_ids":["ITEM_UUID"]}`. A retry
does not change completed entries. `next_offset` paginates items without changing
their original `position`. Per-item errors expose codes, not local paths/stderr.

For offline tests or operator-authorized local sources, register a COPY for a device:

```sh
./start-companion.sh add-file --device DEVICE_UUID /path/to/owned.wav
```

Use its returned opaque `asset_id` in an `asset` source. Only the owning device
can use it. There is deliberately no HTTP route that reads an arbitrary Mac file.
Original source files are not changed/deleted. Copies live in `.companion/assets`.

## Resource limits and recovery

- One active conversion subprocess, two yt-dlp fragments; core/CLI worker locks
  still apply. The event loop never runs FFmpeg.
- Eight queued/running API jobs globally; three per device. Admission, ownership
  and job insertion share one SQLite transaction. Limits also apply to retries.
- Up to 100 requested remote sources or 1000 registered local assets, 1000
  expanded items per job, 128 KiB request body,
  two simultaneous verified downloads, 512 MiB per asset/download.
- Tracks are limited to two hours, and yt-dlp downloads to 512 MiB when the
  source reports its size. These safeguards do not replace available disk space.
- Per-peer rate limit: five pairing attempts/minute and 120 other requests/minute.
- Core timeouts, hashes and full audio validation remain in effect. No download
  is served until completed/reused; missing/corrupt files return 409.
- Files are opened via trusted directory FDs, without following symlinks. Internal
  state and credentials cannot be downloaded through artifact IDs.
- Downloads expose strong ETag, SHA-256 and Content-Digest; clients must verify
  the complete received file. Multipart ranges are rejected.
- SQLite survives restart. Queued API jobs resume; interrupted active jobs require
  explicit retry. Parent-pipe loss cancels the child worker and its descendants.
- Shutdown cancels the active job; queued jobs are retained. Working files remain
  conservatively retained as documented in `CONVERTER.md`.

## Optional macOS login start — NOT activated

```sh
./start-companion.sh launchagent
```

This prints a launchd plist with absolute paths. It writes nothing into
`~/Library/LaunchAgents`, calls no `launchctl`, and enables no login item.
Inspect the output first. Only after a separate explicit decision would you save
it as `~/Library/LaunchAgents/local.offlinemusic.companion.plist` and load it.
The service must run as your normal user, never as root. No automatic pairing
secret is printed by the login-started server.

## Tests

```sh
.venv-companion/bin/python -m pip install -r requirements-companion-test.txt
PYTHONDONTWRITEBYTECODE=1 .venv-companion/bin/python -m unittest discover -s Tests -p 'test_*.py' -v
```

Tests use temporary libraries, simulated conversion jobs, locally generated audio
and a TLS listener on loopback only. No external media download is necessary.
