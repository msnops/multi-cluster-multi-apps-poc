#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

############################################
# Tools
############################################

for cmd in curl jq openssl base64; do
  command -v "${cmd}" >/dev/null 2>&1 ||
    fail "${cmd} is not installed"
done

############################################
# Inputs
############################################

: "${DEPLOY_ENV:?required}"

: "${KEYFACTOR_URL:?required}"
: "${KEYFACTOR_USERNAME:?required}"
: "${KEYFACTOR_PASSWORD:?required}"
: "${KEYFACTOR_ENROLLMENT_PATTERN_ID:?required}"

: "${CERT_CN:?required}"
: "${CERT_SANS:?required}"

: "${HCV_ADDR:?required}"
: "${HCV_NAMESPACE:?required}"
: "${HCV_TOKEN:?required}"
: "${HCV_KV_MOUNT:?required}"
: "${HCV_SECRET_PATH:?required}"

KEYFACTOR_URL="${KEYFACTOR_URL%/}"
HCV_ADDR="${HCV_ADDR%/}"

############################################
# Secure work directory
############################################

WORKDIR="$(mktemp -d)"
chmod 700 "${WORKDIR}"

cleanup() {
  rm -rf "${WORKDIR}" 2>/dev/null || true
}

trap cleanup EXIT

KF_REQUEST="${WORKDIR}/keyfactor-request.json"
KF_RESPONSE="${WORKDIR}/keyfactor-response.json"

PFX_FILE="${WORKDIR}/certificate.pfx"
TLS_CERT="${WORKDIR}/tls.crt"
TLS_KEY="${WORKDIR}/tls.key"
CA_CERT="${WORKDIR}/ca.crt"
FULL_CHAIN="${WORKDIR}/fullchain.crt"

VAULT_REQUEST="${WORKDIR}/vault-request.json"
VAULT_RESPONSE="${WORKDIR}/vault-response.json"
VAULT_READ="${WORKDIR}/vault-read.json"

############################################
# Information only - never print credentials
############################################

log "Environment       : ${DEPLOY_ENV}"
log "Certificate CN    : ${CERT_CN}"
log "Vault namespace   : ${HCV_NAMESPACE}"
log "Vault secret      : ${HCV_KV_MOUNT}/${HCV_SECRET_PATH}"
log "Enrollment pattern: ${KEYFACTOR_ENROLLMENT_PATTERN_ID}"

############################################
# Build DNS SAN JSON array
############################################

SAN_JSON="$(
  printf '%s' "${CERT_SANS}" |
    jq -R '
      split(",")
      | map(gsub("^\\s+|\\s+$"; ""))
      | map(select(length > 0))
    '
)"

SAN_COUNT="$(jq 'length' <<< "${SAN_JSON}")"

if [ "${SAN_COUNT}" -eq 0 ]; then
  fail "At least one SAN must be supplied"
fi

############################################
# Test Keyfactor PFX enrollment access
############################################

log "Checking Keyfactor enrollment context"

CONTEXT_CODE="$(
  curl \
    --silent \
    --show-error \
    --user "${KEYFACTOR_USERNAME}:${KEYFACTOR_PASSWORD}" \
    --header "Accept: application/json" \
    --output "${WORKDIR}/context.json" \
    --write-out "%{http_code}" \
    "${KEYFACTOR_URL}/KeyfactorAPI/Enrollment/PFX/Context/My"
)"

if [[ "${CONTEXT_CODE}" -lt 200 || "${CONTEXT_CODE}" -ge 300 ]]; then
  fail "Unable to query Keyfactor PFX enrollment context. HTTP ${CONTEXT_CODE}"
fi

############################################
# Keyfactor request
#
# Keyfactor v25.x PFX enrollment requires
# KeyType and KeyLength/Curve as applicable.
############################################

TIMESTAMP="$(
  date -u +"%Y-%m-%dT%H:%M:%SZ"
)"

