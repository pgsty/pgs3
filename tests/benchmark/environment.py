#!/usr/bin/env python3
"""Capture machine-readable benchmark environment without container secrets."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from typing import Any, Sequence


SCHEMA = "pgs3.http-benchmark-environment.v1"


class CaptureError(RuntimeError):
    pass


def command(arguments: Sequence[str], *, check: bool = True) -> dict[str, Any]:
    completed = subprocess.run(
        list(arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    record = {
        "argv": list(arguments),
        "exit_status": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }
    if check and completed.returncode != 0:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(arguments)}: "
            f"{completed.stderr.strip()}"
        )
    return record


def docker_json(*arguments: str) -> Any:
    record = command(("docker", *arguments))
    try:
        return json.loads(record["stdout"])
    except json.JSONDecodeError as error:
        raise CaptureError(f"docker {' '.join(arguments)} did not return JSON") from error


def image_info(reference: str) -> dict[str, Any]:
    values = docker_json("image", "inspect", reference)
    if not isinstance(values, list) or len(values) != 1:
        raise CaptureError(f"expected one image for {reference}")
    image = values[0]
    return {
        "requested_reference": reference,
        "id": image.get("Id"),
        "repo_digests": image.get("RepoDigests", []),
        "repo_tags": image.get("RepoTags", []),
        "created": image.get("Created"),
        "architecture": image.get("Architecture"),
        "os": image.get("Os"),
        "size": image.get("Size"),
        "labels": (image.get("Config") or {}).get("Labels") or {},
    }


def container_info(name: str) -> dict[str, Any]:
    values = docker_json("container", "inspect", name)
    if not isinstance(values, list) or len(values) != 1:
        raise CaptureError(f"expected one container for {name}")
    container = values[0]
    config = container.get("Config") or {}
    host = container.get("HostConfig") or {}
    state = container.get("State") or {}
    # Config.Env is deliberately omitted: benchmark credentials are injected by
    # environment-variable name and must never enter the evidence JSON.
    return {
        "name": name,
        "id": container.get("Id"),
        "image_id": container.get("Image"),
        "platform": container.get("Platform"),
        "path": container.get("Path"),
        "args": container.get("Args", []),
        "labels": config.get("Labels") or {},
        "working_dir": config.get("WorkingDir"),
        "mounts": container.get("Mounts", []),
        "state": {
            "status": state.get("Status"),
            "running": state.get("Running"),
            "started_at": state.get("StartedAt"),
            "pid": state.get("Pid"),
            "error": state.get("Error"),
        },
        "resources": {
            "shm_size": host.get("ShmSize"),
            "memory": host.get("Memory"),
            "nano_cpus": host.get("NanoCpus"),
            "cpu_count": host.get("CpuCount"),
            "runtime": host.get("Runtime"),
            "security_opt": host.get("SecurityOpt"),
        },
    }


def volume_info(name: str) -> dict[str, Any]:
    values = docker_json("volume", "inspect", name)
    if not isinstance(values, list) or len(values) != 1:
        raise CaptureError(f"expected one volume for {name}")
    volume = values[0]
    return {
        "name": volume.get("Name"),
        "driver": volume.get("Driver"),
        "mountpoint": volume.get("Mountpoint"),
        "labels": volume.get("Labels") or {},
        "options": volume.get("Options") or {},
        "scope": volume.get("Scope"),
    }


def docker_environment() -> dict[str, Any]:
    values = docker_json("info", "--format", "{{json .}}")
    keys = (
        "ServerVersion",
        "OperatingSystem",
        "OSType",
        "Architecture",
        "NCPU",
        "MemTotal",
        "DockerRootDir",
        "Driver",
        "CgroupDriver",
        "KernelVersion",
        "Name",
    )
    return {key: values.get(key) for key in keys}


def postgres_environment(container: str) -> dict[str, Any]:
    names = (
        "server_version",
        "shared_buffers",
        "fsync",
        "full_page_writes",
        "synchronous_commit",
        "wal_level",
        "checkpoint_timeout",
        "max_wal_size",
        "autovacuum",
        "jit",
        "max_worker_processes",
        "pgs3.enabled",
        "pgs3.workers",
        "pgs3.listen_addr",
        "pgs3.port",
        "pgs3.inline_threshold",
        "pgs3.chunk_size",
        "pgs3.statement_timeout_ms",
        "pgs3.server_role",
    )
    quoted = ",".join("'%s'" % name.replace("'", "''") for name in names)
    query = f"""
        SELECT jsonb_build_object(
            'postmaster_start', pg_postmaster_start_time(),
            'in_recovery', pg_is_in_recovery(),
            'settings', (
                SELECT jsonb_object_agg(name, jsonb_build_object(
                    'setting', setting, 'unit', unit, 'source', source,
                    'pending_restart', pending_restart
                ) ORDER BY name)
                FROM pg_settings WHERE name IN ({quoted})
            )
        )::text
    """
    record = command(
        (
            "docker",
            "exec",
            container,
            "psql",
            "--username",
            "postgres",
            "--dbname",
            "postgres",
            "--no-psqlrc",
            "--tuples-only",
            "--no-align",
            "--command",
            query,
        )
    )
    try:
        return json.loads(record["stdout"])
    except json.JSONDecodeError as error:
        raise CaptureError("PostgreSQL environment query returned invalid JSON") from error


def storage_environment(container: str, path: str) -> dict[str, Any]:
    df = command(("docker", "exec", container, "df", "-Pk", path), check=False)
    mount = command(
        (
            "docker",
            "exec",
            container,
            "sh",
            "-c",
            f"grep ' {path} ' /proc/mounts || grep ' / ' /proc/mounts | head -n 1",
        ),
        check=False,
    )
    return {"path": path, "df": df, "mount": mount}


def host_environment() -> dict[str, Any]:
    optional = []
    for argv in (
        ("uname", "-a"),
        ("sysctl", "-n", "machdep.cpu.brand_string"),
        ("sysctl", "-n", "hw.physicalcpu"),
        ("sysctl", "-n", "hw.logicalcpu"),
        ("sysctl", "-n", "hw.memsize"),
    ):
        try:
            optional.append(command(argv, check=False))
        except FileNotFoundError:
            continue
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "os_cpu_count": os.cpu_count(),
        "commands": optional,
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def capture(arguments: argparse.Namespace) -> int:
    minio_version = command(
        ("docker", "exec", arguments.minio_container, "minio", "--version"),
        check=False,
    )
    pgs3 = postgres_environment(arguments.pgs3_container)
    settings = pgs3.get("settings") or {}
    environment = {
        "schema": SCHEMA,
        "profile": arguments.profile,
        "pg_major": arguments.pg_major,
        "host": host_environment(),
        "docker": docker_environment(),
        "images": {
            "pgs3": image_info(arguments.pgs3_image),
            "minio": image_info(arguments.minio_image),
            "client": image_info(arguments.client_image),
        },
        "containers": {
            "pgs3": container_info(arguments.pgs3_container),
            "minio": container_info(arguments.minio_container),
        },
        "volumes": {
            "pgs3": volume_info(arguments.pgs3_volume),
            "minio": volume_info(arguments.minio_volume),
        },
        "postgresql": pgs3,
        "minio": {
            "version": minio_version,
            "topology": "single server, single Docker named volume, versioning enabled",
            "erasure_coding": "not used by single-drive topology",
        },
        "storage": {
            "pgs3": storage_environment(
                arguments.pgs3_container, "/var/lib/postgresql/data"
            ),
            "minio": storage_environment(arguments.minio_container, "/data"),
        },
        "durability": {
            "pgs3": {
                name: (settings.get(name) or {}).get("setting")
                for name in ("fsync", "full_page_writes", "synchronous_commit")
            },
            "minio": {
                "single_drive": True,
                "fsync_behavior": "server default; exact binary/version recorded",
            },
        },
        "acceptance_baseline": {
            "requested_workers": arguments.workers,
            "requested_shared_buffers": arguments.shared_buffers,
            "power_loss_protected_nvme": "NOT_VERIFIED",
            "hot_data_residency": "NOT_PROVEN; shared_buffers and dataset are recorded",
            "sixteen_physical_cores": "NOT_AUTOMATICALLY_VERIFIED",
            "normalization_applied": False,
            "environment_note": arguments.environment_note,
        },
    }
    write_json(Path(arguments.output).resolve(), environment)
    print(json.dumps(environment, indent=2, sort_keys=True))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    root.add_argument("--output", required=True)
    root.add_argument("--profile", choices=("acceptance", "smoke"), required=True)
    root.add_argument("--pg-major", type=int, choices=(17, 18), required=True)
    root.add_argument("--pgs3-image", required=True)
    root.add_argument("--minio-image", required=True)
    root.add_argument("--client-image", required=True)
    root.add_argument("--pgs3-container", required=True)
    root.add_argument("--minio-container", required=True)
    root.add_argument("--pgs3-volume", required=True)
    root.add_argument("--minio-volume", required=True)
    root.add_argument("--workers", type=int, required=True)
    root.add_argument("--shared-buffers", required=True)
    root.add_argument("--environment-note", default="")
    return root


def main() -> int:
    return capture(parser().parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
