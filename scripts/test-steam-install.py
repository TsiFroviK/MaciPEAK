"""Regression checks for local Steam integration, using synthetic files only."""

import hashlib
import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

import steam_appinfo as info


spec = importlib.util.spec_from_file_location("steam_install", Path(__file__).with_name("steam-install.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def catalog(version=41, mac=False, build="26542162", oses="windows", extended="", legacy=False):
    keys = []
    def kv(entries):
        data = bytearray()
        for key, value in entries.items():
            if key not in keys:
                keys.append(key)
            data += struct.pack("<BI", 0 if isinstance(value, dict) else 1, keys.index(key))
            data += kv(value) if isinstance(value, dict) else value.encode() + b"\0"
        return bytes(data) + b"\x08"
    choices = {"0": {"config": {"oslist": "windows"}, "executable": "sample.exe"}}
    if mac:
        choices["2"] = {"config": {"oslist": "macos"}, "executable": "other.app"}
    if legacy:
        choices["1"] = {"executable": info.LEGACY_LAUNCH, "type": "default",
                        "config": {"oslist": "macos"}, "description": info.DESCRIPTION}
    entries = [
        (111, kv({"other": {"first": "neighbour"}})),
        (info.APP_ID, kv({"appinfo": {
            "common": {"name": "PEAK", "oslist": oses, "osextended": extended},
            "config": {"installdir": "PEAK", "launch": choices},
            "depots": {"branches": {"public": {"buildid": build}}},
        }})),
        (222, kv({"other": {"last": "neighbour"}})),
    ]
    # A Steam table is shared. These keys already used by other apps avoid
    # unnecessarily extending the table when registering the native entry.
    keys.extend(k for k in ("1", "3", "type", "description") if k not in keys)
    key_table = b"".join(k.encode() + b"\0" for k in keys)
    if version == 41:
        rows = bytearray()
        for appid, raw in entries:
            rows += struct.pack("<II", appid, len(raw) + 60) + bytes(40) + hashlib.sha1(raw).digest() + raw
        rows += bytes(4)
        return struct.pack("<IIQ", 0x07564429, 1, len(rows) + 16) + rows + struct.pack("<I", len(keys)) + key_table
    index, payload = bytearray(), bytearray()
    for appid, raw in entries:
        segment = hashlib.sha1(raw).digest() + raw
        index += struct.pack("<IIII", appid, len(payload), len(segment), 64) + bytes(64)
        payload += segment
    header = struct.pack("<10I", 0x0756442a, 1, 77, 256, len(entries), len(index), len(keys),
                         len(key_table), len(payload), zlib.crc32(index + key_table))
    return header + struct.pack("<I", zlib.crc32(header)) + index + key_table + payload


class MetadataTests(unittest.TestCase):
    def test_round_trip_in_both_cache_formats(self):
        for version in (41, 42):
            with self.subTest(version=version):
                original = catalog(version)
                added = info.patch_cache(original)
                self.assertIn(info.LAUNCH.encode(), added)
                self.assertIn(b"macos64,macosapplesilicon\0", added)
                self.assertEqual(info.patch_cache(added), added)
                self.assertEqual(info.patch_cache(added, True), original)
                self.assertEqual(info.patch_cache(original, True), original)

    def test_invalid_or_conflicting_metadata(self):
        for version in (41, 42):
            with self.subTest(version=version):
                for raw in (catalog(version, mac=True), catalog(version, build="11"), b"future schema"):
                    with self.assertRaises((ValueError, struct.error)):
                        info.patch_cache(raw)
                damaged = catalog(version).replace(b"sample.exe", b"sample.abc")
                with self.assertRaises(ValueError):
                    info.patch_cache(damaged)

    def test_bundle_launch_preserves_existing_platform_flags(self):
        for version in (41, 42):
            for oses in ("windows", "windows,macos"):
                for previous in ("macos64", "macosapplesilicon", "macos64,macosapplesilicon"):
                    with self.subTest(version=version, oses=oses, previous=previous):
                        original = catalog(version, oses=oses, extended=previous)
                        native = info.patch_cache(original)
                        self.assertIn(b"PEAK.app\0", native)
                        self.assertEqual(info.patch_cache(native, True), original)

    def test_migrating_binary_launch_to_native_bundle(self):
        for previous in ("macos64", "macos64,macosapplesilicon"):
            with self.subTest(previous=previous):
                old = catalog(41, oses="windows,macos", extended=previous, legacy=True)
                native = info.patch_cache(old)
                self.assertNotIn(info.LEGACY_LAUNCH.encode(), native)
                self.assertIn(b"PEAK.app\0", native)
                self.assertIn(b"macos64,macosapplesilicon\0", native)
                self.assertEqual(info.patch_cache(native), native)
                self.assertEqual(info.patch_cache(native, True), info.patch_cache(old, True))

    def test_registering_different_architectures_preserves_original_metadata(self):
        for version in (41, 42):
            for original_flags in ("", "macosapplesilicon"):
                with self.subTest(version=version, original=original_flags):
                    original = catalog(version, extended=original_flags)
                    native = info.patch_cache(original)
                    intel = info.patch_cache(native, apple_silicon=False)
                    self.assertEqual(b"macosapplesilicon" in intel, bool(original_flags))
                    self.assertIn(b"macos64", intel)
                    self.assertEqual(info.patch_cache(intel, apple_silicon=False), intel)
                    self.assertEqual(info.patch_cache(intel), native)
                    self.assertEqual(info.patch_cache(intel, True), original)


@unittest.skipIf(sys.platform == "win32", "Steam library writes target POSIX macOS")
class LibraryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.steam = self.root / "profile"
        self.lib = self.root / "SSD with spaces"
        self.app = self.lib / "steamapps/common/PEAK/PEAK.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/PEAK").write_bytes(b"sample")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "PEAK", "CFBundleIdentifier": "local.peak.macport",
        }))
        self.files = [self.steam / "config/libraryfolders.vdf", self.steam / "steamapps/libraryfolders.vdf"]
        for path in self.files:
            path.parent.mkdir(parents=True)
            path.write_text('"libraryfolders" { "0" { "path" %s "contentid" "7" "apps" {"99" "101"} } }'
                            % installer.quoted(self.steam), encoding="utf-8")
        self.cache = self.steam / "appcache/appinfo.vdf"
        self.cache.parent.mkdir()
        self.cache.write_bytes(catalog())
        self.manifest = self.lib / "steamapps" / installer.MANIFEST
        idle = patch.object(installer.subprocess, "run")
        self.process = idle.start()
        self.steam_running = False
        self.architectures = "x86_64 arm64"
        def installed_tools(args, **kwargs):
            if args[0] == "/usr/bin/lipo":
                return subprocess.CompletedProcess(args, 0, self.architectures)
            self.assertEqual(args[0], "/usr/bin/pgrep")
            return subprocess.CompletedProcess(args, 0 if self.steam_running else 1)
        self.process.side_effect = installed_tools
        self.addCleanup(idle.stop)

    def apply(self, remove=False):
        installer.register(self.steam, str(self.lib), self.files, remove)

    def test_external_library_registration_and_idempotent_undo(self):
        self.apply()
        snapshot = {p: p.read_bytes() for p in [*self.files, self.cache, self.manifest]}
        self.apply()
        self.assertEqual(snapshot, {p: p.read_bytes() for p in snapshot})
        for path in self.files:
            _, libs = installer.read_libraries(path.read_bytes())
            self.assertEqual(libs[self.steam][1]["apps"][0]["99"][0], "101")
            self.assertIn(installer.APP, libs[self.lib][1]["apps"][0])
        self.apply(remove=True)
        self.apply(remove=True)
        self.assertEqual(self.cache.read_bytes(), catalog())
        self.assertFalse(self.manifest.exists())
        self.assertTrue((self.app / "Contents/MacOS/PEAK").is_file())

    def test_existing_manifest_and_other_fields_survive(self):
        stock = installer.new_manifest(22).replace(b'"StateFlags"', b'"custom" "untouched"\n "StateFlags"')
        self.manifest.write_bytes(stock)
        self.apply()
        self.apply(remove=True)
        self.assertEqual(self.manifest.read_bytes(), stock)

    def test_active_steam_blocks_all_changes(self):
        self.steam_running = True
        with self.assertRaisesRegex(ValueError, "Quit Steam"):
            self.apply()
        self.assertFalse(self.manifest.exists())
        self.assertEqual(self.cache.read_bytes(), catalog())

    def test_repairs_registration_from_installed_player_slices(self):
        for self.architectures in ("x86_64", "arm64", "x86_64 arm64", "x86_64"):
            self.apply()
            self.assertEqual(b"macosapplesilicon" in self.cache.read_bytes(), "arm64" in self.architectures)
        self.architectures = ""
        with self.assertRaisesRegex(ValueError, "supported architectures"):
            self.apply()
        self.apply(remove=True)
        self.assertEqual(self.cache.read_bytes(), catalog())

    def test_existing_symlink_is_rejected_during_path_selection(self):
        other = self.root / "other-library"
        other.mkdir()
        (other / "steamapps").symlink_to(self.lib / "steamapps", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            installer.choose_library(self.steam, str(other), self.files[0].read_bytes())

    def test_preserves_external_library_identity(self):
        descriptor = self.lib / "libraryfolder.vdf"
        descriptor.write_text('"libraryfolder" {"contentid" "4321" "label" "Existing SSD"}')
        self.apply()
        for path in self.files:
            _, libs = installer.read_libraries(path.read_bytes())
            self.assertEqual(libs[self.lib][1]["contentid"][0], "4321")
            self.assertEqual(libs[self.lib][1]["label"][0], "Existing SSD")

    def test_partial_failure_rolls_back_other_steam_files(self):
        original = {p: p.read_bytes() for p in [*self.files, self.cache]}
        real_replace = installer.replace
        def simulate_full_disk(path, data):
            if path == self.files[1]:
                raise OSError("disk full")
            real_replace(path, data)
        with patch.object(installer, "replace", side_effect=simulate_full_disk):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.apply()
        self.assertEqual(original, {p: p.read_bytes() for p in original})
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
