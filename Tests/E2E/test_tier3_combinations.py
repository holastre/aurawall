#!/usr/bin/env python3
"""Tier 3: Pairwise Cross-Feature Combination E2E Tests (Track A)."""

import io
import json
import os
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


TESTING_MACROS_DYLIB = Path(
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
)


class Tier3CombinationTests(unittest.TestCase):
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

    def _resolve_aurawall_binary(self) -> Path:
        bundled = PROJECT_ROOT / "build" / "AuraWall.app" / "Contents" / "MacOS" / "AuraWall"
        if bundled.is_file():
            return bundled
        bin_path_res = subprocess.run(
            ["swift", "build", "--disable-sandbox", "--show-bin-path"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(bin_path_res.stdout.strip()) / "AuraWall"

    def _get_mock_requests(self) -> list:
        status, _, body = http_request(f"{self.base_url}/_e2e/requests")
        self.assertEqual(status, 200)
        return json.loads(body.decode("utf-8"))

    # T3-06: (F1, F6) Built .app Bundle Launch -> Background Lifecycle -> Clean Exit
    def test_t3_06_bundle_launch_background_lifecycle_clean_exit(self) -> None:
        app = PROJECT_ROOT / "build" / "AuraWall.app"
        if not app.is_dir():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: build/AuraWall.app not present yet")
            self.fail(f"build/AuraWall.app missing in full mode: {app}")

        plist_data = validate_plist(app / "Contents" / "Info.plist")
        self.assertIs(plist_data.get("LSUIElement"), False)
        self.assertEqual(plist_data.get("CFBundleIconFile"), "AppIcon")
        icon_path = app / "Contents" / "Resources" / "AppIcon.icns"
        self.assertTrue(icon_path.is_file(), f"AppIcon.icns missing at {icon_path}")
        self.assertGreater(icon_path.stat().st_size, 0)

        validate_macho_arm64(app / "Contents" / "MacOS" / "AuraWall")
        validate_codesign(app)

        host_app_support = Path.home() / "Library" / "Application Support" / "AuraWall"
        host_existed_before = host_app_support.exists()

        with tempfile.TemporaryDirectory(prefix="aurawall_t3_06_") as tmp:
            tmp_home = Path(tmp)
            res = launch_app_and_verify_sigterm(app, tmp_home)
            self.assertIn(res["returncode"], (0, -15))
            self.assertTrue((tmp_home / "Library" / "Application Support").is_dir())
            self.assertTrue((tmp_home / "Library" / "Caches").is_dir())

        if not host_existed_before:
            self.assertFalse(
                host_app_support.exists(),
                f"Isolated bundle launch unexpectedly created host {host_app_support}",
            )

    # T3-07: (F1, F2) SPM Build + Starter & Wallhaven Smoke with HTTPS/ATS Compliance
    def test_t3_07_spm_build_and_starter_wallhaven_smoke(self) -> None:
        pkg = PROJECT_ROOT / "Package.swift"
        if not pkg.is_file():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: Package.swift absent")
            self.fail("Package.swift missing in full mode")

        build = subprocess.run(
            ["swift", "build", "--disable-sandbox"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(build.returncode, 0, f"swift build failed: {build.stderr}")

        # Mock Starter resources-16.tar + Wallhaven search
        s_tar, _, tar_bytes = http_request(f"{self.base_url}/aerials/resources-16.tar")
        self.assertEqual(s_tar, 200)
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
            entries = json.loads(tf.extractfile("entries.json").read().decode("utf-8"))
        self.assertGreaterEqual(len(entries["assets"]), 4)

        s_wh, _, wh_bytes = http_request(f"{self.base_url}/wallhaven/api/v1/search?q=landscape&purity=100")
        self.assertEqual(s_wh, 200)
        self.assertGreater(len(json.loads(wh_bytes.decode("utf-8"))["data"]), 0)

        if is_live_enabled():
            ls_tar, _, l_tar_bytes = http_request("https://sylvan.apple.com/Aerials/resources-16.tar", timeout=25.0)
            self.assertEqual(ls_tar, 200)
            with tarfile.open(fileobj=io.BytesIO(l_tar_bytes), mode="r:") as tf:
                self.assertIn("entries.json", tf.getnames())
                live_entries = json.loads(tf.extractfile("entries.json").read().decode("utf-8"))
            assets = live_entries.get("assets", [])
            self.assertGreaterEqual(len(assets), 50)

            live_video_url = None
            for asset in assets:
                for key in ("url-4K-SDR", "url-1080-SDR", "url-1080-H264", "url-4K-HDR"):
                    candidate = asset.get(key)
                    if isinstance(candidate, str) and candidate.startswith("https://"):
                        live_video_url = candidate
                        break
                if live_video_url:
                    break
            self.assertIsNotNone(live_video_url, "Expected at least one HTTPS video URL in live entries.json")

            head_s, head_h, _ = http_request(live_video_url, method="HEAD", timeout=20.0)
            self.assertEqual(head_s, 200)
            self.assertIn("video/", head_h.get("content-type", "").lower())

            rng_s, rng_h, rng_chunk = http_request(
                live_video_url, headers={"Range": "bytes=0-511"}, timeout=20.0
            )
            self.assertIn(rng_s, (200, 206))
            self.assertIn("video/", rng_h.get("content-type", "").lower())
            self.assertGreater(len(rng_chunk), 0)

            ls_wh, l_wh_hdrs, l_wh_bytes = http_request(
                "https://wallhaven.cc/api/v1/search?q=landscape&purity=100", timeout=20.0
            )
            self.assertEqual(ls_wh, 200)
            self.assertIn("application/json", l_wh_hdrs.get("content-type", "").lower())
            wh_payload = json.loads(l_wh_bytes.decode("utf-8"))
            self.assertGreater(len(wh_payload.get("data", [])), 0)
            self.assertTrue(all(item.get("purity") == "sfw" for item in wh_payload["data"]))

    # T3-08: (F1, F3, F4) Custom Feed Media Streaming, Container Integrity & Engine Framework Linkage
    def test_t3_08_mock_media_streaming_and_fixture_integrity(self) -> None:
        if get_e2e_mode() == "full" or (PROJECT_ROOT / "Package.swift").is_file():
            binary = self._resolve_aurawall_binary()
            otool_res = subprocess.run(
                ["/usr/bin/otool", "-L", str(binary)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn("AVFoundation.framework", otool_res.stdout)
            self.assertIn("CoreGraphics.framework", otool_res.stdout)

        before_len = len(self._get_mock_requests())
        status, _, body = http_request(f"{self.base_url}/custom/wrapped.json")
        self.assertEqual(status, 200)
        items = json.loads(body.decode("utf-8"))["items"]
        self.assertGreaterEqual(len(items), 3)

        media_dir = get_media_dir()
        for fname in ("sample_video.mp4", "sample_aerial_4k.mov", "sample_video.mov", "sample_image.jpg", "sample_image.png", "sample_image.heic"):
            info = validate_media_file(media_dir / fname)
            self.assertGreater(info["size"], 0)

        for item in items:
            url = item["url"]
            fname = url.rsplit("/", 1)[-1]
            local_info = validate_media_file(media_dir / fname)
            s_full, _, full_bytes = http_request(url)
            self.assertEqual(s_full, 200)
            self.assertEqual(len(full_bytes), local_info["size"])

            s_rng, _, part_bytes = http_request(url, headers={"Range": "bytes=0-255"})
            self.assertEqual(s_rng, 206)
            self.assertEqual(part_bytes, full_bytes[:256])

        new_reqs = self._get_mock_requests()[before_len:]
        recorded_paths = {r["path"] for r in new_reqs}
        self.assertIn("/custom/wrapped.json", recorded_paths)
        self.assertTrue(any(p.startswith("/media/") for p in recorded_paths))

    # T3-09: (F1, F5) Toolchain, IOKit/Power Linkage & Host Power Monitor Readiness
    def test_t3_09_toolchain_and_host_power_readiness(self) -> None:
        swift_ver = subprocess.run(["swift", "--version"], capture_output=True, text=True, check=False)
        self.assertEqual(swift_ver.returncode, 0)
        self.assertIn("Apple Swift version 6", swift_ver.stdout)
        self.assertTrue(
            TESTING_MACROS_DYLIB.is_file(),
            f"Expected CLT macro plugin at {TESTING_MACROS_DYLIB}",
        )

        if get_e2e_mode() == "full" or (PROJECT_ROOT / "Package.swift").is_file():
            binary = self._resolve_aurawall_binary()
            otool_res = subprocess.run(
                ["/usr/bin/otool", "-L", str(binary)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn("IOKit.framework", otool_res.stdout)
            self.assertIn("AppKit.framework", otool_res.stdout)

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

    # T3-10: (F2, F4, F5) Online Variant Selection, Media Stream Verification & Multi-Provider Error Isolation
    def test_t3_10_online_variant_selection_and_error_isolation(self) -> None:
        before_len = len(self._get_mock_requests())

        # Pexels: filter out HLS/portrait and pick landscape UHD for wallpaper + SD for preview
        s_px, _, b_px = http_request(
            f"{self.base_url}/pexels/v1/videos/search?query=waves",
            headers={"Authorization": "valid_key"},
        )
        self.assertEqual(s_px, 200)
        vfiles = json.loads(b_px.decode("utf-8"))["videos"][0]["video_files"]
        landscape_mp4s = [
            vf
            for vf in vfiles
            if vf.get("file_type") == "video/mp4"
            and vf.get("width") is not None
            and vf.get("height") is not None
            and vf["width"] >= vf["height"]
        ]
        full_choice = max(landscape_mp4s, key=lambda vf: vf["width"] * vf["height"])
        preview_choice = min(landscape_mp4s, key=lambda vf: vf["width"] * vf["height"])
        self.assertEqual(full_choice["quality"], "uhd")
        self.assertEqual(preview_choice["quality"], "sd")

        # Stream selected UHD MP4 from mock server and verify valid video container
        s_dl, h_dl, b_dl = http_request(full_choice["link"])
        self.assertEqual(s_dl, 200)
        self.assertIn("video/mp4", h_dl.get("content-type", ""))
        with tempfile.TemporaryDirectory(prefix="aurawall_t3_10_") as tmp:
            dl_path = Path(tmp) / "pexels_uhd.mp4"
            dl_path.write_bytes(b_dl)
            dl_info = validate_media_file(dl_path)
            self.assertEqual(dl_info["size"], len(b_dl))

        # Pixabay: item 1 has empty large -> fall back to medium
        s_pb, _, b_pb = http_request(f"{self.base_url}/pixabay/api/videos/?key=valid_key")
        self.assertEqual(s_pb, 200)
        hit1 = json.loads(b_pb.decode("utf-8"))["hits"][1]["videos"]
        selected_pb = hit1["large"] if hit1["large"]["url"] and hit1["large"]["size"] > 0 else hit1["medium"]
        self.assertEqual(selected_pb["width"], 1920)
        self.assertTrue(selected_pb["url"].startswith(self.base_url))

        # Failing providers (Wallhaven 500 HTML + Pexels 401 + Pixabay 400 text) leave healthy custom feed intact
        s_wh_err, _, _ = http_request(f"{self.base_url}/wallhaven/api/v1/search?page=-1")
        s_px_err, _, _ = http_request(f"{self.base_url}/pexels/v1/videos/search?query=waves")
        s_pb_err, _, _ = http_request(f"{self.base_url}/pixabay/api/videos/")
        s_cf_ok, _, b_cf_ok = http_request(f"{self.base_url}/custom/wrapped.json")
        self.assertEqual(s_wh_err, 500)
        self.assertEqual(s_px_err, 401)
        self.assertEqual(s_pb_err, 400)
        self.assertEqual(s_cf_ok, 200)
        self.assertEqual(len(json.loads(b_cf_ok.decode("utf-8"))["items"]), 3)

        new_reqs = self._get_mock_requests()[before_len:]
        recorded_paths = {r["path"] for r in new_reqs}
        for expected_path in (
            "/pexels/v1/videos/search",
            "/pixabay/api/videos/",
            "/wallhaven/api/v1/search",
            "/custom/wrapped.json",
        ):
            self.assertIn(expected_path, recorded_paths)


if __name__ == "__main__":
    unittest.main()
