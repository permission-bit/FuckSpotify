"""Durable, JSON-compatible conversion jobs. Standard library only."""

import json
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path


class JobStore:
    def __init__(self, filename):
        self.path = Path(filename).expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self._connection() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, status TEXT NOT NULL, spec TEXT NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    cancel_requested INTEGER NOT NULL DEFAULT 0, error TEXT
                );
                CREATE TABLE IF NOT EXISTS items (
                    id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id),
                    position INTEGER NOT NULL, status TEXT NOT NULL,
                    source TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT '{}',
                    attempts INTEGER NOT NULL DEFAULT 0, progress TEXT NOT NULL DEFAULT '{}',
                    error TEXT, artifact_key TEXT, output_path TEXT,
                    result TEXT, updated_at REAL NOT NULL,
                    UNIQUE(job_id, position)
                );
                CREATE INDEX IF NOT EXISTS items_job_order ON items(job_id, position);
                CREATE INDEX IF NOT EXISTS items_pending ON items(job_id, status, position);
                CREATE TABLE IF NOT EXISTS artifacts (
                    key TEXT PRIMARY KEY, result TEXT NOT NULL,
                    valid INTEGER NOT NULL DEFAULT 1, updated_at REAL NOT NULL
                );
            """)
        self.path.chmod(0o600)

    @contextmanager
    def _connection(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def create(self, spec):
        with self._connection() as db:
            job_id = self.insert_job(db, spec)
        return self.get(job_id)

    @staticmethod
    def insert_job(db, spec):
        """Insert using an existing transaction (e.g. atomic API ownership/quota)."""
        job_id = str(uuid.uuid4())
        now = time.time()
        db.execute("INSERT INTO jobs(id,status,spec,created_at,updated_at) VALUES(?,?,?,?,?)",
                   (job_id, "queued", json.dumps(spec, allow_nan=False), now, now))
        for position, source in enumerate(spec["sources"], 1):
            db.execute("INSERT INTO items(id,job_id,position,status,source,updated_at) VALUES(?,?,?,?,?,?)",
                       (str(uuid.uuid4()), job_id, position, "pending", json.dumps(source, allow_nan=False), now))
        return job_id

    def get(self, job_id):
        with self._connection() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise KeyError(job_id)
            job = dict(row)
            job["spec"] = json.loads(job["spec"])
            job["cancel_requested"] = bool(job["cancel_requested"])
            job["error"] = json.loads(job["error"]) if job["error"] else None
            job["items"] = []
            for row in db.execute("SELECT * FROM items WHERE job_id=? ORDER BY position", (job_id,)):
                job["items"].append(self._item(row))
            counts = {}
            for item in job["items"]:
                counts[item["status"]] = counts.get(item["status"], 0) + 1
            job["counts"] = counts
            return job

    @staticmethod
    def _item(row):
        item = dict(row)
        for name in ("source", "metadata", "progress", "error", "result"):
            item[name] = json.loads(item[name]) if item[name] is not None else None
        return item

    def next_pending(self, job_id):
        with self._connection() as db:
            row = db.execute("SELECT * FROM items WHERE job_id=? AND status='pending' ORDER BY position LIMIT 1", (job_id,)).fetchone()
            return self._item(row) if row else None

    def item_statuses(self, job_id):
        with self._connection() as db:
            return {row[0] for row in db.execute("SELECT DISTINCT status FROM items WHERE job_id=?", (job_id,))}

    def list_jobs(self):
        with self._connection() as db:
            ids = [row[0] for row in db.execute("SELECT id FROM jobs ORDER BY created_at DESC")]
        return [self.get(job_id) for job_id in ids]

    def snapshot(self, job_id, limit=100, offset=0):
        """Bounded API snapshot; does not materialize an entire large playlist."""
        with self._connection() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise KeyError(job_id)
            job = dict(row)
            job["spec"] = json.loads(job["spec"])
            job["error"] = json.loads(job["error"]) if job["error"] else None
            job["counts"] = {row[0]: row[1] for row in db.execute("SELECT status,COUNT(*) FROM items WHERE job_id=? GROUP BY status", (job_id,))}
            job["total_items"] = sum(job["counts"].values())
            job["items"] = [self._item(row) for row in db.execute("SELECT * FROM items WHERE job_id=? ORDER BY position LIMIT ? OFFSET ?", (job_id, limit, offset))]
            job["offset"] = offset
            job["next_offset"] = offset + limit if limit and offset + limit < job["total_items"] else None
            return job

    def item(self, job_id, item_id):
        with self._connection() as db:
            row = db.execute("SELECT * FROM items WHERE id=? AND job_id=?", (item_id, job_id)).fetchone()
            return self._item(row) if row else None

    def update_job(self, job_id, status, error=None):
        with self._connection() as db:
            db.execute("UPDATE jobs SET status=?,error=?,updated_at=? WHERE id=?",
                       (status, json.dumps(error) if error else None, time.time(), job_id))

    def update_item(self, item_id, **changes):
        allowed = {"status", "metadata", "progress", "error", "artifact_key", "output_path", "result", "attempts"}
        if not changes or not set(changes) <= allowed:
            raise ValueError("Invalid item update")
        for name in ("metadata", "progress", "error", "result"):
            if name in changes:
                changes[name] = json.dumps(changes[name], allow_nan=False) if changes[name] is not None else None
        changes["updated_at"] = time.time()
        with self._connection() as db:
            db.execute("UPDATE items SET " + ",".join(f"{key}=?" for key in changes) + " WHERE id=?",
                       (*changes.values(), item_id))

    def expand_item(self, item_id, entries):
        with self._connection() as db:
            item = db.execute("SELECT * FROM items WHERE id=?", (item_id,)).fetchone()
            if not entries:
                db.execute("UPDATE items SET status='skipped',progress=?,updated_at=? WHERE id=?",
                           (json.dumps({"phase": "completed", "reason": "empty_playlist"}), time.time(), item_id))
                return
            ordered = [row[0] for row in db.execute("SELECT id FROM items WHERE job_id=? ORDER BY position", (item["job_id"],))]
            index = ordered.index(item_id)
            db.execute("UPDATE items SET position=-position WHERE job_id=?", (item["job_id"],))
            children = []
            for number, entry in enumerate(entries):
                child_id = item_id if number == 0 else str(uuid.uuid4())
                data = (entry.get("status", "pending"), json.dumps(entry["source"]), json.dumps(entry.get("metadata", {})),
                        json.dumps(entry["error"]) if entry.get("error") else None, time.time())
                if number == 0:
                    db.execute("UPDATE items SET status=?,source=?,metadata=?,error=?,updated_at=?,attempts=0,progress='{}' WHERE id=?", (*data, child_id))
                else:
                    db.execute("INSERT INTO items(id,job_id,position,status,source,metadata,error,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                               (child_id, item["job_id"], -(len(ordered) + number + 1), *data))
                children.append(child_id)
            ordered[index:index + 1] = children
            for position, child_id in enumerate(ordered, 1):
                db.execute("UPDATE items SET position=? WHERE id=?", (position, child_id))

    def request_cancel(self, job_id):
        with self._connection() as db:
            row = db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise KeyError(job_id)
            if row[0] not in {"queued", "running", "expanding"}:
                return
            db.execute("UPDATE jobs SET cancel_requested=1,updated_at=? WHERE id=?", (time.time(), job_id))
            if row[0] == "queued":
                db.execute("UPDATE items SET status='cancelled',updated_at=? WHERE job_id=? AND status='pending'", (time.time(), job_id))
            db.execute("UPDATE jobs SET status='cancelled' WHERE id=? AND status='queued'", (job_id,))

    def cancelled(self, job_id):
        with self._connection() as db:
            row = db.execute("SELECT cancel_requested FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise KeyError(job_id)
            return bool(row[0])

    def retry(self, job_id, item_ids=None):
        if item_ids is not None:
            item_ids = set(item_ids)
        job = self.get(job_id)
        if job["status"] in {"running", "expanding"}:
            raise ValueError("Cannot retry a running job")
        if item_ids is not None and not set(item_ids) <= {item["id"] for item in job["items"]}:
            raise ValueError("Unknown item ID")
        with self._connection() as db:
            for item in job["items"]:
                if item["status"] in {"failed", "cancelled", "interrupted", "unavailable"} and (item_ids is None or item["id"] in item_ids):
                    db.execute("UPDATE items SET status='pending',error=NULL,progress='{}',updated_at=? WHERE id=?", (time.time(), item["id"]))
            db.execute("UPDATE jobs SET status='queued',cancel_requested=0,error=NULL,updated_at=? WHERE id=?", (time.time(), job_id))
        return self.get(job_id)

    def recover_interrupted(self):
        """Caller must hold the exclusive worker lock, never recover a live worker."""
        with self._connection() as db:
            db.execute("UPDATE items SET status='interrupted',updated_at=? WHERE status IN ('downloading','converting','validating')", (time.time(),))
            db.execute("UPDATE jobs SET status='interrupted',updated_at=? WHERE status IN ('running','expanding')", (time.time(),))

    def artifact(self, key):
        with self._connection() as db:
            row = db.execute("SELECT result FROM artifacts WHERE key=? AND valid=1", (key,)).fetchone()
            return json.loads(row[0]) if row else None

    def invalidate_artifact(self, key):
        with self._connection() as db:
            db.execute("UPDATE artifacts SET valid=0 WHERE key=?", (key,))

    def complete(self, item_id, key, result, reused=False):
        encoded = json.dumps(result, allow_nan=False)
        with self._connection() as db:
            db.execute("INSERT INTO artifacts(key,result,valid,updated_at) VALUES(?,?,1,?) ON CONFLICT(key) DO UPDATE SET result=excluded.result,valid=1,updated_at=excluded.updated_at",
                       (key, encoded, time.time()))
            db.execute("UPDATE items SET status=?,result=?,output_path=?,error=NULL,progress=?,updated_at=? WHERE id=?",
                       ("reused" if reused else "completed", encoded, result["path"], json.dumps({"phase": "completed", "fraction": 1.0}), time.time(), item_id))
