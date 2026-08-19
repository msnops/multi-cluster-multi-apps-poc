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

QUERY="accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${HARNESS_ORG_ID}&projectIdentifier=${HARNESS_PROJECT_ID}"

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
# Read secret value without printing it.
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
echo "Secret ID : ${SECRET_ID}"
echo "Org       : ${HARNESS_ORG_ID}"
echo "Project   : ${HARNESS_PROJECT_ID}"
echo "=========================================="

echo
echo "Checking whether Harness secret exists..."

HTTP_CODE=$(
  curl \
    --silent \
    --show-error \
    --output "${CHECK_FILE}" \
    --write-out "%{http_code}" \
    --request GET \
    --header "x-api-key: ${HARNESS_API_KEY}" \
    "${BASE_URL}/${SECRET_ID}?${QUERY}"
)

case "${HTTP_CODE}" in

  200)

    echo "Secret exists. Updating: ${SECRET_ID}"

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
        "${BASE_URL}/${SECRET_ID}?${QUERY}"
    )

    ;;

  404)

    echo "Secret does not exist. Creating: ${SECRET_ID}"

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
        "${BASE_URL}?${QUERY}"
    )

    ;;

  *)

    echo "ERROR: Unable to check Harness secret."
    echo "HTTP status: ${HTTP_CODE}"
    exit 1

    ;;
esac

if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
  echo "ERROR: Failed to create/update Harness secret."
  echo "Secret ID : ${SECRET_ID}"
  echo "HTTP code : ${HTTP_CODE}"

  #
  # Do not print RESPONSE_FILE because it may contain
  # sensitive information.
  #
  exit 1
fi

echo
echo "Harness secret stored successfully."
echo "Secret ID: ${SECRET_ID}"