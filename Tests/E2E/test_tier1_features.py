#!/usr/bin/env python3
"""Tier 1: Isolated Happy-Path E2E Tests (Track A)."""

import io
import json
import os
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

from e2e_support import (
    PROJECT_ROOT,
    MockAuraWallServer,
    get_e2e_mode,
    get_fixtures_dir,
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


class Tier1FeatureTests(unittest.TestCase):
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

    def _require_package_swift(self) -> Path:
        pkg = PROJECT_ROOT / "Package.swift"
        if not pkg.is_file():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: Package.swift not present yet")
            self.fail(f"Package.swift missing in full mode: {pkg}")
        return pkg

    def _require_app_bundle(self) -> Path:
        app = PROJECT_ROOT / "build" / "AuraWall.app"
        if not app.is_dir():
            if get_e2e_mode() == "pre-bundle":
                raise unittest.SkipTest("pre-bundle: build/AuraWall.app not present yet")
            self.fail(f"build/AuraWall.app missing in full mode: {app}")
        return app

    # T1-F1-01
    def test_t1_f1_01_spm_manifest_validation(self) -> None:
        pkg = self._require_package_swift()
        text = pkg.read_text(encoding="utf-8")
        self.assertIn("swift-tools-version: 6.0", text)
        self.assertIn(".macOS(.v14)", text)
        for target_name in ("AuraWallCore", "AuraWall", "AuraWallCoreTests"):
            self.assertIn(target_name, text)

        dump = subprocess.run(
            ["swift", "package", "dump-package"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(dump.returncode, 0, f"swift package dump-package failed: {dump.stderr}")
        manifest = json.loads(dump.stdout)
        target_names = {t["name"] for t in manifest.get("targets", [])}
        self.assertTrue({"AuraWallCore", "AuraWall", "AuraWallCoreTests"}.issubset(target_names))

    # T1-F1-02
    def test_t1_f1_02_clean_swift_build(self) -> None:
        self._require_package_swift()
        build = subprocess.run(
            ["swift", "build", "--disable-sandbox"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(build.returncode, 0, f"swift build failed:\n{build.stdout}\n{build.stderr}")

        bin_path_res = subprocess.run(
            ["swift", "build", "--disable-sandbox", "--show-bin-path"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            check=True,
        )
        binary = Path(bin_path_res.stdout.strip()) / "AuraWall"
        arch_info = validate_macho_arm64(binary)
        self.assertIn("arm64", arch_info["lipo"])

    # T1-F1-03
    def test_t1_f1_03_unit_test_suite_pass(self) -> None:
        self._require_package_swift()
        cmd = ["swift", "test", "--disable-sandbox"]
        if TESTING_MACROS_DYLIB.is_file():
            cmd.extend(["-Xswiftc", "-load-plugin-library", "-Xswiftc", str(TESTING_MACROS_DYLIB)])
        res = subprocess.run(
            cmd,
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0, f"swift test failed:\n{res.stdout}\n{res.stderr}")

    # T1-F1-04
    def test_t1_f1_04_app_bundle_structure_and_plist(self) -> None:
        app = self._require_app_bundle()
        self.assertTrue((app / "Contents" / "MacOS" / "AuraWall").is_file())
        plist_data = validate_plist(app / "Contents" / "Info.plist")
        self.assertEqual(plist_data["CFBundleExecutable"], "AuraWall")

    # T1-F1-05
    def test_t1_f1_05_macho_arch_and_codesign(self) -> None:
        app = self._require_app_bundle()
        arch_info = validate_macho_arm64(app / "Contents" / "MacOS" / "AuraWall")
        self.assertIn("arm64", arch_info["lipo"])
        cs_out = validate_codesign(app)
        self.assertTrue(len(cs_out) > 0)

    # T1-F2-01
    def test_t1_f2_01_aerials_resources16_tar_and_live_smoke(self) -> None:
        status, headers, body = http_request(f"{self.base_url}/aerials/resources-16.tar")
        self.assertEqual(status, 200)
        self.assertIn("application/octet-stream", headers.get("content-type", ""))

        with tarfile.open(fileobj=io.BytesIO(body), mode="r:") as tf:
            names = tf.getnames()
            self.assertIn("entries.json", names)
            self.assertIn("snapshots/seal.jpg", names)
            entries_raw = tf.extractfile("entries.json").read().decode("utf-8")
            seal_raw = tf.extractfile("snapshots/seal.jpg").read()
            self.assertTrue(seal_raw.startswith(b"\xff\xd8"))

        entries = json.loads(entries_raw)
        self.assertEqual(len(entries["categories"]), 4)
        self.assertGreaterEqual(len(entries["assets"]), 4)
        self.assertIn("url-4K-SDR", entries["assets"][0])
        self.assertIn("url-1080-SDR", entries["assets"][0])

        # Also verify legacy phobos array fixture endpoint
        ph_status, _, ph_body = http_request(f"{self.base_url}/aerials/phobos/entries.json")
        self.assertEqual(ph_status, 200)
        ph_data = json.loads(ph_body.decode("utf-8"))
        self.assertIsInstance(ph_data, list)
        self.assertGreaterEqual(len(ph_data), 2)

        if is_live_enabled():
            live_status, _, live_tar = http_request(
                "https://sylvan.apple.com/Aerials/resources-16.tar", timeout=25.0
            )
            self.assertEqual(live_status, 200)
            with tarfile.open(fileobj=io.BytesIO(live_tar), mode="r:") as tf:
                self.assertIn("entries.json", tf.getnames())
                live_entries = json.loads(tf.extractfile("entries.json").read().decode("utf-8"))
                self.assertGreaterEqual(len(live_entries.get("assets", [])), 50)

            for curated_url in (
                "https://sylvan.apple.com/Aerials/2x/Videos/HK_H004_C013_4K_SDR_HEVC.mov",
                "https://sylvan.apple.com/Aerials/2x/Videos/SE_A016_C009_SDR_20190717_SDR_4K_HEVC.mov",
            ):
                head_s, head_h, _ = http_request(curated_url, method="HEAD", timeout=20.0)
                self.assertEqual(head_s, 200)
                self.assertIn("video/quicktime", head_h.get("content-type", ""))
                vid_status, vid_hdrs, vid_chunk = http_request(
                    curated_url,
                    headers={"Range": "bytes=0-511"},
                    timeout=20.0,
                )
                self.assertIn(vid_status, (200, 206))
                self.assertIn("video/quicktime", vid_hdrs.get("content-type", ""))
                self.assertGreater(len(vid_chunk), 0)

    # T1-F2-02
    def test_t1_f2_02_wallhaven_sfw_search_and_detail(self) -> None:
        status, headers, body = http_request(
            f"{self.base_url}/wallhaven/api/v1/search?q=landscape&purity=100"
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("x-ratelimit-limit"), "45")
        payload = json.loads(body.decode("utf-8"))
        self.assertEqual(payload["meta"]["query"], "landscape")
        self.assertGreaterEqual(len(payload["data"]), 2)
        first = payload["data"][0]
        self.assertEqual(first["purity"], "sfw")
        self.assertIn("thumbs", first)

        d_status, _, d_body = http_request(f"{self.base_url}/wallhaven/api/v1/w/{first['id']}")
        self.assertEqual(d_status, 200)
        detail = json.loads(d_body.decode("utf-8"))["data"]
        self.assertIn("tags", detail)
        self.assertIn("uploader", detail)

        if is_live_enabled():
            l_status, l_hdrs, l_body = http_request(
                "https://wallhaven.cc/api/v1/search?q=landscape&purity=100", timeout=20.0
            )
            self.assertEqual(l_status, 200)
            self.assertIn("application/json", l_hdrs.get("content-type", ""))
            live_payload = json.loads(l_body.decode("utf-8"))
            self.assertGreater(len(live_payload.get("data", [])), 0)
            self.assertEqual(live_payload["meta"]["query"], "landscape")

    # T1-F2-03
    def test_t1_f2_03_pexels_landscape_uhd_sd_and_curated(self) -> None:
        status, headers, body = http_request(
            f"{self.base_url}/pexels/v1/videos/search?query=waves",
            headers={"Authorization": "valid_pexels_test_key"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("x-ratelimit-limit"), "200")
        payload = json.loads(body.decode("utf-8"))
        vfiles = payload["videos"][0]["video_files"]
        landscape_mp4s = [
            vf
            for vf in vfiles
            if vf.get("file_type") == "video/mp4"
            and (vf.get("width") or 0) >= (vf.get("height") or 0)
        ]
        qualities = {vf.get("quality") for vf in landscape_mp4s}
        self.assertEqual(qualities, {"uhd", "hd", "sd"})

        p_status, _, p_body = http_request(
            f"{self.base_url}/pexels/v1/curated",
            headers={"Authorization": "valid_pexels_test_key"},
        )
        self.assertEqual(p_status, 200)
        photos = json.loads(p_body.decode("utf-8"))["photos"]
        self.assertGreaterEqual(len(photos), 2)
        self.assertIn("original", photos[0]["src"])

    # T1-F2-04
    def test_t1_f2_04_pixabay_video_and_photo_search(self) -> None:
        v_status, v_hdrs, v_body = http_request(
            f"{self.base_url}/pixabay/api/videos/?key=valid_pixabay_key&safesearch=true&q=ocean"
        )
        self.assertEqual(v_status, 200)
        self.assertEqual(v_hdrs.get("x-ratelimit-limit"), "100")
        v_payload = json.loads(v_body.decode("utf-8"))
        self.assertGreater(len(v_payload["hits"]), 0)
        self.assertTrue(v_payload["hits"][0]["videos"]["large"]["url"].startswith(self.base_url))

        p_status, _, p_body = http_request(
            f"{self.base_url}/pixabay/api/?key=valid_pixabay_key&safesearch=true&q=sunset"
        )
        self.assertEqual(p_status, 200)
        p_payload = json.loads(p_body.decode("utf-8"))
        self.assertTrue(p_payload["hits"][0]["largeImageURL"].startswith(self.base_url))

    # T1-F2-05
    def test_t1_f2_05_custom_feed_wrapped_and_array(self) -> None:
        w_status, _, w_body = http_request(f"{self.base_url}/custom/wrapped.json")
        self.assertEqual(w_status, 200)
        wrapped = json.loads(w_body.decode("utf-8"))
        self.assertEqual(len(wrapped["items"]), 3)
        for item in wrapped["items"]:
            self.assertTrue(item["url"].startswith(self.base_url + "/media/"))
            m_status, _, _ = http_request(item["url"], method="HEAD")
            self.assertEqual(m_status, 200)

        a_status, _, a_body = http_request(f"{self.base_url}/custom/array.json")
        self.assertEqual(a_status, 200)
        arr = json.loads(a_body.decode("utf-8"))
        self.assertIsInstance(arr, list)
        self.assertEqual(len(arr), 2)

    # T1-F3-04 (Track A HTTP Range/Streaming server contract)
    def test_t1_f3_04_media_streaming_and_byte_ranges(self) -> None:
        for fname, expected_mime in (
            ("sample_video.mp4", "video/mp4"),
            ("sample_aerial_4k.mov", "video/quicktime"),
            ("sample_image.jpg", "image/jpeg"),
        ):
            url = f"{self.base_url}/media/{fname}"
            h_status, h_hdrs, h_body = http_request(url, method="HEAD")
            self.assertEqual(h_status, 200)
            self.assertEqual(h_body, b"")
            self.assertEqual(h_hdrs.get("accept-ranges"), "bytes")
            self.assertIn(expected_mime, h_hdrs.get("content-type", ""))
            total_len = int(h_hdrs["content-length"])
            self.assertGreater(total_len, 512)

            f_status, _, full_body = http_request(url)
            self.assertEqual(f_status, 200)
            self.assertEqual(len(full_body), total_len)

            r_status, r_hdrs, r_body = http_request(url, headers={"Range": "bytes=0-511"})
            self.assertEqual(r_status, 206)
            self.assertEqual(r_hdrs.get("content-range"), f"bytes 0-511/{total_len}")
            self.assertEqual(r_body, full_body[:512])

    # T1-F4-05
    def test_t1_f4_05_media_fixtures_valid(self) -> None:
        media_dir = get_media_dir()
        expected = {
            "sample_video.mp4": "MP4",
            "sample_video.mov": "QuickTime",
            "sample_aerial_4k.mov": "QuickTime",
            "sample_image.jpg": "JPEG",
            "sample_image.png": "PNG",
            "sample_image.heic": "HEIF",
            "seal.jpg": "JPEG",
        }
        for fname, marker in expected.items():
            info = validate_media_file(media_dir / fname)
            self.assertGreater(info["size"], 0, f"{fname} must be non-empty")
            self.assertIn(marker, info["file"], f"{fname} unexpected file magic: {info['file']}")

    # T1-F5-05
    def test_t1_f5_05_host_pmset_batt_readability(self) -> None:
        res = subprocess.run(
            ["/usr/bin/pmset", "-g", "batt"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0, f"pmset -g batt failed: {res.stderr}")

        batt_reg = subprocess.run(
            ["/usr/sbin/ioreg", "-rc", "AppleSmartBattery"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(batt_reg.returncode, 0, f"ioreg failed: {batt_reg.stderr}")

        has_battery = ("AppleSmartBattery" in batt_reg.stdout) or ("InternalBattery" in res.stdout)
        if has_battery:
            self.assertIn("Now drawing from", res.stdout)
            self.assertTrue(
                ("AC Power" in res.stdout) or ("Battery Power" in res.stdout),
                f"Expected AC Power or Battery Power in pmset output: {res.stdout!r}",
            )
        elif any(tok in res.stdout for tok in ("Battery", "AC Power", "UPS", "drawing")):
            self.assertIn("Now drawing from", res.stdout)

    # T1-F6-01
    def test_t1_f6_01_app_launch_and_clean_sigterm(self) -> None:
        app = self._require_app_bundle()
        with tempfile.TemporaryDirectory(prefix="aurawall_e2e_home_") as tmp:
            res = launch_app_and_verify_sigterm(app, Path(tmp))
            self.assertIn(res["returncode"], (0, -15))

    # T1-F6-04
    def test_t1_f6_04_supported_import_media_fixtures(self) -> None:
        media_dir = get_media_dir()
        supported_files = [
            "sample_video.mp4",
            "sample_video.mov",
            "sample_image.jpg",
            "sample_image.png",
            "sample_image.heic",
        ]
        for fname in supported_files:
            info = validate_media_file(media_dir / fname)
            self.assertGreater(info["size"], 0)
            self.assertTrue((get_fixtures_dir() / "custom_feed_wrapped.json").is_file())


if __name__ == "__main__":
    unittest.main()
