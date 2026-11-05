"""Private subprocess entry point. Loss of the parent pipe cancels descendants."""

import argparse
import signal
import sys
import threading

from companion_security import CompanionConfig
from conversion_worker import ConversionError, ConversionWorker
from converter_core import Converter


class LimitedWorker(ConversionWorker):
    def __init__(self, stopped):
        super().__init__(timeout=900, fragments=2)
        self.stopped = stopped
        self.job_store = None
        self.job_id = None

    def run_process(self, arguments, cancelled, on_line=None):
        if arguments[0] == self.tools["yt-dlp"]:
            if "--extract-audio" in arguments:
                arguments = [arguments[0], "--max-filesize", "512M", *arguments[1:]]
            elif "--flat-playlist" in arguments:
                # One extra entry detects over-limit playlists rather than
                # silently truncating them; avoid fetching arbitrarily many.
                arguments = [arguments[0], "--playlist-end", "1001", *arguments[1:]]
        return super().run_process(arguments, lambda: self.stopped.is_set() or cancelled(), on_line)

    def discover(self, source, cancelled):
        info = super().discover(source, cancelled)
        if source["kind"] == "playlist":
            existing = 1
            if self.job_store:
                with self.job_store._connection() as db:
                    existing = db.execute("SELECT COUNT(*) FROM items WHERE job_id=?", (self.job_id,)).fetchone()[0]
            if existing - 1 + len(info.get("entries") or []) > 1000:
                raise ConversionError("playlist_limit", "At most 1000 entries per job")
        elif info.get("duration") and info["duration"] > 7200:
            raise ConversionError("duration_limit", "At most two hours per track")
        return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--job", required=True)
    args = parser.parse_args()
    config = CompanionConfig(args.root)
    stopped = threading.Event()
    worker = LimitedWorker(stopped)
    converter = Converter(config.root, worker=worker)
    worker.job_store, worker.job_id = converter.store, args.job
    def parent_pipe():
        sys.stdin.buffer.read()
        stopped.set()
    def cancel_on_stop():
        stopped.wait()
        converter.cancel(args.job)
    threading.Thread(target=parent_pipe, daemon=True).start()
    threading.Thread(target=cancel_on_stop, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    try:
        converter.run(args.job)
        return 0
    except ConversionError as error:
        return 73 if error.code == "worker_busy" else 1


if __name__ == "__main__":
    raise SystemExit(main())
