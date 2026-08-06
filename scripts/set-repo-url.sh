#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 https://github.com/ORG/REPOSITORY.git" >&2
  exit 1
fi

repo_url="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "$repo_root" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
  | xargs -0 sed -i "s#https://github.com/msnops/multi-cluster-multi-apps-poc.git#${repo_url}#g"

echo "Repository URL updated to: $repo_url"
