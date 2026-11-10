#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3==1.43.114"]
# ///
"""Entry point for the Python commands: scripts/py/main.py <command> ... (--help on any level).

Each command is a module next to this file with add_parser(commands), which registers its argparse
subcommand and the function that runs it. main.py is the one place that lists their dependencies
(locked in main.py.lock). The modules import each other directly (`import lib`): uv runs main.py as
a script, so its directory is on sys.path. No __init__.py or pyproject.toml: nothing here is installed.
"""

from __future__ import annotations

import argparse
import sys

import codebuild
import db_restore
import revoke
import verify

MODULES = (verify, db_restore, revoke, codebuild)


def main() -> int:
    parser = argparse.ArgumentParser(prog="scripts/py/main.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True, metavar="<command>")
    for module in MODULES:
        module.add_parser(commands)
    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
