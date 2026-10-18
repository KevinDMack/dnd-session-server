#!/usr/bin/env python3
"""Copy a local VM video into an existing Jellyfin series on Azure Files."""

import argparse
from pathlib import Path

from vm_media import date, name, number, run, season_number, text, upload_episode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("series", type=name, help="existing series folder name")
    parser.add_argument("video", type=Path, help="local video file on the VM")
    parser.add_argument("--title", type=name, required=True)
    parser.add_argument("--season", type=season_number, required=True, help="0 for specials")
    parser.add_argument("--episode", type=number, required=True)
    parser.add_argument("--overview", type=text, help="session summary")
    parser.add_argument("--date", type=date, help="session date (YYYY-MM-DD)")
    parser.add_argument("--runtime-minutes", type=number)
    parser.add_argument("--tag", type=text, action="append", default=[])
    return run(upload_episode, parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
