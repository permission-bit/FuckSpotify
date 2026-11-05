"""Offline tests: simulated downloads and real local FFmpeg conversions only."""

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tracemalloc
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from converter_core import Converter, MediaSource, normalize_quality, valid_url
from conversion_worker import Cancelled, ConversionError, ConversionWorker, file_hash
from job_store import JobStore
import playlist


A = "aaaaaaaaaaa"
B = "BBBBBBBBBBB"


def video(identifier=A):
    return MediaSource(f"https://www.youtube.com/watch?v={identifier}", authorized=True)


class FakeWorker:
    def __init__(self):
        self.fail = set()
        self.calls = []
        self.invalid = False
        self.drm = False
        self.empty_playlist = False

    def discover(self, source, cancelled):
        if cancelled():
            raise Cancelled()
        if source["kind"] == "playlist":
            return {"title": "An ordered playlist", "entries": [] if self.empty_playlist else [
                {"id": B}, None, {"id": A}, {"id": B}]}
        identifier = source["url"].split("v=")[-1]
        return {"id": identifier, "title": source.get("fallback_title") or identifier, "artist": "Original Artist", "duration": 4, "has_drm": self.drm}

    def convert(self, source, info, workspace, quality, metadata, arguments, cancelled, progress):
        self.calls.append(info["id"])
        progress({"phase": "downloading", "fraction": 0.5})
        if cancelled():
            raise Cancelled()
        if info["id"] in self.fail:
            raise ConversionError("simulated_failure", "Download failed")
        workspace.mkdir(parents=True, exist_ok=True)
        target = workspace / "test.mp3"
        target.write_bytes((info["id"] + quality).encode())
        progress({"phase": "converting", "fraction": 1.0})
        return target

    def validate(self, filename, expected, cancelled):
        if self.invalid:
            raise ConversionError("invalid_format", "Not a valid MP3")
        return {"path": str(filename), "format": "mp3", "duration": 4,
                "size": filename.stat().st_size, "sha256": file_hash(filename), "metadata": {}, "cover_embedded": False}


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.worker = FakeWorker()
        self.converter = Converter(self.root, worker=self.worker)

    def test_explicit_authorization_and_input_validation(self):
        for source in (MediaSource(video().url), MediaSource(video().url, authorized="yes"), MediaSource("https://youtube.com.evil.example/watch?v=x", authorized=True)):
            with self.assertRaises(ValueError):
                self.converter.submit(source)
        self.assertFalse(valid_url("https://youtube.com@evil.example/video"))
        self.assertFalse(valid_url("https://user:password@youtube.com/video"))
        with self.assertRaises(ValueError):
            self.converter.submit(video(), quality="320K --exec evil")
        with self.assertRaises(ValueError):
            self.converter.submit(video(), output_template="../escape.mp3")
        with self.assertRaises(ValueError):
            self.converter.submit(MediaSource("https://example.com/encrypted.m3u8", "direct", authorized=True))
        self.assertEqual(self.worker.calls, [])

    def test_batch_partial_failure_and_selective_retry(self):
        self.worker.fail.add(B)
        job = self.converter.submit([video(), video(B)], quality="192k")
        events = []
        result = self.converter.run(job["id"], events.append)
        self.assertEqual(result["status"], "partial")
        self.assertEqual([item["status"] for item in result["items"]], ["completed", "failed"])
        self.assertEqual(result["items"][1]["error"]["code"], "simulated_failure")
        self.worker.fail.clear()
        self.converter.retry(job["id"], [result["items"][1]["id"]])
        result = self.converter.run(job["id"])
        self.assertEqual(result["status"], "completed")
        self.assertEqual(self.worker.calls, [A, B, B])
        self.assertTrue(any(event.get("phase") == "downloading" for event in events))
        json.dumps(result, allow_nan=False)

    def test_playlist_positions_and_unavailable_entries(self):
        job = self.converter.submit(MediaSource("https://youtube.com/playlist?list=test", "playlist", authorized=True))
        result = self.converter.run(job["id"])
        self.assertEqual(result["status"], "partial")
        self.assertEqual([item["position"] for item in result["items"]], [1, 2, 3, 4])
        self.assertEqual([item["metadata"]["playlist_index"] for item in result["items"]], [1, 2, 3, 4])
        self.assertEqual(result["items"][1]["status"], "unavailable")
        self.assertEqual(self.worker.calls, [B, A, B])
        self.assertTrue(Path(result["items"][0]["output_path"]).name.startswith("001 - "))

    def test_empty_playlist(self):
        self.worker.empty_playlist = True
        result = self.converter.run(self.converter.submit(MediaSource("https://youtube.com/playlist?list=empty", "playlist", authorized=True))["id"])
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["items"][0]["status"], "skipped")
        self.assertEqual(self.worker.calls, [])

    def test_cancel_queued_and_running_then_retry(self):
        queued = self.converter.submit(video())
        cancelled = self.converter.cancel(queued["id"])
        self.assertEqual(cancelled["status"], "cancelled")
        self.assertEqual(cancelled["items"][0]["status"], "cancelled")
        self.assertEqual(self.converter.run(queued["id"])["status"], "cancelled")
        job = self.converter.submit([video(), video(B)])
        def callback(event):
            if event.get("fraction") == 0.5:
                # A separate API object must be able to cancel the live worker.
                Converter(self.root, worker=self.worker).cancel(job["id"])
        result = self.converter.run(job["id"], callback)
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(all(item["status"] == "cancelled" for item in result["items"]))
        self.converter.retry(job["id"])
        self.assertEqual(self.converter.run(job["id"])["status"], "completed")

    def test_persistence_reuse_and_changed_or_missing_output(self):
        first = self.converter.run(self.converter.submit(video())["id"])
        output = Path(first["items"][0]["result"]["path"])
        reopened = Converter(self.root, worker=self.worker)
        self.assertEqual(reopened.get_job(first["id"])["status"], "completed")
        second = reopened.run(reopened.submit(video())["id"])
        self.assertEqual(second["items"][0]["status"], "reused")
        self.assertEqual(len(self.worker.calls), 1)
        output.write_bytes(b"user-changed-existing-file")
        third = reopened.run(reopened.submit(video())["id"])
        self.assertEqual(output.read_bytes(), b"user-changed-existing-file")
        new_output = Path(third["items"][0]["result"]["path"])
        self.assertNotEqual(output, new_output)
        new_output.unlink()  # Only a generated fixture, never user music.
        fourth = reopened.run(reopened.submit(video())["id"])
        self.assertEqual(fourth["items"][0]["status"], "completed")

    def test_existing_music_is_not_overwritten(self):
        existing = self.root / "my-song.mp3"
        existing.write_bytes(b"original user music")
        job = self.converter.submit(video(), output_template="my-song.mp3")
        result = self.converter.run(job["id"])
        self.assertEqual(existing.read_bytes(), b"original user music")
        self.assertNotEqual(result["items"][0]["output_path"], str(existing))

    def test_validation_failure_never_publishes(self):
        self.worker.invalid = True
        result = self.converter.run(self.converter.submit(video())["id"])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(list((self.root / "Singles").glob("*.mp3")), [])

    def test_drm_is_rejected_before_conversion(self):
        self.worker.drm = True
        result = self.converter.run(self.converter.submit(video())["id"])
        self.assertEqual(result["items"][0]["error"]["code"], "unsupported_media")
        self.assertEqual(self.worker.calls, [])

    def test_recovery_preserves_completed_items(self):
        job = self.converter.submit([video(), video(B)])
        result = self.converter.run(job["id"])
        self.converter.store.update_job(job["id"], "running")
        self.converter.store.update_item(result["items"][1]["id"], status="converting")
        reopened = Converter(self.root, worker=self.worker)
        recovered = reopened.get_job(job["id"])
        self.assertEqual(recovered["status"], "interrupted")
        self.assertEqual(recovered["items"][0]["status"], "completed")
        self.assertEqual(recovered["items"][1]["status"], "interrupted")
        reopened.retry(job["id"])
        finished = reopened.run(job["id"])
        self.assertEqual(finished["status"], "completed")
        self.assertEqual(len(self.worker.calls), 2, "Valid completed audio must be reused after recovery")

    def test_callback_errors_do_not_destroy_success(self):
        def broken_callback(event):
            raise RuntimeError("UI callback failed")
        job = self.converter.submit(video())
        self.assertEqual(self.converter.run(job["id"], broken_callback)["status"], "completed")

    def test_playlist_discovery_failure_can_be_retried(self):
        job = self.converter.submit([MediaSource("https://youtube.com/playlist?list=test", "playlist", authorized=True), video()])
        original = self.worker.discover
        def fail_playlist(source, cancelled):
            if source["kind"] == "playlist":
                raise ConversionError("discovery_failed", "Playlist is temporarily unavailable")
            return original(source, cancelled)
        with patch.object(self.worker, "discover", side_effect=fail_playlist):
            result = self.converter.run(job["id"])
        self.assertEqual(result["status"], "partial")
        self.converter.retry(job["id"], [result["items"][0]["id"]])
        result = self.converter.run(job["id"])
        self.assertEqual([item["position"] for item in result["items"]], [1, 2, 3, 4, 5])
        self.assertEqual(result["items"][-1]["status"], "completed")

    def test_published_file_recovers_after_database_completion_failure(self):
        job = self.converter.submit(video())
        with patch.object(self.converter.store, "complete", side_effect=RuntimeError("Commit interrupted")):
            result = self.converter.run(job["id"])
        self.assertEqual(result["status"], "failed")
        published = Path(result["items"][0]["output_path"])
        self.assertTrue(published.is_file())
        self.converter.retry(job["id"])
        recovered = self.converter.run(job["id"])
        self.assertEqual(recovered["items"][0]["status"], "reused")
        self.assertEqual(len(self.worker.calls), 1)

    def test_exclusive_worker_and_keyboard_interrupt(self):
        job = self.converter.submit(video())
        with self.converter._exclusive_worker():
            with self.assertRaises(ConversionError) as caught:
                Converter(self.root, worker=self.worker).run(job["id"])
            self.assertEqual(caught.exception.code, "worker_busy")
        with patch.object(self.worker, "discover", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.converter.run(job["id"])
        self.assertEqual(self.converter.get_job(job["id"])["status"], "cancelled")

    def test_rejects_missing_completion_marker_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            worker = ConversionWorker()
            commands = []
            def incomplete(arguments, cancelled, on_line=None):
                commands.append(arguments)
                if on_line:
                    on_line('__DOWNLOAD__{"downloaded_bytes": 100, "total_bytes": 100}', "stdout")
            with patch.object(worker, "run_process", side_effect=incomplete):
                with self.assertRaises(ConversionError) as caught:
                    worker.convert(video().normalized(), {}, Path(directory), "192K", {}, [], lambda: False, lambda event: None)
            self.assertEqual(caught.exception.code, "incomplete_processing")
            self.assertIn("--ignore-config", commands[0])
            self.assertNotIn("--ignore-errors", commands[0])
            self.assertNotIn("--allow-unplayable-formats", commands[0])

    def test_cli_helpers_and_authorization_declined(self):
        links = self.root / "links.txt"
        links.write_text(f"\ufeff# comment\n{video().url}\n{video().url}\nhttps://invalid.example/x\n", encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(playlist.read_links(links), [video().url])
            with patch.object(playlist, "BASE_DIR", self.root), patch.object(playlist, "dependencies_ready", return_value=True), patch("builtins.input", side_effect=[video().url, "", "", "n"]), patch.object(playlist, "download") as download:
                playlist.main([])
                download.assert_not_called()
        self.assertEqual(normalize_quality("128"), "128K")
        self.assertEqual(normalize_quality("0"), "0")


class ProcessTests(unittest.TestCase):
    def test_streaming_hash_has_bounded_memory_and_can_cancel(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "large-local-fixture.mp3"
            chunk = b"\x12" * (1024 * 1024)
            expected = hashlib.sha256()
            with source.open("wb") as stream:
                for _ in range(16):
                    stream.write(chunk)
                    expected.update(chunk)
            tracemalloc.start()
            try:
                actual = file_hash(source)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
            self.assertEqual(actual, expected.hexdigest())
            self.assertLess(peak, 4 * 1024 * 1024, "Hashing must not load the complete audio file into RAM")
            checks = 0
            def cancelled():
                nonlocal checks
                checks += 1
                return checks == 3
            with self.assertRaises(Cancelled):
                file_hash(source, cancelled)
            self.assertEqual(checks, 3)
            self.assertEqual(source.stat().st_size, 16 * 1024 * 1024)

    def test_nonzero_exit_preserves_error_without_newline(self):
        with self.assertRaises(ConversionError) as caught:
            ConversionWorker().run_process([sys.executable, "-c", "import sys; sys.stderr.write('meaningful failure'); sys.exit(3)"], lambda: False)
        self.assertIn("meaningful failure", str(caught.exception))

    def test_timeout_and_descendant_cancellation(self):
        with self.assertRaises(ConversionError) as caught:
            ConversionWorker(timeout=0.15).run_process([sys.executable, "-c", "import time; time.sleep(30)"], lambda: False)
        self.assertEqual(caught.exception.code, "timeout")
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child-survived"
            child = f"import time; from pathlib import Path; time.sleep(1); Path({str(marker)!r}).write_text('alive')"
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1]]); print('ready',flush=True); time.sleep(30)"
            cancel = threading.Event()
            def receive(line, stream):
                if line == "ready":
                    cancel.set()
            with self.assertRaises(Cancelled):
                ConversionWorker().run_process([sys.executable, "-u", "-c", parent, child], cancel.is_set, receive)
            time.sleep(1.2)
            self.assertFalse(marker.exists(), "Cancellation must terminate descendants too")


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg/FFprobe not installed")
class NativeAudioTests(unittest.TestCase):
    def test_real_mp3_metadata_cover_validation_and_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "owned.wav"
            with wave.open(str(source), "wb") as stream:
                stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(44100)
                stream.writeframes(b"\0\0" * 44100)
            cover = root / "cover.ppm"
            cover.write_bytes(b"P6\n16 16\n255\n" + b"\xff\0\0" * 256)
            artist = 'Artist: "quotes" 100% 🎵'
            converter = Converter(root / "library")
            spec = MediaSource(str(source), "file", authorized=True, cover_path=str(cover),
                               metadata={"title": "My song", "artist": artist, "album": "My album"})
            job = converter.submit(spec, quality="128K")
            result = converter.run(job["id"])
            self.assertEqual(result["status"], "completed", result)
            audio = result["items"][0]["result"]
            self.assertEqual(audio["metadata"]["artist"], artist)
            self.assertEqual(audio["format"], "mp3")
            self.assertTrue(audio["cover_embedded"])
            self.assertTrue(source.exists())
            reused = converter.run(converter.submit(spec, quality="128K")["id"])
            self.assertEqual(reused["items"][0]["status"], "reused")
            with self.assertRaises(ConversionError) as caught:
                converter.worker.validate(audio["path"], 30, lambda: False)
            self.assertEqual(caught.exception.code, "incomplete_audio")
            broken = root / "broken.mp3"
            broken.write_bytes(Path(audio["path"]).read_bytes()[:64])
            with self.assertRaises(ConversionError):
                converter.worker.validate(broken, 1, lambda: False)


if __name__ == "__main__":
    unittest.main()
