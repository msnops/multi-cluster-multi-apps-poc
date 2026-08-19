variable "harness_endpoint" {
  description = "Harness API gateway endpoint."
  type        = string
  default     = "https://app.harness.io/gateway"
}

variable "harness_account_id" {
  description = "Harness account identifier, not the display name."
  type        = string
}

variable "harness_api_key" {
  description = "Harness NextGen platform API key. Prefer TF_VAR_harness_platform_api_key."
  type        = string
  sensitive   = true
}

variable "github_app_id" {
  description = "GitHub App application ID."
  type        = string
}

variable "github_app_installation_id" {
  description = "GitHub App installation ID."
  type        = string
}

variable "github_app_private_key_ref" {
  description = "Harness secret identifier containing the GitHub App PKCS8 private key."
  type        = string
  default     = "github_app_private_key_new"
}

variable "gitops_repo_name" {
  description = "Git repository containing GitOps configuration and bootstrap pipelines."
  type        = string
  default     = "multi-cluster-multi-apps-poc"
}
