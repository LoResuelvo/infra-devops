#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 staging|production" >&2
  exit 2
fi

case "$1" in
  staging)
    base_url="https://api-test.loresuelvo.com.ar"
    ;;
  production)
    base_url="https://api.loresuelvo.com.ar"
    ;;
  *)
    echo "environment must be staging or production" >&2
    exit 2
    ;;
esac

for route in / /health/ready; do
  echo "Checking $base_url$route"
  curl --fail --silent --show-error \
    --retry 5 --retry-delay 2 --retry-all-errors --max-time 10 \
    "$base_url$route" >/dev/null
done

echo "Smoke test passed."
