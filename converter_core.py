"""Programmatic conversion API; no terminal prompts and no network server.

    converter = Converter('/path/to/music')
    job = converter.submit([MediaSource('/path/to/owned.wav', 'file', authorized=True)], quality='192K')
    result = converter.run(job['id'], on_progress=print)

Authorization is an explicit caller assertion, not automatic legal verification.
"""

import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

from conversion_worker import Cancelled, ConversionError, ConversionWorker, file_hash
from job_store import JobStore


def clean_name(value):
    return re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", str(value)).strip(" .")


def valid_url(value):
    try:
        parsed = urlparse(value)
        host = (parsed.hostname or "").lower()
        return parsed.scheme in ("http", "https") and not parsed.username and not parsed.password and (
            host in ("youtube.com", "youtu.be") or host.endswith(".youtube.com"))
    except (ValueError, TypeError):
        return False


def missing_dependencies():
    return [name for name in ("yt-dlp", "ffmpeg", "ffprobe") if not shutil.which(name)]


def normalize_quality(value):
    value = str(value).strip().upper()
    if value in {str(number) for number in range(11)}:
        return value
    if value.rstrip("K") in {"64", "96", "128", "160", "192", "224", "256", "320"}:
        return value.rstrip("K") + "K"
    raise ValueError("Use MP3 bitrate 64–320K or VBR quality 0–10")


def metadata_options(artist="", album="", playlist=False, *, title="", genre="", playlist_title="", playlist_index=None):
    """FFmpeg argument list; literal metadata cannot become command options."""
    values = {"title": title, "artist": artist, "album_artist": artist,
              "album": album or (playlist_title if playlist else ""), "genre": genre}
    if playlist and playlist_index is not None:
        values["track"] = str(playlist_index)
    return [part for key, value in values.items() if value not in (None, "") for part in ("-metadata", f"{key}={value}")]


@dataclass(frozen=True)
class MediaSource:
    url: str
    kind: str = "video"  # video / playlist / file / direct
    authorized: bool = False
    metadata: dict = field(default_factory=dict)
    cover_path: str | None = None
    fallback_title: str | None = None

    def normalized(self):
        if self.authorized is not True:
            raise ValueError("Each source requires explicit authorization")
        if self.kind not in {"video", "playlist", "file", "direct"}:
            raise ValueError("Unsupported source kind")
        value = str(self.url).strip()
        if not value or any(ord(character) < 32 for character in value):
            raise ValueError("Invalid media source")
        if self.kind in {"video", "playlist"} and not valid_url(value):
            raise ValueError("Expected a valid YouTube URL")
        if self.kind == "file":
            value = str(Path(value).expanduser().resolve())
            if not Path(value).is_file():
                raise ValueError("Source file does not exist")
        if self.kind == "direct":
            parsed = urlparse(value)
            if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                raise ValueError("Direct media must use an HTTPS URL without credentials")
            if Path(parsed.path).suffix.lower() not in {".mp3", ".m4a", ".mp4", ".wav", ".flac", ".ogg", ".opus", ".webm", ".aac", ".aiff", ".mov"}:
                raise ValueError("Expected a direct audio/video file, not a streaming manifest")
        metadata = dict(self.metadata)
        if not set(metadata) <= {"title", "artist", "album", "genre"} or any(not isinstance(v, str) or "\x00" in v for v in metadata.values()):
            raise ValueError("Unsupported or invalid metadata")
        cover = str(Path(self.cover_path).expanduser().resolve()) if self.cover_path else None
        if cover and self.kind not in {"file", "direct"}:
            raise ValueError("Explicit cover files are supported for local/direct sources only")
        if cover and not Path(cover).is_file():
            raise ValueError("Cover file does not exist")
        fallback_title = str(self.fallback_title or "")[:500]
        return {"url": value, "kind": self.kind, "authorized": True, "metadata": metadata, "cover_path": cover,
                "fallback_title": fallback_title}


