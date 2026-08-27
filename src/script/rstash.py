#!/usr/bin/env -S uv --no-config --quiet run --script
# /// script
# dependencies = [
#   "loguru~=0.7.0",
#   "pyyaml~=6.0",
#   "typer~=0.27.0",
# ]
# requires-python = "~=3.11"
# ///

"""Rclone wrapper for interactive and conditional backups."""

from __future__ import annotations

import functools
import json
import os
import platform
import subprocess
import sys
import time
from itertools import chain
from pathlib import Path
from typing import TYPE_CHECKING, Annotated, Any

import typer
import yaml
from loguru import logger
from typer import Option, Typer

if TYPE_CHECKING:
    from collections.abc import Iterable

__version__ = "0.1.2"

cli = Typer(
    add_completion=False,
    help=__doc__,
    no_args_is_help=True,
    pretty_exceptions_enable=False,
)

# Use Rclone environment variables to avoid unsupported flags on specific versions.
os.environ["RCLONE_COPY_LINKS"] = "true"
os.environ["RCLONE_CREATE_EMPTY_SRC_DIRS"] = "true"
os.environ["RCLONE_EXCLUDE_FROM"] = ""
os.environ["RCLONE_HUMAN_READABLE"] = "true"
os.environ["RCLONE_INCLUDE_FROM"] = ""
os.environ["RCLONE_NO_UPDATE_DIR_MODTIME"] = "true"
os.environ["RCLONE_NO_UPDATE_MODTIME"] = "true"

# Shared state to hold global application flags.
state: dict[str, Any] = {"config": None, "dry": False}


class Manifest:
    """Synchronization and location details."""

    arguments: list[str]
    dest: str
    filters: list[str]
    source: str

    def __init__(
        self,
        dest: str | dict[str, str],
        source: str | dict[str, str],
        args: list[str] | None = None,
        filters: list[str] | None = None,
    ) -> None:
        """Create a Manifest instance."""
        self.arguments = args or []
        self.filters = filters or []

        if isinstance(dest, dict):
            option = select_option(dest)
            self.dest = Path(option).expanduser().as_posix()
        else:
            self.dest = Path(dest).expanduser().as_posix()
        if isinstance(source, dict):
            option = select_option(source)
            self.source = Path(option).expanduser().as_posix()
        else:
            self.source = Path(source).expanduser().as_posix()

    # TODO: Refactor into standalone function to fix lint.
    @functools.cache  # noqa: B019
    def args(self, upload: bool = True) -> list[str]:
        """Create Rclone synchronization arguments."""
        arguments = (["--filter", filter_] for filter_ in self.filters)
        if upload:
            return list(chain(*arguments)) + self.arguments + [self.source, self.dest]
        return list(chain(*arguments)) + self.arguments + [self.dest, self.source]

    @property
    def cmd(self) -> str:
        """Get Rclone subcommand."""
        return "copy" if self.filters else "copyto"

    def mkdir_source(self) -> None:
        """Ensure the parent folder of the source path exists."""
        folder = Path(self.source) if self.filters else Path(self.source).parent
        folder.mkdir(exist_ok=True, parents=True)


def compute_changes(
    manifests: Iterable[Manifest],
    upload: bool = True,
) -> tuple[list[Manifest], str]:
    """Dry run synchronizations to assemble list of changes."""
    records = []
    changes = ""

    for manifest in manifests:
        if upload:
            source, dest = manifest.source, manifest.dest
        else:
            source, dest = manifest.dest, manifest.source

        command = [
            "rclone",
            "--dry-run",
            "--use-json-log",
            manifest.cmd,
            "--update",
            *manifest.args(upload),
        ]

        logger.debug(f"Running command '{' '.join(command)}'.")
        start = time.time()
        process = subprocess.run(
            command,
            check=False,
            capture_output=True,
            env={**os.environ, "RCLONE_PROGRESS": "false"},
            text=True,
        )
        stop = time.time()
        logger.debug(f"Ran command in {stop - start:.4e} seconds.")

        if process.returncode != 0:
            print(process.stderr, file=sys.stderr)
            sys.exit(process.returncode)

        logs = (json.loads(line) for line in process.stderr.strip().split("\n") if line)
        change = parse_logs(source, dest, logs, manifest.cmd == "copyto")
        if change:
            records.append(manifest)
            changes = "{}\n{}".format(changes, "\n".join(change))

    return records, changes


