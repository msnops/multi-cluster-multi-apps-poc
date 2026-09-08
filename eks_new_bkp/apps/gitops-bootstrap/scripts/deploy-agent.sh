#!/usr/bin/env bash

set -euo pipefail

required_vars=(
  REPO_ROOT
  CLUSTER_NAME
  ENVIRONMENT
  GITOPS_AGENT_ID
  NAMESPACE
  HARNESS_ACCOUNT_ID
  HARNESS_ORG_ID
  HARNESS_PROJECT_ID
  AGENT_SECRET
  REDIS_PASSWORD
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is required"
    exit 1
  fi
done

RELEASE_NAME="${RELEASE_NAME:-argocd}"
CHART_NAME="${CHART_NAME:-gitops-agent/gitops-helm}"
CHART_VERSION="${CHART_VERSION:-1.2.8}"

WORKDIR="$(mktemp -d)"

cleanup() {
  rm -rf "${WORKDIR}"
}

trap cleanup EXIT

DEFAULT_VALUES="${REPO_ROOT}/eks_new/apps/gitops-bootstrap/values.yaml"

ENV_VALUES="${REPO_ROOT}/eks_new/environments/${ENVIRONMENT}/gitops-bootstrap.yaml"

CLUSTER_VALUES="${REPO_ROOT}/eks_new/clusters/${CLUSTER_NAME}/values/gitops-bootstrap.yaml"

echo "=========================================="
echo "Harness GitOps Agent Deployment"
echo "=========================================="
echo "Cluster       : ${CLUSTER_NAME}"
echo "Environment   : ${ENVIRONMENT}"
echo "Agent         : ${GITOPS_AGENT_ID}"
echo "Namespace     : ${NAMESPACE}"
echo "Account       : ${HARNESS_ACCOUNT_ID}"
echo "Org           : ${HARNESS_ORG_ID}"
echo "Project       : ${HARNESS_PROJECT_ID}"
echo "Chart         : ${CHART_NAME}"
echo "Chart Version : ${CHART_VERSION}"
echo "=========================================="

if [[ ! -s "${DEFAULT_VALUES}" ]]; then
  echo "ERROR: Missing/empty default values:"
  echo "${DEFAULT_VALUES}"
  exit 1
fi

#
# Runtime identity.
#
cat > "${WORKDIR}/runtime-values.yaml" <<EOF
harness:
  identity:
    accountIdentifier: "${HARNESS_ACCOUNT_ID}"
    orgIdentifier: "${HARNESS_ORG_ID}"
    projectIdentifier: "${HARNESS_PROJECT_ID}"
    agentIdentifier: "${GITOPS_AGENT_ID}"

agent:
  harnessName: "${CLUSTER_NAME}"
EOF

#
# Secrets.
#
printf '%s' "${AGENT_SECRET}" \
  > "${WORKDIR}/agent-secret"

printf '%s' "${REDIS_PASSWORD}" \
  > "${WORKDIR}/redis-password"

chmod 600 \
  "${WORKDIR}/agent-secret" \
  "${WORKDIR}/redis-password"

#
# Critical validation.
#
if ! base64 --decode "${WORKDIR}/agent-secret" >/dev/null 2>&1; then
  echo "ERROR: GitOps Agent token is not valid Base64."
  exit 1
fi

#
# Helm precedence:
#
# defaults
#   ↓
# environment
#   ↓
# cluster
#   ↓
# runtime identity
#   ↓
# runtime secrets
#
HELM_VALUES_ARGS=(
  -f "${DEFAULT_VALUES}"
)

echo "Values layer 1: ${DEFAULT_VALUES}"

if [[ -f "${ENV_VALUES}" ]]; then
  HELM_VALUES_ARGS+=(
    -f "${ENV_VALUES}"
  )

  echo "Values layer 2: ${ENV_VALUES}"
else
  echo "Environment override not found. Skipping."
fi

if [[ -f "${CLUSTER_VALUES}" ]]; then
  HELM_VALUES_ARGS+=(
    -f "${CLUSTER_VALUES}"
  )

  echo "Values layer 3: ${CLUSTER_VALUES}"
else
  echo "Cluster override not found. Skipping."
fi

HELM_VALUES_ARGS+=(
  -f "${WORKDIR}/runtime-values.yaml"
)

echo "Values layer 4: runtime identity"
echo "Values layer 5: Harness secrets"

#
# Kubernetes connectivity.
#
echo
echo "Checking Kubernetes access..."

kubectl get nodes -o wide

#
# Helm repository.
#
helm repo add gitops-agent \
  https://harness.github.io/gitops-helm/ \
  --force-update

helm repo update gitops-agent

#
# Render first.
#
echo
echo "Rendering Helm manifest..."

helm template "${RELEASE_NAME}" \
  "${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  "${HELM_VALUES_ARGS[@]}" \
  --set-file harness.secrets.agentSecret="${WORKDIR}/agent-secret" \
  --set-file harness.secrets.redisPassword="${WORKDIR}/redis-password" \
  --set argo-cd.crds.install=false \
  > "${WORKDIR}/rendered.yaml"

#
# Validate critical config.
#
if ! grep -q \
  'AGENT_HTTP_TARGET.*https://app.harness.io' \
  "${WORKDIR}/rendered.yaml"; then

  echo "ERROR: AGENT_HTTP_TARGET did not render correctly."

  grep -A3 -B3 \
    'AGENT_HTTP_TARGET' \
    "${WORKDIR}/rendered.yaml" || true

  exit 1
fi

if ! grep -q \
  'GITOPS_AGENT_APPSET_RECONCILE_ENABLE: "true"' \
  "${WORKDIR}/rendered.yaml"; then

  echo "WARNING: ApplicationSet reconcile is not enabled."
fi

echo "Helm render validation passed."

#
# Install/upgrade.
#
echo
echo "Installing/upgrading GitOps Agent..."

helm upgrade --install "${RELEASE_NAME}" \
  "${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  "${HELM_VALUES_ARGS[@]}" \
  --set-file harness.secrets.agentSecret="${WORKDIR}/agent-secret" \
  --set-file harness.secrets.redisPassword="${WORKDIR}/redis-password" \
  --set argo-cd.crds.install=false \
  --wait \
  --timeout 15m

echo
echo "Waiting for GitOps Agent deployment..."

kubectl rollout status \
  deployment/gitops-agent \
  -n "${NAMESPACE}" \
  --timeout=5m

echo
echo "=========================================="
echo "GitOps Agent configuration"
echo "=========================================="

kubectl get configmap gitops-agent \
  -n "${NAMESPACE}" \
  -o jsonpath='Account={.data.GITOPS_ACCOUNT_IDENTIFIER}{"\n"}Org={.data.GITOPS_ORG_IDENTIFIER}{"\n"}Project={.data.GITOPS_PROJECT_IDENTIFIER}{"\n"}Agent={.data.GITOPS_AGENT_IDENTIFIER}{"\n"}HTTP_Target={.data.AGENT_HTTP_TARGET}{"\n"}AppSet_Reconcile={.data.GITOPS_AGENT_APPSET_RECONCILE_ENABLE}{"\n"}'

echo
echo "Agent image:"

kubectl get deployment gitops-agent \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

echo
echo "Checking deployed token format..."

if kubectl get secret gitops-agent \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.GITOPS_AGENT_TOKEN}' \
    | base64 --decode \
    | base64 --decode >/dev/null 2>&1; then

  echo "GitOps Agent token format: OK"
else

  echo "ERROR: Deployed GitOps Agent token format is invalid."
  exit 1
fi

echo
echo "Pods:"

kubectl get pods \
  -n "${NAMESPACE}" \
  -o wide

echo
echo "Recent GitOps Agent logs:"

kubectl logs \
  -n "${NAMESPACE}" \
  deployment/gitops-agent \
  --tail=30 || true

echo
echo "=========================================="
echo "GitOps Agent deployment successful"
echo "=========================================="