#!/usr/bin/env python3
"""Validate one server-produced EXPLAIN JSON plan against a fixed scale gate."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any


# Acceptance thresholds are intentionally not command-line options.  A scaled
# developer fixture may reduce row counts, but it cannot relax the timing gate.
THRESHOLDS_MS = {
    "fork": 1000.0,
    "list": 5.0,
    "delimiter": 10.0,
}

BUFFER_KEYS = (
    "Shared Hit Blocks",
    "Shared Read Blocks",
    "Shared Dirtied Blocks",
    "Shared Written Blocks",
    "Local Hit Blocks",
    "Local Read Blocks",
    "Local Dirtied Blocks",
    "Local Written Blocks",
    "Temp Read Blocks",
    "Temp Written Blocks",
)
WAL_KEYS = ("WAL Records", "WAL FPI", "WAL Bytes")


class PlanError(ValueError):
    """The evidence is missing, malformed, or outside its acceptance gate."""


def load_explain(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PlanError(f"cannot read PostgreSQL EXPLAIN JSON: {error}") from error
    if not isinstance(payload, list) or len(payload) != 1:
        raise PlanError("EXPLAIN JSON must contain exactly one top-level document")
    document = payload[0]
    if not isinstance(document, dict) or not isinstance(document.get("Plan"), dict):
        raise PlanError("EXPLAIN JSON is missing its root Plan object")
    return document


def _number(mapping: dict[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PlanError(f"EXPLAIN JSON is missing numeric {key!r}")
    return float(value)


def evaluate_plan(
    document: dict[str, Any], kind: str, expected_rows: int
) -> tuple[dict[str, Any], list[str]]:
    if kind not in THRESHOLDS_MS:
        raise PlanError(f"unknown plan kind: {kind}")
    if expected_rows <= 0:
        raise PlanError("expected rows must be positive")

    plan = document["Plan"]
    execution_ms = _number(document, "Execution Time")
    planning_ms = _number(document, "Planning Time")
    actual_rows = _number(plan, "Actual Rows")
    actual_loops = _number(plan, "Actual Loops")

    present_buffers = {key: int(plan[key]) for key in BUFFER_KEYS if key in plan}
    if not present_buffers:
        raise PlanError(
            "root plan has no BUFFERS counters; evidence was not produced with BUFFERS"
        )
    for key, value in present_buffers.items():
        if value < 0:
            raise PlanError(f"negative buffer counter {key}: {value}")

    threshold_ms = THRESHOLDS_MS[kind]
    shared_blocks_touched = sum(
        present_buffers.get(key, 0)
        for key in ("Shared Hit Blocks", "Shared Read Blocks")
    )
    temp_blocks_touched = sum(
        present_buffers.get(key, 0)
        for key in ("Temp Read Blocks", "Temp Written Blocks")
    )
    errors: list[str] = []
    if actual_loops != 1:
        errors.append(f"root Actual Loops is {actual_loops:g}, expected 1")
    if actual_rows != expected_rows:
        errors.append(
            f"root Actual Rows is {actual_rows:g}, expected {expected_rows}"
        )
    if not execution_ms < threshold_ms:
        errors.append(
            f"Execution Time {execution_ms:.3f} ms is not below "
            f"{threshold_ms:.3f} ms"
        )

    summary: dict[str, Any] = {
        "actual_loops": actual_loops,
        "actual_rows": actual_rows,
        "buffers": present_buffers,
        "execution_ms": execution_ms,
        "expected_rows": expected_rows,
        "gate": kind,
        "node_type": plan.get("Node Type"),
        "planning_ms": planning_ms,
        "result": "PASS" if not errors else "FAIL",
        "shared_blocks_per_output_row": shared_blocks_touched / actual_rows
        if actual_rows > 0
        else None,
        "shared_blocks_touched": shared_blocks_touched,
        "threshold_ms_strictly_less_than": threshold_ms,
        "temp_blocks_touched": temp_blocks_touched,
        "wal": {key: int(plan[key]) for key in WAL_KEYS if key in plan},
    }
    return summary, errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", required=True, choices=tuple(THRESHOLDS_MS))
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--expected-rows", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        document = load_explain(arguments.plan)
        summary, errors = evaluate_plan(
            document, arguments.kind, arguments.expected_rows
        )
    except PlanError as error:
        print(json.dumps({"gate": arguments.kind, "result": "FAIL"}, sort_keys=True))
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
