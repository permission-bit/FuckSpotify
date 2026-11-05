"""HTTPS-only, private-network FastAPI API. No public download/static mounts."""

import asyncio
import base64
import re
import time
from collections import deque
from contextlib import asynccontextmanager
from typing import Literal
from urllib.parse import quote
from uuid import UUID

from fastapi import Depends, FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator

from companion_security import SecurityError, local_address
from companion_service import CompanionService
from converter_core import normalize_quality

MAX_REQUEST_BYTES = 131072


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_max_length=500)


class PairRequest(StrictModel):
    secret: str = Field(min_length=32, max_length=128)


class SourceRequest(StrictModel):
    kind: Literal["youtube_video", "youtube_playlist", "asset"]
    id: str = Field(min_length=1, max_length=128)
    authorized: StrictBool
    metadata: dict[str, str] = Field(default_factory=dict, max_length=4)

    @model_validator(mode="after")
    def validate_source(self):
        if self.authorized is not True:
            raise ValueError("Explicit source authorization is required")
        if self.kind == "youtube_video" and not re.fullmatch(r"[A-Za-z0-9_-]{11}", self.id):
            raise ValueError("Invalid video ID")
        if self.kind == "youtube_playlist" and not re.fullmatch(r"[A-Za-z0-9_-]{10,128}", self.id):
            raise ValueError("Invalid playlist ID")
        if self.kind == "asset":
            self.id = str(UUID(self.id))
        if not set(self.metadata) <= {"title", "artist", "album", "genre"} or any(len(value) > 500 or any(ord(c) < 32 for c in value) for value in self.metadata.values()):
            raise ValueError("Invalid metadata")
        return self


class JobRequest(StrictModel):
    sources: list[SourceRequest] = Field(min_length=1, max_length=1000)
    quality: str = Field(default="192K", max_length=4)
    request_id: UUID | None = None

    @model_validator(mode="after")
    def source_limit(self):
        if len(self.sources) > 100 and any(source.kind != "asset" for source in self.sources):
            raise ValueError("At most 100 remote sources or 1000 registered local files")
        return self

    @field_validator("quality")
    @classmethod
    def quality_value(cls, value):
        return normalize_quality(value)


class RetryRequest(StrictModel):
    item_ids: list[UUID] | None = Field(default=None, min_length=1, max_length=1000)


class VerifiedStreamingResponse(StreamingResponse):
    """Release the descriptor/slot even if the client disconnects at headers."""
    def __init__(self, verified, start, length, **kwargs):
        self.verified = verified
        super().__init__(verified.chunks(start, length), **kwargs)

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            self.verified.close()


class LocalTLSMiddleware:
    def __init__(self, app, config):
        self.app, self.config = app, config
        self.rates = {}

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        async def reject(status, code):
            await JSONResponse({"error": {"code": code}}, status_code=status, headers={"Cache-Control": "no-store"})(scope, receive, send)
        peer = scope.get("client", ("", 0))[0]
        if not local_address(peer):
            await reject(403, "local_network_only"); return
        if scope.get("scheme") != "https":
            await reject(426, "tls_required"); return
        headers = {key.lower(): value for key, value in scope["headers"]}
        host = headers.get(b"host", b"").decode("ascii", errors="replace")
        hosts = {self.config.host, f"{self.config.host}:{self.config.port}"}
        if self.config.host.startswith("127."):
            hosts |= {"localhost", f"localhost:{self.config.port}"}
        if host not in hosts or b"origin" in headers:
            await reject(403, "invalid_origin_or_host"); return
        now = time.monotonic()
        bucket = (peer, scope["path"] == "/v1/pair")
        if len(self.rates) > 4096:
            self.rates = {key: values for key, values in self.rates.items() if values and values[-1] > now - 60}
            if len(self.rates) > 4096:
                await reject(429, "rate_limit"); return
        values = self.rates.setdefault(bucket, deque())
        while values and values[0] <= now - 60:
            values.popleft()
        if len(values) >= (5 if bucket[1] else 120):
            await reject(429, "rate_limit"); return
        values.append(now)
        if len(scope.get("query_string", b"")) > 2048 or len(headers.get(b"authorization", b"")) > 512 or len(headers.get(b"range", b"")) > 128:
            await reject(400, "header_limit"); return
        try:
            length = int(headers.get(b"content-length", b"0"))
        except ValueError:
            await reject(400, "invalid_length"); return
        if length < 0 or length > MAX_REQUEST_BYTES:
            await reject(413, "request_too_large"); return
        body = bytearray()
        deadline = now + 10
        try:
            while True:
                event = await asyncio.wait_for(receive(), timeout=max(0.001, deadline - time.monotonic()))
                if event["type"] == "http.disconnect":
                    return
                body.extend(event.get("body", b""))
                if len(body) > MAX_REQUEST_BYTES:
                    await reject(413, "request_too_large"); return
                if not event.get("more_body", False):
                    break
        except TimeoutError:
            await reject(408, "request_timeout"); return
        replayed = False
        async def replay():
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()
        async def private_send(event):
            if event["type"] == "http.response.start":
                event["headers"] = [*event.get("headers", []), (b"cache-control", b"no-store"), (b"x-content-type-options", b"nosniff")]
            await send(event)
        await self.app(scope, replay, private_send)


