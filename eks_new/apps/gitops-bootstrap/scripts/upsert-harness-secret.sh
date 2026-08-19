#!/usr/bin/env bash

set -euo pipefail

required_vars=(
  HARNESS_API_KEY
  HARNESS_ACCOUNT_ID
  HARNESS_ORG_ID
  HARNESS_PROJECT_ID
  SECRET_ID
  SECRET_NAME
  SECRET_VALUE_FILE
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is required"
    exit 1
  fi
done

if [[ ! -s "${SECRET_VALUE_FILE}" ]]; then
  echo "ERROR: Secret value file is empty."
  exit 1
fi

SECRET_MANAGER_ID="${SECRET_MANAGER_ID:-harnessSecretManager}"

BASE_URL="https://app.harness.io/ng/api/v2/secrets"

PAYLOAD_FILE="$(mktemp)"
CHECK_FILE="$(mktemp)"
RESPONSE_FILE="$(mktemp)"

cleanup() {
  rm -f \
    "${PAYLOAD_FILE}" \
    "${CHECK_FILE}" \
    "${RESPONSE_FILE}"
}

trap cleanup EXIT

#
# Read secret without printing it.
#
SECRET_VALUE="$(cat "${SECRET_VALUE_FILE}")"

#
# JSON escaping helper.
#
json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"

  printf '%s' "${value}"
}

ESCAPED_SECRET_NAME="$(json_escape "${SECRET_NAME}")"
ESCAPED_SECRET_ID="$(json_escape "${SECRET_ID}")"
ESCAPED_ORG_ID="$(json_escape "${HARNESS_ORG_ID}")"
ESCAPED_PROJECT_ID="$(json_escape "${HARNESS_PROJECT_ID}")"
ESCAPED_MANAGER_ID="$(json_escape "${SECRET_MANAGER_ID}")"
ESCAPED_SECRET_VALUE="$(json_escape "${SECRET_VALUE}")"

#
# Create API payload.
#
cat > "${PAYLOAD_FILE}" <<EOF
{
  "secret": {
    "type": "SecretText",
    "name": "${ESCAPED_SECRET_NAME}",
    "identifier": "${ESCAPED_SECRET_ID}",
    "orgIdentifier": "${ESCAPED_ORG_ID}",
    "projectIdentifier": "${ESCAPED_PROJECT_ID}",
    "tags": {
      "managedBy": "gitops-bootstrap"
    },
    "description": "Automatically managed GitOps Agent bootstrap secret",
    "spec": {
      "secretManagerIdentifier": "${ESCAPED_MANAGER_ID}",
      "valueType": "Inline",
      "value": "${ESCAPED_SECRET_VALUE}"
    }
  }
}
EOF

chmod 600 "${PAYLOAD_FILE}"

echo "=========================================="
echo "Harness Secret Upsert"
echo "=========================================="
echo "Secret ID      : ${SECRET_ID}"
echo "Secret Manager : ${SECRET_MANAGER_ID}"
echo "Org            : ${HARNESS_ORG_ID}"
echo "Project        : ${HARNESS_PROJECT_ID}"
echo "=========================================="

#
# ---------------------------------------------------------
# STEP 1
# Check whether the secret already exists.
# ---------------------------------------------------------
#
echo
echo "Checking whether Harness secret exists..."

CHECK_HTTP_CODE=$(
  curl \
    --silent \
    --show-error \
    --output "${CHECK_FILE}" \
    --write-out "%{http_code}" \
    --request GET \
    --header "x-api-key: ${HARNESS_API_KEY}" \
    --get \
    --data-urlencode "accountIdentifier=${HARNESS_ACCOUNT_ID}" \
    --data-urlencode "orgIdentifier=${HARNESS_ORG_ID}" \
    --data-urlencode "projectIdentifier=${HARNESS_PROJECT_ID}" \
    --data-urlencode "identifiers=${SECRET_ID}" \
    --data-urlencode "pageIndex=0" \
    --data-urlencode "pageSize=10" \
    "${BASE_URL}"
)

if [[ "${CHECK_HTTP_CODE}" -lt 200 || "${CHECK_HTTP_CODE}" -ge 300 ]]; then
  echo "ERROR: Unable to query Harness secrets."
  echo "HTTP status: ${CHECK_HTTP_CODE}"

  #
  # Print only a possible error message.
  #
  grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' \
    "${CHECK_FILE}" || true

  exit 1
fi

#
# jq is not available on the delegate, so perform a simple
# identifier match.
#
if grep -q "\"identifier\":\"${SECRET_ID}\"" "${CHECK_FILE}" \
   || grep -q "\"identifier\": \"${SECRET_ID}\"" "${CHECK_FILE}"; then

  SECRET_EXISTS=true

else

  SECRET_EXISTS=false

fi

#
# ---------------------------------------------------------
# STEP 2
# Update existing secret.
# ---------------------------------------------------------
#
if [[ "${SECRET_EXISTS}" == "true" ]]; then

  echo "Secret exists. Updating: ${SECRET_ID}"

  UPDATE_URL="${BASE_URL}/${SECRET_ID}?accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${HARNESS_ORG_ID}&projectIdentifier=${HARNESS_PROJECT_ID}"

  HTTP_CODE=$(
    curl \
      --silent \
      --show-error \
      --output "${RESPONSE_FILE}" \
      --write-out "%{http_code}" \
      --request PUT \
      --header "x-api-key: ${HARNESS_API_KEY}" \
      --header "Content-Type: application/json" \
      --data-binary @"${PAYLOAD_FILE}" \
      "${UPDATE_URL}"
  )

#
# ---------------------------------------------------------
# STEP 3
# Create new secret.
# ---------------------------------------------------------
#
else

  echo "Secret does not exist. Creating: ${SECRET_ID}"

  CREATE_URL="${BASE_URL}?accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${HARNESS_ORG_ID}&projectIdentifier=${HARNESS_PROJECT_ID}"

  HTTP_CODE=$(
    curl \
      --silent \
      --show-error \
      --output "${RESPONSE_FILE}" \
      --write-out "%{http_code}" \
      --request POST \
      --header "x-api-key: ${HARNESS_API_KEY}" \
      --header "Content-Type: application/json" \
      --data-binary @"${PAYLOAD_FILE}" \
      "${CREATE_URL}"
  )

fi

#
# ---------------------------------------------------------
# STEP 4
# Validate create/update response.
# ---------------------------------------------------------
#
if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then

  echo
  echo "ERROR: Failed to create/update Harness secret."
  echo "Secret ID : ${SECRET_ID}"
  echo "HTTP code : ${HTTP_CODE}"

  #
  # Do NOT print the request payload.
  #
  # Try to print only Harness's error message.
  #
  grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' \
    "${RESPONSE_FILE}" || true

  exit 1
fi

echo
echo "=========================================="
echo "Harness secret stored successfully"
echo "=========================================="
echo "Secret ID : ${SECRET_ID}"
echo "Operation : $(
  if [[ "${SECRET_EXISTS}" == "true" ]]; then
    echo "updated"
  else
    echo "created"
  fi
)"
echo "=========================================="