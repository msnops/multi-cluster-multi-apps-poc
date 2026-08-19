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
  exit 1
fi

if [[ ! -s "${OVERRIDES_FILE}" ]]; then
  echo "ERROR: Harness returned an empty override file."
  exit 1
fi

chmod 600 "${OVERRIDES_FILE}"

echo "Harness override file retrieved successfully."

#
# Extract agentSecret.
#
# Expected:
#
# harness:
#   secrets:
#     agentSecret: xxxxx
#
AGENT_SECRET=$(
  awk '
    /^[[:space:]]*agentSecret:[[:space:]]*/ {
      sub(/^[[:space:]]*agentSecret:[[:space:]]*/, "")
      print
      exit
    }
  ' "${OVERRIDES_FILE}"
)

#
# Extract redisPassword.
#
REDIS_PASSWORD=$(
  awk '
    /^[[:space:]]*redisPassword:[[:space:]]*/ {
      sub(/^[[:space:]]*redisPassword:[[:space:]]*/, "")
      print
      exit
    }
  ' "${OVERRIDES_FILE}"
)

#
# Remove surrounding single/double quotes if present.
#
AGENT_SECRET=$(
  printf '%s' "${AGENT_SECRET}" \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
)

REDIS_PASSWORD=$(
  printf '%s' "${REDIS_PASSWORD}" \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
)

if [[ -z "${AGENT_SECRET}" ]]; then
  echo "ERROR: agentSecret was not found in Harness override YAML."
  exit 1
fi

if [[ -z "${REDIS_PASSWORD}" ]]; then
  echo "ERROR: redisPassword was not found in Harness override YAML."
  exit 1
fi

#
# Write secrets without printing them.
#
printf '%s' "${AGENT_SECRET}" \
  > "${AGENT_SECRET_FILE}"

printf '%s' "${REDIS_PASSWORD}" \
  > "${REDIS_PASSWORD_FILE}"

chmod 600 \
  "${AGENT_SECRET_FILE}" \
  "${REDIS_PASSWORD_FILE}"

#
# Validate the GitOps Agent token.
#
if ! base64 --decode "${AGENT_SECRET_FILE}" >/dev/null 2>&1; then
  echo "ERROR: Harness-generated agentSecret is not valid Base64."
  exit 1
fi

echo "Agent secret extracted successfully."
echo "Agent secret format: valid Base64."
echo "Redis password extracted successfully."
echo "No secret values were printed."