def create_app(config, service=None):
    service = service or CompanionService(config)
    @asynccontextmanager
    async def lifespan(app):
        service.start()
        try:
            display = getattr(app.state, "pairing_display", None)
            if display is not None:
                display.start()
            yield
        finally:
            display = getattr(app.state, "pairing_display", None)
            if display is not None:
                await asyncio.to_thread(display.stop)
            await asyncio.to_thread(service.close)
    app = FastAPI(title="OfflineMusic local companion", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.service = service
    app.add_middleware(LocalTLSMiddleware, config=config)
    bearer = HTTPBearer(auto_error=False)

    @app.exception_handler(SecurityError)
    async def security_error(request, error):
        headers = {"WWW-Authenticate": "Bearer"} if error.status == 401 else {"Retry-After": "60"} if error.status == 429 else None
        return JSONResponse({"error": {"code": error.code}}, status_code=error.status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        # Do not echo request bodies, bearer tokens or pairing secrets.
        return JSONResponse({"error": {"code": "invalid_request", "fields": [list(entry["loc"]) for entry in error.errors()]}}, status_code=422)

    @app.exception_handler(Exception)
    async def internal_error(request, error):
        return JSONResponse({"error": {"code": "internal_error"}}, status_code=500)

    def device(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        return service.security.authenticate(credentials.credentials if credentials else None)

    def snapshot(device_id, job_id, limit=100, offset=0):
        service.security.owns(device_id, job_id)
        return service.public_job(service.converter.store.snapshot(job_id, limit, offset))

    @app.post("/v1/pair")
    def pair(body: PairRequest):
        return {**service.security.pair(body.secret), "server_certificate_sha256": config.fingerprint}

    @app.get("/v1/health")
    @app.get("/v1/status")
    def health(current=Depends(device)):
        return {"status": "ok", "api_version": 1, "device_id": current["id"], "worker_limit": 1,
                "worker_running": bool(service.thread and service.thread.is_alive())}

    @app.get("/v1/device")
    def identity(current=Depends(device)):
        return current

    @app.delete("/v1/device", status_code=204)
    def revoke(current=Depends(device)):
        service.security.revoke(current["id"])
        return Response(status_code=204)

    @app.post("/v1/jobs", status_code=202)
    def create_job(body: JobRequest, limit: int = Query(100, ge=1, le=200), current=Depends(device)):
        job = service.submit(current["id"], body)
        return snapshot(current["id"], job["id"], limit)

    @app.get("/v1/assets")
    def assets(limit: int = Query(50, ge=1, le=100), offset: int = Query(0, ge=0, le=2147483647), current=Depends(device)):
        entries = service.assets(current["id"], limit + 1, offset)
        return {"assets": entries[:limit], "next_offset": offset + limit if len(entries) > limit else None}

    @app.get("/v1/jobs")
    def jobs(limit: int = Query(20, ge=1, le=50), offset: int = Query(0, ge=0), current=Depends(device)):
        return {"jobs": [snapshot(current["id"], job_id, 0) for job_id in service.security.owned_ids(current["id"], limit, offset)], "offset": offset}

    @app.get("/v1/deliveries")
    def deliveries(after: int = Query(0, ge=0, le=9223372036854775807), limit: int = Query(10, ge=1, le=20), current=Depends(device)):
        rows = service.security.deliveries(current["id"], after, limit)
        entries, summaries = [], {}
        for row in rows:
            job_id = row["job_id"]
            if job_id not in summaries:
                summaries[job_id] = snapshot(current["id"], job_id, 0)
            item = service.converter.store.item(job_id, row["item_id"])
            if item and item["status"] in {"completed", "reused"} and item["result"]:
                job = service.converter.store.snapshot(job_id, 0)
                job["items"] = [item]
                entries.append({"sequence": row["sequence"], "job": summaries[job_id],
                                "item": service.public_job(job)["items"][0]})
        return {"deliveries": entries, "next_after": rows[-1]["sequence"] if rows else after,
                "has_more": len(rows) == limit}

    @app.get("/v1/jobs/{job_id}")
    def job(job_id: UUID, limit: int = Query(100, ge=1, le=200), offset: int = Query(0, ge=0), current=Depends(device)):
        return snapshot(current["id"], str(job_id), limit, offset)

    @app.get("/v1/jobs/{job_id}/progress")
    def progress(job_id: UUID, limit: int = Query(100, ge=1, le=200), offset: int = Query(0, ge=0), current=Depends(device)):
        result = snapshot(current["id"], str(job_id), limit, offset)
        result["items"] = [{key: item[key] for key in ("id", "position", "status", "progress", "error")} for item in result["items"]]
        return result

    @app.post("/v1/jobs/{job_id}/cancel")
    def cancel(job_id: UUID, limit: int = Query(100, ge=1, le=200), current=Depends(device)):
        service.security.owns(current["id"], str(job_id))
        service.converter.cancel(str(job_id))
        return snapshot(current["id"], str(job_id), limit)

    @app.post("/v1/jobs/{job_id}/retry", status_code=202)
    def retry(job_id: UUID, body: RetryRequest, limit: int = Query(100, ge=1, le=200), current=Depends(device)):
        service.security.retry(current["id"], str(job_id), None if body.item_ids is None else [str(item) for item in body.item_ids])
        service.wakeup.set()
        return snapshot(current["id"], str(job_id), limit)

    @app.get("/v1/jobs/{job_id}/items/{item_id}/metadata")
    def metadata(job_id: UUID, item_id: UUID, current=Depends(device)):
        verified = service.verified_file(current["id"], str(job_id), str(item_id))
        try:
            return service.public_result(verified.result)
        finally:
            verified.close()

    @app.api_route("/v1/jobs/{job_id}/items/{item_id}/file", methods=["GET", "HEAD"])
    def download(job_id: UUID, item_id: UUID, request: Request, current=Depends(device)):
        verified = service.verified_file(current["id"], str(job_id), str(item_id))
        size = verified.result["size"]
        checksum = verified.result["sha256"]
        etag = f'"{checksum}"'
        start, end, status = 0, size - 1, 200
        range_header = request.headers.get("range")
        if range_header and request.headers.get("if-range", etag) == etag:
            match = re.fullmatch(r"bytes=(\d{0,20})-(\d{0,20})", range_header)
            if not match or not any(match.groups()):
                verified.close(); raise SecurityError(416, "invalid_range")
            left, right = match.groups()
            if left:
                start = int(left)
                end = min(int(right), size - 1) if right else size - 1
            else:
                start = max(0, size - int(right))
            if start > end or start >= size:
                verified.close(); raise SecurityError(416, "invalid_range")
            status = 206
        representation_digest = "sha-256=:" + base64.b64encode(bytes.fromhex(checksum)).decode() + ":"
        headers = {"Content-Length": str(end - start + 1), "Accept-Ranges": "bytes", "ETag": etag,
                   "X-Content-SHA256": checksum, "Repr-Digest": representation_digest,
                   "Content-Disposition": "attachment; filename=audio.mp3; filename*=UTF-8''" + quote(verified.name, safe="")}
        if status == 200:
            headers["Content-Digest"] = representation_digest
        if status == 206:
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        if request.method == "HEAD":
            verified.close()
            return Response(status_code=status, headers=headers, media_type="audio/mpeg")
        return VerifiedStreamingResponse(verified, start, end - start + 1, status_code=status, headers=headers,
                                         media_type="audio/mpeg")
    return app
