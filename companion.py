#!/usr/bin/env python3
"""Operator CLI. No service starts, pairing happens or login item installs on import."""

import argparse
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from companion_security import CompanionConfig, SecurityError


def main(argv=None):
    parser = argparse.ArgumentParser(description="Private HTTPS Mac companion (no public/wildcard binding)")
    parser.add_argument("--root", type=Path, default=Path.home() / "Music" / "YouTube")
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="Create a private local TLS identity, once")
    init.add_argument("--host", default="127.0.0.1", help="Explicit loopback or private LAN IPv4; never 0.0.0.0")
    init.add_argument("--port", type=int, default=8765)
    pair = commands.add_parser("pair", help="Print a one-time pairing payload; expires after five minutes")
    pair.add_argument("--name", required=True)
    pair.add_argument("--qr", action="store_true", help="Show the one-time pairing code as a QR in this terminal")
    commands.add_parser("devices", help="List paired devices without credentials")
    revoke = commands.add_parser("revoke", help="Revoke a device and cancel its pending/running jobs")
    revoke.add_argument("device_id")
    asset = commands.add_parser("add-file", help="Register an authorized local file for one device; never deletes the source")
    asset.add_argument("--device", required=True)
    asset.add_argument("filename", type=Path)
    submit = commands.add_parser("submit-files", help="Convert authorized local files for one paired device, in the given order")
    submit.add_argument("--device", required=True)
    submit.add_argument("--authorized", required=True, action="store_true")
    submit.add_argument("--quality", default="192K")
    submit.add_argument("--album", default="")
    submit.add_argument("filenames", type=Path, nargs="+")
    serve = commands.add_parser("serve", help="Run one TLS listener and one bounded worker")
    serve.add_argument("--bonjour", action="store_true", help="Optionally advertise via macOS dns-sd; no secrets in TXT")
    serve.add_argument("--no-qr", action="store_true", help="Disable the interactive pairing QR (always disabled in redirected logs)")
    commands.add_parser("launchagent", help="Print an OPTIONAL launchd plist; does not write/install/load it")
    args = parser.parse_args(argv)
    if args.command == "init":
        config = CompanionConfig.initialize(args.root, args.host, args.port)
        print(json.dumps({"url": config.url, "certificate": str(config.cert), "certificate_sha256": config.fingerprint}, indent=2))
        return
    config = CompanionConfig(args.root)
    if args.command == "launchagent":
        payload = {"Label": "local.offlinemusic.companion", "RunAtLoad": True, "KeepAlive": False,
                   "ProgramArguments": [sys.executable, str(Path(__file__).resolve()), "--root", str(config.root), "serve"],
                   "WorkingDirectory": str(Path(__file__).resolve().parent), "ProcessType": "Background",
                   "StandardOutPath": str(config.state / "service.log"), "StandardErrorPath": str(config.state / "service-error.log")}
        sys.stdout.buffer.write(plistlib.dumps(payload))
        return
    from companion_service import CompanionService
    if args.command != "serve":
        service = CompanionService(config, start_worker=False)
        if args.command == "pair":
            if args.qr and (not sys.stdout.isatty() or config.host.startswith("127.")):
                raise ValueError("QR pairing requires an interactive terminal and a configured LAN IPv4")
            from companion_pairing import pairing_payload, terminal_qr
            payload = pairing_payload(config, service.security, args.name)
            print(terminal_qr(payload) if args.qr else json.dumps(payload, indent=2), flush=True)
        elif args.command == "devices":
            print(json.dumps(service.security.devices(), indent=2))
        elif args.command == "revoke":
            service.security.revoke(args.device_id)
            print("Device revoked; active jobs will be cancelled.")
        elif args.command == "add-file":
            print(json.dumps(service.register_asset(args.device, args.filename), indent=2))
        elif args.command == "submit-files":
            from companion_api import JobRequest
            from converter_core import normalize_quality
            if not 1 <= len(args.filenames) <= 100:
                raise ValueError("Provide between 1 and 100 authorized files")
            quality = normalize_quality(args.quality)
            sources = []
            for filename in args.filenames:
                asset = service.register_asset(args.device, filename)
                sources.append({"kind": "asset", "id": asset["asset_id"], "authorized": True,
                                "metadata": {"album": args.album} if args.album else {}})
            job = service.submit(args.device, JobRequest(sources=sources, quality=quality))
            print(json.dumps({"job_id": job["id"], "status": job["status"], "items": len(sources)}, indent=2))
        return
    # Fail closed for expired/mismatched certificates, before accepting requests.
    subprocess.run(["openssl", "x509", "-in", str(config.cert), "-checkend", "0", "-noout"], check=True, stdout=subprocess.DEVNULL)
    import ssl
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config.cert, config.key)
    import uvicorn
    from companion_api import create_app
    discovery = None
    if args.bonjour:
        if not shutil.which("dns-sd") or config.host.startswith("127."):
            raise ValueError("Bonjour requires macOS dns-sd and an explicitly configured LAN address")
        discovery = subprocess.Popen(["dns-sd", "-R", "OfflineMusic Companion", "_offlinemusic._tcp", "local.", str(config.port), "tls=1", "api=1"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Local-only HTTPS: {config.url}\nCertificate SHA-256: {config.fingerprint}", flush=True)
    try:
        app = create_app(config)
        if args.bonjour and not args.no_qr and sys.stdout.isatty():
            from companion_pairing import TerminalPairingDisplay
            app.state.pairing_display = TerminalPairingDisplay(config, app.state.service.security)
        uvicorn.run(app, host=config.host, port=config.port, workers=1,
                    ssl_keyfile=str(config.key), ssl_certfile=str(config.cert),
                    ssl_context_factory=lambda _config, _default_factory: context,
                    proxy_headers=False, forwarded_allow_ips="", access_log=False,
                    server_header=False, ws="none", limit_concurrency=32, timeout_keep_alive=5)
    finally:
        if discovery:
            discovery.terminate()
            discovery.wait(timeout=3)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, SecurityError, subprocess.CalledProcessError) as error:
        print(f"Companion error: {error}", file=sys.stderr)
        raise SystemExit(1)
