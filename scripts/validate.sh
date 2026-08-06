#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v helm >/dev/null 2>&1 || {
  echo "helm is required" >&2
  exit 1
}

helm lint "$repo_root/applications/hello-world"

for cluster in dev-cluster01 sit-cluster01 uat-cluster01 prd-cluster01; do
  helm lint "$repo_root/platform/appset" \
    --set-string clusterName="$cluster" \
    --set-string repoURL="https://github.com/example/example.git" \
    --set-string targetRevision="main" \
    --set-string gitopsNamespace="harness-gitops"

  helm template "root-$cluster" "$repo_root/platform/appset" \
    --set-string clusterName="$cluster" \
    --set-string repoURL="https://github.com/example/example.git" \
    --set-string targetRevision="main" \
    --set-string gitopsNamespace="harness-gitops" \
    > /dev/null
done

echo "Validation completed successfully."
