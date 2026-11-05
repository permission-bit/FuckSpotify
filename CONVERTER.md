# Converter API (local Mac, no server)

Requires Python 3.10+, FFmpeg/FFprobe, and yt-dlp for YouTube sources. No new Python
packages are required. Current yt-dlp may additionally need its documented EJS/JS
runtime dependencies. Local files work without yt-dlp.

```python
from converter_core import Converter, MediaSource

converter = Converter("/absolute/path/to/music")
job = converter.submit([
    MediaSource("/absolute/path/to/owned.wav", "file", authorized=True,
                metadata={"artist": "Artist", "album": "Album"}),
], quality="192K")
result = converter.run(job["id"], on_progress=lambda event: print(event))
```

`authorized=True` is mandatory per source. It is the caller's assertion of the
necessary copyright/platform permissions, not proof or an automatic rights check.
No DRM bypass, login-cookie extraction, unofficial authentication or server is
implemented. yt-dlp user configuration/plugins are disabled for controlled jobs.

## Operations

- `submit(sources, quality="320K", artist="", album="", output_template=None)`:
  validate and persist without starting media processing.
- `run(job_id, on_progress=None)`: synchronous worker; run in a background thread
  or dedicated process for a future UI. Callback events and results contain only
  JSON-compatible values. Callback errors do not abort conversion.
- `get_job(job_id)` / `converter.store.list_jobs()`: durable snapshots, ordered items,
  progress, attempts, per-item errors, verified output manifests and state counts.
- `cancel(job_id)`: durable cancellation request; a running subprocess and its
  descendants are stopped, normally within the worker's polling/termination window.
  This can be requested through another Converter instance/process.
- `retry(job_id, item_ids=None)`: requeue failed/cancelled/interrupted/unavailable
  entries. Completed entries remain intact. Then call `run` again.

Source kinds: `video` (YouTube URL), `playlist` (YouTube playlist URL), `file`
(local audio/video), `direct` (authorized HTTPS media-file URL, no streaming manifest).
Explicit local cover images are supported through `cover_path` for local/direct
conversion. YouTube covers come from yt-dlp's thumbnail processing.
Quality: 64/96/128/160/192/224/256/320K, or yt-dlp/LAME VBR values 0–10.

## Durability and safety

State lives in `<output>/.converter/jobs.sqlite3` (SQLite WAL); work files are in
`.converter/work/<item-id>`. One worker per state store is enforced with a POSIX
file lock. On reopening after a crash, active entries become `interrupted`; retry
them explicitly. Status/cancellation remain available while a worker holds the lock.

Playlist expansion is transactional. Entries retain source order and one-based
playlist indices, including unavailable entries. Empty playlists complete as skipped.
Missing/private entries report errors instead of silently disappearing.

Successful subprocess completion, output format, source/output duration comparison,
full FFmpeg audio decoding and a streamed SHA-256 hash are required before publication.
Finished files are published atomically with a no-overwrite hard link. The output
filesystem therefore needs hard-link support (standard Mac APFS supports this).
Publication failures remain retryable; existing music is never overwritten/deleted.

The cache identifies the source, MP3 quality and requested metadata/cover profile.
Changed, deleted or corrupt cached files are not silently accepted. Different
metadata profiles (for example playlist album/track tags) can create separate MP3s.
A job snapshot is a historical result, not a promise its file was never externally
changed: verify its SHA-256 before a future iPhone transfer.
Arbitrary direct HTTPS URLs are not reused across separate jobs because their
content may change without their URL changing. Their verified results can still
be recovered within the original job. Local sources use a content hash;
YouTube sources use the source ID, observed duration and requested profile.

Working/intermediate files are intentionally retained; invalid outputs are renamed
inside the job workspace on retry. Automatic disk cleanup is not implemented.
Per-process timeouts and a 16 MiB limit per JSON/log record bound stuck processes and
oversized extraction output. Very large playlists may need future streaming expansion.

## Existing CLI

`python3 playlist.py` retains single/playlist/TXT prompts, custom filenames and
artist/album overrides. It adds explicit authorization and MP3 quality prompts.
The original archive files are left untouched: their IDs cannot prove a valid local
file still exists, so validated SQLite results now govern reuse.

```text
python3 playlist.py --status JOB_ID
python3 playlist.py --cancel JOB_ID
python3 playlist.py --retry JOB_ID --json
```

Tests perform no internet downloads:

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_converter.py -v
```
