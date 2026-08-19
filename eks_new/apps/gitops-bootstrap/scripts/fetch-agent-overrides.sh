#!/usr/bin/env bash

set -euo pipefail

required_vars=(
  HARNESS_API_KEY
  HARNESS_ACCOUNT_ID
  HARNESS_ORG_ID
  HARNESS_PROJECT_ID
  GITOPS_AGENT_ID
  NAMESPACE
  OUTPUT_DIR
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is required"
    exit 1
  fi
done

mkdir -p "${OUTPUT_DIR}"

chmod 700 "${OUTPUT_DIR}"

OVERRIDES_FILE="${OUTPUT_DIR}/harness-agent-overrides.yaml"
AGENT_SECRET_FILE="${OUTPUT_DIR}/agent-secret"
REDIS_PASSWORD_FILE="${OUTPUT_DIR}/redis-password"

echo "=========================================="
echo "Fetching Harness-generated Agent overrides"
echo "=========================================="
echo "Agent     : ${GITOPS_AGENT_ID}"
echo "Org       : ${HARNESS_ORG_ID}"
echo "Project   : ${HARNESS_PROJECT_ID}"
echo "Namespace : ${NAMESPACE}"
echo "=========================================="

HTTP_CODE=$(
  curl \
    --silent \
    --show-error \
    --output "${OVERRIDES_FILE}" \
    --write-out "%{http_code}" \
    --request GET \
    --header "x-api-key: ${HARNESS_API_KEY}" \
    --get \
    --data-urlencode "accountIdentifier=${HARNESS_ACCOUNT_ID}" \
    --data-urlencode "orgIdentifier=${HARNESS_ORG_ID}" \
    --data-urlencode "projectIdentifier=${HARNESS_PROJECT_ID}" \
    --data-urlencode "namespace=${NAMESPACE}" \
    --data-urlencode "skipCrds=true" \
    "https://app.harness.io/gitops/api/v1/agents/${GITOPS_AGENT_ID}/helm-overrides"
)

if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
  echo "ERROR: Failed to retrieve Harness GitOps Agent overrides."
  echo "HTTP status: ${HTTP_CODE}"

  # Don't print the response because it could contain sensitive material.
  exit 1
fi

if [[ ! -s "${OVERRIDES_FILE}" ]]; then
  echo "ERROR: Harness returned an empty override file."
  exit 1
fi

chmod 600 "${OVERRIDES_FILE}"

#
# Extract secrets without printing them.
#
# Harness's generated override file contains:
#
# harness:
#   secrets:
#     agentSecret: ...
#     redisPassword: ...
#
python3 - \
  "${OVERRIDES_FILE}" \
  "${AGENT_SECRET_FILE}" \
  "${REDIS_PASSWORD_FILE}" <<'PY'

import sys
import re

source = sys.argv[1]
agent_file = sys.argv[2]
redis_file = sys.argv[3]

agent_secret = None
redis_password = None

with open(source, "r", encoding="utf-8") as f:
    for line in f:

        match = re.match(
            r'^\s*agentSecret:\s*(.*?)\s*$',
            line
        )

        if match and agent_secret is None:
            agent_secret = match.group(1)

        match = re.match(
            r'^\s*redisPassword:\s*(.*?)\s*$',
            line
        )

        if match and redis_password is None:
            redis_password = match.group(1)

def cleanup(value):
    if value is None:
        return None

    value = value.strip()

    if (
        len(value) >= 2
        and value[0] == value[-1]
        and value[0] in ("'", '"')
    ):
        value = value[1:-1]

    return value

agent_secret = cleanup(agent_secret)
redis_password = cleanup(redis_password)

if not agent_secret:
    raise SystemExit(
        "ERROR: agentSecret was not found in Harness overrides"
    )

if not redis_password:
    raise SystemExit(
        "ERROR: redisPassword was not found in Harness overrides"
    )

with open(agent_file, "w", encoding="utf-8") as f:
    f.write(agent_secret)

with open(redis_file, "w", encoding="utf-8") as f:
    f.write(redis_password)

PY

chmod 600 \
  "${AGENT_SECRET_FILE}" \
  "${REDIS_PASSWORD_FILE}"

#
# Harness Agent token is expected to contain valid Base64.
#
if ! base64 --decode "${AGENT_SECRET_FILE}" >/dev/null 2>&1; then
  echo "ERROR: Harness generated agentSecret is not valid Base64."
  exit 1
fi

echo "Harness Agent overrides retrieved successfully."
echo "Agent secret validated as Base64."
echo "Redis password retrieved successfully."
echo
echo "No secret values were printed."