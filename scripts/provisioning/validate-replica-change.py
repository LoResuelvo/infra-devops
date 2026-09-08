#!/usr/bin/env python3
"""Validate replica counts and sanitized Terraform plan topology."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def replica_names(environment: str, start: int, end: int) -> list[str]:
    return [f"{environment}-replica-{index:02d}" for index in range(start + 1, end + 1)]


def validate_count(current: int, desired: int) -> None:
    if not 0 <= current <= 99 or not 0 <= desired <= 99:
        raise SystemExit("Replica counts must be between 0 and 99.")
    if desired < current:
        raise SystemExit("Reducing replica_count is not allowed by this workflow.")
    print("unchanged" if desired == current else "grow")


def validate_context(environment: str, terraform_root: str) -> None:
    expected = f"terraform/environments/{environment}/replicas"
    if terraform_root != expected:
        raise SystemExit("Terraform root does not match the controlled environment.")


def validate_state(
    expected_count: int,
    current_count: int,
    desired_count: int,
    expected_fingerprint: str,
    current_fingerprint: str,
    run_attempt: int,
) -> None:
    if current_count == expected_count and current_fingerprint == expected_fingerprint:
        print("apply")
        return
    if run_attempt > 1 and expected_count < desired_count == current_count:
        print("resume")
        return
    raise SystemExit("Terraform state changed after the reviewed plan.")


def validate_plan(path: Path, environment: str, current: int, desired: int) -> None:
    plan = json.loads(path.read_text(encoding="utf-8"))
    expected_names = replica_names(environment, current, desired)
    expected_addresses = {
        address
        for name in expected_names
        for address in (
            f'module.replica["{name}"].openstack_compute_keypair_v2.instance',
            f'module.replica["{name}"].openstack_compute_instance_v2.instance',
        )
    }
    changed: dict[str, list[str]] = {}
    for resource in plan.get("resource_changes", []):
        actions = resource.get("change", {}).get("actions", [])
        if actions not in (["no-op"], ["read"]):
            changed[resource["address"]] = actions
    if set(changed) != expected_addresses or any(actions != ["create"] for actions in changed.values()):
        raise SystemExit("Terraform plan contains changes outside the expected new replicas.")

    print("### Replica plan")
    print()
    print(f"- Environment: `{environment}`")
    print(f"- Current replicas: `{current}`")
    print(f"- Desired replicas: `{desired}`")
    print(f"- New replicas: `{len(expected_names)}`")
    for name in expected_names:
        if not re.fullmatch(r"(?:staging|production)-replica-[0-9]{2}", name):
            raise SystemExit("Generated replica name is invalid.")
        print(f"  - `{name}`")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    count_parser = subparsers.add_parser("count")
    count_parser.add_argument("current", type=int)
    count_parser.add_argument("desired", type=int)
    context_parser = subparsers.add_parser("context")
    context_parser.add_argument("environment", choices=("staging", "production"))
    context_parser.add_argument("terraform_root")
    state_parser = subparsers.add_parser("state")
    state_parser.add_argument("expected_count", type=int)
    state_parser.add_argument("current_count", type=int)
    state_parser.add_argument("desired_count", type=int)
    state_parser.add_argument("expected_fingerprint")
    state_parser.add_argument("current_fingerprint")
    state_parser.add_argument("run_attempt", type=int)
    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("path", type=Path)
    plan_parser.add_argument("environment", choices=("staging", "production"))
    plan_parser.add_argument("current", type=int)
    plan_parser.add_argument("desired", type=int)
    args = parser.parse_args()
    if args.command == "count":
        validate_count(args.current, args.desired)
    elif args.command == "context":
        validate_context(args.environment, args.terraform_root)
    elif args.command == "state":
        validate_state(
            args.expected_count,
            args.current_count,
            args.desired_count,
            args.expected_fingerprint,
            args.current_fingerprint,
            args.run_attempt,
        )
    else:
        validate_plan(args.path, args.environment, args.current, args.desired)


if __name__ == "__main__":
    main()
