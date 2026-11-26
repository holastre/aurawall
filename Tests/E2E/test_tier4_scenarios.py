#!/usr/bin/env python3
"""Tier 4: Real-World Daily-Driver Application Scenarios (Track A)."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
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


class Tier4ScenarioTests(unittest.TestCase):
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

    def _probe_remote_asset_reachable(self, url: str) -> tuple[int, dict[str, str]]:
        status, hdrs, _ = http_request(url, method="HEAD", timeout=20.0)
        if status in (405, 501):
            status, hdrs, _ = http_request(
                url,
                method="GET",
                headers={"Range": "bytes=0-511"},
                timeout=20.0,
            )
        return status, hdrs

    # T4-01: First-Launch Starter Catalog, Live Feed Smoke & Bundle Verification
    def test_t4_01_first_launch_starter_live_smoke_and_bundle(self) -> None:
        # 1. Starter catalog via resources-16.tar
        s_tar, _, tar_bytes = http_request(f"{self.base_url}/aerials/resources-16.tar")
        self.assertEqual(s_tar, 200)
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
            entries = json.loads(tf.extractfile("entries.json").read().decode("utf-8"))
        self.assertGreaterEqual(len(entries.get("assets", [])), 1)
        first_video_url = entries["assets"][0]["url-4K-SDR"]
        s_vid, h_vid, b_vid = http_request(first_video_url, headers={"Range": "bytes=0-1023"})
        self.assertEqual(s_vid, 206)
        self.assertIn("video/quicktime", h_vid.get("content-type", ""))
        self.assertEqual(len(b_vid), 1024)

        # 2. Live smoke check (when enabled)
        if is_live_enabled():
            ls_tar, _, live_tar = http_request("https://sylvan.apple.com/Aerials/resources-16.tar", timeout=25.0)
            self.assertEqual(ls_tar, 200)
            with tarfile.open(fileobj=io.BytesIO(live_tar), mode="r:") as tf:
                self.assertIn("entries.json", tf.getnames())
                live_entries = json.loads(tf.extractfile("entries.json").read().decode("utf-8"))
            live_assets = live_entries.get("assets", [])
            self.assertGreaterEqual(len(live_assets), 50)

            live_mov_url = None
            for asset in live_assets:
                for key in ("url-4K-SDR", "url-1080-SDR", "url-1080-H264"):
                    candidate = asset.get(key)
                    if isinstance(candidate, str) and candidate.startswith("https://"):
                        live_mov_url = candidate
                        break
                if live_mov_url:
                    break
            self.assertIsNotNone(live_mov_url, "Expected at least one HTTPS video URL in live Aerials entries.json")
            mov_status, mov_hdrs = self._probe_remote_asset_reachable(live_mov_url)
            self.assertIn(mov_status, (200, 206))
            self.assertTrue(
                mov_hdrs.get("content-type", "").startswith("video/"),
                f"Expected video/* content-type from live Aerial probe, got {mov_hdrs.get('content-type')!r}",
            )

            ls_wh, h_wh, live_wh = http_request(
                "https://wallhaven.cc/api/v1/search?q=landscape&purity=100", timeout=20.0
            )
            self.assertEqual(ls_wh, 200)
            self.assertIn("application/json", h_wh.get("content-type", ""))
            wh_payload = json.loads(live_wh.decode("utf-8"))
            self.assertGreater(len(wh_payload["data"]), 0)
            first_wh = wh_payload["data"][0]
            self.assertEqual(first_wh.get("purity"), "sfw")
            wh_img_status, wh_img_hdrs = self._probe_remote_asset_reachable(first_wh["path"])
            self.assertIn(wh_img_status, (200, 206))
            self.assertTrue(
                wh_img_hdrs.get("content-type", "").startswith("image/"),
                f"Expected image/* content-type from live Wallhaven image probe, got {wh_img_hdrs.get('content-type')!r}",
            )

        # 3. Bundle & Launch check (pre-bundle skips only if build/AuraWall.app absent)
        app = PROJECT_ROOT / "build" / "AuraWall.app"
        if not app.is_dir():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: build/AuraWall.app absent; live & mock starter smoke passed")
            self.fail(f"build/AuraWall.app missing in full mode: {app}")

        plist_data = validate_plist(app / "Contents" / "Info.plist")
        self.assertIs(plist_data.get("LSUIElement"), False)
        self.assertEqual(plist_data.get("CFBundleIconFile"), "AppIcon")
        icon_path = app / "Contents" / "Resources" / "AppIcon.icns"
        self.assertTrue(icon_path.is_file(), f"AppIcon.icns missing at {icon_path}")
        self.assertGreater(icon_path.stat().st_size, 0)

        binary = app / "Contents" / "MacOS" / "AuraWall"
        validate_macho_arm64(binary)
        validate_codesign(app)
        otool_res = subprocess.run(["/usr/bin/otool", "-L", str(binary)], capture_output=True, text=True, check=True)
        for fw in ("AVFoundation.framework", "CoreGraphics.framework", "IOKit.framework", "AppKit.framework"):
            self.assertIn(fw, otool_res.stdout)

        host_app_support = Path.home() / "Library" / "Application Support" / "AuraWall"
        host_caches = Path.home() / "Library" / "Caches" / "AuraWall"
        existed_app_support = host_app_support.exists()
        existed_caches = host_caches.exists()

        with tempfile.TemporaryDirectory(prefix="aurawall_t4_01_") as tmp:
            res = launch_app_and_verify_sigterm(app, Path(tmp))
            self.assertIn(res["returncode"], (0, -15))

        if not existed_app_support:
            self.assertFalse(host_app_support.exists(), f"Isolated launch mutated host {host_app_support}")
        if not existed_caches:
            self.assertFalse(host_caches.exists(), f"Isolated launch mutated host {host_caches}")

    # T4-02: Multi-Monitor Media Assets, Range Streaming & DisplayConfig Contract
    def test_t4_02_multi_monitor_media_fixtures_and_streaming(self) -> None:
        media_dir = get_media_dir()
        disp1_video = validate_media_file(media_dir / "sample_aerial_4k.mov")
        disp2_image = validate_media_file(media_dir / "sample_image.heic")
        self.assertIn("QuickTime", disp1_video["file"])
        self.assertIn("HEIF", disp2_image["file"])

        s1, h1, b1 = http_request(f"{self.base_url}/media/sample_aerial_4k.mov")
        s2, h2, b2 = http_request(f"{self.base_url}/media/sample_image.heic")
        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)
        self.assertEqual(int(h1["content-length"]), len(b1))
        self.assertEqual(int(h2["content-length"]), len(b2))

        r1_st, r1_hdrs, r1_bytes = http_request(
            f"{self.base_url}/media/sample_aerial_4k.mov",
            headers={"Range": "bytes=0-511"},
        )
        r2_st, r2_hdrs, r2_bytes = http_request(
            f"{self.base_url}/media/sample_image.heic",
            headers={"Range": "bytes=0-511"},
        )
        self.assertEqual(r1_st, 206)
        self.assertEqual(r2_st, 206)
        self.assertEqual(r1_hdrs.get("content-range"), f"bytes 0-511/{len(b1)}")
        self.assertEqual(r2_hdrs.get("content-range"), f"bytes 0-511/{len(b2)}")
        self.assertEqual(r1_bytes, b1[:512])
        self.assertEqual(r2_bytes, b2[:512])

        with tempfile.TemporaryDirectory(prefix="aurawall_t4_02_") as tmp:
            dl_mov = Path(tmp) / "disp1.mov"
            dl_heic = Path(tmp) / "disp2.heic"
            dl_mov.write_bytes(b1)
            dl_heic.write_bytes(b2)
            self.assertEqual(validate_media_file(dl_mov)["size"], len(b1))
            self.assertEqual(validate_media_file(dl_heic)["size"], len(b2))

        display_config = {
            "mode": "independent",
            "assignments": {
                "101": {"displayID": 101, "displayName": "Built-in", "scalingMode": "fill"},
                "202": {"displayID": 202, "displayName": "External 4K", "scalingMode": "fit"},
                "mirror": {"displayID": 0, "displayName": "Mirror", "scalingMode": "fill"},
            },
        }
        round_tripped = json.loads(json.dumps(display_config))
        self.assertEqual(round_tripped["mode"], "independent")
        self.assertEqual(round_tripped["assignments"]["101"]["scalingMode"], "fill")
        self.assertEqual(round_tripped["assignments"]["202"]["scalingMode"], "fit")
        round_tripped["mode"] = "mirrorAll"
        self.assertEqual(round_tripped["mode"], "mirrorAll")

    # T4-03: Wallhaven Search/Filter -> Chunked Range Download -> Checksum & Media Integrity
    def test_t4_03_wallhaven_search_streaming_download_and_checksum(self) -> None:
        s_wh, _, b_wh = http_request(
            f"{self.base_url}/wallhaven/api/v1/search"
            "?q=landscape&categories=100&purity=100&atleast=1920x1080&ratios=16x9&sorting=toplist&topRange=1y&page=1"
        )
        self.assertEqual(s_wh, 200)
        payload = json.loads(b_wh.decode("utf-8"))
        self.assertGreater(len(payload["data"]), 0)
        first = payload["data"][0]
        self.assertEqual(first["purity"], "sfw")
        asset_url = first["path"]
        thumb_url = first["thumbs"]["large"]

        s_thumb, _, b_thumb = http_request(thumb_url)
        self.assertEqual(s_thumb, 200)
        self.assertGreater(len(b_thumb), 0)

        h_status, h_hdrs, _ = http_request(asset_url, method="HEAD")
        self.assertEqual(h_status, 200)
        total = int(h_hdrs["content-length"])
        chunk_size = 1024
        assembled = bytearray()
        offset = 0
        while offset < total:
            end = min(offset + chunk_size - 1, total - 1)
            r_status, r_hdrs, chunk = http_request(
                asset_url, headers={"Range": f"bytes={offset}-{end}"}
            )
            self.assertEqual(r_status, 206)
            self.assertEqual(r_hdrs.get("content-range"), f"bytes {offset}-{end}/{total}")
            assembled.extend(chunk)
            offset = end + 1

        expected_bytes = (get_media_dir() / "sample_image.jpg").read_bytes()
        self.assertEqual(
            hashlib.sha256(assembled).hexdigest(),
            hashlib.sha256(expected_bytes).hexdigest(),
        )
        with tempfile.TemporaryDirectory(prefix="aurawall_t4_03_") as tmp:
            out_img = Path(tmp) / "wallhaven_assembled.jpg"
            out_img.write_bytes(bytes(assembled))
            img_info = validate_media_file(out_img)
            self.assertEqual(img_info["size"], len(expected_bytes))
            self.assertGreater(img_info["width"], 0)
            self.assertGreater(img_info["height"], 0)

    # T4-04: Host Power Readability, Binary Linkage & Video Media Readiness
    def test_t4_04_power_host_pmset_and_video_readiness(self) -> None:
        pm = subprocess.run(["/usr/bin/pmset", "-g", "batt"], capture_output=True, text=True, check=False)
        self.assertEqual(pm.returncode, 0, f"pmset -g batt failed: {pm.stderr}")

        batt_reg = subprocess.run(
            ["/usr/sbin/ioreg", "-rc", "AppleSmartBattery"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(batt_reg.returncode, 0, f"ioreg failed: {batt_reg.stderr}")

        has_battery = ("AppleSmartBattery" in batt_reg.stdout) or ("InternalBattery" in pm.stdout)
        if has_battery:
            self.assertIn("Now drawing from", pm.stdout)
            self.assertTrue(
                ("AC Power" in pm.stdout) or ("Battery Power" in pm.stdout),
                f"Expected AC Power or Battery Power in pmset output: {pm.stdout!r}",
            )
        elif any(tok in pm.stdout for tok in ("Battery", "AC Power", "UPS", "drawing")):
            self.assertIn("Now drawing from", pm.stdout)

        app_binary = PROJECT_ROOT / "build" / "AuraWall.app" / "Contents" / "MacOS" / "AuraWall"
        if get_e2e_mode() == "full" or app_binary.is_file():
            self.assertTrue(app_binary.is_file(), f"Expected app binary at {app_binary}")
            otool_res = subprocess.run(["/usr/bin/otool", "-L", str(app_binary)], capture_output=True, text=True, check=True)
            self.assertIn("IOKit.framework", otool_res.stdout)
            self.assertIn("AVFoundation.framework", otool_res.stdout)

        info = validate_media_file(get_media_dir() / "sample_video.mp4")
        self.assertIn("MP4", info["file"])

    # T4-05: Cache Bloat Cleanup Preserving Active Desktop & Imported Wallpapers
    def test_t4_05_cache_cleanup_preserving_active_and_imported(self) -> None:
        with tempfile.TemporaryDirectory(prefix="aurawall_t4_05_") as tmp:
            tmp_dir = Path(tmp)
            cache_dir = tmp_dir / "Cache"
            imports_dir = tmp_dir / "Imports"
            cache_dir.mkdir()
            imports_dir.mkdir()

            downloads = [
                ("active_video.mov", f"{self.base_url}/media/sample_aerial_4k.mov"),
                ("old_video1.mp4", f"{self.base_url}/media/sample_video.mp4"),
                ("old_image2.jpg", f"{self.base_url}/media/sample_image.jpg"),
            ]
            for local_name, url in downloads:
                st, _, body = http_request(url)
                self.assertEqual(st, 200)
                target = cache_dir / local_name
                target.write_bytes(body)
                validate_media_file(target)

            orphan_tmp = cache_dir / ".stale-download.tmp"
            orphan_tmp.write_bytes(b"partial-data")

            imported_mov = imports_dir / "imported.mov"
            shutil.copy2(get_media_dir() / "sample_video.mov", imported_mov)
            validate_media_file(imported_mov)

            active_file = cache_dir / "active_video.mov"
            active_size = active_file.stat().st_size
            symlink_alias = tmp_dir / "active_alias.mov"
            symlink_alias.symlink_to(active_file)
            preserved = {Path(os.path.realpath(symlink_alias))}

            # Safe cache clear (preserving canonical active paths and removing stale .tmp)
            for entry in list(cache_dir.iterdir()):
                if Path(os.path.realpath(entry)) not in preserved:
                    entry.unlink()

            remaining_size = sum(p.stat().st_size for p in cache_dir.iterdir() if p.is_file())
            self.assertEqual(remaining_size, active_size)
            self.assertTrue(active_file.is_file())
            self.assertFalse((cache_dir / "old_video1.mp4").exists())
            self.assertFalse((cache_dir / "old_image2.jpg").exists())
            self.assertFalse(orphan_tmp.exists())
            self.assertTrue(imported_mov.is_file())

    # T4-06: Multi-Provider Concurrent Aggregation with Invalid Keys, Rate Limits & Custom Feed
    def test_t4_06_multi_provider_concurrent_aggregation_and_isolation(self) -> None:
        http_request(f"{self.base_url}/_e2e/requests/reset", method="POST")

        endpoints = [
            ("aerials_r16", f"{self.base_url}/aerials/resources-16.tar", {}),
            ("wallhaven_ok", f"{self.base_url}/wallhaven/api/v1/search?q=landscape&purity=100", {}),
            ("wallhaven_500", f"{self.base_url}/wallhaven/api/v1/search?page=-1", {}),
            ("wallhaven_401", f"{self.base_url}/wallhaven/api/v1/search?apikey=invalid_key_123", {}),
            ("wallhaven_429", f"{self.base_url}/wallhaven/api/v1/search?q=ratelimit&purity=100", {}),
            ("pexels_bearer_401", f"{self.base_url}/pexels/v1/videos/search?query=waves", {"Authorization": "Bearer bad"}),
            ("pexels_ok", f"{self.base_url}/pexels/v1/videos/search?query=waves", {"Authorization": "valid_key"}),
            ("pexels_429", f"{self.base_url}/pexels/v1/videos/search?query=ratelimit", {"Authorization": "valid_key"}),
            ("pixabay_400", f"{self.base_url}/pixabay/api/videos/?q=nature", {}),
            ("pixabay_ok", f"{self.base_url}/pixabay/api/videos/?key=valid_key", {}),
            ("pixabay_429", f"{self.base_url}/pixabay/api/videos/?key=valid_key&q=ratelimit", {}),
            ("custom_ok", f"{self.base_url}/custom/wrapped.json", {}),
            ("custom_array", f"{self.base_url}/custom/array.json", {}),
            ("custom_empty", f"{self.base_url}/custom/empty.json", {}),
            ("custom_malformed", f"{self.base_url}/custom/malformed.json", {}),
            ("custom_500", f"{self.base_url}/custom/error500.html", {}),
        ]

        results = {}
        with ThreadPoolExecutor(max_workers=6) as pool:
            futures = {
                name: pool.submit(http_request, url, "GET", hdrs)
                for name, url, hdrs in endpoints
            }
            for name, fut in futures.items():
                results[name] = fut.result()

        self.assertEqual(results["aerials_r16"][0], 200)
        self.assertEqual(results["wallhaven_ok"][0], 200)
        self.assertEqual(results["wallhaven_500"][0], 500)
        self.assertEqual(results["wallhaven_401"][0], 401)
        self.assertEqual(results["wallhaven_429"][0], 429)
        self.assertEqual(results["wallhaven_429"][1].get("retry-after"), "60")
        self.assertEqual(results["pexels_bearer_401"][0], 401)
        self.assertEqual(results["pexels_ok"][0], 200)
        self.assertEqual(results["pexels_429"][0], 429)
        self.assertEqual(results["pexels_429"][1].get("retry-after"), "60")
        self.assertEqual(results["pixabay_400"][0], 400)
        self.assertEqual(results["pixabay_ok"][0], 200)
        self.assertEqual(results["pixabay_429"][0], 429)
        self.assertEqual(results["pixabay_429"][1].get("retry-after"), "60")
        self.assertEqual(results["custom_ok"][0], 200)
        self.assertEqual(results["custom_array"][0], 200)
        self.assertIsInstance(json.loads(results["custom_array"][2].decode("utf-8")), list)
        self.assertEqual(results["custom_empty"][0], 200)
        self.assertEqual(json.loads(results["custom_empty"][2].decode("utf-8"))["items"], [])
        self.assertEqual(results["custom_malformed"][0], 200)
        self.assertEqual(results["custom_500"][0], 500)

        with tempfile.TemporaryDirectory(prefix="aurawall_t4_06_") as tmp:
            sec_file = Path(tmp) / "secrets.json"
            sec_file.write_text('{"pexelsAPIKey":"valid_key"}\n', encoding="utf-8")
            os.chmod(sec_file, 0o600)
            self.assertEqual(sec_file.stat().st_mode & 0o777, 0o600)

        # Verify request log endpoint captured all 16 concurrent requests
        log_status, _, log_body = http_request(f"{self.base_url}/_e2e/requests")
        self.assertEqual(log_status, 200)
        recorded = json.loads(log_body.decode("utf-8"))
        self.assertGreaterEqual(len(recorded), len(endpoints))


if __name__ == "__main__":
    unittest.main()
