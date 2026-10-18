#!/usr/bin/env python3
"""Create a Jellyfin series on the VM's Azure Files share."""

import argparse

from vm_media import create_series, name, number, run, text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("series", type=name, help="series title and folder name")
    parser.add_argument("--overview", type=text, help="campaign description")
    parser.add_argument("--year", type=number, help="starting year")
    parser.add_argument("--genre", type=text, action="append", default=[])
    parser.add_argument("--tag", type=text, action="append", default=[])
    return run(create_series, parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
