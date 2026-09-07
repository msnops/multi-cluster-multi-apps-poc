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

    command = <<EOF

cat > payload.yaml <<YAML
pipeline:
  variables:
    - name: gitops_agent_identifier
      type: String
      value: ${harness_platform_gitops_agent.gitops_agent[each.key].identifier}
YAML

echo "==== payload ===="
cat payload.json

curl -sS -X POST \
  "https://app.harness.io/pipeline/api/pipeline/execute/sys_gitops_bootstrap?accountIdentifier=${each.value.harness_api_details.harness_account_id}&orgIdentifier=${each.value.harness_api_details.harness_org_id}&projectIdentifier=${each.value.harness_api_details.harness_project_id}&branch=eks_bootstrap" \
  -H "x-api-key: ${var.harness_api_key}" \
  -H "Content-Type: application/yaml" \
  --data-binary @payload.yaml

EOF
  }
}
