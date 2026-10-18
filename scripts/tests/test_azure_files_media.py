"""Offline tests for Azure Files commands and Jellyfin metadata."""

import argparse
import contextlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import azure_files_media as media


class FakeAzureFiles(media.AzureFiles):
    def __init__(self):
        super().__init__("testaccount", "media")
        self.directories = set()
        self.files = {}
        self.calls = []
        self.fail_video = False

    def command(self, resource, operation, *arguments):
        self.calls.append((resource, operation, arguments))
        args = dict(zip(arguments[::2], arguments[1::2]))
        if resource == "directory":
            path = PurePosixPath(args["--name"])
            if operation == "create":
                if args["--fail-on-exist"] == "true" and path in self.directories:
                    raise subprocess.CalledProcessError(1, "az", stderr="already exists")
                self.directories.add(path)
            elif operation == "delete":
                self.directories.remove(path)
            return {}
        path = PurePosixPath(args["--path"])
        if operation == "exists":
            return {"exists": path in self.files}
        if operation == "list":
            return [{"name": remote.name} for remote in self.files if remote.parent == path]
        if operation == "upload":
            if self.fail_video and path.suffix == ".mp4":
                self.files[path] = b"partial"
                raise subprocess.CalledProcessError(1, "az", stderr="network failure")
            self.files[path] = Path(args["--source"]).read_bytes()
            return {}
        raise AssertionError((resource, operation, arguments))


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.video = Path(self.temporary.name) / "session.MP4"
        self.video.write_bytes(b"test video content")
        self.client = FakeAzureFiles()
        self.series = argparse.Namespace(
            series="D&D Campaign", overview="A < B & C", year=2026,
            genre=["RPG", "Fantasy"], tag=["D&D"],
        )
        self.episode = argparse.Namespace(
            series=self.series.series, video=self.video, title="Meeting & trouble",
            season=1, episode=1, overview="A < B", date="2026-10-18",
            runtime_minutes=180, tag=["session"],
        )

    def create(self):
        return media.create_series(self.client, self.series)

    def test_create_series_xml_and_duplicate_refusal(self):
        result = self.create()
        metadata = ET.fromstring(self.client.files[result / "tvshow.nfo"])
        self.assertEqual(metadata.tag, "tvshow")
        self.assertEqual(metadata.findtext("title"), "D&D Campaign")
        self.assertEqual(metadata.findtext("plot"), "A < B & C")
        self.assertEqual([item.text for item in metadata.findall("genre")], ["RPG", "Fantasy"])
        before = dict(self.client.files)
        with self.assertRaises(subprocess.CalledProcessError):
            self.create()
        self.assertEqual(before, self.client.files)

    def test_upload_preserves_source_and_writes_episode_metadata(self):
        self.create()
        result = media.upload_episode(self.client, self.episode)
        self.assertEqual(str(result),
                         "D&D Campaign/Season 01/S01E01 - Meeting & trouble.mp4")
        self.assertEqual(self.client.files[result], self.video.read_bytes())
        metadata = ET.fromstring(self.client.files[result.with_suffix(".nfo")])
        self.assertEqual(metadata.tag, "episodedetails")
        for field, value in [("title", self.episode.title), ("season", "1"), ("episode", "1"),
                             ("plot", "A < B"), ("aired", "2026-10-18"), ("runtime", "180")]:
            self.assertEqual(metadata.findtext(field), value)
        self.assertNotIn(PurePosixPath("D&D Campaign/.jellyfin-upload-lock"),
                         self.client.directories)
        listing = [call for call in self.client.calls if call[:2] == ("file", "list")][0]
        self.assertIn("*", listing[2])

    def test_duplicate_number_even_with_changed_title_or_extension(self):
        self.create()
        media.upload_episode(self.client, self.episode)
        self.episode.title = "Different title"
        before = dict(self.client.files)
        with self.assertRaisesRegex(ValueError, "already exists"):
            media.upload_episode(self.client, self.episode)
        self.assertEqual(before, self.client.files)
        self.assertNotIn(PurePosixPath("D&D Campaign/.jellyfin-upload-lock"),
                         self.client.directories)

    def test_unknown_series_is_not_created(self):
        with self.assertRaisesRegex(ValueError, "create the series first"):
            media.upload_episode(self.client, self.episode)
        self.assertEqual(self.client.directories, set())

    def test_invalid_sources_do_not_make_network_calls(self):
        for path in [self.video.parent / "missing.mp4", self.video.parent, self.video]:
            self.video.write_bytes(b"")
            self.episode.video = path
            with self.assertRaises((OSError, ValueError)):
                media.upload_episode(self.client, self.episode)
            self.assertEqual(self.client.calls, [])

    def test_failed_upload_retains_reservation_and_refuses_retry(self):
        self.create()
        self.client.fail_video = True
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                media.upload_episode(self.client, self.episode)
        self.assertIn(PurePosixPath("D&D Campaign/.jellyfin-upload-lock"),
                      self.client.directories)
        before = dict(self.client.files)
        with self.assertRaises(subprocess.CalledProcessError):
            media.upload_episode(self.client, self.episode)
        self.assertEqual(before, self.client.files)

    def test_specials(self):
        self.create()
        self.episode.season = 0
        result = media.upload_episode(self.client, self.episode)
        self.assertIn("Season 00/S00E01", str(result))

    def test_input_validation(self):
        for value in ["..", "../escape", "/absolute", "name/child", "trailing.",
                      " space", "bad\\name", "bad\nname", "", "é" * 100]:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                media.name(value)
        for value in ["0", "-1", "10000", "abc"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                media.number(value)
        for value in ["2026-02-30", "20261018", "2026-1-1"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                media.date(value)
        with self.assertRaises(argparse.ArgumentTypeError):
            media.text("bad\x00xml")
        self.assertEqual(media.season_number("0"), 0)


class CommandTests(unittest.TestCase):
    def test_commands_use_oauth_backup_intent_and_no_ambient_secrets(self):
        client = media.AzureFiles("testaccount", "media")
        with mock.patch.dict(os.environ, {
            "AZURE_STORAGE_KEY": "dummy", "AZURE_STORAGE_SAS_TOKEN": "dummy",
            "AZURE_STORAGE_CONNECTION_STRING": "dummy",
            "AZURE_STORAGE_SERVICE_ENDPOINT": "https://unwanted.example",
        }), mock.patch.object(media.subprocess, "run",
                              return_value=mock.Mock(stdout='{"exists": true}')) as command:
            self.assertTrue(client.command("file", "exists", "--path", "D&D/tvshow.nfo")["exists"])
            args = command.call_args.args[0]
            self.assertEqual(args[args.index("--auth-mode") + 1], "login")
            self.assertIn("--enable-file-backup-request-intent", args)
            self.assertIn("D&D/tvshow.nfo", args)
            self.assertNotIn("AZURE_STORAGE_KEY", command.call_args.kwargs["env"])
            self.assertNotIn("AZURE_STORAGE_SAS_TOKEN", command.call_args.kwargs["env"])
            self.assertNotIn("AZURE_STORAGE_CONNECTION_STRING", command.call_args.kwargs["env"])
            self.assertNotIn("AZURE_STORAGE_SERVICE_ENDPOINT", command.call_args.kwargs["env"])

    def test_cli_failures_propagate_without_fallback(self):
        client = media.AzureFiles("testaccount", "media")
        with mock.patch.object(media.subprocess, "run",
                               side_effect=subprocess.CalledProcessError(1, "az")) as command:
            with self.assertRaises(subprocess.CalledProcessError):
                client.command("file", "exists", "--path", "show/tvshow.nfo")
            self.assertEqual(command.call_count, 1)

    def test_invalid_destinations(self):
        for account, share in [("bad/account", "media"), ("testaccount", "../escape"),
                               ("testaccount", "ab"), ("testaccount", "bad--share")]:
            with self.assertRaises(ValueError):
                media.AzureFiles(account, share)


if __name__ == "__main__":
    unittest.main()