jq -n \
  --arg subject "CN=${CERT_CN}" \
  --arg timestamp "${TIMESTAMP}" \
  --argjson pattern "${KEYFACTOR_ENROLLMENT_PATTERN_ID}" \
  --argjson sans "${SAN_JSON}" \
  '{
     EnrollmentPatternId: $pattern,
     Subject: $subject,
     SANs: {
       dns: $sans
     },

     KeyType: "RSA",
     KeyLength: 2048,

     IncludeChain: true,
     ChainOrder: "EndEntityFirst",
     InstallIntoExistingCertificateStores: false,
     UseLegacyEncryption: false,

     Timestamp: $timestamp
   }' > "${KF_REQUEST}"

############################################
# Enroll PFX
############################################

log "Requesting PFX certificate from Keyfactor"

KF_HTTP_CODE="$(
  curl \
    --silent \
    --show-error \
    --user "${KEYFACTOR_USERNAME}:${KEYFACTOR_PASSWORD}" \
    --request POST \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --header "x-CertificateFormat: PFX" \
    --data @"${KF_REQUEST}" \
    --output "${KF_RESPONSE}" \
    --write-out "%{http_code}" \
    "${KEYFACTOR_URL}/KeyfactorAPI/Enrollment/PFX"
)"

if [[ "${KF_HTTP_CODE}" -lt 200 || "${KF_HTTP_CODE}" -ge 300 ]]; then
  log "Keyfactor enrollment failed with HTTP ${KF_HTTP_CODE}"

  # API error response can be useful but do not print request data.
  jq . "${KF_RESPONSE}" 2>/dev/null || true

  exit 1
fi

############################################
# Request disposition
############################################

DISPOSITION="$(
  jq -r '
    .CertificateInformation.RequestDisposition
    // "UNKNOWN"
  ' "${KF_RESPONSE}"
)"

log "Keyfactor disposition: ${DISPOSITION}"

if [ "${DISPOSITION}" != "ISSUED" ]; then

  REQUEST_ID="$(
    jq -r '
      .CertificateInformation.KeyfactorRequestId
      // "unknown"
    ' "${KF_RESPONSE}"
  )"

  WORKFLOW_ID="$(
    jq -r '
      .CertificateInformation.WorkflowReferenceId
      // "unknown"
    ' "${KF_RESPONSE}"
  )"

  log "Keyfactor request ID: ${REQUEST_ID}"
  log "Workflow ID        : ${WORKFLOW_ID}"

  fail "Certificate was not immediately issued"
fi

############################################
# Extract PFX data/password
############################################

PFX_BASE64="$(
  jq -r '
    .CertificateInformation.PKCS12Blob
    // empty
  ' "${KF_RESPONSE}"
)"

PFX_PASSWORD="$(
  jq -r '
    .CertificateInformation.Password
    // empty
  ' "${KF_RESPONSE}"
)"

[ -n "${PFX_BASE64}" ] ||
  fail "Keyfactor response does not contain PKCS12Blob"

[ -n "${PFX_PASSWORD}" ] ||
  fail "Keyfactor response does not contain generated PFX password"

############################################
# Decode PFX
############################################

printf '%s' "${PFX_BASE64}" |
  base64 --decode > "${PFX_FILE}"

chmod 600 "${PFX_FILE}"

############################################
# Validate PKCS12 package
############################################

log "Validating returned PFX"

openssl pkcs12 \
  -in "${PFX_FILE}" \
  -passin "pass:${PFX_PASSWORD}" \
  -info \
  -noout >/dev/null 2>&1 ||
  fail "Returned PFX cannot be opened"

############################################
# Extract leaf certificate
############################################

openssl pkcs12 \
  -in "${PFX_FILE}" \
  -passin "pass:${PFX_PASSWORD}" \
  -clcerts \
  -nokeys \
  -out "${TLS_CERT}"

############################################
# Extract private key
############################################