class Converter:
    def __init__(self, output_dir, *, store=None, worker=None):
        self.output_dir = Path(output_dir).expanduser().resolve()
        self.state_dir = self.output_dir / ".converter"
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.store = store or JobStore(self.state_dir / "jobs.sqlite3")
        self.worker = worker or ConversionWorker()
        try:
            with self._exclusive_worker():
                self.store.recover_interrupted()
        except ConversionError as error:
            if error.code != "worker_busy":
                raise

    @contextmanager
    def _exclusive_worker(self):
        # A lock shared by every worker using this store; cancel/status remain usable.
        with self.store.path.with_suffix(".worker.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ConversionError("worker_busy", "Another conversion worker is active") from error
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def submit(self, sources, *, quality="320K", artist="", album="", output_template=None):
        if isinstance(sources, (MediaSource, dict)):
            sources = [sources]
        normalized = [(source if isinstance(source, MediaSource) else MediaSource(**source)).normalized() for source in sources]
        if not normalized:
            raise ValueError("A job needs at least one source")
        if any(not isinstance(value, str) or "\x00" in value for value in (artist, album)):
            raise ValueError("Invalid artist/album override")
        template = str(output_template) if output_template else None
        if template:
            self._output_path(template, {"title": "test", "id": "test", "playlist_title": "test", "playlist_index": 1})
        spec = {"sources": normalized, "quality": normalize_quality(quality), "artist": artist, "album": album,
                "output_template": template}
        job = self.store.create(spec)
        return self.store.get(job["id"])

    def get_job(self, job_id):
        return self.store.get(job_id)

    def cancel(self, job_id):
        self.store.request_cancel(job_id)
        return self.get_job(job_id)

    def retry(self, job_id, item_ids=None):
        with self._exclusive_worker():
            self.store.recover_interrupted()
            return self.store.retry(job_id, item_ids)

    @staticmethod
    def _emit(callback, job_id, item_id=None, **payload):
        if callback:
            # UI/logging failures must not turn a verified conversion into a failure.
            try:
                callback({"job_id": job_id, "item_id": item_id, **payload})
            except Exception:
                pass

    def run(self, job_id, on_progress=None):
        with self._exclusive_worker():
            self.store.recover_interrupted()
            job = self.get_job(job_id)
            if job["status"] != "queued":
                return job
            cancelled = lambda: self.store.cancelled(job_id)
            self.store.update_job(job_id, "running")
            try:
                while True:
                    if cancelled():
                        raise Cancelled()
                    item = self.store.next_pending(job_id)
                    if item is None:
                        break
                    self._run_item(job, item, cancelled, on_progress)
                statuses = self.store.item_statuses(job_id)
                successful = bool(statuses & {"completed", "reused", "skipped"})
                failed = bool(statuses - {"completed", "reused", "skipped"})
                self.store.update_job(job_id, "partial" if failed and successful else "failed" if failed else "completed")
            except (Cancelled, KeyboardInterrupt) as error:
                self.store.request_cancel(job_id)
                for item in self.get_job(job_id)["items"]:
                    if item["status"] in {"pending", "downloading", "converting", "validating"}:
                        self.store.update_item(item["id"], status="cancelled", error=Cancelled().as_dict())
                self.store.update_job(job_id, "cancelled")
                if isinstance(error, KeyboardInterrupt):
                    raise
            except BaseException as error:
                self.store.update_job(job_id, "interrupted", {"code": "worker_interrupted", "message": str(error)})
                raise
            result = self.get_job(job_id)
            self._emit(on_progress, job_id, status=result["status"], counts=result["counts"])
            return result

    def _run_item(self, job, item, cancelled, callback):
        item_id, job_id = item["id"], job["id"]
        self.store.update_item(item_id, status="downloading", attempts=item["attempts"] + 1, error=None)
        last_progress = 0.0
        def progress(event):
            nonlocal last_progress
            if cancelled():
                raise Cancelled()
            # Persist at most twice a second, plus phase changes and final events.
            phase = event["phase"]
            now = time.monotonic()
            if now - last_progress >= 0.5 or phase != progress.phase:
                status = "downloading" if phase in {"downloading", "expanding"} else phase
                self.store.update_item(item_id, status=status, progress=event)
                last_progress = now
                progress.phase = phase
            self._emit(callback, job_id, item_id, **event)
        progress.phase = None
        try:
            source = MediaSource(**item["source"]).normalized()
            progress({"phase": "expanding" if source["kind"] == "playlist" else "downloading", "fraction": None})
            info = self.worker.discover(source, cancelled)
            if source["kind"] == "playlist":
                entries = self._playlist_entries(source, info)
                self.store.expand_item(item_id, entries)
                return
            if info.get("_type") in {"playlist", "multi_video"} or "entries" in info:
                raise ConversionError("unexpected_playlist", "This item is not an accessible single video")
            if info.get("has_drm") or info.get("is_live") or info.get("live_status") in {"is_live", "is_upcoming"}:
                raise ConversionError("unsupported_media", "Protected or unfinished live media is not supported")
            metadata = {**item["metadata"], **{key: info[key] for key in ("id", "title", "artist", "album", "duration") if info.get(key) is not None}}
            metadata.update(source.get("metadata", {}))
            metadata["artist"] = job["spec"]["artist"] or metadata.get("artist", "")
            metadata["album"] = job["spec"]["album"] or metadata.get("album") or metadata.get("playlist_title", "")
            if not metadata.get("title"):
                metadata["title"] = "Audio"
            metadata["id"] = str(info.get("id") or source["url"])
            expected = float(metadata["duration"]) if metadata.get("duration") is not None else None
            if expected is None or not math.isfinite(expected) or expected <= 0:
                raise ConversionError("invalid_duration", "Invalid source duration")
            metadata["duration"] = expected
            identity = {"kind": source["kind"], "id": metadata["id"], "duration": expected, "quality": job["spec"]["quality"],
                        "tags": {key: metadata.get(key) for key in ("title", "artist", "album", "genre", "playlist_index")}, "version": 1}
            if source["kind"] == "direct":
                # An arbitrary URL may serve different bytes tomorrow. Only reuse
                # its verified result within the same item/recovery attempt.
                identity["direct_request"] = item_id
            if source["kind"] == "file":
                identity["source_sha256"] = file_hash(source["url"], cancelled)
            if source.get("cover_path"):
                identity["cover_sha256"] = file_hash(source["cover_path"], cancelled)
            key = hashlib.sha256(json.dumps(identity, sort_keys=True, allow_nan=False).encode()).hexdigest()
            self.store.update_item(item_id, metadata=metadata, artifact_key=key)
            artifact = self.store.artifact(key)
            # A published file may survive a crash just before the SQLite commit.
            if not artifact and item.get("artifact_key") == key:
                artifact = item.get("result")
            if artifact and self._valid_cached(artifact, cancelled):
                artifact = {**artifact, "playlist_title": metadata.get("playlist_title"), "playlist_index": metadata.get("playlist_index")}
                self.store.complete(item_id, key, artifact, reused=True)
                self._emit(callback, job_id, item_id, status="reused", result=artifact)
                return
            if artifact:
                self.store.invalidate_artifact(key)
            workspace = self.state_dir / "work" / item_id
            arguments = metadata_options(metadata.get("artist", ""), metadata.get("album", ""),
                                         bool(metadata.get("playlist_title")), title=metadata["title"], genre=metadata.get("genre", ""),
                                         playlist_title=metadata.get("playlist_title", ""), playlist_index=metadata.get("playlist_index"))
            output = self.worker.convert(source, info, workspace, job["spec"]["quality"], metadata, arguments, cancelled, progress)
            if not Path(output).resolve().is_relative_to(workspace.resolve()):
                raise ConversionError("invalid_output_path", "Output escaped the job workspace")
            progress({"phase": "validating", "fraction": None})
            result = self.worker.validate(output, expected, cancelled)
            if source["kind"] == "file" and identity["source_sha256"] != file_hash(source["url"], cancelled):
                raise ConversionError("source_changed", "Source file changed during conversion")
            if source.get("cover_path") and identity["cover_sha256"] != file_hash(source["cover_path"], cancelled):
                raise ConversionError("source_changed", "Cover file changed during conversion")
            if source.get("cover_path") and not result.get("cover_embedded"):
                raise ConversionError("missing_cover", "The requested cover was not embedded")
            if cancelled():
                raise Cancelled()
            destination = self._output_path(job["spec"]["output_template"], metadata)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination = self._unused_path(destination, key)
            result.update({"path": str(destination), "source_id": metadata["id"], "quality": job["spec"]["quality"],
                           "playlist_title": metadata.get("playlist_title"), "playlist_index": metadata.get("playlist_index"),
                           "warnings": [] if result.get("cover_embedded") else ["No embedded cover available"]})
            self.store.update_item(item_id, result=result, output_path=str(destination))
            # Atomic, no-overwrite publication. Work and outputs share a filesystem.
            os.link(output, destination)
            self.store.complete(item_id, key, result)
            self._emit(callback, job_id, item_id, status="completed", result=result)
        except Cancelled:
            raise
        except Exception as error:
            detail = error.as_dict() if isinstance(error, ConversionError) else {"code": "processing_error", "message": str(error)}
            self.store.update_item(item_id, status="failed", error=detail)
            self._emit(callback, job_id, item_id, status="failed", error=detail)

    @staticmethod
    def _playlist_entries(source, info):
        entries = []
        for index, entry in enumerate(info.get("entries") or [], 1):
            entry = entry or {}
            video_id = entry.get("id")
            url = entry.get("webpage_url") or entry.get("url")
            if not valid_url(url):
                url = f"https://www.youtube.com/watch?v={video_id}" if video_id and re.fullmatch(r"[\w-]{11}", video_id, re.ASCII) else None
            item_source = {**source, "kind": "video", "url": url or source["url"]}
            item_metadata = {"playlist_title": str(info.get("title") or "Playlist"), "playlist_index": index}
            if url:
                entries.append({"source": item_source, "metadata": item_metadata})
            else:
                entries.append({"source": item_source, "metadata": item_metadata, "status": "unavailable",
                                "error": {"code": "unavailable_entry", "message": "Playlist entry has no accessible video ID"}})
        return entries

    def _output_path(self, template, metadata):
        template = template or ("Playlists/%(playlist_title|Playlist).150B/%(playlist_index|0)03d - %(title).150B [%(id)s].%(ext)s" if metadata.get("playlist_title") else "Singles/%(title).180B [%(id)s].%(ext)s")
        values = {**metadata, "ext": "mp3"}
        if len(str(values.get("id", ""))) > 32:
            values["id"] = hashlib.sha256(str(values["id"]).encode()).hexdigest()[:12]
        pattern = r"%\((\w+)(?:\|([^)]*))?\)(?:\.(\d+)B|0?(\d*)d|s)"
        def replace(match):
            key, fallback, byte_limit, width = match.groups()
            if key not in {"title", "id", "playlist_title", "playlist_index", "ext"}:
                raise ValueError("Unsupported output template field")
            value = values.get(key)
            if value in (None, ""):
                value = fallback or (0 if key == "playlist_index" else "Audio")
            if width is not None:
                return str(int(value)).zfill(min(10, int(width or 0)))
            value = clean_name(value) or "Audio"
            if byte_limit:
                value = value.encode()[:min(200, int(byte_limit))].decode("utf-8", errors="ignore") or "Audio"
            # Direct URL IDs and titles must never become path components.
            return value[:180]
        rendered = re.sub(pattern, replace, template)
        if "%(" in rendered or "\x00" in rendered:
            raise ValueError("Invalid output template")
        path = Path(rendered).expanduser()
        path = (path if path.is_absolute() else self.output_dir / path).resolve()
        if not path.is_relative_to(self.output_dir) or path.is_relative_to(self.state_dir) or path.suffix.lower() != ".mp3":
            raise ValueError("Output must be an MP3 inside the output directory, outside internal state")
        return path

    @staticmethod
    def _unused_path(path, key):
        if not path.exists():
            return path
        suffix = 1
        while True:
            candidate = path.with_name(f"{path.stem[:140]} [{key[:8]}-{suffix}].mp3")
            if not candidate.exists():
                return candidate
            suffix += 1

    @staticmethod
    def _valid_cached(result, cancelled=lambda: False):
        try:
            path = Path(result["path"])
            return path.is_file() and path.stat().st_size == result["size"] and file_hash(path, cancelled) == result["sha256"]
        except (OSError, KeyError, TypeError):
            return False
