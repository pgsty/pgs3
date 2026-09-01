#!/usr/bin/env python3
"""Validate and materialize the pinned Ceph s3-tests case selection."""

from __future__ import annotations

import argparse
import ast
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Iterable


EXPECTED_SCHEMA = "pgs3.ceph-s3-tests.selection.v2"
FIRST_RUN_STATUSES = ("PASS", "FAIL", "ERROR", "SKIP", "NOT_RUN")
COUNT_KEYS = ("passed", "failed", "errors", "skipped", "not_run")


class SelectionError(RuntimeError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SelectionError(f"cannot read selection {path}: {error}") from error
    if not isinstance(value, dict):
        raise SelectionError("selection root must be an object")
    return value


def save_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def flatten(selection: dict[str, Any]) -> list[dict[str, Any]]:
    categories = selection.get("categories")
    if not isinstance(categories, dict) or not categories:
        raise SelectionError("categories must be a non-empty object")

    cases: list[dict[str, Any]] = []
    for category, definition in categories.items():
        if not isinstance(category, str) or not category:
            raise SelectionError("category names must be non-empty strings")
        if not isinstance(definition, dict):
            raise SelectionError(f"category {category!r} must be an object")
        requirement = definition.get("requirement")
        nodeids = definition.get("nodeids")
        if not isinstance(requirement, str) or not requirement:
            raise SelectionError(f"category {category!r} has no requirement")
        if not isinstance(nodeids, list) or not nodeids:
            raise SelectionError(f"category {category!r} has no nodeids")
        for nodeid in nodeids:
            if not isinstance(nodeid, str) or nodeid.count("::") != 1:
                raise SelectionError(f"invalid nodeid in {category!r}: {nodeid!r}")
            cases.append(
                {
                    "ordinal": len(cases) + 1,
                    "category": category,
                    "requirement": requirement,
                    "nodeid": nodeid,
                }
            )

    nodeids = [case["nodeid"] for case in cases]
    duplicates = sorted({nodeid for nodeid in nodeids if nodeids.count(nodeid) > 1})
    if duplicates:
        raise SelectionError(f"duplicate nodeids: {', '.join(duplicates)}")
    return cases


def git_head(upstream: Path) -> str:
    completed = subprocess.run(
        [
            "git",
            "-c",
            f"safe.directory={upstream}",
            "-C",
            str(upstream),
            "rev-parse",
            "HEAD",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode:
        raise SelectionError(
            f"cannot verify upstream Git checkout: {completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def decorator_name(decorator: ast.expr) -> str:
    if isinstance(decorator, ast.Call):
        return decorator_name(decorator.func)
    if isinstance(decorator, ast.Attribute):
        parent = decorator_name(decorator.value)
        return f"{parent}.{decorator.attr}" if parent else decorator.attr
    if isinstance(decorator, ast.Name):
        return decorator.id
    return ""


def source_functions(path: Path) -> dict[str, ast.FunctionDef | ast.AsyncFunctionDef]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, SyntaxError) as error:
        raise SelectionError(f"cannot parse upstream test file {path}: {error}") from error
    return {
        node.name: node
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }


def validate_count_map(value: Any, name: str) -> dict[str, int]:
    if not isinstance(value, dict) or set(value) != set(COUNT_KEYS):
        raise SelectionError(f"{name} must contain exactly {', '.join(COUNT_KEYS)}")
    if any(not isinstance(value[key], int) or value[key] < 0 for key in COUNT_KEYS):
        raise SelectionError(f"{name} counts must be nonnegative integers")
    return value


def validate_candidate_audit(
    selection: dict[str, Any], selected_count: int, excluded: dict[str, Any]
) -> None:
    audit = selection.get("candidate_audit")
    if not isinstance(audit, dict):
        raise SelectionError("candidate_audit must be an object")
    policy = audit.get("policy")
    if not isinstance(policy, str) or not policy:
        raise SelectionError("candidate_audit.policy must explain exclusion policy")
    for name in (
        "candidate_count",
        "selected_count",
        "excluded_count",
        "minimum_in_scope_core",
    ):
        if not isinstance(audit.get(name), int) or audit[name] < 1:
            raise SelectionError(f"candidate_audit.{name} must be a positive integer")
    if audit["selected_count"] != selected_count:
        raise SelectionError(
            f"candidate_audit.selected_count={audit['selected_count']} != {selected_count}"
        )
    if audit["excluded_count"] != len(excluded):
        raise SelectionError(
            f"candidate_audit.excluded_count={audit['excluded_count']} != {len(excluded)}"
        )
    if audit["candidate_count"] != selected_count + len(excluded):
        raise SelectionError("candidate_count must equal selected plus explicitly excluded")
    if audit["minimum_in_scope_core"] < 150:
        raise SelectionError("minimum_in_scope_core cannot be below the user-required 150")
    if audit["minimum_in_scope_core"] > selected_count:
        raise SelectionError("minimum_in_scope_core cannot exceed selected count")

    first_run = audit.get("first_run")
    if not isinstance(first_run, dict) or not isinstance(first_run.get("artifact"), str):
        raise SelectionError("candidate_audit.first_run must name its evidence artifact")
    candidate = validate_count_map(
        first_run.get("candidate_counts"), "candidate_audit.first_run.candidate_counts"
    )
    excluded_counts = validate_count_map(
        first_run.get("excluded_status_counts"),
        "candidate_audit.first_run.excluded_status_counts",
    )
    retained = validate_count_map(
        first_run.get("retained_counts"), "candidate_audit.first_run.retained_counts"
    )
    if sum(candidate.values()) != audit["candidate_count"]:
        raise SelectionError("first-run candidate counts do not sum to candidate_count")
    if sum(excluded_counts.values()) != len(excluded):
        raise SelectionError("first-run excluded counts do not sum to excluded_count")
    if sum(retained.values()) != selected_count:
        raise SelectionError("first-run retained counts do not sum to selected_count")
    for key in COUNT_KEYS:
        if candidate[key] - excluded_counts[key] != retained[key]:
            raise SelectionError(f"first-run retained {key} count is arithmetically invalid")
    observed = Counter(entry.get("first_run_status") for entry in excluded.values())
    expected = {
        "passed": observed["PASS"],
        "failed": observed["FAIL"],
        "errors": observed["ERROR"],
        "skipped": observed["SKIP"],
        "not_run": observed["NOT_RUN"],
    }
    if expected != excluded_counts:
        raise SelectionError("excluded case first_run_status values disagree with audit counts")


def validate_excluded_cases(
    selection: dict[str, Any],
    cases: list[dict[str, Any]],
    functions: dict[str, ast.FunctionDef | ast.AsyncFunctionDef],
    source: str,
    test_file: str,
) -> dict[str, Any]:
    excluded = selection.get("excluded_cases")
    if not isinstance(excluded, dict) or not excluded:
        raise SelectionError("excluded_cases must explicitly account for candidate removals")
    classes = selection.get("excluded_classes")
    if not isinstance(classes, dict) or not classes:
        raise SelectionError("excluded_classes must record out-of-scope reasons")
    selected = {case["nodeid"] for case in cases}
    for nodeid, definition in excluded.items():
        if not isinstance(nodeid, str) or nodeid.count("::") != 1:
            raise SelectionError(f"invalid excluded nodeid: {nodeid!r}")
        if nodeid in selected:
            raise SelectionError(f"case cannot be selected and excluded: {nodeid}")
        if not isinstance(definition, dict):
            raise SelectionError(f"excluded case {nodeid!r} must be an object")
        class_name = definition.get("class")
        reason = definition.get("reason")
        first_status = definition.get("first_run_status")
        decorators = definition.get("decorators")
        source_contains = definition.get("source_contains")
        if class_name not in classes:
            raise SelectionError(f"excluded case {nodeid!r} uses unknown class {class_name!r}")
        if not isinstance(reason, str) or not reason:
            raise SelectionError(f"excluded case {nodeid!r} has no reason")
        if first_status not in FIRST_RUN_STATUSES:
            raise SelectionError(f"excluded case {nodeid!r} has invalid first_run_status")
        if (
            not isinstance(decorators, list)
            or any(not isinstance(item, str) or not item for item in decorators)
            or len(decorators) != len(set(decorators))
        ):
            raise SelectionError(f"excluded case {nodeid!r} has invalid decorators")
        if (
            not isinstance(source_contains, list)
            or not source_contains
            or any(not isinstance(item, str) or not item for item in source_contains)
        ):
            raise SelectionError(f"excluded case {nodeid!r} has no source evidence")
        file_part, function_name = nodeid.split("::", 1)
        if file_part != test_file:
            raise SelectionError(f"excluded case {nodeid!r} is outside pinned test_file")
        function = functions.get(function_name)
        if function is None:
            raise SelectionError(f"excluded upstream function is missing: {nodeid}")
        actual_decorators = [decorator_name(item) for item in function.decorator_list]
        if actual_decorators != decorators:
            raise SelectionError(
                f"excluded case decorator drift for {nodeid}: "
                f"expected {decorators}, got {actual_decorators}"
            )
        function_source = ast.get_source_segment(source, function) or ""
        missing_evidence = [item for item in source_contains if item not in function_source]
        if missing_evidence:
            raise SelectionError(
                f"excluded case source drift for {nodeid}: missing {missing_evidence}"
            )
    validate_candidate_audit(selection, len(cases), excluded)
    return excluded


def validate(selection_path: Path, upstream: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    selection = load_json(selection_path)
    if selection.get("schema") != EXPECTED_SCHEMA:
        raise SelectionError(f"schema must be {EXPECTED_SCHEMA!r}")
    upstream_definition = selection.get("upstream")
    if not isinstance(upstream_definition, dict):
        raise SelectionError("upstream must be an object")
    expected_commit = upstream_definition.get("commit")
    test_file = upstream_definition.get("test_file")
    if not isinstance(expected_commit, str) or len(expected_commit) != 40:
        raise SelectionError("upstream.commit must be a full 40-character commit")
    if not isinstance(test_file, str) or not test_file.endswith(".py"):
        raise SelectionError("upstream.test_file must name a Python file")
    actual_commit = git_head(upstream)
    if actual_commit != expected_commit:
        raise SelectionError(
            f"upstream commit mismatch: expected {expected_commit}, got {actual_commit}"
        )

    cases = flatten(selection)
    gates = selection.get("gates")
    if not isinstance(gates, dict):
        raise SelectionError("gates must be an object")
    for name in ("minimum_selected", "minimum_executed", "minimum_passed"):
        if not isinstance(gates.get(name), int) or gates[name] < 1:
            raise SelectionError(f"gates.{name} must be a positive integer")
    if len(cases) < gates["minimum_selected"]:
        raise SelectionError(
            f"selected {len(cases)} cases, below minimum {gates['minimum_selected']}"
        )
    if gates["minimum_passed"] > gates["minimum_executed"]:
        raise SelectionError("minimum_passed cannot exceed minimum_executed")
    if gates["minimum_executed"] > len(cases):
        raise SelectionError("minimum_executed cannot exceed selected case count")

    test_path = upstream / test_file
    functions = source_functions(test_path)
    for case in cases:
        file_part, function_name = case["nodeid"].split("::", 1)
        if file_part != test_file:
            raise SelectionError(
                f"nodeid {case['nodeid']!r} does not use pinned test_file {test_file!r}"
            )
        function = functions.get(function_name)
        if function is None:
            raise SelectionError(f"upstream function is missing: {case['nodeid']}")
        decorators = {decorator_name(item) for item in function.decorator_list}
        if any(name.endswith(".parametrize") or name == "parametrize" for name in decorators):
            raise SelectionError(
                f"parameterized function needs explicit expanded nodeids: {case['nodeid']}"
            )

    excluded_classes = selection.get("excluded_classes")
    if not isinstance(excluded_classes, dict) or not excluded_classes:
        raise SelectionError("excluded_classes must record out-of-scope reasons")
    for name, reason in excluded_classes.items():
        if not isinstance(name, str) or not isinstance(reason, str) or not reason:
            raise SelectionError("every excluded class must have a non-empty reason")
    source = test_path.read_text(encoding="utf-8")
    validate_excluded_cases(selection, cases, functions, source, test_file)
    adapters = selection.get("adapters", {})
    if not isinstance(adapters, dict):
        raise SelectionError("adapters must be an object")
    for name, reason in adapters.items():
        if not isinstance(name, str) or not isinstance(reason, str) or not reason:
            raise SelectionError("every adapter must have a non-empty reason")
    return selection, cases


def selection_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def materialized_manifest(
    selection_path: Path, selection: dict[str, Any], cases: list[dict[str, Any]]
) -> dict[str, Any]:
    return {
        "schema": "pgs3.ceph-s3-tests.suite-manifest.v2",
        "selection_sha256": selection_digest(selection_path),
        "upstream": selection["upstream"],
        "gates": selection["gates"],
        "selected_count": len(cases),
        "excluded_count": len(selection["excluded_cases"]),
        "candidate_count": selection["candidate_audit"]["candidate_count"],
        "cases": cases,
        "adapters": selection.get("adapters", {}),
        "excluded_classes": selection["excluded_classes"],
        "excluded_cases": selection["excluded_cases"],
        "candidate_audit": selection["candidate_audit"],
    }


def collected_nodeids(lines: Iterable[str], test_file: str) -> list[str]:
    prefix = f"{test_file}::"
    return [line.strip() for line in lines if line.strip().startswith(prefix)]


def count_statuses(cases: Iterable[dict[str, Any]]) -> dict[str, int]:
    counts = {key: 0 for key in COUNT_KEYS}
    mapping = {
        "PASS": "passed",
        "FAIL": "failed",
        "ERROR": "errors",
        "SKIP": "skipped",
        "NOT_RUN": "not_run",
    }
    for case in cases:
        status = case.get("status")
        if status not in mapping:
            raise SelectionError(f"historical result has invalid status {status!r}")
        counts[mapping[status]] += 1
    return counts


def audit_historical_results(
    selection: dict[str, Any], cases: list[dict[str, Any]], results: dict[str, Any]
) -> dict[str, Any]:
    upstream = results.get("upstream")
    if not isinstance(upstream, dict) or upstream.get("commit") != selection["upstream"]["commit"]:
        raise SelectionError("historical result does not use the pinned upstream commit")
    result_cases = results.get("cases")
    if not isinstance(result_cases, list):
        raise SelectionError("historical result has no cases array")
    by_nodeid: dict[str, dict[str, Any]] = {}
    duplicates: list[str] = []
    for result in result_cases:
        if not isinstance(result, dict) or not isinstance(result.get("nodeid"), str):
            raise SelectionError("historical result has an invalid case record")
        nodeid = result["nodeid"]
        if nodeid in by_nodeid:
            duplicates.append(nodeid)
        by_nodeid[nodeid] = result
    if duplicates:
        raise SelectionError(f"historical result duplicates nodeids: {duplicates}")

    selected_ids = [case["nodeid"] for case in cases]
    excluded_ids = list(selection["excluded_cases"])
    candidate_ids = selected_ids + excluded_ids
    missing = sorted(set(candidate_ids) - set(by_nodeid))
    unexpected = sorted(set(by_nodeid) - set(candidate_ids))
    if missing or unexpected:
        raise SelectionError(
            f"historical candidate mismatch: missing={missing}, unexpected={unexpected}"
        )
    candidate_records = [by_nodeid[nodeid] for nodeid in candidate_ids]
    selected_records = [by_nodeid[nodeid] for nodeid in selected_ids]
    excluded_records = [by_nodeid[nodeid] for nodeid in excluded_ids]
    observed = {
        "candidate_counts": count_statuses(candidate_records),
        "excluded_status_counts": count_statuses(excluded_records),
        "retained_counts": count_statuses(selected_records),
    }
    expected = selection["candidate_audit"]["first_run"]
    for key, counts in observed.items():
        if counts != expected[key]:
            raise SelectionError(
                f"historical {key} drift: expected {expected[key]}, got {counts}"
            )
    mismatched_excluded_status = [
        nodeid
        for nodeid in excluded_ids
        if by_nodeid[nodeid]["status"]
        != selection["excluded_cases"][nodeid]["first_run_status"]
    ]
    if mismatched_excluded_status:
        raise SelectionError(
            f"excluded first-run status drift: {mismatched_excluded_status}"
        )
    return {
        "schema": "pgs3.ceph-s3-tests.selection-audit.v1",
        "result": "PASS",
        "upstream": selection["upstream"],
        "candidate_count": len(candidate_ids),
        "selected_count": len(selected_ids),
        "excluded_count": len(excluded_ids),
        **observed,
        "excluded_cases": [
            {
                "nodeid": nodeid,
                "status": by_nodeid[nodeid]["status"],
                "class": selection["excluded_cases"][nodeid]["class"],
                "reason": selection["excluded_cases"][nodeid]["reason"],
            }
            for nodeid in excluded_ids
        ],
    }


def command_validate(arguments: argparse.Namespace) -> int:
    selection, cases = validate(arguments.selection, arguments.upstream)
    summary = {
        "upstream_commit": selection["upstream"]["commit"],
        "selected_count": len(cases),
        "excluded_count": len(selection["excluded_cases"]),
        "candidate_count": selection["candidate_audit"]["candidate_count"],
        "category_counts": {
            category: len(definition["nodeids"])
            for category, definition in selection["categories"].items()
        },
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


def command_materialize(arguments: argparse.Namespace) -> int:
    selection, cases = validate(arguments.selection, arguments.upstream)
    manifest = materialized_manifest(arguments.selection, selection, cases)
    save_json(arguments.output, manifest)
    arguments.nodeids.parent.mkdir(parents=True, exist_ok=True)
    arguments.nodeids.write_text(
        "".join(f"{case['nodeid']}\n" for case in cases), encoding="utf-8"
    )
    print(f"materialized {len(cases)} pinned nodeids")
    return 0


def command_verify_collection(arguments: argparse.Namespace) -> int:
    selection, cases = validate(arguments.selection, arguments.upstream)
    expected = [case["nodeid"] for case in cases]
    actual = collected_nodeids(
        arguments.collection.read_text(encoding="utf-8", errors="replace").splitlines(),
        selection["upstream"]["test_file"],
    )
    missing = [nodeid for nodeid in expected if nodeid not in actual]
    unexpected = [nodeid for nodeid in actual if nodeid not in expected]
    duplicates = sorted({nodeid for nodeid in actual if actual.count(nodeid) > 1})
    report = {
        "schema": "pgs3.ceph-s3-tests.collection.v1",
        "expected_count": len(expected),
        "collected_count": len(actual),
        "missing": missing,
        "unexpected": unexpected,
        "duplicates": duplicates,
        "result": "PASS"
        if actual == expected and not duplicates
        else "FAIL",
    }
    save_json(arguments.output, report)
    if report["result"] != "PASS":
        raise SelectionError(
            "pytest collection differs from the explicit selection; see collection.json"
        )
    print(f"pytest collected exactly {len(actual)} pinned cases")
    return 0


def command_audit_results(arguments: argparse.Namespace) -> int:
    selection = load_json(arguments.selection)
    if selection.get("schema") != EXPECTED_SCHEMA:
        raise SelectionError(f"schema must be {EXPECTED_SCHEMA!r}")
    cases = flatten(selection)
    validate_candidate_audit(selection, len(cases), selection.get("excluded_cases", {}))
    report = audit_historical_results(selection, cases, load_json(arguments.results))
    if arguments.output:
        save_json(arguments.output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    for name in ("validate", "materialize", "verify-collection", "audit-results"):
        command = commands.add_parser(name)
        command.add_argument("--selection", type=Path, required=True)
        if name != "audit-results":
            command.add_argument("--upstream", type=Path, required=True)
        if name == "validate":
            command.set_defaults(function=command_validate)
        elif name == "materialize":
            command.add_argument("--output", type=Path, required=True)
            command.add_argument("--nodeids", type=Path, required=True)
            command.set_defaults(function=command_materialize)
        elif name == "verify-collection":
            command.add_argument("--collection", type=Path, required=True)
            command.add_argument("--output", type=Path, required=True)
            command.set_defaults(function=command_verify_collection)
        else:
            command.add_argument("--results", type=Path, required=True)
            command.add_argument("--output", type=Path)
            command.set_defaults(function=command_audit_results)
    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        return arguments.function(arguments)
    except SelectionError as error:
        print(f"selection error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