openssl pkcs12 \
  -in "${PFX_FILE}" \
  -passin "pass:${PFX_PASSWORD}" \
  -nocerts \
  -nodes \
  -out "${TLS_KEY}"

chmod 600 "${TLS_KEY}"

############################################
# Extract CA chain
############################################

openssl pkcs12 \
  -in "${PFX_FILE}" \
  -passin "pass:${PFX_PASSWORD}" \
  -cacerts \
  -nokeys \
  -out "${CA_CERT}" 2>/dev/null || true

touch "${CA_CERT}"

cat "${TLS_CERT}" "${CA_CERT}" > "${FULL_CHAIN}"

############################################
# Validate issued certificate
############################################

log "Validating issued certificate"

openssl x509 \
  -in "${TLS_CERT}" \
  -noout \
  -subject \
  -issuer \
  -serial \
  -dates

############################################
# Check private key matches cert
############################################

KEY_HASH="$(
  openssl pkey \
    -in "${TLS_KEY}" \
    -pubout \
    -outform DER 2>/dev/null |
  openssl sha256 |
  awk '{print $2}'
)"

CERT_HASH="$(
  openssl x509 \
    -in "${TLS_CERT}" \
    -pubkey \
    -noout |
  openssl pkey \
    -pubin \
    -outform DER 2>/dev/null |
  openssl sha256 |
  awk '{print $2}'
)"

[ "${KEY_HASH}" = "${CERT_HASH}" ] ||
  fail "Issued certificate/private-key mismatch"

############################################
# Verify SANs
############################################

ISSUED_SANS="$(
  openssl x509 \
    -in "${TLS_CERT}" \
    -noout \
    -ext subjectAltName 2>/dev/null || true
)"

IFS=',' read -ra SAN_ARRAY <<< "${CERT_SANS}"

for SAN in "${SAN_ARRAY[@]}"; do

  SAN="$(printf '%s' "${SAN}" | xargs)"

  [ -z "${SAN}" ] && continue

  if ! grep -Fq "DNS:${SAN}" <<< "${ISSUED_SANS}"; then
    fail "Certificate missing requested SAN: ${SAN}"
  fi
done

############################################
# Metadata
############################################

SERIAL="$(
  openssl x509 \
    -in "${TLS_CERT}" \
    -noout \
    -serial |
  cut -d= -f2
)"

EXPIRY="$(
  openssl x509 \
    -in "${TLS_CERT}" \
    -noout \
    -enddate |
  cut -d= -f2-
)"

FINGERPRINT="$(
  openssl x509 \
    -in "${TLS_CERT}" \
    -noout \
    -fingerprint \
    -sha256 |
  cut -d= -f2
)"

KEYFACTOR_ID="$(
  jq -r '
    .CertificateInformation.KeyfactorId
    // .CertificateInformation.KeyfactorID
    // "unknown"
  ' "${KF_RESPONSE}"
)"

############################################
# Build Vault KV v2 object
############################################

jq -n \
  --rawfile tls_cert "${TLS_CERT}" \
  --rawfile tls_key "${TLS_KEY}" \
  --rawfile ca_cert "${CA_CERT}" \
  --rawfile fullchain "${FULL_CHAIN}" \
  --arg environment "${DEPLOY_ENV}" \
  --arg common_name "${CERT_CN}" \
  --arg serial "${SERIAL}" \
  --arg expiry "${EXPIRY}" \
  --arg fingerprint "${FINGERPRINT}" \
  --arg keyfactor_id "${KEYFACTOR_ID}" \
  '{
     data: {
       "tls.crt": $tls_cert,
       "tls.key": $tls_key,
       "ca.crt": $ca_cert,
       "fullchain.crt": $fullchain,

       "environment": $environment,
       "common_name": $common_name,
       "serial_number": $serial,
       "expiry": $expiry,
       "sha256_fingerprint": $fingerprint,
       "keyfactor_id": $keyfactor_id
     }
   }' > "${VAULT_REQUEST}"

