#!/usr/bin/env python3
"""Tier 2: Boundary & Corner-Case E2E Tests (Track A)."""

import json
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from e2e_support import (
    PROJECT_ROOT,
    MockAuraWallServer,
    get_e2e_mode,
    get_media_dir,
    http_request,
    is_live_enabled,
    launch_app_and_verify_sigterm,
    validate_codesign,
    validate_macho_arm64,
    validate_media_file,
    validate_plist,
)


class Tier2BoundaryTests(unittest.TestCase):
    _owned_server = None
    base_url: str = ""

    @classmethod
    def setUpClass(cls) -> None:
        env_url = os.environ.get("AURAWALL_E2E_MOCK_URL", "").strip()
        if env_url:
            cls.base_url = env_url.rstrip("/")
        else:
            cls._owned_server = MockAuraWallServer().start()
            cls.base_url = cls._owned_server.base_url

    @classmethod
    def tearDownClass(cls) -> None:
        if cls._owned_server is not None:
            cls._owned_server.stop()
            cls._owned_server = None

    def _require_app_bundle(self) -> Path:
        app = PROJECT_ROOT / "build" / "AuraWall.app"
        if not app.is_dir():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: build/AuraWall.app not present yet")
            self.fail(f"build/AuraWall.app missing in full mode: {app}")
        return app

    # T2-F1-01
    def test_t2_f1_01_bundle_rerun_idempotency(self) -> None:
        bundle_script = PROJECT_ROOT / "scripts" / "bundle.sh"
        app = PROJECT_ROOT / "build" / "AuraWall.app"
        if not bundle_script.is_file() or not app.is_dir():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: scripts/bundle.sh or build/AuraWall.app absent")
            self.fail("scripts/bundle.sh or build/AuraWall.app missing in full mode")

        for run_idx in (1, 2):
            res = subprocess.run(
                ["bash", str(bundle_script)],
                cwd=str(PROJECT_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, f"bundle.sh run #{run_idx} failed:\n{res.stdout}\n{res.stderr}")
            validate_plist(app / "Contents" / "Info.plist")
            validate_macho_arm64(app / "Contents" / "MacOS" / "AuraWall")
            validate_codesign(app)

    # T2-F1-02
    def test_t2_f1_02_layout_compliance_teamwork_hygiene(self) -> None:
        teamwork_dir = PROJECT_ROOT / ".agents" / "teamwork"
        if teamwork_dir.exists():
            forbidden_exts = {".swift", ".mp4", ".mov", ".jpg", ".jpeg", ".png", ".heic"}
            bad_files = [
                str(p)
                for p in teamwork_dir.rglob("*")
                if p.is_file() and (p.suffix.lower() in forbidden_exts or "fixtures" in p.parts)
            ]
            self.assertEqual(bad_files, [], f"Forbidden source/media files inside .agents/teamwork: {bad_files}")

    # T2-F1-03
    def test_t2_f1_03_ats_security_audit(self) -> None:
        sources_dir = PROJECT_ROOT / "Sources"
        non_loopback_http = re.compile(r"http://(?!(?:127\.0\.0\.1|localhost|\[::1\])(?::|/|$))[A-Za-z0-9.-]+")
        if sources_dir.is_dir():
            for swift_file in sources_dir.rglob("*.swift"):
                content = swift_file.read_text(encoding="utf-8", errors="replace")
                self.assertNotIn(
                    "http://a1.phobos.apple.com",
                    content,
                    f"Plain HTTP phobos URL found in {swift_file}; ATS requires HTTPS",
                )
                matches = non_loopback_http.findall(content)
                self.assertEqual(
                    matches,
                    [],
                    f"Non-loopback plain HTTP URL(s) {matches} found in {swift_file}; ATS requires HTTPS",
                )

        plist_candidates = [
            PROJECT_ROOT / "build" / "AuraWall.app" / "Contents" / "Info.plist",
            PROJECT_ROOT / "Resources" / "Info.plist",
        ]
        found_plist = next((p for p in plist_candidates if p.is_file()), None)
        if found_plist is None:
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: Info.plist not present yet")
            self.fail("Info.plist missing in full mode")
        validate_plist(found_plist)

    # T2-F1-04
    def test_t2_f1_04_no_xctest_dependency(self) -> None:
        pkg = PROJECT_ROOT / "Package.swift"
        if not pkg.is_file():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: Package.swift absent")
            self.fail("Package.swift missing in full mode")
        self.assertNotIn("XCTest", pkg.read_text(encoding="utf-8"))
        tests_dir = PROJECT_ROOT / "Tests"
        if tests_dir.is_dir():
            for swift_file in tests_dir.rglob("*.swift"):
                text = swift_file.read_text(encoding="utf-8", errors="replace")
                self.assertNotIn("import XCTest", text, f"Forbidden import XCTest in {swift_file}")
                self.assertNotIn("XCTestCase", text, f"Forbidden XCTestCase in {swift_file}")

    # T2-F1-05
    def test_t2_f1_05_corrupt_plist_detection_guard(self) -> None:
        with tempfile.TemporaryDirectory(prefix="aurawall_bad_plist_") as tmp:
            tmp_dir = Path(tmp)
            # 1. Truncated XML plist
            broken = tmp_dir / "broken.plist"
            broken.write_text("<?xml version='1.0'?><plist><dict><key>CFBundleExecutable</key>", encoding="utf-8")
            with self.assertRaises(AssertionError):
                validate_plist(broken)

            # 2. Unresolved placeholder $(PRODUCT_NAME)
            placeholder = tmp_dir / "placeholder.plist"
            with placeholder.open("wb") as fh:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "AuraWall",
                        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                        "LSMinimumSystemVersion": "14.0",
                    },
                    fh,
                )
            with self.assertRaises(AssertionError):
                validate_plist(placeholder)

            # 3. Global NSAllowsArbitraryLoads = True
            insecure = tmp_dir / "insecure.plist"
            with insecure.open("wb") as fh:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "AuraWall",
                        "LSMinimumSystemVersion": "14.0",
                        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
                    },
                    fh,
                )
            with self.assertRaises(AssertionError):
                validate_plist(insecure)

    # T2-F2-01
    def test_t2_f2_01_apple_2x_entries_12_of_13_404_resilience(self) -> None:
        status, _, body = http_request(f"{self.base_url}/aerials/2x/entries.json")
        self.assertEqual(status, 200)
        payload = json.loads(body.decode("utf-8"))
        assets = payload["assets"]
        self.assertEqual(len(assets), 13)

        missing_count = 0
        healthy_count = 0
        for asset in assets:
            url = asset["url-4K-SDR"]
            s, hdrs, rbody = http_request(url, headers={"Range": "bytes=0-127"})
            if s == 404:
                missing_count += 1
                err_json = json.loads(rbody.decode("utf-8"))
                self.assertEqual(err_json["httpStatusCode"], 404)
            elif s in (200, 206):
                healthy_count += 1
                self.assertIn("video/quicktime", hdrs.get("content-type", ""))
        self.assertEqual(missing_count, 12)
        self.assertEqual(healthy_count, 1)

        if is_live_enabled():
            l_status, _, l_body = http_request("https://sylvan.apple.com/Aerials/2x/entries.json", timeout=20.0)
            self.assertEqual(l_status, 200)
            live_2x = json.loads(l_body.decode("utf-8"))
            self.assertGreater(len(live_2x.get("assets", [])), 0)

    # T2-F2-02
    def test_t2_f2_02_wallhaven_polymorphic_meta_query_and_empty_source(self) -> None:
        # 1. Object meta.query + seed
        s1, _, b1 = http_request(f"{self.base_url}/wallhaven/api/v1/search?q=id:37&purity=100")
        self.assertEqual(s1, 200)
        p1 = json.loads(b1.decode("utf-8"))
        self.assertIsInstance(p1["meta"]["query"], dict)
        self.assertEqual(p1["meta"]["query"]["id"], 37)
        self.assertEqual(p1["meta"]["seed"], "uwn0FK")
        self.assertEqual(p1["data"][0]["source"], "")

        # 2. Null meta.query when q omitted
        s2, _, b2 = http_request(f"{self.base_url}/wallhaven/api/v1/search?purity=100")
        self.assertEqual(s2, 200)
        p2 = json.loads(b2.decode("utf-8"))
        self.assertIsNone(p2["meta"]["query"])
        self.assertEqual(p2["data"][0]["source"], "")

        # 3. Unauthenticated purity=001 returns empty data array
        s3, _, b3 = http_request(f"{self.base_url}/wallhaven/api/v1/search?purity=001")
        self.assertEqual(s3, 200)
        self.assertEqual(json.loads(b3.decode("utf-8"))["data"], [])

    # T2-F2-03
    def test_t2_f2_03_wallhaven_500_html_and_401_429_errors(self) -> None:
        # page=-1 -> 500 text/html (non-JSON)
        s500, h500, b500 = http_request(f"{self.base_url}/wallhaven/api/v1/search?page=-1")
        self.assertEqual(s500, 500)
        self.assertIn("text/html", h500.get("content-type", ""))
        self.assertIn(b"It broke - wallhaven.cc", b500)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(b500.decode("utf-8"))

        # invalid apikey -> 401 JSON
        s401, _, b401 = http_request(
            f"{self.base_url}/wallhaven/api/v1/search?apikey=invalid_key_123"
        )
        self.assertEqual(s401, 401)
        self.assertEqual(json.loads(b401.decode("utf-8"))["error"], "Unauthorized")

        # rate limit -> 429
        s429, h429, _ = http_request(f"{self.base_url}/wallhaven/api/v1/search?q=ratelimit")
        self.assertEqual(s429, 429)
        self.assertEqual(h429.get("retry-after"), "60")

        # unknown detail -> 404
        s404, _, _ = http_request(f"{self.base_url}/wallhaven/api/v1/w/doesnotexist999")
        self.assertEqual(s404, 404)

    # T2-F2-04
    def test_t2_f2_04_pexels_bearer_rejection_and_hls_null_filtering(self) -> None:
        # Missing Authorization
        s_missing, _, b_missing = http_request(f"{self.base_url}/pexels/v1/videos/popular")
        self.assertEqual(s_missing, 401)
        self.assertEqual(json.loads(b_missing.decode("utf-8"))["code"], "Unauthorized")

        # Bearer prefix rejected
        s_bearer, _, _ = http_request(
            f"{self.base_url}/pexels/v1/videos/popular",
            headers={"Authorization": "Bearer valid_key"},
        )
        self.assertEqual(s_bearer, 401)

        # Rate limit
        s_429, _, _ = http_request(
            f"{self.base_url}/pexels/v1/videos/search?query=ratelimit",
            headers={"Authorization": "valid_key"},
        )
        self.assertEqual(s_429, 429)

        # HLS null fields & portrait entry present in 200 payload
        s_200, _, b_200 = http_request(
            f"{self.base_url}/pexels/v1/videos/search?query=waves",
            headers={"Authorization": "valid_key"},
        )
        self.assertEqual(s_200, 200)
        vfiles = json.loads(b_200.decode("utf-8"))["videos"][0]["video_files"]
        hls = [vf for vf in vfiles if vf.get("file_type") == "application/x-mpegURL"]
        self.assertEqual(len(hls), 1)
        self.assertIsNone(hls[0]["quality"])
        self.assertIsNone(hls[0]["width"])

    # T2-F2-05
    def test_t2_f2_05_pixabay_empty_large_url_and_plaintext_errors(self) -> None:
        # Missing key -> 400 text/html plain text (not JSON)
        s400, h400, b400 = http_request(f"{self.base_url}/pixabay/api/videos/?q=nature")
        self.assertEqual(s400, 400)
        self.assertIn("text/html", h400.get("content-type", ""))
        self.assertIn(b"[ERROR 400]", b400)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(b400.decode("utf-8"))

        # Rate limit -> 429 plain text
        s429, _, b429 = http_request(f"{self.base_url}/pixabay/api/?key=valid_key&q=ratelimit")
        self.assertEqual(s429, 429)
        self.assertIn(b"rate limit exceeded", b429)

        # Hit 1 has empty videos.large.url -> medium fallback
        s200, _, b200 = http_request(f"{self.base_url}/pixabay/api/videos/?key=valid_key")
        self.assertEqual(s200, 200)
        hits = json.loads(b200.decode("utf-8"))["hits"]
        self.assertEqual(hits[1]["videos"]["large"]["url"], "")
        self.assertEqual(hits[1]["videos"]["large"]["size"], 0)
        self.assertNotIn("picture_id", hits[1])
        self.assertTrue(hits[1]["videos"]["medium"]["url"].startswith(self.base_url))

    # T2-F2-06 (Track A mock boundaries)
    def test_t2_f2_06_custom_feed_empty_malformed_500_and_media_errors(self) -> None:
        s_emp, _, b_emp = http_request(f"{self.base_url}/custom/empty.json")
        self.assertEqual(s_emp, 200)
        self.assertEqual(json.loads(b_emp.decode("utf-8"))["items"], [])

        s_mal, _, b_mal = http_request(f"{self.base_url}/custom/malformed.json")
        self.assertEqual(s_mal, 200)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(b_mal.decode("utf-8"))

        s_500, _, _ = http_request(f"{self.base_url}/custom/error500.html")
        self.assertEqual(s_500, 500)

        s_m404, _, _ = http_request(f"{self.base_url}/media/not_found.mp4")
        self.assertEqual(s_m404, 404)

        s_m500, _, _ = http_request(f"{self.base_url}/media/broken_500.mp4")
        self.assertEqual(s_m500, 500)

        s_416, _, _ = http_request(
            f"{self.base_url}/media/sample_video.mp4",
            headers={"Range": "bytes=9999999-99999999"},
        )
        self.assertEqual(s_416, 416)

    # T2-F6-01
    def test_t2_f6_01_invalid_local_import_extensions_rejected(self) -> None:
        supported = {".mp4", ".mov", ".m4v", ".jpg", ".jpeg", ".png", ".heic"}
        media_dir = get_media_dir()
        for fname in ("sample.txt", "sample.svg"):
            p = media_dir / fname
            self.assertTrue(p.is_file())
            self.assertNotIn(p.suffix.lower(), supported)
        for synthetic in ("installer.dmg", "binary.exe"):
            self.assertNotIn(Path(synthetic).suffix.lower(), supported)

    # T2-F6-02
    def test_t2_f6_02_corrupt_zero_byte_media_detected(self) -> None:
        media_dir = get_media_dir()
        for fname in ("corrupt_empty.mp4", "corrupt_empty.jpg"):
            p = media_dir / fname
            self.assertTrue(p.is_file())
            self.assertEqual(p.stat().st_size, 0)
            f_res = subprocess.run(["/usr/bin/file", "-b", str(p)], capture_output=True, text=True, check=True)
            self.assertIn("empty", f_res.stdout.lower())

        sips_res = subprocess.run(
            ["/usr/bin/sips", "-g", "format", str(media_dir / "corrupt_empty.jpg")],
            capture_output=True,
            text=True,
            check=False,
        )
        combined = sips_res.stdout + "\n" + sips_res.stderr
        self.assertTrue(
            sips_res.returncode != 0 or "not a valid file" in combined or "format:" not in sips_res.stdout,
            f"Expected sips to reject 0-byte jpg, got: {combined!r}",
        )

    # T2-F6-03
    def test_t2_f6_03_validate_media_file_rejects_malformed_isobmff_containers(self) -> None:
        def box(box_type: bytes, payload: bytes) -> bytes:
            return (len(payload) + 8).to_bytes(4, "big") + box_type + payload

        ftyp_mp4 = box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
        ftyp_mov = box(b"ftyp", b"qt  \x00\x00\x02\x00qt  ")
        valid_moov = box(b"moov", box(b"trak", box(b"mdia", box(b"hdlr", b"\x00" * 8 + b"vide"))))

        with tempfile.TemporaryDirectory(prefix="aurawall_bad_video_") as tmp:
            tmp_dir = Path(tmp)

            # (a) ftyp + mdat without moov
            no_moov = tmp_dir / "no_moov.mp4"
            no_moov.write_bytes(ftyp_mp4 + box(b"mdat", b"\x00" * 32))
            with self.assertRaises(AssertionError):
                validate_media_file(no_moov)

            # (b) ftyp + fake 'moov' substring inside mdat (no top-level moov box)
            fake_moov = tmp_dir / "fake_moov_substring.mp4"
            fake_moov.write_bytes(ftyp_mp4 + box(b"mdat", b"junk_moov_trak_vide_bytes_" + b"\x00" * 16))
            with self.assertRaises(AssertionError):
                validate_media_file(fake_moov)

            # (c) truncated moov box (declared length exceeds EOF)
            truncated_moov = tmp_dir / "truncated_moov.mp4"
            trunc_hdr = (256).to_bytes(4, "big") + b"moov" + b"trakvide"
            truncated_moov.write_bytes(ftyp_mp4 + box(b"mdat", b"\x00" * 16) + trunc_hdr)
            with self.assertRaises(AssertionError):
                validate_media_file(truncated_moov)

            # (d) corrupt trailing box in .mov
            corrupt_trailer = tmp_dir / "corrupt_trailer.mov"
            corrupt_trailer.write_bytes(ftyp_mov + box(b"mdat", b"\x00" * 16) + valid_moov + b"\x00\x00\x00\x04free")
            with self.assertRaises(AssertionError):
                validate_media_file(corrupt_trailer)

    # T2-F6-05
    def test_t2_f6_05_bundle_isolated_home_launch(self) -> None:
        app = self._require_app_bundle()
        with tempfile.TemporaryDirectory(prefix="aurawall_isolated_") as tmp:
            tmp_home = Path(tmp)
            res = launch_app_and_verify_sigterm(app, tmp_home)
            self.assertIn(res["returncode"], (0, -15))
            self.assertTrue((tmp_home / "Library" / "Application Support").is_dir())


if __name__ == "__main__":
    unittest.main()
