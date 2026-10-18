#!/usr/bin/env python3
"""Create a Jellyfin series directly on Azure Files from your computer."""

import argparse

from azure_files_media import create_series, name, number, run, storage_arguments, text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    storage_arguments(parser)
    parser.add_argument("series", type=name, help="series title and folder name")
    parser.add_argument("--overview", type=text, help="campaign description")
    parser.add_argument("--year", type=number, help="starting year")
    parser.add_argument("--genre", type=text, action="append", default=[])
    parser.add_argument("--tag", type=text, action="append", default=[])
    return run(create_series, parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
