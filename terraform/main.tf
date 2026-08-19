resource "harness_platform_gitops_agent" "this" {
  for_each = local.clusters

  org_id     = each.value.org_id
  project_id = each.value.project_id

  identifier = each.value.gitops_agent_id
  name       = each.value.gitops_agent_name

  type     = "MANAGED_ARGO_PROVIDER"
  operator = "ARGO"

  metadata {
    namespace         = each.value.namespace
    high_availability = false
  }
}

#
# One GitHub connector per Harness project
#
resource "harness_platform_connector_github" "pipeline_repo" {
  for_each = local.harness_projects

  identifier  = "github_pipeline_repo"
  name        = "GitHub Pipeline Repository"
  description = "GitHub connector for Git-backed Harness pipelines"

  org_id     = each.value.org_id
  project_id = each.value.project_id

  url             = "https://github.com/msnops"
  connection_type = "Account"
  validation_repo = "multi-cluster-multi-apps-poc"

  credentials {
    http {
      github_app {
        installation_id = var.github_app_installation_id
        application_id  = var.github_app_id
        private_key_ref = var.github_app_private_key_ref
      }
    }
  }

  api_authentication {
    github_app {
      installation_id = var.github_app_installation_id
      application_id  = var.github_app_id
      private_key_ref = var.github_app_private_key_ref
    }
  }
}

#
# One bootstrap pipeline per Harness project.
#
resource "harness_platform_pipeline" "bootstrap_gitops_agent" {
  for_each = local.harness_projects

  identifier = "bootstrap_gitops_agent"
  name       = "Bootstrap GitOps Agent"

  org_id     = each.value.org_id
  project_id = each.value.project_id

  import_from_git = true

  git_import_info {
    branch_name = "main"

    file_path = "eks_new/apps/gitops-bootstrap/pipelines/${each.value.project_id}/bootstrap_gitops_agent.yaml"

    connector_ref = harness_platform_connector_github.pipeline_repo[
      each.key
    ].identifier

    repo_name = var.gitops_repo_name

    is_force_import = true
  }

  pipeline_import_request {
    pipeline_name        = "Bootstrap GitOps Agent"
    pipeline_description = "Bootstrap and deploy Harness GitOps Agent into the target Kubernetes cluster"
  }

  depends_on = [
    harness_platform_connector_github.pipeline_repo
  ]
}

#
# Trigger once per cluster.
#
resource "terraform_data" "trigger_gitops_bootstrap" {
  for_each = local.clusters

  triggers_replace = {
    cluster_name = each.value.cluster_name
    environment  = each.value.environment

    agent_id = harness_platform_gitops_agent.this[
      each.key
    ].identifier

    pipeline_id = harness_platform_pipeline.bootstrap_gitops_agent[
      each.value.project_id
    ].identifier

    delegate_selector = each.value.delegate_selector

    input_hash = sha256(
      local.pipeline_input_yaml[each.key]
    )
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      HARNESS_API_KEY = var.harness_api_key

      INPUT_YAML_B64 = base64encode(
        local.pipeline_input_yaml[each.key]
      )
    }

    command = <<-EOT
      set -euo pipefail

      INPUT_FILE="$(mktemp)"
      RESPONSE_FILE="$(mktemp)"

      cleanup() {
        rm -f "$INPUT_FILE" "$RESPONSE_FILE"
      }

      trap cleanup EXIT

      echo "$INPUT_YAML_B64" \
        | base64 --decode \
        > "$INPUT_FILE"

      echo "=========================================="
      echo "Triggering Harness GitOps bootstrap"
      echo "=========================================="
      echo "Cluster     : ${each.value.cluster_name}"
      echo "Environment : ${each.value.environment}"
      echo "Agent       : ${each.value.gitops_agent_id}"
      echo "Org         : ${each.value.org_id}"
      echo "Project     : ${each.value.project_id}"
      echo "Pipeline    : ${each.value.pipeline_id}"
      echo "Delegate    : ${each.value.delegate_selector}"
      echo "=========================================="

      HTTP_CODE=$(
        curl \
          --silent \
          --show-error \
          --output "$RESPONSE_FILE" \
          --write-out "%%{http_code}" \
          --request POST \
          --header "x-api-key: $HARNESS_API_KEY" \
          --header "Content-Type: application/yaml" \
          --data-binary @"$INPUT_FILE" \
          "${var.harness_endpoint}/pipeline/api/pipeline/execute/${each.value.pipeline_id}?accountIdentifier=${var.harness_account_id}&orgIdentifier=${each.value.org_id}&projectIdentifier=${each.value.project_id}"
      )

      echo
      echo "HTTP status: $HTTP_CODE"
      echo "Harness response:"
      cat "$RESPONSE_FILE"
      echo

      if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
        echo "ERROR: Failed to trigger Harness pipeline."
        exit 1
      fi

      echo "Pipeline triggered successfully."
    EOT
  }

  depends_on = [
    harness_platform_gitops_agent.this,
    harness_platform_pipeline.bootstrap_gitops_agent
  ]
}
