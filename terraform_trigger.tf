resource "terraform_data" "deploy_gitops_agent" {

  for_each = local.eks_config

  triggers_replace = [
    harness_platform_gitops_agent.gitops_agent[each.key].identifier
  ]

  depends_on = [
    harness_platform_gitops_agent.gitops_agent
  ]

  provisioner "local-exec" {

    interpreter = ["/bin/bash", "-c"]

    environment = {
      HARNESS_API_KEY = var.harness_api_key
    }

    command = <<EOF
set -euo pipefail
set +x

WORK_DIR="$(mktemp -d)"
PAYLOAD_FILE="$WORK_DIR/payload.yaml"
RESPONSE_FILE="$WORK_DIR/response.json"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

cat > "$PAYLOAD_FILE" <<YAML
pipeline:
  identifier: sys_gitops_bootstrap
  variables:
    - name: gitops_agent_identifier
      type: String
      value: ${harness_platform_gitops_agent.gitops_agent[each.key].identifier}
YAML

echo "Triggering Harness pipeline..."
echo "GitOps Agent: ${harness_platform_gitops_agent.gitops_agent[each.key].identifier}"

HTTP_STATUS="$(
  curl \
    --silent \
    --show-error \
    --location \
    --output "$RESPONSE_FILE" \
    --write-out '%{http_code}' \
    --request POST \
    "https://app.harness.io/pipeline/api/pipeline/execute/sys_gitops_bootstrap?accountIdentifier=${each.value.harness_api_details.harness_account_id}&orgIdentifier=${each.value.harness_api_details.harness_org_id}&projectIdentifier=${each.value.harness_api_details.harness_project_id}&branch=eks_bootstrap" \
    --header "x-api-key: $HARNESS_API_KEY" \
    --header "Content-Type: application/yaml" \
    --data-binary @"$PAYLOAD_FILE"
)"

if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  echo "ERROR: Failed to trigger Harness pipeline."
  echo "HTTP status: $HTTP_STATUS"

  if command -v jq >/dev/null 2>&1; then
    jq -r '.message // .status // .' "$RESPONSE_FILE" 2>/dev/null || true
  else
    cat "$RESPONSE_FILE"
  fi

  exit 1
fi

echo "Harness pipeline triggered successfully."

if command -v jq >/dev/null 2>&1; then
  EXECUTION_ID="$(
    jq -r '
      .data.planExecutionId //
      .data.executionId //
      .executionId //
      empty
    ' "$RESPONSE_FILE"
  )"

  if [ -n "$EXECUTION_ID" ]; then
    echo "Execution ID: $EXECUTION_ID"
  fi
fi
EOF
  }
}