def load_config(config: Path) -> list[Manifest]:
    """Load Rstash configuration."""
    try:
        with Path.open(config) as file:
            configs = yaml.safe_load(file)
    except FileNotFoundError:
        logger.error(f"Unable to find configuration file at {config}.")
        sys.exit(1)
    return [Manifest(**config) for config in configs]


def parse_logs(
    source: str, dest: str, logs: Iterable[dict], rename: bool = False
) -> list[str]:
    """Parse Rclone logs for synchronization changes."""
    changes = []
    for log in logs:
        if "object" in log and "Skipped copy as --dry-run is set" in log.get("msg", ""):
            if rename:
                changes.append(f"{source} -> {dest}")
            else:
                changes.append(f"{source}/{log['object']} -> {dest}/{log['object']}")
    return changes


def print_version(value: bool) -> None:
    """Print Rstash version string."""
    if value:
        print(f"Rstash {__version__}")
        sys.exit()


def select_option(options: dict[str, str]) -> str:
    """Choose most compatible option for current operating system."""
    system = platform.system().lower().replace("darwin", "macos")
    if system in options:
        return options[system]
    if "unix" in options and system != "windows":
        return options["unix"]
    return options["default"]


def sync_changes(manifests: Iterable[Manifest], upload: bool = True) -> None:
    """Apply synchronization changes."""
    for manifest in manifests:
        command = [
            "rclone",
            "--verbose",
            manifest.cmd,
            "--update",
            *manifest.args(upload),
        ]

        logger.debug(f"Running command '{' '.join(command)}'.")
        start = time.time()
        process = subprocess.run(command, check=False, capture_output=True, text=True)
        stop = time.time()
        logger.debug(f"Ran command in {stop - start:.4e} seconds.")

        if process.returncode != 0:
            print(process.stderr, file=sys.stderr)
            sys.exit(process.returncode)


@cli.command()
def download() -> None:
    """Download files with Rclone."""
    manifests = load_config(state["config"])
    for manifest in manifests:
        manifest.mkdir_source()
    manifests, changes = compute_changes(manifests, upload=False)
    if not manifests:
        return

    print(f"Changes to be synced.\n{changes}\n")
    if state["dry"]:
        return
    confirm = typer.confirm("Sync changes?")
    if confirm:
        sync_changes(manifests, upload=False)


@cli.callback()
def main(
    config_path: Annotated[
        Path | None,
        Option("-c", "--config", help="Configuration file path."),
    ] = None,
    dry: Annotated[
        bool,
        Option("-d", "--dry", help="Only print actions to be taken."),
    ] = False,
    log_level: Annotated[str, Option("-l", "--log-level", help="Log level.")] = "info",
    version: Annotated[  # noqa: ARG001
        bool,
        Option(
            "-v",
            "--version",
            callback=print_version,
            help="Print version information.",
            is_eager=True,
        ),
    ] = False,
) -> None:
    """Setup global state for commands."""
    logger.remove()
    logger.add(sys.stderr, level=log_level.upper())
    state["dry"] = dry

    if config_path is not None:
        state["config"] = config_path
    elif "RSTASH_CONFIG" in os.environ:
        state["config"] = Path(os.environ["RSTASH_CONFIG"])
    else:
        match platform.system().lower():
            case "darwin":
                state["config"] = (
                    Path.home() / "Library/Application Support/rstash/rstash.yaml"
                )
            case "windows":
                state["config"] = Path.home() / "AppData/Roaming/rstash/rstash.yaml"
            case _:
                state["config"] = Path.home() / ".config/rstash/rstash.yaml"


@cli.command()
def sync() -> None:
    """Sync files with Rclone."""
    manifests = load_config(state["config"])
    for manifest in manifests:
        manifest.mkdir_source()

    downloads = compute_changes(manifests, upload=False)
    uploads = compute_changes(manifests, upload=True)
    manifests = downloads[0] + uploads[0]
    changes = downloads[1] + uploads[1]
    if not manifests:
        return

    print(f"Changes to be synced.\n{changes}\n")
    if state["dry"]:
        return
    confirm = typer.confirm("Sync changes?")
    if confirm:
        sync_changes(downloads[0], upload=False)
        sync_changes(uploads[0], upload=True)


@cli.command()
def upload() -> None:
    """Upload files with Rclone."""
    manifests = load_config(state["config"])
    manifests, changes = compute_changes(manifests, upload=True)
    if not manifests:
        return

    print(f"Changes to be synced.\n{changes}\n")
    if state["dry"]:
        return
    confirm = typer.confirm("Sync changes?")
    if confirm:
        sync_changes(manifests, upload=True)


if __name__ == "__main__":
    cli(prog_name="rstash")