############################################
# Write to KV v2
############################################

VAULT_URL="${HCV_ADDR}/v1/${HCV_KV_MOUNT}/data/${HCV_SECRET_PATH}"

log "Writing certificate to HCV"

VAULT_HTTP_CODE="$(
  curl \
    --silent \
    --show-error \
    --request POST \
    --header "X-Vault-Token: ${HCV_TOKEN}" \
    --header "X-Vault-Namespace: ${HCV_NAMESPACE}" \
    --header "Content-Type: application/json" \
    --data @"${VAULT_REQUEST}" \
    --output "${VAULT_RESPONSE}" \
    --write-out "%{http_code}" \
    "${VAULT_URL}"
)"

if [[ "${VAULT_HTTP_CODE}" -lt 200 || "${VAULT_HTTP_CODE}" -ge 300 ]]; then
  jq . "${VAULT_RESPONSE}" 2>/dev/null || true
  fail "HCV write failed. HTTP ${VAULT_HTTP_CODE}"
fi

VAULT_VERSION="$(
  jq -r '.data.version // "unknown"' "${VAULT_RESPONSE}"
)"

############################################
# Read secret back
############################################

log "Reading certificate back from HCV"

READ_CODE="$(
  curl \
    --silent \
    --show-error \
    --request GET \
    --header "X-Vault-Token: ${HCV_TOKEN}" \
    --header "X-Vault-Namespace: ${HCV_NAMESPACE}" \
    --output "${VAULT_READ}" \
    --write-out "%{http_code}" \
    "${VAULT_URL}"
)"

if [[ "${READ_CODE}" -lt 200 || "${READ_CODE}" -ge 300 ]]; then
  fail "Unable to read certificate back from HCV. HTTP ${READ_CODE}"
fi

jq -r \
  '.data.data["tls.crt"]' \
  "${VAULT_READ}" \
  > "${WORKDIR}/vault-tls.crt"

jq -r \
  '.data.data["tls.key"]' \
  "${VAULT_READ}" \
  > "${WORKDIR}/vault-tls.key"

############################################
# Compare cert fingerprint
############################################

VAULT_FINGERPRINT="$(
  openssl x509 \
    -in "${WORKDIR}/vault-tls.crt" \
    -noout \
    -fingerprint \
    -sha256 |
  cut -d= -f2
)"

[ "${FINGERPRINT}" = "${VAULT_FINGERPRINT}" ] ||
  fail "Certificate stored in HCV differs from Keyfactor certificate"

############################################
# Check HCV cert/key pair
############################################

VAULT_KEY_HASH="$(
  openssl pkey \
    -in "${WORKDIR}/vault-tls.key" \
    -pubout \
    -outform DER 2>/dev/null |
  openssl sha256 |
  awk '{print $2}'
)"

VAULT_CERT_HASH="$(
  openssl x509 \
    -in "${WORKDIR}/vault-tls.crt" \
    -pubkey \
    -noout |
  openssl pkey \
    -pubin \
    -outform DER 2>/dev/null |
  openssl sha256 |
  awk '{print $2}'
)"

[ "${VAULT_KEY_HASH}" = "${VAULT_CERT_HASH}" ] ||
  fail "Certificate/private key stored in HCV do not match"

############################################
# Success
############################################

log "============================================"
log "Certificate provisioning successful"
log "Environment    : ${DEPLOY_ENV}"
log "CN             : ${CERT_CN}"
log "Serial         : ${SERIAL}"
log "Expiry         : ${EXPIRY}"
log "Keyfactor ID   : ${KEYFACTOR_ID}"
log "Vault namespace: ${HCV_NAMESPACE}"
log "Vault path     : ${HCV_KV_MOUNT}/${HCV_SECRET_PATH}"
log "Vault version  : ${VAULT_VERSION}"
log "============================================"
