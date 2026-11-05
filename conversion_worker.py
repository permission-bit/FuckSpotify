"""Cancellable child-process boundary for yt-dlp, FFmpeg and FFprobe."""

import hashlib
import json
import math
import os
import selectors
import signal
import subprocess
import time
from collections import deque
from pathlib import Path


class ConversionError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

    def as_dict(self):
        return {"code": self.code, "message": str(self)}


class Cancelled(ConversionError):
    def __init__(self):
        super().__init__("cancelled", "Cancelled by user")


def file_hash(filename, cancelled=lambda: False):
    digest = hashlib.sha256()
    with Path(filename).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            if cancelled():
                raise Cancelled()
            digest.update(chunk)
    return digest.hexdigest()


class ConversionWorker:
    def __init__(self, executables=None, timeout=3600, fragments=4):
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("Process timeout must be a finite positive number")
        self.tools = {"yt-dlp": "yt-dlp", "ffmpeg": "ffmpeg", "ffprobe": "ffprobe", **(executables or {})}
        self.timeout = timeout
        if not isinstance(fragments, int) or not 1 <= fragments <= 16:
            raise ValueError("Fragment concurrency must be between 1 and 16")
        self.fragments = fragments

    @staticmethod
    def _terminate(process):
        # Descendants (FFmpeg, JS runtime) belong to the same process group.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    def run_process(self, arguments, cancelled, on_line=None):
        if cancelled():
            raise Cancelled()
        try:
            process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True, bufsize=0)
        except OSError as error:
            raise ConversionError("dependency_error", str(error)) from error
        stderr = deque(maxlen=30)
        start = time.monotonic()
        buffers = {}
        try:
            with selectors.DefaultSelector() as selector:
                for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, name)
                    buffers[name] = bytearray()
                while selector.get_map():
                    if cancelled():
                        raise Cancelled()
                    if time.monotonic() - start > self.timeout:
                        raise ConversionError("timeout", "Media process exceeded its time limit")
                    for key, _ in selector.select(timeout=0.1):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        name = key.data
                        if chunk:
                            buffers[name].extend(chunk)
                            if len(buffers[name]) > 16 * 1024 * 1024:
                                raise ConversionError("output_limit", "Media process returned an oversized record")
                        while b"\n" in buffers[name]:
                            raw, _, rest = buffers[name].partition(b"\n")
                            buffers[name] = bytearray(rest)
                            line = raw.decode("utf-8", errors="replace").rstrip("\r")
                            if name == "stderr":
                                stderr.append(line[-2000:])
                            if on_line:
                                on_line(line, name)
                        if not chunk:
                            if buffers[name] and name == "stderr":
                                stderr.append(buffers[name].decode("utf-8", errors="replace")[-2000:])
                            if buffers[name] and on_line:
                                on_line(buffers[name].decode("utf-8", errors="replace"), name)
                            selector.unregister(key.fileobj)
                while process.poll() is None:
                    if cancelled():
                        raise Cancelled()
                    if time.monotonic() - start > self.timeout:
                        raise ConversionError("timeout", "Media process exceeded its time limit")
                    time.sleep(0.05)
                if process.returncode:
                    raise ConversionError("process_failed", "\n".join(stderr) or f"Process exited with {process.returncode}")
        except BaseException:
            self._terminate(process)
            raise
        finally:
            process.stdout.close()
            process.stderr.close()

    def _json_process(self, arguments, cancelled):
        lines = []
        size = 0
        def receive(line, stream):
            nonlocal size
            if stream == "stdout" and line.strip():
                size += len(line.encode("utf-8"))
                if size > 16 * 1024 * 1024:
                    raise ConversionError("output_limit", "Media JSON exceeded 16 MiB")
                lines.append(line)
        self.run_process(arguments, cancelled, receive)
        if not lines:
            raise ConversionError("missing_process_output", "Media process returned no result")
        try:
            record = json.loads("\n".join(lines))
        except ValueError as error:
            raise ConversionError("invalid_process_output", "Expected a JSON media record") from error
        if not isinstance(record, dict):
            raise ConversionError("invalid_process_output", "Expected a JSON media object")
        return record

    def discover(self, source, cancelled):
        if source["kind"] in {"file", "direct"}:
            info = self.probe(source["url"], cancelled)
            audio = self._audio_stream(info)
            self._reject_drm(info)
            tags = info.get("format", {}).get("tags", {})
            cover_stream = next((s for s in info.get("streams", []) if s.get("disposition", {}).get("attached_pic")), None)
            return {"id": source["url"], "title": tags.get("title") or source.get("fallback_title") or Path(source["url"]).stem,
                    "artist": tags.get("artist", ""), "album": tags.get("album", ""),
                    "duration": self._duration(info, audio), "has_cover": cover_stream is not None,
                    "cover_stream_index": cover_stream.get("index") if cover_stream else None}
        flags = [self.tools["yt-dlp"], "--ignore-config", "--no-plugin-dirs", "--no-cache-dir",
                 "--no-remote-components", "--skip-download", "--dump-single-json", "--socket-timeout", "30",
                 "--yes-playlist" if source["kind"] == "playlist" else "--no-playlist"]
        if source["kind"] == "playlist":
            flags.append("--flat-playlist")
        info = self._json_process([*flags, "--", source["url"]], cancelled)
        self._reject_drm(info)
        return info

    @staticmethod
    def _reject_drm(info):
        if info.get("has_drm") or any(s.get("codec_tag_string") in {"enca", "encv"} for s in info.get("streams", [])):
            raise ConversionError("protected_media", "DRM-protected media is not supported")

    def convert(self, source, info, workspace, quality, metadata, metadata_arguments, cancelled, progress):
        workspace = Path(workspace)
        workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = workspace / "media.mp3"
        if target.exists():
            # Preserve interrupted/invalid output for inspection; never overwrite it.
            target.rename(workspace / f"media.previous-{time.time_ns()}.mp3")
        if source["kind"] in {"file", "direct"}:
            return self._convert_file(source, info, target, quality, metadata, cancelled, progress)
        result = None
        def receive(line, stream):
            nonlocal result
            if stream != "stdout":
                return
            for prefix, phase in (("__DOWNLOAD__", "downloading"), ("__POSTPROCESS__", "converting")):
                if line.startswith(prefix):
                    try:
                        data = json.loads(line[len(prefix):])
                    except ValueError:
                        return
                    total = data.get("total_bytes") or data.get("total_bytes_estimate")
                    downloaded = data.get("downloaded_bytes", 0)
                    progress({"phase": phase, "downloaded_bytes": downloaded, "total_bytes": total,
                              "fraction": min(1, downloaded / total) if total and isinstance(downloaded, (int, float)) else None})
                    return
            if line.startswith("__RESULT__"):
                result = json.loads(line[len("__RESULT__"):])
        command = [self.tools["yt-dlp"], "--ignore-config", "--no-plugin-dirs", "--no-exec", "--no-cache-dir",
                   "--no-remote-components", "--no-playlist", "--abort-on-error", "--no-overwrites", "--no-post-overwrites",
                   "--continue", "--retries", "5", "--fragment-retries", "5", "--concurrent-fragments", str(self.fragments), "--socket-timeout", "30",
                   "-f", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", quality,
                   "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg", "--keep-video",
                   "--no-embed-chapters", "--no-embed-info-json", "--no-simulate", "--newline", "--progress", "--no-colors",
                   "--progress-template", "download:__DOWNLOAD__%(progress)j",
                   "--progress-template", "postprocess:__POSTPROCESS__%(progress)j",
                   "--print", "after_move:__RESULT__%()j",
                   "-o", str(workspace / "media.%(ext)s"), "--", source["url"]]
        if Path(self.tools["ffmpeg"]).is_absolute():
            command[1:1] = ["--ffmpeg-location", str(Path(self.tools["ffmpeg"]).parent)]
        self.run_process(command, cancelled, receive)
        if not isinstance(result, dict) or not result.get("filepath"):
            raise ConversionError("incomplete_processing", "No completed post-processing result was received")
        output = Path(result["filepath"]).resolve()
        if output.parent != workspace.resolve() or output.suffix.lower() != ".mp3":
            raise ConversionError("invalid_output_path", "Unexpected converter output path")
        self._reject_drm(result)
        tagged = workspace / "tagged.mp3"
        if tagged.exists():
            tagged.rename(workspace / f"tagged.previous-{time.time_ns()}.mp3")
        self.run_process([self.tools["ffmpeg"], "-nostdin", "-v", "error", "-i", str(output), "-map", "0", "-c", "copy",
                          "-id3v2_version", "3", *metadata_arguments, "-n", str(tagged)], cancelled)
        return tagged

    def _convert_file(self, source, info, target, quality, metadata, cancelled, progress):
        # No encrypted HLS/DRM protocols, credentials, cookies or bypass flags.
        arguments = [self.tools["ffmpeg"], "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file,http,https,tcp,tls",
                     "-i", source["url"]]
        cover = source.get("cover_path")
        if cover:
            arguments += ["-i", cover]
        arguments += ["-map", "0:a:0", "-map_metadata", "0", "-c:a", "libmp3lame"]
        arguments += ["-b:a", quality] if quality.endswith("K") else ["-q:a", quality]
        if cover:
            arguments += ["-map", "1:v:0", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
        elif info.get("has_cover"):
            arguments += ["-map", f"0:{info['cover_stream_index']}", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
        else:
            arguments.append("-vn")
        tags = {key: metadata.get(key) for key in ("title", "artist", "album", "genre")}
        tags["album_artist"] = metadata.get("artist")
        tags["track"] = metadata.get("playlist_index")
        for key, value in tags.items():
            if value not in (None, ""):
                arguments += ["-metadata", f"{key}={value}"]
        arguments += ["-id3v2_version", "3", "-progress", "pipe:1", "-nostats", "-n", str(target)]
        def receive(line, stream):
            if stream == "stdout" and line.startswith("out_time_us="):
                try:
                    seconds = int(line.partition("=")[2]) / 1_000_000
                except ValueError:
                    return
                duration = info.get("duration")
                progress({"phase": "converting", "seconds": seconds,
                          "fraction": min(1, seconds / duration) if duration else None})
        self.run_process(arguments, cancelled, receive)
        return target

    def probe(self, filename, cancelled):
        return self._json_process([self.tools["ffprobe"], "-v", "error", "-protocol_whitelist", "file,http,https,tcp,tls",
                                   "-show_format", "-show_streams", "-of", "json", str(filename)], cancelled)

    @staticmethod
    def _audio_stream(info):
        audio = next((s for s in info.get("streams", []) if s.get("codec_type") == "audio"), None)
        if not audio:
            raise ConversionError("missing_audio", "No audio stream found")
        return audio

    @staticmethod
    def _duration(info, audio):
        try:
            duration = float(audio.get("duration") or info.get("format", {}).get("duration", 0))
        except (TypeError, ValueError) as error:
            raise ConversionError("invalid_duration", "Missing media duration") from error
        if not math.isfinite(duration) or duration <= 0:
            raise ConversionError("invalid_duration", "Invalid media duration")
        return duration

    def validate(self, filename, expected_duration, cancelled):
        filename = Path(filename)
        if not filename.is_file() or filename.stat().st_size <= 0:
            raise ConversionError("missing_output", "No finished audio file found")
        info = self.probe(filename, cancelled)
        audio = self._audio_stream(info)
        duration = self._duration(info, audio)
        if info.get("format", {}).get("format_name") != "mp3" or audio.get("codec_name") != "mp3":
            raise ConversionError("invalid_format", "Output is not MP3 audio")
        if int(audio.get("channels", 0)) <= 0 or int(audio.get("sample_rate", 0)) <= 0:
            raise ConversionError("invalid_format", "Invalid audio channels/sample rate")
        if expected_duration and abs(duration - expected_duration) > max(0.15, min(2, expected_duration * 0.01)):
            raise ConversionError("incomplete_audio", "Output duration differs from the source")
        # Read/decode the complete audio stream, not just a valid-looking header.
        self.run_process([self.tools["ffmpeg"], "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
                          "-i", str(filename), "-map", "0:a:0", "-f", "null", "-"], cancelled)
        return {"path": str(filename.resolve()), "format": "mp3", "duration": duration,
                "size": filename.stat().st_size, "sha256": file_hash(filename, cancelled),
                "metadata": info.get("format", {}).get("tags", {}),
                "cover_embedded": any(s.get("disposition", {}).get("attached_pic") for s in info.get("streams", []))}
