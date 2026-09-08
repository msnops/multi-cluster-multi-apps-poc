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

RAW_RESPONSE_FILE="${OUTPUT_DIR}/harness-agent-overrides.raw"
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
    --output "${RAW_RESPONSE_FILE}" \
    --write-out "%{http_code}" \
    --request GET \
    --header "x-api-key: ${HARNESS_API_KEY}" \
    --header "Accept: application/yaml" \
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

if [[ ! -s "${RAW_RESPONSE_FILE}" ]]; then
  echo "ERROR: Harness returned an empty override response."
  exit 1
fi

chmod 600 "${RAW_RESPONSE_FILE}"

echo "Harness override response retrieved successfully."
echo "Response size: $(wc -c < "${RAW_RESPONSE_FILE}") bytes"

#
# Determine whether Harness gave us:
#
# 1. Raw multiline YAML
#
# OR
#
# 2. A quoted/escaped string containing \n
#
if grep -q '^[[:space:]]*harness:[[:space:]]*$' \
  "${RAW_RESPONSE_FILE}"; then

  echo "Response format: raw YAML"

  cp "${RAW_RESPONSE_FILE}" "${OVERRIDES_FILE}"

else

  echo "Response is not directly formatted as multiline YAML."
  echo "Checking for encoded string response..."

  #
  # Detect JSON/YAML quoted string with escaped newlines.
  #
  if grep -q '\\n' "${RAW_RESPONSE_FILE}"; then

    echo "Response format: escaped string"

    #
    # Remove a surrounding double quote, if present,
    # then turn escaped newline/tab/quote sequences
    # back into their text representation.
    #
    sed \
      -e '1s/^"//' \
      -e '$s/"$//' \
      -e 's/\\n/\
/g' \
      -e 's/\\t/	/g' \
      -e 's/\\"/"/g' \
      -e 's/\\\\/\\/g' \
      "${RAW_RESPONSE_FILE}" \
      > "${OVERRIDES_FILE}"

  else

    echo "ERROR: Harness response was not recognized as Helm override YAML."
    echo
    echo "Diagnostic information:"
    echo "Size: $(wc -c < "${RAW_RESPONSE_FILE}") bytes"
    echo
    echo "No response contents were printed because the file may contain credentials."
    exit 1

  fi

fi

chmod 600 "${OVERRIDES_FILE}"

#
# Validate that we now have the expected YAML structure.
#
if ! grep -q '^[[:space:]]*harness:[[:space:]]*$' \
  "${OVERRIDES_FILE}"; then

  echo "ERROR: Decoded response does not contain a harness: section."
  exit 1
fi

AGENT_KEY_COUNT=$(
  grep -c \
    '^[[:space:]]*agentSecret:[[:space:]]*' \
    "${OVERRIDES_FILE}" \
    || true
)

REDIS_KEY_COUNT=$(
  grep -c \
    '^[[:space:]]*redisPassword:[[:space:]]*' \
    "${OVERRIDES_FILE}" \
    || true
)

echo
echo "Override validation:"
echo "agentSecret keys   : ${AGENT_KEY_COUNT}"
echo "redisPassword keys : ${REDIS_KEY_COUNT}"

if [[ "${AGENT_KEY_COUNT}" -eq 0 ]]; then
  echo "ERROR: agentSecret was not found in Harness override YAML."
  exit 1
fi

if [[ "${REDIS_KEY_COUNT}" -eq 0 ]]; then
  echo "ERROR: redisPassword was not found in Harness override YAML."
  exit 1
fi

#
# Extract agentSecret.
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
# Remove CR characters, which can sometimes appear when
# generated files use Windows-style line endings.
#
AGENT_SECRET=$(
  printf '%s' "${AGENT_SECRET}" \
    | tr -d '\r'
)

REDIS_PASSWORD=$(
  printf '%s' "${REDIS_PASSWORD}" \
    | tr -d '\r'
)

#
# Strip surrounding quotes.
#
AGENT_SECRET=$(
  printf '%s' "${AGENT_SECRET}" \
    | sed \
        -e 's/^"//' \
        -e 's/"$//' \
        -e "s/^'//" \
        -e "s/'$//"
)

REDIS_PASSWORD=$(
  printf '%s' "${REDIS_PASSWORD}" \
    | sed \
        -e 's/^"//' \
        -e 's/"$//' \
        -e "s/^'//" \
        -e "s/'$//"
)

if [[ -z "${AGENT_SECRET}" ]]; then
  echo "ERROR: agentSecret exists but is empty."
  exit 1
fi

if [[ -z "${REDIS_PASSWORD}" ]]; then
  echo "ERROR: redisPassword exists but is empty."
  exit 1
fi

#
# Never echo either secret.
#
printf '%s' "${AGENT_SECRET}" \
  > "${AGENT_SECRET_FILE}"

printf '%s' "${REDIS_PASSWORD}" \
  > "${REDIS_PASSWORD_FILE}"

chmod 600 \
  "${AGENT_SECRET_FILE}" \
  "${REDIS_PASSWORD_FILE}"

#
# Validate agentSecret.
#
# Your Harness-generated value is Base64 containing the
# RSA private key used by the GitOps Agent.
#
if ! base64 --decode "${AGENT_SECRET_FILE}" >/dev/null 2>&1; then
  echo "ERROR: Harness-generated agentSecret is not valid Base64."
  exit 1
fi

#
# Stronger validation:
# after Base64 decoding, this should look like a private key.
#
if ! base64 --decode "${AGENT_SECRET_FILE}" 2>/dev/null \
  | grep -q 'BEGIN .*PRIVATE KEY'; then

  echo "ERROR: Decoded agentSecret does not look like a private key."
  exit 1
fi

echo
echo "=========================================="
echo "Harness Agent credentials prepared"
echo "=========================================="
echo "agentSecret    : found"
echo "agentSecret    : valid Base64"
echo "agentSecret    : private key validated"
echo "redisPassword  : found"
echo "=========================================="
echo "No credential values were printed."