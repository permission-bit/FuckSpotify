# Connect the iPhone to the Mac without a terminal

## Download and start

1. Open GitHub **Releases** and download the Companion ZIP. Choose `arm64` for
   Apple silicon (M1 or later) or `x86_64` for Intel. The minimum is macOS 14.
2. Unzip it, move **OfflineMusic Companion.app** to Applications and open it.
   Python, FFmpeg and FFprobe are bundled in the package.
3. Click **Start Mac service**. The app suggests the Mac's private IP. Existing
   certificates, data and configuration are preserved.
4. On the iPhone open **Home → Mac icon → Scan Mac QR code**, scan the code in
   the Mac window and confirm the certificate identity.
5. On the Mac refresh the device list, select the iPhone and choose authorized
   audio files. On the iPhone open **YouTube & Import → Imports** and choose the
   quality and playlist destination.

The Companion must remain open while it is needed. Stopping it keeps music and
pairings. QR codes expire after five minutes. The connection uses HTTPS and
certificate pinning; an IP change is never silently accepted.

## Permissions and network

- Allow the Companion on macOS under **Privacy & Security → Local Network** if
  macOS asks for permission.
- Allow incoming connections if the macOS firewall asks. The app does not turn
  off the firewall or create router rules.
- Allow **Local Network** and **Camera** access for OfflineMusic on the iPhone.
- Keep both devices on the same reachable Wi-Fi. Guest networks and VPNs may
  isolate them. Do not use port forwarding, a public server or a tunnel.

## GitHub releases

The **Download Mac Companion** workflow builds both architectures. A manual run
creates downloadable artifacts. A tag matching `companion-v*` creates a draft
release; review it before publishing.

The package is ad-hoc signed and not Apple-notarized. Gatekeeper may require
**Privacy & Security → Open Anyway** after verifying the source. A normal public
distribution needs the maintainer's own Developer ID certificate and Apple
notarization. No signing credentials are stored in this repository.

For a local build, install the requirements in `requirements-mac-build.txt` and
run `python MacCompanion/build.py`. FFmpeg, FFprobe, OpenSSL and Xcode are
required.

