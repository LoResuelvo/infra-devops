#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 CALLER_REPOSITORY REF_TYPE CALLER_TAG IMAGE_REF RELEASE_TAG" >&2
  exit 2
fi

caller_repository=$1
ref_type=$2
caller_tag=$3
image_ref=$4
release_tag=$5
tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'
image_pattern='^ghcr\.io/loresuelvo/webapp@sha256:[a-f0-9]{64}$'

[[ "$caller_repository" == "LoResuelvo/loresuelvo-webapp" ]] || {
  echo "Deployment caller is not allowed." >&2
  exit 1
}
[[ "$ref_type" == "tag" && "$caller_tag" =~ $tag_pattern ]] || {
  echo "Caller must run from a vX.Y.Z tag." >&2
  exit 1
}
[[ "$release_tag" == "$caller_tag" ]] || {
  echo "Release tag does not match the caller tag." >&2
  exit 1
}
[[ "$image_ref" =~ $image_pattern ]] || {
  echo "Image reference must be an immutable LoResuelvo Web App digest." >&2
  exit 1
}
