#!/usr/bin/env python3
"""
AuraWall E2E Support Library & Mock HTTP Server (Python 3.9.6 stdlib only).

Provides:
- ThreadingHTTPServer simulating Apple Aerials (2x, resources-16.tar, phobos),
  Wallhaven v1, Pexels v1, Pixabay, Custom JSON feeds, and /media/* with Range/206.
- Standalone `--serve --ready-file <path>` mode for scripts/e2e_run.sh & SwiftE2E.
- Bundle, Info.plist, Mach-O arm64, codesign, media fixture, and isolated
  CFFIXED_USER_HOME app launch + SIGTERM verification helpers.
"""

import argparse
import io
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


E2E_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = E2E_DIR.parent.parent


def get_fixtures_dir() -> Path:
    env_dir = os.environ.get("AURAWALL_E2E_FIXTURES_DIR")
    if env_dir:
        return Path(env_dir).resolve()
    return (E2E_DIR / "fixtures").resolve()


def get_media_dir() -> Path:
    return get_fixtures_dir() / "media"


def get_e2e_mode() -> str:
    mode = os.environ.get("AURAWALL_E2E_MODE", "pre-bundle").strip().lower()
    return mode if mode in ("pre-bundle", "full") else "pre-bundle"


def is_live_enabled() -> bool:
    return os.environ.get("AURAWALL_E2E_NO_LIVE", "0").strip() != "1"


def _mime_for_filename(name: str) -> str:
    ext = Path(name).suffix.lower()
    return {
        ".mp4": "video/mp4",
        ".mov": "video/quicktime",
        ".m4v": "video/x-m4v",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".heic": "image/heic",
        ".json": "application/json",
        ".tar": "application/octet-stream",
        ".svg": "image/svg+xml",
        ".txt": "text/plain; charset=utf-8",
    }.get(ext, "application/octet-stream")


class _MockServerState:
    def __init__(self, fixtures_dir: Path) -> None:
        self.fixtures_dir = fixtures_dir
        self.media_dir = fixtures_dir / "media"
        self.base_url: str = ""
        self._lock = threading.Lock()
        self.requests: List[Dict[str, Any]] = []

    def record_request(
        self,
        method: str,
        path: str,
        query: Dict[str, List[str]],
        headers: Dict[str, str],
    ) -> None:
        with self._lock:
            self.requests.append(
                {
                    "method": method,
                    "path": path,
                    "query": query,
                    "headers": {k.lower(): v for k, v in headers.items()},
                }
            )

    def get_requests(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self.requests)

    def clear_requests(self) -> None:
        with self._lock:
            self.requests.clear()

    def load_fixture_text(self, filename: str) -> str:
        text = (self.fixtures_dir / filename).read_text(encoding="utf-8")
        if self.base_url:
            text = text.replace("https://mock.aurawall.local", self.base_url)
        return text

    def load_fixture_json(self, filename: str) -> Any:
        return json.loads(self.load_fixture_text(filename))

    def build_resources_16_tar(self) -> bytes:
        entries_bytes = self.load_fixture_text("aerial_r16_entries.json").encode("utf-8")
        seal_path = self.media_dir / "seal.jpg"
        seal_bytes = seal_path.read_bytes() if seal_path.is_file() else b"\xff\xd8\xff\xd9"

        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
            entries_info = tarfile.TarInfo(name="entries.json")
            entries_info.size = len(entries_bytes)
            entries_info.mode = 0o644
            entries_info.mtime = 1700000000
            tf.addfile(entries_info, io.BytesIO(entries_bytes))

            snap_info = tarfile.TarInfo(name="snapshots/seal.jpg")
            snap_info.size = len(seal_bytes)
            snap_info.mode = 0o644
            snap_info.mtime = 1700000000
            tf.addfile(snap_info, io.BytesIO(seal_bytes))
        return buf.getvalue()


