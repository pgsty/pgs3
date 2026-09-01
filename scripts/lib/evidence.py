#!/usr/bin/env python3
"""Create redacted, reproducible acceptance evidence manifests.

This helper intentionally uses only the Python standard library.  Secrets are
read from named environment variables and are never accepted on the command
line, so process listings and the manifest cannot expose them accidentally.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable


DEFAULT_SECRET_ENV_NAMES = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "PGS3_ACCESS_KEY_A",
    "PGS3_ACCESS_KEY_B",
    "PGS3_SECRET_A",
    "PGS3_SECRET_B",
    "PGS3_TEST_ACCESS_KEY_A",
    "PGS3_TEST_ACCESS_KEY_B",
    "PGS3_TEST_SECRET_A",
    "PGS3_TEST_SECRET_B",
)

REDACTION_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"(?im)^(\s*authorization\s*:)\s*[^\r\n]*"),
        r"\1 [REDACTED]",
    ),
    (
        re.compile(r"(?i)(authorization\s*:)\s*[^'\"\r\n]*"),
        r"\1 [REDACTED]",
    ),
    (
        re.compile(
            r"(?i)(X-Amz-(?:Signature|Credential|Security-Token)=)[^&\s\"']+"
        ),
        r"\1[REDACTED]",
    ),
    (
        re.compile(
            r"(?i)\b(AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)\s*=\s*)"
            r"(?:'[^']*'|\"[^\"]*\"|[^\s]+)"
        ),
        r"\1[REDACTED]",
    ),
    (
        re.compile(
            r'(?i)([\"\'](?:AccessKeyId|SecretAccessKey|SessionToken|Token)[\"\']\s*:\s*)'
            r'([\"\'])[^\"\']*\2'
        ),
        r'\1"[REDACTED]"',
    ),
    (
        re.compile(
            r"(?is)(<(?:AWSAccessKeyId|SecretAccessKey|SessionToken)>).*?"
            r"(</(?:AWSAccessKeyId|SecretAccessKey|SessionToken)>)"
        ),
        r"\1[REDACTED]\2",
    ),
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), "[REDACTED-AWS-ACCESS-KEY]"),
)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def secret_values() -> list[str]:
    names = list(DEFAULT_SECRET_ENV_NAMES)
    names.extend(
        name.strip()
        for name in os.environ.get("PGS3_REDACT_ENV_NAMES", "").split(",")
        if name.strip()
    )
    values = {os.environ.get(name, "") for name in names}
    return sorted((value for value in values if value), key=len, reverse=True)


def redact(text: str) -> str:
    for value in secret_values():
        text = text.replace(value, "[REDACTED]")
    for pattern, replacement in REDACTION_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def run_git(repo: Path, *args: str, binary: bool = False) -> bytes | str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    data = completed.stdout
    return data if binary else data.decode("utf-8", "replace").strip()


def iter_workspace_files(repo: Path) -> Iterable[Path]:
    """Yield files relevant to a no-HEAD or dirty workspace digest."""
    excluded_roots = {
        ".git",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".venv",
        "__pycache__",
        "artifacts",
        "target",
        "venv",
    }
    for root, directories, files in os.walk(repo):
        root_path = Path(root)
        relative_root = root_path.relative_to(repo)
        directories[:] = sorted(
            directory
            for directory in directories
            if directory not in excluded_roots
            and not (relative_root / directory).as_posix().startswith("tests/pg_regress/results")
        )
        for filename in sorted(files):
            path = root_path / filename
            if path.suffix in {".pyc", ".pyo"}:
                continue
            if path.is_symlink() or path.is_file():
                yield path


def workspace_digest(repo: Path) -> tuple[str, str, str]:
    head = str(run_git(repo, "rev-parse", "--verify", "HEAD")) or "UNBORN"
    status = str(
        run_git(repo, "status", "--porcelain=v1", "--untracked-files=all")
    )
    digest = hashlib.sha256()
    digest.update(b"pgs3-workspace-v1\0")
    digest.update(head.encode())
    digest.update(b"\0")

    if head != "UNBORN":
        diff = run_git(
            repo,
            "diff",
            "--binary",
            "--no-ext-diff",
            "HEAD",
            "--",
            ".",
            ":(exclude)artifacts",
            binary=True,
        )
        assert isinstance(diff, bytes)
        digest.update(diff)

    # Hash every non-build file as well as the Git diff.  This covers untracked
    # files and makes evidence useful before the repository has its first commit.
    for path in iter_workspace_files(repo):
        relative = path.relative_to(repo).as_posix()
        digest.update(b"\0path\0")
        digest.update(relative.encode("utf-8", "surrogateescape"))
        digest.update(b"\0")
        if path.is_symlink():
            digest.update(os.readlink(path).encode("utf-8", "surrogateescape"))
        else:
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return head, status, digest.hexdigest()


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def save_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".manifest-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(manifest, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def command_init(arguments: argparse.Namespace) -> int:
    run_dir = Path(arguments.run_dir).resolve()
    repo = Path(arguments.repo).resolve()
    run_dir.mkdir(parents=True, exist_ok=False)
    (run_dir / "steps").mkdir()
    head, status, digest = workspace_digest(repo)
    manifest = {
        "schema": "pgs3.acceptance-evidence.v1",
        "run_id": run_dir.name,
        "suite": arguments.suite,
        "pg_major": arguments.pg_major,
        "started_at": utc_now(),
        "finished_at": None,
        "result": "RUNNING",
        "repository": {
            "path": str(repo),
            "head": head,
            "dirty": bool(status),
            "status_porcelain": status.splitlines(),
            "workspace_sha256": digest,
        },
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "steps": [],
    }
    save_manifest(run_dir / "manifest.json", manifest)
    return 0


def command_record(arguments: argparse.Namespace) -> int:
    manifest_path = Path(arguments.run_dir).resolve() / "manifest.json"
    manifest = load_manifest(manifest_path)
    command_file = getattr(arguments, "command_file", None)
    if command_file:
        command_text = Path(command_file).read_text(encoding="utf-8")
    else:
        command_text = arguments.command
    step = {
        "name": arguments.name,
        "status": arguments.status,
        "exit_status": arguments.exit_status,
        "started_at": arguments.started_at,
        "finished_at": arguments.finished_at,
        "command": redact(command_text),
        "output": arguments.output,
    }
    manifest["steps"].append(step)
    save_manifest(manifest_path, manifest)
    return 0


def command_finalize(arguments: argparse.Namespace) -> int:
    manifest_path = Path(arguments.run_dir).resolve() / "manifest.json"
    manifest = load_manifest(manifest_path)
    manifest["result"] = arguments.result
    manifest["finished_at"] = utc_now()
    save_manifest(manifest_path, manifest)
    return 0


def command_redact(_arguments: argparse.Namespace) -> int:
    # Reading the bounded command log at once prevents a credential split over
    # chunk boundaries from escaping literal replacement.
    sys.stdout.write(redact(sys.stdin.read()))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    initialize = commands.add_parser("init")
    initialize.add_argument("--repo", required=True)
    initialize.add_argument("--run-dir", required=True)
    initialize.add_argument("--suite", required=True)
    initialize.add_argument("--pg-major", required=True, type=int)
    initialize.set_defaults(function=command_init)

    record = commands.add_parser("record")
    record.add_argument("--run-dir", required=True)
    record.add_argument("--name", required=True)
    record.add_argument("--status", required=True, choices=("PASS", "FAIL", "BLOCKED"))
    record.add_argument("--exit-status", required=True, type=int)
    record.add_argument("--started-at", required=True)
    record.add_argument("--finished-at", required=True)
    command_source = record.add_mutually_exclusive_group(required=True)
    command_source.add_argument("--command")
    command_source.add_argument("--command-file")
    record.add_argument("--output", required=True)
    record.set_defaults(function=command_record)

    finalize = commands.add_parser("finalize")
    finalize.add_argument("--run-dir", required=True)
    finalize.add_argument("--result", required=True, choices=("PASS", "FAIL", "BLOCKED"))
    finalize.set_defaults(function=command_finalize)

    redaction = commands.add_parser("redact")
    redaction.set_defaults(function=command_redact)
    return root


def main() -> int:
    arguments = parser().parse_args()
    return arguments.function(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
