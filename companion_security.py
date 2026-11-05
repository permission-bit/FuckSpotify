"""Local-only configuration, TLS identity and hashed device credentials."""

import hashlib
import ipaddress
import json
import os
import secrets
import shutil
import ssl
import subprocess
import time
import uuid
from pathlib import Path

from job_store import JobStore

PRIVATE_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8"))
ACTIVE = ("queued", "running", "expanding")


def local_address(value):
    try:
        ip = ipaddress.ip_address(value)
        return isinstance(ip, ipaddress.IPv4Address) and any(ip in network for network in PRIVATE_NETWORKS)
    except ValueError:
        return False


def digest(secret):
    return hashlib.sha256(secret.encode()).hexdigest()


def private_write(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(data)


class CompanionConfig:
    def __init__(self, root):
        self.root = Path(root).expanduser().resolve()
        self.state = self.root / ".companion"
        self.cert = self.state / "server-cert.pem"
        self.key = self.state / "server-key.pem"
        data = json.loads((self.state / "config.json").read_text())
        self.host, self.port = data["host"], data["port"]
        if not local_address(self.host) or not isinstance(self.port, int) or not 1024 <= self.port <= 65535:
            raise ValueError("Invalid local listen address/port")
        self.fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(self.cert.read_text())).hexdigest()
        if self.key.stat().st_mode & 0o077 or self.state.stat().st_mode & 0o077:
            raise ValueError("TLS key and companion directory must have private permissions (600/700)")

    @property
    def url(self):
        return f"https://{self.host}:{self.port}"

    @classmethod
    def initialize(cls, root, host="127.0.0.1", port=8765):
        if not local_address(host) or not isinstance(port, int) or not 1024 <= port <= 65535:
            raise ValueError("Choose loopback or an explicit RFC1918 IPv4 address; wildcards/public IPs are forbidden")
        root = Path(root).expanduser().resolve()
        state = root / ".companion"
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        config_file = state / "config.json"
        if config_file.exists():
            config = cls(root)
            if (config.host, config.port) != (host, port):
                raise ValueError("Existing identity/configuration preserved; do not silently change the paired endpoint")
            return config
        cert, key = state / "server-cert.pem", state / "server-key.pem"
        if cert.exists() or key.exists():
            raise ValueError("Partial TLS initialization exists; inspect it locally before trying again")
        if not shutil.which("openssl"):
            raise ValueError("OpenSSL is required to generate the local TLS identity")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes", "-days", "365",
                        "-subj", "/CN=OfflineMusic Companion", "-addext", f"subjectAltName=IP:{host},IP:127.0.0.1,DNS:localhost",
                        "-addext", "extendedKeyUsage=serverAuth", "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                        "-addext", "basicConstraints=critical,CA:FALSE",
                        "-keyout", str(key), "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key.chmod(0o600)
        cert.chmod(0o600)
        private_write(config_file, json.dumps({"version": 1, "host": host, "port": port}).encode())
        return cls(root)


class SecurityError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code
        super().__init__(code)


