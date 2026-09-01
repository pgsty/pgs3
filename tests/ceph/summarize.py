#!/usr/bin/env python3
"""Turn pytest JUnit into a complete per-case, gate-enforced JSON report."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import sys
from typing import Any
import xml.etree.ElementTree as ET


STATUS_PRIORITY = {"PASS": 0, "SKIP": 1, "FAIL": 2, "ERROR": 3}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"JSON root is not an object: {path}")
    return value


def save_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def bounded_reason(element: ET.Element | None) -> str | None:
    if element is None:
        return None
    parts = [element.attrib.get("message", "").strip(), (element.text or "").strip()]
    reason = "\n".join(part for part in parts if part)
    if not reason:
        reason = element.tag
    # The redacted JUnit remains the full diagnostic artifact.  Bounding the
    # duplicate JSON field keeps results.json practical to inspect and diff.
    if len(reason) > 16_384:
        reason = reason[:16_384] + "\n[diagnostic truncated; see junit.xml]"
    return reason


def testcase_status(testcase: ET.Element) -> tuple[str, str | None]:
    error = testcase.find("error")
    if error is not None:
        return "ERROR", bounded_reason(error)
    failure = testcase.find("failure")
    if failure is not None:
        return "FAIL", bounded_reason(failure)
    skipped = testcase.find("skipped")
    if skipped is not None:
        return "SKIP", bounded_reason(skipped)
    return "PASS", None


def junit_records(path: Path) -> tuple[dict[str, dict[str, Any]], list[str]]:
    records: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    if not path.exists():
        return records, [f"JUnit report does not exist: {path}"]
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as error:
        return records, [f"cannot parse JUnit report: {error}"]

    for testcase in root.iter("testcase"):
        name = testcase.attrib.get("name", "")
        if not name:
            errors.append("JUnit testcase has no name")
            continue
        status, reason = testcase_status(testcase)
        try:
            duration = float(testcase.attrib.get("time", "0"))
        except ValueError:
            duration = 0.0
            errors.append(f"JUnit testcase {name!r} has an invalid duration")
        current = records.get(name)
        if current is None:
            records[name] = {
                "status": status,
                "reason": reason,
                "duration_seconds": duration,
            }
            continue
        current["duration_seconds"] += duration
        if STATUS_PRIORITY[status] > STATUS_PRIORITY[current["status"]]:
            current["status"] = status
        if reason:
            if current["reason"]:
                current["reason"] += "\n" + reason
            else:
                current["reason"] = reason
    return records, errors


def gate_report(
    manifest: dict[str, Any], counts: dict[str, int], pytest_exit_status: int, errors: list[str]
) -> tuple[str, list[str]]:
    gates = manifest["gates"]
    issues = list(errors)
    if counts["selected"] < gates["minimum_selected"]:
        issues.append(
            f"selected {counts['selected']} < required {gates['minimum_selected']}"
        )
    if counts["executed"] < gates["minimum_executed"]:
        issues.append(
            f"executed {counts['executed']} < required {gates['minimum_executed']}"
        )
    if counts["passed"] < gates["minimum_passed"]:
        issues.append(f"passed {counts['passed']} < required {gates['minimum_passed']}")
    for count_name, setting in (
        ("failed", "allow_failures"),
        ("errors", "allow_errors"),
        ("skipped", "allow_skips"),
        ("not_run", "allow_not_run"),
    ):
        if counts[count_name] and not gates.get(setting, False):
            issues.append(f"{count_name}={counts[count_name]} but {setting}=false")
    if pytest_exit_status:
        issues.append(f"pytest exit status was {pytest_exit_status}")
    return ("PASS" if not issues else "FAIL"), issues


def summarize(arguments: argparse.Namespace) -> tuple[dict[str, Any], int]:
    manifest = load_json(arguments.manifest)
    cases = manifest.get("cases")
    if not isinstance(cases, list):
        raise ValueError("suite manifest has no cases array")
    junit, errors = junit_records(arguments.junit)
    if arguments.harness_error:
        errors.extend(arguments.harness_error)

    selected_names = {case["nodeid"].rsplit("::", 1)[1] for case in cases}
    unexpected = sorted(name for name in junit if name not in selected_names)
    if unexpected:
        errors.append(f"JUnit contains unselected cases: {', '.join(unexpected)}")

    results: list[dict[str, Any]] = []
    for case in cases:
        function_name = case["nodeid"].rsplit("::", 1)[1]
        observed = junit.get(function_name)
        if observed is None:
            status = "NOT_RUN"
            reason = "No JUnit testcase was emitted; pytest may have stopped or collection changed."
            duration = 0.0
        else:
            status = observed["status"]
            reason = observed["reason"]
            duration = observed["duration_seconds"]
        results.append(
            {
                **case,
                "status": status,
                "reason": reason,
                "duration_seconds": round(duration, 6),
            }
        )

    counts = {
        "selected": len(results),
        "passed": sum(result["status"] == "PASS" for result in results),
        "failed": sum(result["status"] == "FAIL" for result in results),
        "errors": sum(result["status"] == "ERROR" for result in results),
        "skipped": sum(result["status"] == "SKIP" for result in results),
        "not_run": sum(result["status"] == "NOT_RUN" for result in results),
    }
    counts["executed"] = counts["passed"] + counts["failed"] + counts["errors"]
    gate_result, gate_issues = gate_report(
        manifest, counts, arguments.pytest_exit_status, errors
    )
    report = {
        "schema": "pgs3.ceph-s3-tests.results.v2",
        "generated_at": utc_now(),
        "result": gate_result,
        "pg_major": arguments.pg_major,
        "pytest_exit_status": arguments.pytest_exit_status,
        "upstream": manifest["upstream"],
        "selection_sha256": manifest["selection_sha256"],
        "gates": manifest["gates"],
        "candidate_count": manifest.get("candidate_count", counts["selected"]),
        "excluded_count": manifest.get("excluded_count", 0),
        "excluded_cases": manifest.get("excluded_cases", {}),
        "counts": counts,
        "gate_issues": gate_issues,
        "cases": results,
    }
    return report, 0 if gate_result == "PASS" else 1


def write_text_summary(path: Path, report: dict[str, Any]) -> None:
    counts = report["counts"]
    lines = [
        f"result: {report['result']}",
        f"upstream: {report['upstream']['commit']}",
        f"candidate: {report['candidate_count']}",
        f"excluded: {report['excluded_count']}",
        f"selected: {counts['selected']}",
        f"executed: {counts['executed']}",
        f"passed: {counts['passed']}",
        f"failed: {counts['failed']}",
        f"errors: {counts['errors']}",
        f"skipped: {counts['skipped']}",
        f"not_run: {counts['not_run']}",
    ]
    if report["gate_issues"]:
        lines.append("gate issues:")
        lines.extend(f"- {issue}" for issue in report["gate_issues"])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--junit", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--pg-major", type=int, required=True)
    parser.add_argument("--pytest-exit-status", type=int, required=True)
    parser.add_argument("--harness-error", action="append", default=[])
    arguments = parser.parse_args()
    try:
        report, status = summarize(arguments)
        save_json(arguments.output, report)
        write_text_summary(arguments.summary, report)
    except (OSError, ValueError, KeyError) as error:
        print(f"summary error: {error}", file=sys.stderr)
        return 2
    print(arguments.summary.read_text(encoding="utf-8"), end="")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
