#!/usr/bin/env python3
"""Upload local recordings and Jellyfin NFO metadata to Azure Blob Storage."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from typing import Any


INVALID_PATH_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def safe_name(value: str) -> str:
    name = INVALID_PATH_CHARS.sub("_", value).strip().rstrip(".")
    if not name or name in {".", ".."}:
        raise ValueError(f"invalid path name: {value!r}")
    return name


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value.strip()


def require_positive_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{field} must be a positive integer")
    return value


def positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def add_text(parent: ET.Element, name: str, value: Any) -> None:
    if value is not None and str(value).strip():
        ET.SubElement(parent, name).text = str(value).strip()


def add_string_list(parent: ET.Element, name: str, values: Any, field: str) -> None:
    if values is None:
        return
    if not isinstance(values, list) or any(
        not isinstance(value, str) or not value.strip() for value in values
    ):
        raise ValueError(f"{field} must be an array of non-empty strings")
    for value in values:
        add_text(parent, name, value)


def xml_bytes(root: ET.Element) -> bytes:
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def create_series_nfo(series: dict[str, Any]) -> bytes:
    root = ET.Element("tvshow")
    add_text(root, "title", require_string(series.get("title"), "series.title"))
    add_text(root, "sorttitle", series.get("sort_title"))
    add_text(root, "plot", series.get("overview"))
    add_text(root, "premiered", series.get("premiered"))
    add_text(root, "studio", series.get("studio"))
    add_string_list(root, "genre", series.get("genres"), "series.genres")
    add_string_list(root, "tag", series.get("tags"), "series.tags")
    return xml_bytes(root)


def create_episode_nfo(recording: dict[str, Any], index: int) -> bytes:
    prefix = f"recordings[{index}]"
    root = ET.Element("episodedetails")
    add_text(root, "title", require_string(recording.get("title"), f"{prefix}.title"))
    add_text(
        root,
        "season",
        require_positive_int(recording.get("season"), f"{prefix}.season"),
    )
    add_text(
        root,
        "episode",
        require_positive_int(recording.get("episode"), f"{prefix}.episode"),
    )
    add_text(root, "plot", recording.get("overview"))
    add_text(root, "aired", recording.get("date"))
    add_text(root, "runtime", recording.get("runtime_minutes"))
    add_string_list(root, "tag", recording.get("tags"), f"{prefix}.tags")
    return xml_bytes(root)


def load_manifest(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid JSON in {path}: {error}") from error

    if not isinstance(manifest, dict):
        raise ValueError("metadata root must be an object")
    series = manifest.get("series")
    recordings = manifest.get("recordings")
    if not isinstance(series, dict):
        raise ValueError("series must be an object")
    if not isinstance(recordings, list) or not recordings:
        raise ValueError("recordings must be a non-empty array")
    if any(not isinstance(recording, dict) for recording in recordings):
        raise ValueError("every recordings entry must be an object")
    return series, recordings


def source_file(source_dir: Path, file_name: Any, index: int) -> Path:
    relative = Path(require_string(file_name, f"recordings[{index}].file"))
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"recordings[{index}].file must stay inside the source folder")
    path = source_dir / relative
    if not path.is_file():
        raise ValueError(f"recording file does not exist: {path}")
    return path


def destination_paths(
    series: dict[str, Any], recording: dict[str, Any], video: Path, index: int
) -> tuple[PurePosixPath, PurePosixPath]:
    series_name = safe_name(require_string(series.get("title"), "series.title"))
    season = require_positive_int(recording.get("season"), f"recordings[{index}].season")
    episode = require_positive_int(
        recording.get("episode"), f"recordings[{index}].episode"
    )
    title = safe_name(require_string(recording.get("title"), f"recordings[{index}].title"))
    stem = f"S{season:02d}E{episode:02d} - {title}"
    folder = PurePosixPath(series_name, f"Season {season:02d}")
    return folder / f"{stem}{video.suffix.lower()}", folder / f"{stem}.nfo"


def upload(
    account: str,
    container: str,
    local_path: Path,
    blob_path: PurePosixPath,
    overwrite: bool,
) -> None:
    command = [
        "az",
        "storage",
        "blob",
        "upload",
        "--account-name",
        account,
        "--container-name",
        container,
        "--name",
        str(blob_path),
        "--file",
        str(local_path),
        "--auth-mode",
        "login",
        "--overwrite",
        str(overwrite).lower(),
        "--only-show-errors",
        "--no-progress",
    ]
    subprocess.run(command, check=True)


def upload_all(
    account: str,
    container: str,
    uploads: list[tuple[Path, PurePosixPath]],
    overwrite: bool,
    workers: int,
    dry_run: bool,
) -> None:
    total = len(uploads)
    if dry_run:
        for completed, (local_path, blob_path) in enumerate(uploads, start=1):
            print(f"[{completed}/{total}] Would upload {local_path} -> {blob_path}")
        return

    print(f"Uploading {total} files with up to {workers} parallel workers...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        pending = {
            executor.submit(
                upload,
                account,
                container,
                local_path,
                blob_path,
                overwrite,
            ): blob_path
            for local_path, blob_path in uploads
        }
        completed = 0
        try:
            for future in concurrent.futures.as_completed(pending):
                blob_path = pending[future]
                future.result()
                completed += 1
                print(f"[{completed}/{total}] Uploaded {blob_path}", flush=True)
        except (OSError, subprocess.CalledProcessError):
            for future in pending:
                future.cancel()
            raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload recordings and JSON metadata for a Jellyfin library."
    )
    parser.add_argument("source", type=Path, help="folder containing the video files")
    parser.add_argument("metadata", type=Path, help="JSON metadata manifest")
    parser.add_argument(
        "--account-name",
        default=os.environ.get("STORAGE_ACCOUNT_NAME"),
        help="Azure Storage account (or STORAGE_ACCOUNT_NAME)",
    )
    parser.add_argument(
        "--container-name",
        default=os.environ.get("MEDIA_CONTAINER_NAME", "media"),
        help="blob container (default: MEDIA_CONTAINER_NAME or media)",
    )
    parser.add_argument("--overwrite", action="store_true", help="replace existing blobs")
    parser.add_argument(
        "--workers",
        type=positive_int,
        default=4,
        help="maximum parallel uploads (default: 4)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="validate and print without uploading"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.account_name:
        print(
            "error: --account-name or STORAGE_ACCOUNT_NAME is required",
            file=sys.stderr,
        )
        return 2

    try:
        source_dir = args.source.resolve(strict=True)
        if not source_dir.is_dir():
            raise ValueError(f"source is not a folder: {source_dir}")
        series, recordings = load_manifest(args.metadata)
        series_title = safe_name(require_string(series.get("title"), "series.title"))
        planned: list[tuple[Path, PurePosixPath, bytes, PurePosixPath]] = []
        destinations: set[PurePosixPath] = set()

        for index, recording in enumerate(recordings):
            video = source_file(source_dir, recording.get("file"), index)
            video_blob, nfo_blob = destination_paths(series, recording, video, index)
            for destination in (video_blob, nfo_blob):
                if destination in destinations:
                    raise ValueError(f"duplicate destination: {destination}")
                destinations.add(destination)
            planned.append(
                (video, video_blob, create_episode_nfo(recording, index), nfo_blob)
            )

        with tempfile.TemporaryDirectory(prefix="jellyfin-upload-") as temporary:
            temporary_dir = Path(temporary)
            series_nfo = temporary_dir / "tvshow.nfo"
            series_nfo.write_bytes(create_series_nfo(series))
            uploads = [
                (series_nfo, PurePosixPath(series_title, "tvshow.nfo")),
            ]

            for index, (video, video_blob, nfo, nfo_blob) in enumerate(planned):
                episode_nfo = temporary_dir / f"episode-{index}.nfo"
                episode_nfo.write_bytes(nfo)
                uploads.extend(((video, video_blob), (episode_nfo, nfo_blob)))

            upload_all(
                args.account_name,
                args.container_name,
                uploads,
                args.overwrite,
                args.workers,
                args.dry_run,
            )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