def _make_handler(state: _MockServerState):
    class MockAuraWallHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:
            # Suppress noisy stderr logs during unittest runs.
            return

        def _send_bytes(
            self,
            status: int,
            content_type: str,
            body: bytes,
            extra_headers: Optional[Dict[str, str]] = None,
            head_only: bool = False,
        ) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            if extra_headers:
                for k, v in extra_headers.items():
                    self.send_header(k, v)
            self.end_headers()
            if not head_only and body:
                self.wfile.write(body)

        def _send_json(
            self,
            status: int,
            payload: Any,
            extra_headers: Optional[Dict[str, str]] = None,
            head_only: bool = False,
        ) -> None:
            raw = json.dumps(payload).encode("utf-8")
            self._send_bytes(status, "application/json", raw, extra_headers, head_only=head_only)

        def do_POST(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            state.record_request("POST", parsed.path, query, dict(self.headers))
            if parsed.path == "/_e2e/requests/reset":
                state.clear_requests()
                self._send_json(200, {"cleared": True})
                return
            self._send_json(404, {"error": "Not Found"})

        def do_HEAD(self) -> None:
            self._handle_get(head_only=True)

        def do_GET(self) -> None:
            self._handle_get(head_only=False)

        def _handle_get(self, head_only: bool) -> None:
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            headers = dict(self.headers)
            state.record_request("HEAD" if head_only else "GET", path, query, headers)

            # Diagnostics
            if path == "/_e2e/health":
                self._send_json(200, {"status": "ok", "base_url": state.base_url}, head_only=head_only)
                return
            if path == "/_e2e/requests":
                self._send_json(200, state.get_requests(), head_only=head_only)
                return

            # Apple Aerials
            if path == "/aerials/2x/entries.json":
                raw = state.load_fixture_text("aerial_2x_entries.json").encode("utf-8")
                self._send_bytes(200, "application/json", raw, head_only=head_only)
                return
            if path == "/aerials/resources-16.tar":
                tar_bytes = state.build_resources_16_tar()
                self._send_bytes(200, "application/octet-stream", tar_bytes, head_only=head_only)
                return
            if path == "/aerials/phobos/entries.json":
                raw = state.load_fixture_text("aerial_phobos_array.json").encode("utf-8")
                self._send_bytes(200, "application/json", raw, head_only=head_only)
                return
            if path.startswith("/aerials/missing/"):
                self._send_json(
                    404,
                    {"httpStatusCode": 404, "traceKey": "e2e-missing-asset"},
                    head_only=head_only,
                )
                return

            # Wallhaven v1
            if path == "/wallhaven/api/v1/search":
                page_raw = query.get("page", ["1"])[0]
                try:
                    page_num = int(page_raw)
                except ValueError:
                    page_num = -1
                q_values = query.get("q")
                q_val = q_values[0] if q_values is not None else None
                if page_num <= 0 or q_val == "error500":
                    self._send_bytes(
                        500,
                        "text/html; charset=UTF-8",
                        b"<html><head><title>500</title></head><body><h1>It broke - wallhaven.cc</h1></body></html>",
                        head_only=head_only,
                    )
                    return

                apikey = query.get("apikey", [""])[0] or self.headers.get("X-API-Key", "")
                if apikey == "invalid_key_123":
                    self._send_json(401, {"error": "Unauthorized"}, head_only=head_only)
                    return

                if q_val == "ratelimit":
                    self._send_bytes(
                        429,
                        "text/plain; charset=utf-8",
                        b"Too Many Requests",
                        extra_headers={
                            "Retry-After": "60",
                            "x-ratelimit-limit": "45",
                            "x-ratelimit-remaining": "0",
                        },
                        head_only=head_only,
                    )
                    return

                purity = query.get("purity", ["100"])[0]
                if purity == "001" and not apikey:
                    self._send_json(
                        200,
                        {
                            "data": [],
                            "meta": {
                                "current_page": page_num,
                                "last_page": 1,
                                "per_page": 24,
                                "total": 0,
                                "query": q_val,
                                "seed": None,
                            },
                        },
                        extra_headers={"x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"},
                        head_only=head_only,
                    )
                    return

                if q_val == "id:37":
                    payload = state.load_fixture_json("wallhaven_tag_object_query.json")
                else:
                    payload = state.load_fixture_json("wallhaven_string_query.json")
                    payload["meta"]["query"] = q_val
                    if query.get("sorting", [""])[0] == "random":
                        payload["meta"]["seed"] = "uwn0FK"
                payload["meta"]["current_page"] = page_num
                self._send_json(
                    200,
                    payload,
                    extra_headers={"x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"},
                    head_only=head_only,
                )
                return

            if path.startswith("/wallhaven/api/v1/w/"):
                wid = path.rsplit("/", 1)[-1]
                known = {}
                for fname in ("wallhaven_string_query.json", "wallhaven_tag_object_query.json"):
                    for item in state.load_fixture_json(fname)["data"]:
                        known[item["id"]] = item
                if wid in known:
                    detail = dict(known[wid])
                    detail["uploader"] = {
                        "username": "aurawall_artist",
                        "group": "User",
                        "avatar": {"200px": f"{state.base_url}/media/sample_image.jpg"},
                    }
                    detail["tags"] = [
                        {
                            "id": 37,
                            "name": "nature",
                            "alias": "",
                            "category_id": 1,
                            "category": "Nature",
                            "purity": "sfw",
                            "created_at": "2025-01-01 00:00:00",
                        }
                    ]
                    self._send_json(200, {"data": detail}, head_only=head_only)
                else:
                    self._send_json(404, {"error": "Wallpaper not found"}, head_only=head_only)
                return

            # Pexels v1
            if path in (
                "/pexels/v1/videos/search",
                "/pexels/v1/videos/popular",
                "/pexels/videos/popular",
                "/pexels/videos/search",
                "/pexels/v1/search",
                "/pexels/v1/curated",
            ):
                auth = self.headers.get("Authorization", "")
                if not auth or auth.startswith("Bearer ") or auth == "invalid_key_123":
                    raw_401 = state.load_fixture_text("pexels_401.json").encode("utf-8")
                    self._send_bytes(401, "application/json; charset=utf-8", raw_401, head_only=head_only)
                    return

                q_val = query.get("query", [""])[0]
                if q_val == "ratelimit":
                    self._send_json(
                        429,
                        {"status": 429, "code": "Too Many Requests", "message": "Rate limit exceeded"},
                        extra_headers={
                            "X-Ratelimit-Limit": "200",
                            "X-Ratelimit-Remaining": "0",
                            "Retry-After": "60",
                        },
                        head_only=head_only,
                    )
                    return

                fixture = (
                    "pexels_videos_search.json"
                    if "videos" in path
                    else "pexels_photos_curated.json"
                )
                raw = state.load_fixture_text(fixture).encode("utf-8")
                self._send_bytes(
                    200,
                    "application/json",
                    raw,
                    extra_headers={
                        "X-Ratelimit-Limit": "200",
                        "X-Ratelimit-Remaining": "199",
                        "X-Ratelimit-Reset": "1795644000",
                    },
                    head_only=head_only,
                )
                return

            # Pixabay
            if path in ("/pixabay/api/videos/", "/pixabay/api/videos", "/pixabay/api/", "/pixabay/api"):
                key = query.get("key", [""])[0]
                if not key or key == "invalid_key_123":
                    self._send_bytes(
                        400,
                        "text/html; charset=utf-8",
                        b"[ERROR 400] Invalid or missing API key (https://pixabay.com/api/docs/).",
                        head_only=head_only,
                    )
                    return
                q_val = query.get("q", [""])[0]
                if q_val == "ratelimit":
                    self._send_bytes(
                        429,
                        "text/html; charset=utf-8",
                        b"API rate limit exceeded",
                        extra_headers={
                            "X-RateLimit-Limit": "100",
                            "X-RateLimit-Remaining": "0",
                            "Retry-After": "60",
                        },
                        head_only=head_only,
                    )
                    return

                fixture = "pixabay_videos.json" if "videos" in path else "pixabay_photos.json"
                raw = state.load_fixture_text(fixture).encode("utf-8")
                self._send_bytes(
                    200,
                    "application/json",
                    raw,
                    extra_headers={
                        "X-RateLimit-Limit": "100",
                        "X-RateLimit-Remaining": "99",
                        "X-RateLimit-Reset": "60",
                    },
                    head_only=head_only,
                )
                return

            # Custom JSON Feeds
            custom_map = {
                "/custom/wrapped.json": "custom_feed_wrapped.json",
                "/custom/array.json": "custom_feed_array.json",
                "/custom/empty.json": "custom_feed_empty.json",
                "/custom/malformed.json": "custom_feed_malformed.json",
            }
            if path in custom_map:
                raw = state.load_fixture_text(custom_map[path]).encode("utf-8")
                self._send_bytes(200, "application/json", raw, head_only=head_only)
                return
            if path == "/custom/error500.html":
                self._send_bytes(
                    500,
                    "text/html; charset=utf-8",
                    b"<html><body><h1>500 Internal Server Error</h1></body></html>",
                    head_only=head_only,
                )
                return

            # Media files with Accept-Ranges & 206 Partial Content
            if path.startswith("/media/"):
                filename = Path(path[len("/media/"):]).name
                if filename == "not_found.mp4":
                    self._send_json(404, {"error": "Media not found"}, head_only=head_only)
                    return
                if filename == "broken_500.mp4":
                    self._send_bytes(
                        500,
                        "text/plain; charset=utf-8",
                        b"Internal Server Error",
                        head_only=head_only,
                    )
                    return

                file_path = state.media_dir / filename
                if not file_path.is_file():
                    self._send_json(404, {"error": "Media not found"}, head_only=head_only)
                    return

                data = file_path.read_bytes()
                total = len(data)
                mime = _mime_for_filename(filename)
                range_hdr = self.headers.get("Range")

                if range_hdr and total > 0:
                    m = re.match(r"^bytes=(\d*)-(\d*)$", range_hdr.strip())
                    if not m or (m.group(1) == "" and m.group(2) == ""):
                        self._send_bytes(
                            416,
                            "text/plain; charset=utf-8",
                            b"Range Not Satisfiable",
                            extra_headers={"Content-Range": f"bytes */{total}"},
                            head_only=head_only,
                        )
                        return
                    start_s, end_s = m.group(1), m.group(2)
                    if start_s == "":
                        suffix_len = int(end_s)
                        start = max(0, total - suffix_len)
                        end = total - 1
                    else:
                        start = int(start_s)
                        end = int(end_s) if end_s != "" else total - 1
                    if start > end or start >= total:
                        self._send_bytes(
                            416,
                            "text/plain; charset=utf-8",
                            b"Range Not Satisfiable",
                            extra_headers={"Content-Range": f"bytes */{total}"},
                            head_only=head_only,
                        )
                        return
                    end = min(end, total - 1)
                    chunk = data[start : end + 1]
                    self._send_bytes(
                        206,
                        mime,
                        chunk,
                        extra_headers={
                            "Accept-Ranges": "bytes",
                            "Content-Range": f"bytes {start}-{end}/{total}",
                        },
                        head_only=head_only,
                    )
                    return

                self._send_bytes(
                    200,
                    mime,
                    data,
                    extra_headers={"Accept-Ranges": "bytes"},
                    head_only=head_only,
                )
                return

            self._send_json(404, {"error": f"Unknown E2E route: {path}"}, head_only=head_only)

    return MockAuraWallHandler


class MockAuraWallServer:
    def __init__(self, fixtures_dir: Optional[Path] = None, port: int = 0) -> None:
        self.fixtures_dir = (fixtures_dir or get_fixtures_dir()).resolve()
        self.state = _MockServerState(self.fixtures_dir)
        self._port = port
        self._httpd: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None

    @property
    def base_url(self) -> str:
        return self.state.base_url

    @property
    def requests(self) -> List[Dict[str, Any]]:
        return self.state.get_requests()

    def clear_requests(self) -> None:
        self.state.clear_requests()

    def start(self) -> "MockAuraWallServer":
        if self._httpd is not None:
            return self
        handler_cls = _make_handler(self.state)
        self._httpd = ThreadingHTTPServer(("127.0.0.1", self._port), handler_cls)
        actual_port = self._httpd.server_address[1]
        self.state.base_url = f"http://127.0.0.1:{actual_port}"
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def __enter__(self) -> "MockAuraWallServer":
        return self.start()

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.stop()


def http_request(
    url: str,
    method: str = "GET",
    headers: Optional[Dict[str, str]] = None,
    timeout: float = 15.0,
) -> Tuple[int, Dict[str, str], bytes]:
    req_headers = {"User-Agent": "AuraWall-E2E/1.0"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
            body = b"" if method == "HEAD" else resp.read()
            return resp.status, resp_headers, body
    except urllib.error.HTTPError as err:
        resp_headers = {k.lower(): v for k, v in err.headers.items()} if err.headers else {}
        body = b"" if method == "HEAD" else err.read()
        return err.code, resp_headers, body


# ---------------------------------------------------------------------------
# Bundle, Plist, Mach-O, Codesign, Media & App Launch Helpers
# ---------------------------------------------------------------------------


def validate_plist(plist_path: Path) -> Dict[str, Any]:
    if not plist_path.is_file():
        raise AssertionError(f"Info.plist not found at {plist_path}")

    lint = subprocess.run(
        ["/usr/bin/plutil", "-lint", str(plist_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if lint.returncode != 0:
        raise AssertionError(f"plutil -lint failed for {plist_path}: {lint.stdout} {lint.stderr}")

    with plist_path.open("rb") as fh:
        data = plistlib.load(fh)

    if data.get("CFBundleExecutable") != "AuraWall":
        raise AssertionError(f"Expected CFBundleExecutable == 'AuraWall', got {data.get('CFBundleExecutable')!r}")

    min_ver = str(data.get("LSMinimumSystemVersion", ""))
    parts = [int(p) for p in re.findall(r"\d+", min_ver)]
    if not parts or parts[0] < 14:
        raise AssertionError(f"LSMinimumSystemVersion must be >= 14.0, got {min_ver!r}")

    def _check_no_placeholders(obj: Any, path_str: str = "") -> None:
        if isinstance(obj, str):
            if "$(" in obj or "${" in obj:
                raise AssertionError(f"Unresolved placeholder in Info.plist at {path_str}: {obj!r}")
        elif isinstance(obj, dict):
            for k, v in obj.items():
                _check_no_placeholders(v, f"{path_str}.{k}" if path_str else str(k))
        elif isinstance(obj, list):
            for idx, item in enumerate(obj):
                _check_no_placeholders(item, f"{path_str}[{idx}]")

    _check_no_placeholders(data)

    ats = data.get("NSAppTransportSecurity")
    if isinstance(ats, dict) and ats.get("NSAllowsArbitraryLoads") is True:
        raise AssertionError("NSAllowsArbitraryLoads must not be true globally in Info.plist")

    return data


def validate_macho_arm64(binary_path: Path) -> Dict[str, str]:
    if not binary_path.is_file():
        raise AssertionError(f"Executable not found: {binary_path}")
    if not os.access(binary_path, os.X_OK):
        raise AssertionError(f"Binary is not executable: {binary_path}")

    lipo_res = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(binary_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if lipo_res.returncode != 0 or "arm64" not in lipo_res.stdout.split():
        raise AssertionError(f"lipo -archs did not report arm64: rc={lipo_res.returncode} out={lipo_res.stdout!r} err={lipo_res.stderr!r}")

    file_res = subprocess.run(
        ["/usr/bin/file", "-b", str(binary_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if file_res.returncode != 0 or "Mach-O" not in file_res.stdout or "arm64" not in file_res.stdout:
        raise AssertionError(f"file did not report arm64 Mach-O: {file_res.stdout!r}")

    return {"lipo": lipo_res.stdout.strip(), "file": file_res.stdout.strip()}


def validate_codesign(app_path: Path) -> str:
    if not app_path.is_dir():
        raise AssertionError(f"App bundle not found: {app_path}")
    res = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        raise AssertionError(f"codesign --verify failed: rc={res.returncode} out={res.stdout} err={res.stderr}")
    return (res.stdout + "\n" + res.stderr).strip()


def validate_media_file(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        raise AssertionError(f"Media fixture missing: {path}")
    size = path.stat().st_size
    if size <= 0:
        raise AssertionError(f"Media file is empty: {path}")
    file_res = subprocess.run(
        ["/usr/bin/file", "-b", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    info: Dict[str, Any] = {"size": size, "file": file_res.stdout.strip()}
    ext = path.suffix.lower()
    if ext in (".mp4", ".mov", ".m4v"):
        if size < 32:
            raise AssertionError(f"Video media file too small ({size} bytes): {path}")
        if not any(tok in info["file"] for tok in ("MP4", "QuickTime", "ISO Media")):
            raise AssertionError(
                f"Expected MP4/QuickTime/ISO Media video container for {path}, got: {info['file']!r}"
            )
        raw_bytes = path.read_bytes()
        if len(raw_bytes) < 8 or raw_bytes[4:8] != b"ftyp":
            raise AssertionError(f"Video media file must begin with ftyp box: {path}")

        offset = 0
        total_len = len(raw_bytes)
        box_types = []
        moov_slices = []
        while offset < total_len:
            if offset + 8 > total_len:
                raise AssertionError(f"Truncated ISO BMFF box header at offset {offset}: {path}")
            box_size = int.from_bytes(raw_bytes[offset:offset + 4], "big")
            box_type = raw_bytes[offset + 4:offset + 8]
            if box_size == 1:
                if offset + 16 > total_len:
                    raise AssertionError(f"Truncated 64-bit ISO BMFF box header at offset {offset}: {path}")
                box_size = int.from_bytes(raw_bytes[offset + 8:offset + 16], "big")
                if box_size < 16:
                    raise AssertionError(f"Invalid 64-bit ISO BMFF box size ({box_size}) at offset {offset}: {path}")
            elif box_size == 0:
                box_size = total_len - offset
            elif box_size < 8:
                raise AssertionError(f"Invalid ISO BMFF box size ({box_size}) at offset {offset}: {path}")

            if offset + box_size > total_len:
                raise AssertionError(
                    f"Truncated ISO BMFF box {box_type!r} (size={box_size} at offset={offset}, file_size={total_len}): {path}"
                )
            box_types.append(box_type)
            if box_type == b"moov":
                moov_slices.append(raw_bytes[offset:offset + box_size])
            offset += box_size

        if b"moov" not in box_types or b"mdat" not in box_types:
            raise AssertionError(f"Video media file missing required moov and mdat boxes ({box_types}): {path}")
        if not any(b"trak" in m and b"vide" in m for m in moov_slices):
            raise AssertionError(f"Video media file moov box missing video track (trak/vide): {path}")
    elif ext in (".jpg", ".jpeg", ".png", ".heic"):
        if not any(tok in info["file"] for tok in ("JPEG", "PNG", "HEIF", "ISO Media")):
            raise AssertionError(
                f"Expected JPEG/PNG/HEIF image file for {path}, got: {info['file']!r}"
            )
        sips_res = subprocess.run(
            ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        info["sips_rc"] = sips_res.returncode
        info["sips"] = sips_res.stdout.strip()
        combined_sips = sips_res.stdout + "\n" + sips_res.stderr
        if (
            sips_res.returncode != 0
            or "not a valid file" in combined_sips
            or "format:" not in sips_res.stdout
        ):
            raise AssertionError(f"sips failed for {path}: {combined_sips.strip()}")
        w_match = re.search(r"pixelWidth:\s*(\d+)", sips_res.stdout)
        h_match = re.search(r"pixelHeight:\s*(\d+)", sips_res.stdout)
        if not w_match or not h_match:
            raise AssertionError(f"sips missing positive pixelWidth/pixelHeight for {path}: {sips_res.stdout!r}")
        width = int(w_match.group(1))
        height = int(h_match.group(1))
        if width <= 0 or height <= 0:
            raise AssertionError(f"Invalid image dimensions {width}x{height} for {path}")
        info["width"] = width
        info["height"] = height
    return info


def launch_app_and_verify_sigterm(
    app_path: Path,
    tmp_home: Path,
    startup_wait: float = 1.8,
    term_timeout: float = 5.0,
) -> Dict[str, Any]:
    binary = app_path / "Contents" / "MacOS" / "AuraWall"
    if not binary.is_file():
        raise AssertionError(f"Bundle executable missing: {binary}")

    (tmp_home / "Library" / "Application Support").mkdir(parents=True, exist_ok=True)
    (tmp_home / "Library" / "Caches").mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["CFFIXED_USER_HOME"] = str(tmp_home)
    env["HOME"] = str(tmp_home)

    proc = subprocess.Popen(
        [str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        start_new_session=True,
        text=True,
    )
    try:
        deadline = time.monotonic() + startup_wait
        while time.monotonic() < deadline:
            rc = proc.poll()
            if rc is not None:
                out, err = proc.communicate(timeout=1.0)
                raise AssertionError(
                    f"AuraWall exited prematurely (rc={rc}) during startup wait.\nstdout:\n{out}\nstderr:\n{err}"
                )
            time.sleep(0.15)

        proc.terminate()
        try:
            out, err = proc.communicate(timeout=term_timeout)
            rc = proc.returncode
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate(timeout=2.0)
            raise AssertionError(f"AuraWall did not exit within {term_timeout}s after SIGTERM.\nstdout:\n{out}\nstderr:\n{err}")

        fatal_markers = ("dyld:", "Library not loaded", "Fatal error:", "EXC_CRASH", "Trace/BPT trap")
        for marker in fatal_markers:
            if marker in err or marker in out:
                raise AssertionError(f"Fatal runtime marker {marker!r} observed in output:\nstderr:\n{err}\nstdout:\n{out}")

        # Clean SIGTERM yields either 0 (handled) or -SIGTERM (-15) on macOS AppKit NSApplication.
        if rc not in (0, -signal.SIGTERM):
            raise AssertionError(f"Unexpected exit code after SIGTERM: rc={rc}\nstdout:\n{out}\nstderr:\n{err}")

        return {"returncode": rc, "stdout": out, "stderr": err}
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=2.0)


def _serve_cli(port: int, ready_file: Optional[Path]) -> int:
    srv = MockAuraWallServer(port=port)
    srv.start()

    stop_event = threading.Event()

    def _on_signal(signum: int, frame: Any) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    if ready_file is not None:
        ready_file.parent.mkdir(parents=True, exist_ok=True)
        tmp_ready = ready_file.with_suffix(".tmp")
        tmp_ready.write_text(srv.base_url + "\n", encoding="utf-8")
        tmp_ready.replace(ready_file)

    print(srv.base_url, flush=True)
    try:
        while not stop_event.is_set():
            stop_event.wait(timeout=0.5)
    finally:
        srv.stop()
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="AuraWall E2E support & mock HTTP server")
    parser.add_argument("--serve", action="store_true", help="Run mock HTTP server in foreground")
    parser.add_argument("--port", type=int, default=0, help="Port to bind (default 0 = ephemeral)")
    parser.add_argument("--ready-file", type=Path, default=None, help="File to write base URL once listening")
    args = parser.parse_args(argv)

    if args.serve:
        return _serve_cli(args.port, args.ready_file)
    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
