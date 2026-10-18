"""Shared helpers for administrator-only Jellyfin media management on the VM."""

from __future__ import annotations

import argparse
import configparser
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


PLAYBACK = "/srv/jellyfin/media"
MOUNT_UNIT = "/etc/systemd/system/srv-jellyfin-media.mount"
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


def directory(path: Path) -> Path:
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"not a real directory: {path}")
    return path


def create_series(root: Path, args: argparse.Namespace) -> Path:
    destination = root / args.series
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"series already exists: {args.series}")
    metadata = nfo("tvshow", [
        ("title", args.series), ("plot", args.overview), ("year", args.year),
        *(("genre", value) for value in args.genre),
        *(("tag", value) for value in args.tag),
    ])
    with tempfile.TemporaryDirectory(prefix=".series-", dir=root) as temporary:
        staging = Path(temporary) / args.series
        staging.mkdir(mode=0o755)
        (staging / "tvshow.nfo").write_bytes(metadata)
        (staging / "tvshow.nfo").chmod(0o644)
        staging.rename(destination)
    return destination.relative_to(root)


def upload_episode(root: Path, args: argparse.Namespace) -> Path:
    series = directory(root / args.series)
    series_nfo = series / "tvshow.nfo"
    if series_nfo.is_symlink() or not series_nfo.is_file():
        raise ValueError("existing series must contain a regular tvshow.nfo")
    if ET.parse(series_nfo).getroot().tag != "tvshow":
        raise ValueError("existing series NFO must have a tvshow root")
    source = args.video.resolve(strict=True)
    if not source.is_file() or source.suffix.lower() not in VIDEO_EXTENSIONS:
        raise ValueError("source must be an existing video file with a supported extension")
    if source.stat().st_size == 0:
        raise ValueError("source video is empty")
    season = series / f"Season {args.season:02d}"
    if season.is_symlink():
        raise ValueError(f"season must not be a symlink: {season}")
    season.mkdir(mode=0o755, exist_ok=True)
    directory(season)
    prefix = f"S{args.season:02d}E{args.episode:02d}"
    duplicate = re.compile(rf"^{re.escape(prefix)}(?:\D|$)", re.IGNORECASE)
    if any(duplicate.match(child.name) for child in season.iterdir()):
        raise ValueError(f"episode {prefix} already exists; refusing to overwrite")
    stem = f"{prefix} - {args.title}"
    video = season / f"{stem}{source.suffix.lower()}"
    sidecar = season / f"{stem}.nfo"
    metadata = nfo("episodedetails", [
        ("title", args.title), ("season", args.season), ("episode", args.episode),
        ("plot", args.overview), ("aired", args.date),
        ("runtime", args.runtime_minutes), *(("tag", value) for value in args.tag),
    ])
    # Keep partially copied videos outside the visible season until fully written.
    with tempfile.TemporaryDirectory(prefix=".episode-", dir=root) as temporary:
        staging = Path(temporary)
        staged_video = staging / video.name
        shutil.copyfile(source, staged_video)
        staged_video.chmod(0o644)
        staged_nfo = staging / sidecar.name
        staged_nfo.write_bytes(metadata)
        staged_nfo.chmod(0o644)
        staged_nfo.rename(sidecar)
        try:
            staged_video.rename(video)
        except BaseException:
            sidecar.unlink()
            raise
    return video.relative_to(root)


def mount_settings() -> tuple[str, str]:
    unit = configparser.ConfigParser(interpolation=None)
    if not unit.read(MOUNT_UNIT):
        raise ValueError(f"missing VM mount configuration: {MOUNT_UNIT}")
    source = unit["Mount"]["What"]
    options = dict(
        option.split("=", 1) for option in unit["Mount"]["Options"].split(",")
        if "=" in option
    )
    if not re.fullmatch(r"//[a-z0-9]+\.file\.core\.windows\.net/[a-z0-9-]+", source):
        raise ValueError("mount unit does not point to an Azure Files share")
    client = options.get("username", "")
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", client):
        raise ValueError("mount unit must specify a managed identity client ID")
    if options.get("sec") != "krb5" or options.get("cruid") != "azfilesuser":
        raise ValueError("mount unit must use managed identity Kerberos credentials")
    result = subprocess.run(
        ["findmnt", "--json", "--mountpoint", PLAYBACK, "--output", "SOURCE,FSTYPE"],
        check=True, capture_output=True, text=True,
    )
    mounts = json.loads(result.stdout)["filesystems"]
    if len(mounts) != 1 or mounts[0]["source"] != source or mounts[0]["fstype"] != "cifs":
        raise ValueError("playback share is not mounted as expected; repair it first")
    uid = pwd.getpwnam("azfilesuser").pw_uid
    return source, (
        f"rw,username={client},sec=krb5,cruid={uid},vers=3.1.1,seal,nosharesock,"
        "uid=1000,gid=1000,dir_mode=0755,file_mode=0644,nodev,nosuid,noexec"
    )


@contextlib.contextmanager
def writable_media():
    if os.geteuid() != 0:
        raise ValueError("run with sudo on the Jellyfin VM")
    # Serialize our writers without changing Jellyfin's read-only mount.
    fd = os.open("/run/jellyfin-media-upload.lock",
                 os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source, options = mount_settings()
        mountpoint = Path(tempfile.mkdtemp(prefix="jellyfin-upload-", dir="/run"))
        try:
            subprocess.run(
                ["mount", "-t", "cifs", source, str(mountpoint), "-o", options],
                check=True,
            )
            if not os.path.ismount(mountpoint):
                raise ValueError("writable share did not mount; refusing local writes")
            yield mountpoint
        finally:
            if os.path.ismount(mountpoint):
                subprocess.run(["umount", str(mountpoint)], check=True)
            mountpoint.rmdir()


def run(action, args: argparse.Namespace) -> int:
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    previous_handler = signal.signal(signal.SIGTERM, interrupted)
    try:
        with writable_media() as root:
            result = action(root, args)
        print(f"Created {result}. Run Scan Library Files in Jellyfin.")
        return 0
    except (OSError, ValueError, KeyError, configparser.Error,
            ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: interrupted; upload was not completed", file=sys.stderr)
        return 130
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