class CompanionStore:
    """Shares the core SQLite DB so auth, ownership and admission are atomic."""
    def __init__(self, jobs):
        self.jobs = jobs
        with jobs._connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS companion_pairings (
                    hash TEXT PRIMARY KEY, name TEXT NOT NULL, expires_at REAL NOT NULL, used_at REAL
                );
                CREATE TABLE IF NOT EXISTS companion_devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT UNIQUE NOT NULL,
                    created_at REAL NOT NULL, revoked_at REAL
                );
                CREATE TABLE IF NOT EXISTS companion_jobs (
                    job_id TEXT PRIMARY KEY REFERENCES jobs(id), device_id TEXT NOT NULL REFERENCES companion_devices(id)
                );
                CREATE INDEX IF NOT EXISTS companion_jobs_owner ON companion_jobs(device_id, job_id);
                CREATE TABLE IF NOT EXISTS companion_requests (
                    device_id TEXT NOT NULL REFERENCES companion_devices(id),
                    request_id TEXT NOT NULL, spec_hash TEXT NOT NULL,
                    job_id TEXT NOT NULL REFERENCES jobs(id), PRIMARY KEY(device_id,request_id)
                );
                CREATE TABLE IF NOT EXISTS companion_assets (
                    id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES companion_devices(id),
                    extension TEXT NOT NULL, title TEXT NOT NULL, sha256 TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS companion_deliveries (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL REFERENCES jobs(id),
                    item_id TEXT NOT NULL UNIQUE REFERENCES items(id)
                );
                CREATE TRIGGER IF NOT EXISTS companion_ready_delivery AFTER UPDATE OF status,result ON items
                WHEN NEW.status IN ('completed','reused') AND NEW.result IS NOT NULL
                  AND EXISTS(SELECT 1 FROM companion_jobs WHERE job_id=NEW.job_id)
                  AND (OLD.status NOT IN ('completed','reused') OR OLD.result IS NOT NEW.result)
                BEGIN
                    INSERT OR REPLACE INTO companion_deliveries(job_id,item_id) VALUES(NEW.job_id,NEW.id);
                END;
                INSERT OR IGNORE INTO companion_deliveries(job_id,item_id)
                    SELECT items.job_id,items.id FROM items JOIN companion_jobs ON companion_jobs.job_id=items.job_id
                    WHERE items.status IN ('completed','reused') AND items.result IS NOT NULL
                    ORDER BY items.updated_at,items.position;
            """)

    def pairing(self, name, seconds=300):
        if not name.strip() or len(name) > 64 or not 1 <= seconds <= 600:
            raise ValueError("Invalid pairing name/lifetime")
        secret = secrets.token_urlsafe(32)
        expiry = time.time() + seconds
        with self.jobs._connection() as db:
            db.execute("INSERT INTO companion_pairings(hash,name,expires_at) VALUES(?,?,?)", (digest(secret), name, expiry))
        return {"secret": secret, "expires_at": expiry, "name": name}

    def pair(self, secret):
        with self.jobs._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM companion_pairings WHERE hash=? AND used_at IS NULL AND expires_at>?", (digest(secret), time.time())).fetchone()
            if row is None:
                raise SecurityError(401, "invalid_or_expired_pairing")
            device_id = str(uuid.uuid4())
            token = "omc_" + secrets.token_urlsafe(32)
            db.execute("UPDATE companion_pairings SET used_at=? WHERE hash=?", (time.time(), row["hash"]))
            db.execute("INSERT INTO companion_devices(id,name,token_hash,created_at) VALUES(?,?,?,?)",
                       (device_id, row["name"], digest(token), time.time()))
        return {"device_id": device_id, "name": row["name"], "token": token, "token_type": "Bearer"}

    def authenticate(self, token):
        if not token or len(token) > 256:
            raise SecurityError(401, "authentication_required")
        with self.jobs._connection() as db:
            row = db.execute("SELECT id,name FROM companion_devices WHERE token_hash=? AND revoked_at IS NULL", (digest(token),)).fetchone()
        if row is None:
            raise SecurityError(401, "invalid_or_revoked_token")
        return dict(row)

    def devices(self):
        with self.jobs._connection() as db:
            return [dict(row) for row in db.execute("SELECT id,name,created_at,revoked_at FROM companion_devices ORDER BY created_at")]

    def revoke(self, device_id):
        with self.jobs._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM companion_devices WHERE id=?", (device_id,)).fetchone() is None:
                raise SecurityError(404, "device_not_found")
            db.execute("UPDATE companion_devices SET revoked_at=? WHERE id=?", (time.time(), device_id))
            ids = [row[0] for row in db.execute("SELECT jobs.id FROM jobs JOIN companion_jobs ON job_id=jobs.id WHERE device_id=? AND status IN ('queued','running','expanding')", (device_id,))]
            for job_id in ids:
                db.execute("UPDATE jobs SET cancel_requested=1,updated_at=? WHERE id=?", (time.time(), job_id))
                db.execute("UPDATE items SET status='cancelled' WHERE job_id=? AND status='pending'", (job_id,))
                db.execute("UPDATE jobs SET status='cancelled' WHERE id=? AND status='queued'", (job_id,))

    def owns(self, device_id, job_id):
        with self.jobs._connection() as db:
            row = db.execute("SELECT 1 FROM companion_jobs WHERE device_id=? AND job_id=?", (device_id, job_id)).fetchone()
        if row is None:
            raise SecurityError(404, "job_not_found")

    @staticmethod
    def _admit(db, device_id):
        if db.execute("SELECT 1 FROM companion_devices WHERE id=? AND revoked_at IS NULL", (device_id,)).fetchone() is None:
            raise SecurityError(401, "invalid_or_revoked_token")
        rows = db.execute("SELECT companion_jobs.device_id FROM companion_jobs JOIN jobs ON jobs.id=job_id WHERE jobs.status IN ('queued','running','expanding')").fetchall()
        if len(rows) >= 8 or sum(row[0] == device_id for row in rows) >= 3:
            raise SecurityError(429, "job_queue_full")

    def create_job(self, device_id, spec):
        with self.jobs._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            request_id = spec.get("client_request_id")
            spec_hash = hashlib.sha256(json.dumps(spec, sort_keys=True, allow_nan=False).encode()).hexdigest()
            if request_id:
                if db.execute("SELECT 1 FROM companion_devices WHERE id=? AND revoked_at IS NULL", (device_id,)).fetchone() is None:
                    raise SecurityError(401, "invalid_or_revoked_token")
                previous = db.execute("SELECT job_id,spec_hash FROM companion_requests WHERE device_id=? AND request_id=?", (device_id, request_id)).fetchone()
                if previous:
                    if previous["spec_hash"] != spec_hash:
                        raise SecurityError(409, "request_id_conflict")
                    return self.jobs.get(previous["job_id"])
            self._admit(db, device_id)
            job_id = JobStore.insert_job(db, spec)
            db.execute("INSERT INTO companion_jobs(job_id,device_id) VALUES(?,?)", (job_id, device_id))
            if request_id:
                db.execute("INSERT INTO companion_requests(device_id,request_id,spec_hash,job_id) VALUES(?,?,?,?)", (device_id, request_id, spec_hash, job_id))
        return self.jobs.get(job_id)

    def retry(self, device_id, job_id, item_ids):
        with self.jobs._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM companion_jobs WHERE device_id=? AND job_id=?", (device_id, job_id)).fetchone() is None:
                raise SecurityError(404, "job_not_found")
            status = db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()[0]
            if status not in {"partial", "failed", "cancelled", "interrupted"}:
                raise SecurityError(409, "job_not_retryable")
            self._admit(db, device_id)
            rows = db.execute("SELECT id,status FROM items WHERE job_id=?", (job_id,)).fetchall()
            if item_ids is not None and not set(item_ids) <= {row[0] for row in rows}:
                raise SecurityError(404, "item_not_found")
            selected = [row[0] for row in rows if row[1] in {"failed", "cancelled", "interrupted", "unavailable"} and (item_ids is None or row[0] in item_ids)]
            if not selected:
                raise SecurityError(409, "no_retryable_items")
            for item_id in selected:
                db.execute("UPDATE items SET status='pending',error=NULL,progress='{}',updated_at=? WHERE id=?", (time.time(), item_id))
            db.execute("UPDATE jobs SET status='queued',cancel_requested=0,error=NULL,updated_at=? WHERE id=?", (time.time(), job_id))

    def owned_ids(self, device_id, limit=20, offset=0):
        with self.jobs._connection() as db:
            return [row[0] for row in db.execute("SELECT jobs.id FROM jobs JOIN companion_jobs ON jobs.id=job_id WHERE device_id=? ORDER BY created_at DESC LIMIT ? OFFSET ?", (device_id, limit, offset))]

    def deliveries(self, device_id, after, limit):
        with self.jobs._connection() as db:
            return [dict(row) for row in db.execute(
                "SELECT sequence,companion_deliveries.job_id,item_id FROM companion_deliveries "
                "JOIN companion_jobs ON companion_jobs.job_id=companion_deliveries.job_id "
                "WHERE companion_jobs.device_id=? AND sequence>? ORDER BY sequence LIMIT ?", (device_id, after, limit))]

    def next_job(self):
        with self.jobs._connection() as db:
            row = db.execute("SELECT jobs.id FROM jobs JOIN companion_jobs ON jobs.id=job_id JOIN companion_devices ON companion_devices.id=device_id WHERE jobs.status='queued' AND companion_devices.revoked_at IS NULL ORDER BY jobs.created_at LIMIT 1").fetchone()
        return row[0] if row else None


class DeviceJobStore(JobStore):
    def __init__(self, security, device_id, request_id=None):
        self.path = security.jobs.path
        self.security, self.device_id = security, device_id
        self.request_id = request_id

    def create(self, spec):
        if self.request_id:
            spec = {**spec, "client_request_id": str(self.request_id)}
        return self.security.create_job(self.device_id, spec)
