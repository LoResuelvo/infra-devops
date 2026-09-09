#!/usr/bin/env python3
"""Validate deployment inputs and turn Terraform outputs into Ansible inventory."""

import argparse
import ipaddress
import json
import os
import re
from pathlib import Path


def hosts(value: object) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        raise SystemExit("Host inventory must be a non-empty list")
    result, names = [], set()
    for host in value:
        if not isinstance(host, dict) or set(host) != {"role", "name", "ipv4"}:
            raise SystemExit("Host inventory contains an invalid object")
        if host["role"] not in {"primary", "replica"} or not host["name"] or host["name"] in names:
            raise SystemExit("Host inventory contains invalid or duplicate metadata")
        names.add(host["name"])
        try:
            address = str(ipaddress.IPv4Address(host["ipv4"]))
        except ipaddress.AddressValueError as error:
            raise SystemExit("Host inventory contains an invalid IPv4 address") from error
        result.append({**host, "ipv4": address})
    return result


def terraform_hosts(value: object) -> list[dict[str, str]]:
    if not isinstance(value, dict):
        raise SystemExit("Terraform outputs must be an object")

    def output(name: str) -> object:
        item = value.get(name)
        if item is None:
            return []
        if not isinstance(item, dict) or "value" not in item:
            raise SystemExit("Terraform replica outputs are invalid")
        return item["value"]

    names = output("replica_names")
    addresses = output("replica_ipv4")
    if not isinstance(names, list) or not isinstance(addresses, list) or len(names) != len(addresses):
        raise SystemExit("Terraform replica outputs are invalid")
    return hosts([
        {"role": "primary", "name": os.environ.get("TF_PRIMARY_INSTANCE_NAME", ""), "ipv4": os.environ.get("TF_PRIMARY_INSTANCE_IPV4", "")},
        *({"role": "replica", "name": name, "ipv4": address} for name, address in zip(names, addresses)),
    ])


def inventory(selected: list[dict[str, str]], user: str) -> dict[str, object]:
    return {
        "all": {"children": {"application_nodes": {"hosts": {
            host["name"]: {"ansible_host": host["ipv4"], "ansible_user": user}
            for host in selected
        }}}}
    }


def new_hosts(all_hosts: list[dict[str, str]], environment: str, current: int, desired: int) -> list[dict[str, str]]:
    expected = {f"{environment}-replica-{n:02d}" for n in range(current + 1, desired + 1)}
    selected = [host for host in all_hosts if host["name"] in expected]
    if {host["name"] for host in selected} != expected:
        raise SystemExit("Terraform outputs do not contain exactly the expected new replicas")
    return selected


def write_private(path: Path, value: object) -> None:
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")
    path.chmod(0o600)


def validate_release(component: str, caller: str, ref_type: str, caller_tag: str, image: str, tag: str) -> None:
    expected = f"LoResuelvo/loresuelvo-{component}"
    if caller != expected:
        raise SystemExit("Deployment caller is not allowed.")
    if ref_type != "tag" or not re.fullmatch(r"v\d+\.\d+\.\d+", caller_tag) or tag != caller_tag:
        raise SystemExit("Caller and release must use the same vX.Y.Z tag.")
    if not re.fullmatch(rf"ghcr\.io/loresuelvo/{component}@sha256:[a-f0-9]{{64}}", image):
        raise SystemExit("Image reference must be an immutable LoResuelvo digest.")


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    release = commands.add_parser("release")
    release.add_argument("component", choices=("api", "webapp"))
    release.add_argument("caller")
    release.add_argument("ref_type")
    release.add_argument("caller_tag")
    release.add_argument("image")
    release.add_argument("tag")
    gateway = commands.add_parser("gateway")
    gateway.add_argument("image")
    gateway.add_argument("tag")
    inv = commands.add_parser("inventory")
    inv.add_argument("hosts_json", type=Path)
    inv.add_argument("output", type=Path)
    inv.add_argument("--user", default="deploy")
    new = commands.add_parser("new-inventory")
    new.add_argument("hosts_json", type=Path)
    new.add_argument("output", type=Path)
    new.add_argument("environment", choices=("staging", "production"))
    new.add_argument("current", type=int)
    new.add_argument("desired", type=int)
    new.add_argument("--user", default="ubuntu")
    keys = commands.add_parser("keys")
    keys.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "release":
        validate_release(args.component, args.caller, args.ref_type, args.caller_tag, args.image, args.tag)
        return
    if args.command == "gateway":
        if not re.fullmatch(r"nginx@sha256:[a-f0-9]{64}", args.image) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-alpine)?", args.tag):
            raise SystemExit("Gateway release inputs are invalid.")
        return
    if args.command == "keys":
        value = json.loads(os.environ["DEPLOY_SSH_PUBLIC_KEYS_JSON"])
        if not isinstance(value, list) or not value or not all(isinstance(key, str) and key.strip() for key in value):
            raise SystemExit("DEPLOY_SSH_PUBLIC_KEYS_JSON must be a non-empty string list")
        write_private(args.output, {"deploy_ssh_public_keys": value})
        return
    all_hosts = terraform_hosts(json.loads(args.hosts_json.read_text(encoding="utf-8")))
    if args.command == "new-inventory":
        all_hosts = new_hosts(all_hosts, args.environment, args.current, args.desired)
        user = args.user
    else:
        user = args.user
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for host in all_hosts:
            print(f"::add-mask::{host['ipv4']}")
    write_private(args.output, inventory(all_hosts, user))


if __name__ == "__main__":
    main()
