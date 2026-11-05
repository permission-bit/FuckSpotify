"""Bounded companion queue, private asset registration and verified file access."""

import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from companion_security import CompanionStore, DeviceJobStore, SecurityError
from converter_core import Converter, MediaSource

MAX_ASSET_BYTES = 512 * 1024 * 1024
MEDIA_EXTENSIONS = {".mp3", ".m4a", ".mp4", ".wav", ".flac", ".ogg", ".opus", ".webm", ".aac", ".aiff", ".mov"}


class CompanionService:
    def __init__(self, config, start_worker=True):
        self.config = config
        self.converter = Converter(config.root)
        self.security = CompanionStore(self.converter.store)
        self.start_worker = start_worker
        self.stopping = threading.Event()
        self.wakeup = threading.Event()
        self.thread = None
        self.active = None
        self.lock_file = None
        self.download_slots = threading.BoundedSemaphore(2)

    def start(self):
        if not self.start_worker:
            return
        self.lock_file = (self.config.state / "service.lock").open("a")
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock_file.close()
            raise RuntimeError("A companion service is already running for this library")
        self.thread = threading.Thread(target=self._dispatch, daemon=True, name="companion-queue")
        self.thread.start()

    def close(self):
        self.stopping.set()
        self.wakeup.set()
        if self.active:
            self.converter.cancel(self.active)
        if self.thread:
            self.thread.join(timeout=12)
            if self.thread.is_alive():
                raise RuntimeError("Worker did not stop; retaining the service lock until process exit")
        if self.lock_file:
            self.lock_file.close()

    def _dispatch(self):
        while not self.stopping.is_set():
            job_id = self.security.next_job()
            if job_id is None:
                self.wakeup.wait(0.5)
                self.wakeup.clear()
                continue
            self.active = job_id
            # Closing this private stdin pipe (including on parent death) tells
            # the child to cancel, and its process runner terminates FFmpeg too.
            try:
                entry = [sys.executable, "--worker"] if getattr(sys, "frozen", False) else [sys.executable, str(Path(__file__).with_name("companion_worker.py"))]
                with subprocess.Popen([*entry,
                                       "--root", str(self.config.root), "--job", job_id],
                                      stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as process:
                    while process.poll() is None:
                        if self.stopping.wait(0.1):
                            self.converter.cancel(job_id)
                            process.stdin.close()
                            break
                    try:
                        code = process.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        code = process.wait(timeout=3)
                    if not process.stdin.closed:
                        process.stdin.close()
                if code not in (0, 73):
                    self._interrupted(job_id)
                if code == 73:
                    self.stopping.wait(1)  # Existing CLI worker holds the core lock.
            except Exception:
                self._interrupted(job_id)
                self.stopping.wait(1)
            finally:
                self.active = None

    def _interrupted(self, job_id):
        with self.converter.store._connection() as db:
            db.execute("UPDATE items SET status='interrupted' WHERE job_id=? AND status IN ('downloading','converting','validating')", (job_id,))
            db.execute("UPDATE jobs SET status='interrupted',error=? WHERE id=? AND status IN ('queued','running','expanding')",
                       (json.dumps({"code": "worker_interrupted", "message": "Worker stopped unexpectedly"}), job_id))

    def asset_path(self, device_id, asset_id):
        with self.converter.store._connection() as db:
            row = db.execute("SELECT * FROM companion_assets WHERE id=? AND device_id=?", (asset_id, device_id)).fetchone()
        if row is None:
            raise SecurityError(404, "asset_not_found")
        if row["extension"] not in MEDIA_EXTENSIONS:
            raise SecurityError(409, "asset_unavailable")
        path = self.config.state / "assets" / (row["id"] + row["extension"])
        if path.is_symlink() or not path.is_file():
            raise SecurityError(409, "asset_unavailable")
        return path, row["title"]

    def register_asset(self, device_id, filename):
        # Operator-only Python/CLI method. No HTTP route accepts a local path.
        if not any(d["id"] == device_id and d["revoked_at"] is None for d in self.security.devices()):
            raise ValueError("Unknown/revoked device")
        source = Path(filename).expanduser().resolve(strict=True)
        before = source.stat()
        if not source.is_file() or source.suffix.lower() not in MEDIA_EXTENSIONS or not 0 < before.st_size <= MAX_ASSET_BYTES:
            raise ValueError("Unsupported/oversized local media")
        folder = self.config.state / "assets"
        folder.mkdir(exist_ok=True, mode=0o700)
        asset_id = str(uuid.uuid4())
        extension = source.suffix.lower()
        destination = folder / (asset_id + extension)
        digest = hashlib.sha256()
        size = 0
        created = False
        try:
            with source.open("rb") as incoming:
                descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                created = True
                with os.fdopen(descriptor, "wb") as outgoing:
                    for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
                        size += len(chunk)
                        if size > MAX_ASSET_BYTES:
                            raise ValueError("Local media exceeds the size limit")
                        digest.update(chunk)
                        outgoing.write(chunk)
                    outgoing.flush()
                    os.fsync(outgoing.fileno())
            after = source.stat()
            if size != before.st_size or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise ValueError("Local media changed during registration")
            # Publish in the source list only after the complete copy is durable.
            with self.converter.store._connection() as db:
                db.execute("INSERT INTO companion_assets(id,device_id,extension,title,sha256) VALUES(?,?,?,?,?)",
                           (asset_id, device_id, extension, source.stem[:200], digest.hexdigest()))
        except BaseException:
            # Only our exclusively created, unregistered copy; never the source
            # or any previously registered media, including after ENOSPC.
            if created:
                destination.unlink(missing_ok=True)
            raise
        return {"asset_id": asset_id, "title": source.stem[:200], "size": size, "sha256": digest.hexdigest()}

    def submit(self, device_id, request):
        sources = []
        for entry in request.sources:
            if entry.kind == "asset":
                path, title = self.asset_path(device_id, entry.id)
                sources.append(MediaSource(str(path), "file", authorized=True, metadata=entry.metadata, fallback_title=title))
            else:
                url = f"https://www.youtube.com/watch?v={entry.id}" if entry.kind == "youtube_video" else f"https://www.youtube.com/playlist?list={entry.id}"
                sources.append(MediaSource(url, "video" if entry.kind == "youtube_video" else "playlist", authorized=True, metadata=entry.metadata))
        converter = Converter(self.config.root, store=DeviceJobStore(self.security, device_id, request.request_id))
        job = converter.submit(sources, quality=request.quality)
        self.wakeup.set()
        return job

    def assets(self, device_id, limit, offset):
        with self.converter.store._connection() as db:
            rows = db.execute("SELECT id,title,extension FROM companion_assets WHERE device_id=? ORDER BY rowid LIMIT ? OFFSET ?", (device_id, limit, offset)).fetchall()
        result = []
        for row in rows:
            size, available = None, False
            try:
                path, _ = self.asset_path(device_id, row["id"])
                size = path.stat().st_size
                available = 0 < size <= MAX_ASSET_BYTES
            except (SecurityError, OSError):
                pass
            result.append({"id": row["id"], "title": row["title"], "format": row["extension"].lstrip(".").upper(),
                           "size": size, "available": available, "can_import": available})
        return result

    @staticmethod
    def public_job(job):
        result = {key: job[key] for key in ("id", "status", "created_at", "updated_at", "counts")}
        result["quality"] = job["spec"]["quality"]
        result["request_id"] = job["spec"].get("client_request_id")
        sources = job["spec"].get("sources") or []
        result["title"] = job["spec"].get("album") or next((source.get("metadata", {}).get("album") for source in sources if source.get("metadata", {}).get("album")), None)
        if not result["title"]:
            first = sources[0].get("fallback_title") if sources else None
            result["title"] = (first + (f" + {len(sources) - 1}" if len(sources) > 1 else "")) if first else "Musikimport"
        for key in ("total_items", "offset", "next_offset"):
            if key in job:
                result[key] = job[key]
        result["error"] = {"code": job["error"]["code"]} if job["error"] else None
        result["items"] = []
        for item in job["items"]:
            source = item["source"]
            parsed = urlparse(source["url"])
            source_id = Path(source["url"]).stem if source["kind"] == "file" else parse_qs(parsed.query).get("v", parse_qs(parsed.query).get("list", [None]))[0]
            entry = {key: item[key] for key in ("id", "position", "status", "attempts", "progress")}
            entry.update({"source": {"kind": "asset" if source["kind"] == "file" else source["kind"], "id": source_id},
                          "title": item["metadata"].get("title") or source.get("metadata", {}).get("title") or source.get("fallback_title"), "playlist_index": item["metadata"].get("playlist_index"),
                          "playlist_title": item["metadata"].get("playlist_title"),
                          "error": {"code": item["error"]["code"]} if item["error"] else None})
            if item["status"] in {"completed", "reused"} and item["result"]:
                entry["result"] = CompanionService.public_result(item["result"])
                entry["download_url"] = f"/v1/jobs/{job['id']}/items/{item['id']}/file"
            result["items"].append(entry)
        return result

    @staticmethod
    def public_result(result):
        public = {key: result[key] for key in ("format", "duration", "size", "sha256", "quality", "cover_embedded") if key in result}
        public["metadata"] = {key.lower(): str(value) for key, value in result.get("metadata", {}).items() if key.lower() in {"title", "artist", "album", "album_artist", "track", "genre", "date"}}
        return public

    def verified_file(self, device_id, job_id, item_id):
        self.security.owns(device_id, job_id)
        item = self.converter.store.item(job_id, item_id)
        if item is None:
            raise SecurityError(404, "item_not_found")
        if item["status"] not in {"completed", "reused"} or not item["result"]:
            raise SecurityError(409, "file_not_ready")
        result = item["result"]
        if not self.download_slots.acquire(blocking=False):
            raise SecurityError(429, "download_limit")
        stream = None
        try:
            # Open each component relative to a trusted directory FD. Symlinks,
            # internal state files and path replacement cannot escape the root.
            path = Path(result["path"])
            relative = path.relative_to(self.config.root)
            if not relative.parts or any(part.startswith(".") or part in {"..", ""} for part in relative.parts) or path.suffix.lower() != ".mp3":
                raise ValueError("Invalid artifact path")
            directory = os.open(self.config.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                for part in relative.parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    os.close(directory)
                    directory = child
                descriptor = os.open(relative.parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            finally:
                os.close(directory)
            stream = os.fdopen(descriptor, "rb")
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size != result["size"] or not 0 < info.st_size <= MAX_ASSET_BYTES:
                raise ValueError("Invalid artifact size/type")
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
            after = os.fstat(stream.fileno())
            if digest.hexdigest() != result["sha256"] or (after.st_mtime_ns, after.st_size) != (info.st_mtime_ns, info.st_size):
                raise ValueError("Artifact no longer matches its checksum")
            stream.seek(0)
            return VerifiedFile(stream, result, path.name, self.download_slots)
        except Exception as error:
            if stream:
                stream.close()
            self.download_slots.release()
            if isinstance(error, SecurityError):
                raise
            raise SecurityError(409, "file_missing_or_changed") from error


class VerifiedFile:
    def __init__(self, stream, result, name, slots):
        self.stream, self.result, self.name, self.slots = stream, result, name, slots
        self.closed = False
        self.lock = threading.Lock()

    def close(self):
        with self.lock:
            if not self.closed:
                self.closed = True
                self.stream.close()
                self.slots.release()

    def chunks(self, start=0, length=None):
        try:
            self.stream.seek(start)
            remaining = self.result["size"] if length is None else length
            while remaining > 0:
                chunk = self.stream.read(min(65536, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk
        finally:
            self.close()
