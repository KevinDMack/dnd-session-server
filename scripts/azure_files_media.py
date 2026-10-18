"""Jellyfin NFO generation and Azure Files uploads using Azure CLI login."""

from __future__ import annotations

import argparse
import contextlib
import datetime
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


VIDEO_EXTENSIONS = {".mp4", ".mkv", ".mov", ".m4v", ".avi", ".webm", ".ts", ".m2ts"}


def text(value: str) -> str:
    if any(
        not (char in "\t\n\r" or "\x20" <= char <= "\ud7ff"
             or "\ue000" <= char <= "\ufffd" or "\U00010000" <= char <= "\U0010ffff")
        for char in value
    ):
        raise argparse.ArgumentTypeError("metadata contains invalid XML characters")
    return value


def name(value: str) -> str:
    text(value)
    if (
        not value.strip() or value != value.strip() or value.endswith(".")
        or value in {".", ".."} or re.search(r'[<>:"/\\|?*\x00-\x1f]', value)
        or len(value.encode("utf-8")) > 180
    ):
        raise argparse.ArgumentTypeError("use a plain filename component (up to 180 UTF-8 bytes)")
    return value


def number(value: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer from 1 to 9999") from error
    if not 1 <= result <= 9999:
        raise argparse.ArgumentTypeError("must be an integer from 1 to 9999")
    return result


def season_number(value: str) -> int:
    return 0 if value == "0" else number(value)


def date(value: str) -> str:
    try:
        if datetime.date.fromisoformat(value).isoformat() != value:
            raise ValueError
    except ValueError as error:
        raise argparse.ArgumentTypeError("date must be YYYY-MM-DD") from error
    return value


def nfo(root_name: str, fields: list[tuple[str, object]]) -> bytes:
    root = ET.Element(root_name)
    for key, value in fields:
        if value is not None:
            ET.SubElement(root, key).text = str(value)
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def storage_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--account-name", required=True, help="Azure Files storage account")
    parser.add_argument("--share-name", default="media", help="file share (default: media)")


class AzureFiles:
    def __init__(self, account: str, share: str):
        if not re.fullmatch(r"[a-z0-9]{3,24}", account):
            raise ValueError("invalid Azure storage account name")
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])", share) or "--" in share:
            raise ValueError("invalid Azure Files share name")
        self.account = account
        self.share = share

    def command(self, resource: str, operation: str, *arguments: str):
        # Do not let ambient shared-key/SAS settings override explicit OAuth login.
        environment = {
            key: value for key, value in os.environ.items()
            if key not in {
                "AZURE_STORAGE_KEY", "AZURE_STORAGE_CONNECTION_STRING",
                "AZURE_STORAGE_SAS_TOKEN", "AZURE_STORAGE_SERVICE_ENDPOINT",
            }
        }
        result = subprocess.run([
            "az", "storage", resource, operation,
            "--account-name", self.account, "--share-name", self.share,
            "--auth-mode", "login", "--enable-file-backup-request-intent",
            "--only-show-errors", "--output", "json", *arguments,
        ], check=True, capture_output=True, text=True, env=environment)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def mkdir(self, path: PurePosixPath, exclusive: bool = False) -> None:
        self.command("directory", "create", "--name", str(path),
                     "--fail-on-exist", str(exclusive).lower())

    def upload(self, local: Path, remote: PurePosixPath) -> None:
        print(f"Uploading {remote}", flush=True)
        self.command("file", "upload", "--source", str(local), "--path", str(remote),
                     "--no-progress")

    @contextlib.contextmanager
    def reservation(self, path: PurePosixPath):
        # Exclusive directory creation coordinates writers across client machines.
        self.mkdir(path, exclusive=True)
        state = {"upload_started": False}
        try:
            yield state
        except BaseException:
            if state["upload_started"]:
                print(f"Upload failed. Inspect {path} and any partial files before retrying.",
                      file=sys.stderr)
                # A remote write may succeed even if the client loses its response.
            else:
                self.command("directory", "delete", "--name", str(path), "--fail-not-exist")
            raise
        else:
            self.command("directory", "delete", "--name", str(path), "--fail-not-exist")


def create_series(client: AzureFiles, args: argparse.Namespace) -> PurePosixPath:
    series = PurePosixPath(args.series)
    metadata = nfo("tvshow", [
        ("title", args.series), ("plot", args.overview), ("year", args.year),
        *(("genre", value) for value in args.genre),
        *(("tag", value) for value in args.tag),
    ])
    with tempfile.TemporaryDirectory(prefix="jellyfin-series-") as temporary:
        local = Path(temporary) / "tvshow.nfo"
        local.write_bytes(metadata)
        client.mkdir(series, exclusive=True)
        # Retain a failed series for inspection instead of risking deletion of data.
        client.upload(local, series / "tvshow.nfo")
    return series


def upload_episode(client: AzureFiles, args: argparse.Namespace) -> PurePosixPath:
    source = args.video.resolve(strict=True)
    if not source.is_file() or source.suffix.lower() not in VIDEO_EXTENSIONS:
        raise ValueError("source must be an existing video file with a supported extension")
    if source.stat().st_size == 0:
        raise ValueError("source video is empty")
    series = PurePosixPath(args.series)
    season = series / f"Season {args.season:02d}"
    prefix = f"S{args.season:02d}E{args.episode:02d}"
    stem = f"{prefix} - {args.title}"
    video = season / f"{stem}{source.suffix.lower()}"
    sidecar = season / f"{stem}.nfo"
    metadata = nfo("episodedetails", [
        ("title", args.title), ("season", args.season), ("episode", args.episode),
        ("plot", args.overview), ("aired", args.date),
        ("runtime", args.runtime_minutes), *(("tag", value) for value in args.tag),
    ])
    if not client.command("file", "exists", "--path", str(series / "tvshow.nfo"))["exists"]:
        raise ValueError("existing series must contain tvshow.nfo; create the series first")
    # One series-wide reservation also serializes creation of season directories.
    with client.reservation(series / ".jellyfin-upload-lock") as reservation:
        client.mkdir(season)
        children = client.command("file", "list", "--path", str(season), "--num-results", "*")
        duplicate = re.compile(rf"^{re.escape(prefix)}(?:\D|$)", re.IGNORECASE)
        if any(duplicate.match(child["name"]) for child in children):
            raise ValueError(f"episode {prefix} already exists; refusing to overwrite")
        with tempfile.TemporaryDirectory(prefix="jellyfin-episode-") as temporary:
            local = Path(temporary) / "episode.nfo"
            local.write_bytes(metadata)
            reservation["upload_started"] = True
            client.upload(local, sidecar)
            client.upload(source, video)
    return video


def run(action, args: argparse.Namespace) -> int:
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    previous_handler = signal.signal(signal.SIGTERM, interrupted)
    try:
        result = action(AzureFiles(args.account_name, args.share_name), args)
        print(f"Created {result}. Run Scan Library Files in Jellyfin.")
        return 0
    except subprocess.CalledProcessError as error:
        print(f"error: Azure CLI failed:\n{error.stderr or error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: interrupted; inspect remote files before retrying", file=sys.stderr)
        return 130
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
