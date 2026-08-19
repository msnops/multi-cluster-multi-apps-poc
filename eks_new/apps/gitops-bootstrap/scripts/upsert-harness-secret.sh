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

SECRET_VALUE="$(cat "${SECRET_VALUE_FILE}")"

#
# Do NOT echo SECRET_VALUE.
#
jq -n \
  --arg name "${SECRET_NAME}" \
  --arg identifier "${SECRET_ID}" \
  --arg org "${HARNESS_ORG_ID}" \
  --arg project "${HARNESS_PROJECT_ID}" \
  --arg manager "${SECRET_MANAGER_ID}" \
  --arg value "${SECRET_VALUE}" \
  '{
    secret: {
      type: "SecretText",
      name: $name,
      identifier: $identifier,
      orgIdentifier: $org,
      projectIdentifier: $project,
      tags: {
        managedBy: "gitops-bootstrap"
      },
      description: "Automatically managed GitOps Agent bootstrap secret",
      spec: {
        secretManagerIdentifier: $manager,
        valueType: "Inline",
        value: $value
      }
    }
  }' > "${PAYLOAD_FILE}"

chmod 600 "${PAYLOAD_FILE}"

echo "Checking Harness secret: ${SECRET_ID}"

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

    echo "Secret exists. Updating ${SECRET_ID}."

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

    echo "Secret does not exist. Creating ${SECRET_ID}."

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

    echo "ERROR: Unable to check Harness secret ${SECRET_ID}."
    echo "HTTP status: ${HTTP_CODE}"
    exit 1

    ;;
esac

if [[ "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
  echo "ERROR: Failed to create/update Harness secret ${SECRET_ID}."
  echo "HTTP status: ${HTTP_CODE}"

  # Don't print response/payload because this operation contains a secret.
  exit 1
fi

echo "Harness secret ${SECRET_ID} successfully stored."