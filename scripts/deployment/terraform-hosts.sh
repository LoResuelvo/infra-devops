#!/usr/bin/env bash
# Write deployment hosts from a Terraform output to a private file.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 TERRAFORM_ROOT OUTPUT_FILE" >&2
  exit 2
fi

terraform_root=$1
output_file=$2
[[ -d "$terraform_root" ]] || { echo "Terraform root not found." >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "terraform is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

umask 077
temporary_file=$(mktemp "${output_file}.XXXXXX")
trap 'rm -f "$temporary_file"' EXIT

terraform -chdir="$terraform_root" output -json deployment_hosts |
  python3 -c '
import ipaddress
import json
import sys

hosts = json.load(sys.stdin)
if not isinstance(hosts, list) or not hosts:
    raise SystemExit("deployment_hosts must be a non-empty list")
addresses = []
names = set()
for host in hosts:
    if set(host) != {"role", "name", "ipv4"}:
        raise SystemExit("deployment_hosts contains an invalid object")
    if host["role"] not in {"primary", "replica"} or not host["name"]:
        raise SystemExit("deployment_hosts contains invalid host metadata")
    if host["name"] in names:
        raise SystemExit("deployment_hosts contains duplicate names")
    names.add(host["name"])
    addresses.append(str(ipaddress.IPv4Address(host["ipv4"])))
sys.stdout.write("\n".join(addresses) + "\n")
' > "$temporary_file"

[[ -s "$temporary_file" ]] || { echo "Terraform returned no deployment hosts." >&2; exit 1; }
mv "$temporary_file" "$output_file"
trap - EXIT
