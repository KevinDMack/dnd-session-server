"""Regression tests for VM media helpers; no Azure access or root required."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vm_media


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.media = self.root / "media"
        self.media.mkdir()
        self.series = argparse.Namespace(
            series="D&D Campaign", overview="A < B & C", year=2026,
            genre=["RPG", "Fantasy"], tag=["D&D"],
        )
        self.video = self.root / "recording.MP4"
        self.video.write_bytes(b"test video content")
        self.episode = argparse.Namespace(
            series=self.series.series, video=self.video, title="Meeting & trouble",
            season=1, episode=1, overview="A < B", date="2026-10-18",
            runtime_minutes=180, tag=["session"],
        )

    def create(self):
        return vm_media.create_series(self.media, self.series)

    def test_series_metadata_and_duplicate_refusal(self):
        result = self.create()
        metadata = ET.parse(self.media / result / "tvshow.nfo").getroot()
        self.assertEqual(metadata.tag, "tvshow")
        self.assertEqual(metadata.findtext("title"), "D&D Campaign")
        self.assertEqual(metadata.findtext("plot"), "A < B & C")
        self.assertEqual([item.text for item in metadata.findall("genre")], ["RPG", "Fantasy"])
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.create()

    def test_upload_metadata_video_and_source_preservation(self):
        self.create()
        result = vm_media.upload_episode(self.media, self.episode)
        self.assertEqual(str(result),
                         "D&D Campaign/Season 01/S01E01 - Meeting & trouble.mp4")
        self.assertEqual((self.media / result).read_bytes(), self.video.read_bytes())
        metadata = ET.parse((self.media / result).with_suffix(".nfo")).getroot()
        self.assertEqual(metadata.tag, "episodedetails")
        for field, expected in [("title", self.episode.title), ("season", "1"),
                                ("episode", "1"), ("aired", "2026-10-18"),
                                ("runtime", "180"), ("plot", "A < B")]:
            self.assertEqual(metadata.findtext(field), expected)
        self.assertFalse(list(self.media.glob(".episode-*")))

    def test_duplicate_number_with_different_title_is_rejected(self):
        self.create()
        vm_media.upload_episode(self.media, self.episode)
        self.episode.title = "Different title"
        with self.assertRaisesRegex(ValueError, "already exists"):
            vm_media.upload_episode(self.media, self.episode)

    def test_unknown_series_and_missing_source(self):
        with self.assertRaises(ValueError):
            vm_media.upload_episode(self.media, self.episode)
        self.create()
        self.episode.video = self.root / "missing.mp4"
        with self.assertRaises(FileNotFoundError):
            vm_media.upload_episode(self.media, self.episode)

    def test_symlink_series_and_season_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        series = self.media / self.series.series
        series.symlink_to(outside)
        with self.assertRaises(ValueError):
            vm_media.upload_episode(self.media, self.episode)
        with self.assertRaises(ValueError):
            self.create()
        series.unlink()
        self.create()
        (series / "Season 01").symlink_to(outside)
        with self.assertRaises(ValueError):
            vm_media.upload_episode(self.media, self.episode)
        self.assertEqual(list(outside.iterdir()), [])

    def test_copy_failure_leaves_no_published_episode(self):
        self.create()
        with mock.patch.object(vm_media.shutil, "copyfile", side_effect=OSError("full")):
            with self.assertRaises(OSError):
                vm_media.upload_episode(self.media, self.episode)
        self.assertEqual(list((self.media / self.series.series / "Season 01").iterdir()), [])
        self.assertFalse(list(self.media.glob(".episode-*")))

    def test_invalid_video(self):
        self.create()
        self.video.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "empty"):
            vm_media.upload_episode(self.media, self.episode)
        self.episode.video = self.root / "notes.txt"
        self.episode.video.write_text("not a video")
        with self.assertRaisesRegex(ValueError, "supported extension"):
            vm_media.upload_episode(self.media, self.episode)

    def test_input_validation(self):
        for value in ["..", "../escape", "/absolute", "name/child", "trailing.",
                      " space", "bad\\name", "bad\nname", "", "é" * 100]:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                vm_media.name(value)
        for value in ["0", "-1", "10000", "abc"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                vm_media.number(value)
        for value in ["2026-02-30", "20261018", "2026-1-1"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                vm_media.date(value)
        with self.assertRaises(argparse.ArgumentTypeError):
            vm_media.text("bad\x00xml")
        self.assertEqual(vm_media.season_number("0"), 0)
        self.assertEqual(vm_media.date("2026-10-18"), "2026-10-18")


class MountTests(unittest.TestCase):
    def test_mount_settings_use_existing_identity_without_keys(self):
        source = "//testaccount.file.core.windows.net/media"
        unit = (
            f"[Mount]\nWhat={source}\n"
            "Options=ro,username=12345678-1234-1234-1234-123456789abc,"
            "sec=krb5,cruid=azfilesuser\n"
        )
        result = mock.Mock(stdout=json.dumps({
            "filesystems": [{"source": source, "fstype": "cifs"}],
        }))
        with mock.patch("builtins.open", mock.mock_open(read_data=unit)), \
                mock.patch.object(vm_media.subprocess, "run", return_value=result), \
                mock.patch.object(vm_media.pwd, "getpwnam", return_value=mock.Mock(pw_uid=1234)):
            actual_source, options = vm_media.mount_settings()
            self.assertEqual(source, actual_source)
            self.assertIn("cruid=1234", options)
            self.assertIn("nosharesock", options)
            self.assertNotIn("mfsymlinks", options)
            self.assertTrue(options.startswith("rw,"))
            result.stdout = json.dumps({"filesystems": [{"source": "/dev/sda", "fstype": "ext4"}]})
            with self.assertRaisesRegex(ValueError, "not mounted"):
                vm_media.mount_settings()

    def test_nonroot_refused(self):
        with mock.patch.object(vm_media.os, "geteuid", return_value=1000):
            with self.assertRaisesRegex(ValueError, "sudo"):
                with vm_media.writable_media():
                    self.fail("must not yield")

    def exercise_mount(self, fail_mount=False, fail_action=False):
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "lock"
            mount = Path(temporary) / "mount"
            mount.mkdir()
            real_open = vm_media.os.open

            def open_lock(path, flags, mode=0o777, **kwargs):
                if path == "/run/jellyfin-media-upload.lock":
                    path = lock
                return real_open(path, flags, mode, **kwargs)

            with mock.patch.object(vm_media.os, "geteuid", return_value=0), \
                    mock.patch.object(vm_media.os, "open", side_effect=open_lock), \
                    mock.patch.object(vm_media, "mount_settings", return_value=("//share", "rw")), \
                    mock.patch.object(vm_media.tempfile, "mkdtemp", return_value=str(mount)), \
                    mock.patch.object(vm_media.os.path, "ismount", return_value=not fail_mount), \
                    mock.patch.object(vm_media.subprocess, "run") as command:
                if fail_mount:
                    command.side_effect = subprocess.CalledProcessError(1, "mount")
                if fail_mount or fail_action:
                    with self.assertRaises((subprocess.CalledProcessError, ValueError)):
                        with vm_media.writable_media():
                            if fail_action:
                                raise ValueError("operation failed")
                            self.fail("failed mount must not yield")
                else:
                    with vm_media.writable_media() as root:
                        self.assertEqual(root, mount)
                self.assertFalse(mount.exists())
                if not fail_mount:
                    self.assertEqual(command.call_args.args[0], ["umount", str(mount)])

    def test_success_unmounts(self):
        self.exercise_mount()

    def test_operation_failure_unmounts(self):
        self.exercise_mount(fail_action=True)

    def test_mount_failure_never_yields_local_directory(self):
        self.exercise_mount(fail_mount=True)


if __name__ == "__main__":
    unittest.main()
