"""Out-of-band terminal pairing. QR secrets never enter Bonjour or HTTP logs."""

import io
import json
import shlex
import sys
import threading
import time

from companion_security import digest


def pairing_payload(config, security, name):
    return {**security.pairing(name), "url": config.url, "server_certificate_sha256": config.fingerprint}


def pairing_qrcode(payload):
    import segno
    # Keep the existing JSON protocol; omit only the display name to keep the
    # code small enough for an ordinary terminal. No long-lived bearer token.
    fields = {key: payload[key] for key in ("url", "secret", "expires_at", "server_certificate_sha256")}
    fields["expires_at"] = int(fields["expires_at"])
    return segno.make(json.dumps(fields, separators=(",", ":"), ensure_ascii=True), micro=False, error="m")


def terminal_qr(payload):
    output = io.StringIO()
    pairing_qrcode(payload).terminal(out=output, compact=True, border=4)
    expiry = time.strftime("%H:%M:%S", time.localtime(payload["expires_at"]))
    return ("\nMit iPhone koppeln: Musik-App → Start → Mac-Symbol → QR-Code scannen\n"
            + "\033[97;40m" + output.getvalue() + "\033[0m"
            + f"Server: {payload['url']}\nEinmalig gültig bis {expiry} (5 Minuten).\n"
              "Scanne den Code direkt von deinem Mac und bestätige die Verbindung in der App.\n")


class TerminalPairingDisplay:
    """Refresh until paired, then stop. Activated only by an interactive operator."""
    def __init__(self, config, security, output=None):
        self.config, self.security = config, security
        self.output = output or sys.stdout
        self.stopping = threading.Event()
        self.thread = None
        self.payload = None

    def start(self):
        self.thread = threading.Thread(target=self._run, name="companion-pairing-qr", daemon=True)
        self.thread.start()

    def stop(self):
        self.stopping.set()
        if self.thread:
            self.thread.join(timeout=3)

    def _run(self):
        try:
            # Keep Uvicorn's startup lines outside the scannable terminal block.
            if self.stopping.wait(0.5):
                return
            while not self.stopping.is_set():
                if self.payload is not None:
                    with self.security.jobs._connection() as db:
                        row = db.execute("SELECT used_at FROM companion_pairings WHERE hash=?", (digest(self.payload["secret"]),)).fetchone()
                    if row is not None and row[0] is not None:
                        command = f"./start-companion.sh --root {shlex.quote(str(self.config.root))} pair --name 'Mein iPhone' --qr"
                        self.output.write("\nKopplung erfolgreich. Für ein weiteres Gerät einen neuen QR-Code erzeugen:\n" + command + "\n")
                        self.output.flush()
                        return
                if self.payload is None or time.time() >= self.payload["expires_at"]:
                    self.payload = pairing_payload(self.config, self.security, "Mein iPhone")
                    self.output.write(terminal_qr(self.payload))
                    self.output.flush()
                if self.stopping.wait(2):
                    return
        except Exception:
            # Do not print an exception/locals which could contain the secret.
            self.output.write("\nQR-Anzeige nicht verfügbar. Erzeuge einen neuen Code mit pair --name 'Mein iPhone' --qr.\n")
            self.output.flush()
        finally:
            if self.payload is not None:
                with self.security.jobs._connection() as db:
                    db.execute("UPDATE companion_pairings SET expires_at=MIN(expires_at,?) WHERE hash=? AND used_at IS NULL",
                               (time.time(), digest(self.payload["secret"])))
