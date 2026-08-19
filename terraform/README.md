# Harness first-class ApplicationSet with Terraform

This Terraform configuration creates a `harness_platform_gitops_applicationset` first-class Harness entity for every entry in `var.clusters`.

It implements:

- one ApplicationSet per cluster;
- a Matrix generator combining one cluster file with that cluster's selected app files;
- Helm value precedence: chart `values.yaml`, environment values, then cluster/application values;
- multiple Argo CD sources using `$values`;
- optional Harness `serviceRef` and `envRef` labels;
- optional GitOps repository registration.

## Requirements

- Harness feature flag `GITOPS_APPLICATIONSET_FIRST_CLASS_SUPPORT` enabled;
- Terraform 1.11 or later;
- Harness provider 0.44.5 or compatible 0.44.x;
- GitOps Agent and mapped Argo project already present;
- repository already connected, or `manage_repository = true`.

## Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

Set the real Harness account identifier and API key. Do not commit `terraform.tfvars`.

A safer alternative for secrets:

```bash
export TF_VAR_harness_account_id='YOUR_ACCOUNT_ID'
export TF_VAR_harness_platform_api_key='YOUR_PLATFORM_API_KEY'
```

For a public repository:

```hcl
manage_repository    = true
repo_connection_type = "HTTPS_ANONYMOUS"
```

For a private GitHub repository:

```bash
export TF_VAR_repo_password='YOUR_GITHUB_PAT'
```

```hcl
manage_repository    = true
repo_connection_type = "HTTPS"
repo_username        = "YOUR_GITHUB_USERNAME"
```

## Apply

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out appset.tfplan
terraform apply appset.tfplan
```

The ApplicationSet should then be listed in Harness under **GitOps > Applications > Application Set**.

## Important migration from the existing root Application

Do not leave both the root Argo CD Application and Terraform managing the same `ApplicationSet` object.

For a no-delete migration:

1. Add this annotation to the currently root-managed ApplicationSet and sync it once:

   ```yaml
   metadata:
     annotations:
       argocd.argoproj.io/sync-options: Prune=false
   ```

2. Remove the ApplicationSet template from the root Application's source, or delete the root Application non-cascading.
3. Confirm `kubectl -n argocd get applicationset dev-cluster01-appset` still exists.
4. Run Terraform with `upsert = true` as provided.
5. Confirm the ApplicationSet appears in the Harness Application Set tab.

For a lower-risk test, first set `appset_name = "dev-cluster01-firstclass-appset"`. Do not let two ApplicationSets generate Applications with the same names for long.

## Import an ApplicationSet already registered as first-class

```bash
terraform import \
  'module.cluster_appset["dev-cluster01"].harness_platform_gitops_applicationset.this' \
  'default/default_project/cluster1/dev-cluster01-appset'
```

Then run `terraform plan`. Import succeeds only when the ApplicationSet is visible through the Harness first-class ApplicationSet API.

## Add another cluster

Add the Git files:

```text
clusters/sit-cluster01/cluster.yaml
clusters/sit-cluster01/apps/*.yaml
clusters/sit-cluster01/values/*.yaml
```

Then add one map entry:

```hcl
clusters = {
  "dev-cluster01" = {
    argo_project_id = "1d7264c7"
  }

  "sit-cluster01" = {
    argo_project_id = "MAPPED_ARGO_PROJECT_ID"
  }
}
```

Defaults automatically resolve:

```text
clusters/<cluster>/cluster.yaml
clusters/<cluster>/apps/*.yaml
<cluster>-appset
```

## Optional Service and Environment integration

Set:

```hcl
enable_service_env_labels = true
```

Then each app assignment must contain:

```yaml
app:
  serviceRef: hello_world
```

and the cluster file must contain:

```yaml
cluster:
  environmentRef: dev
```

Harness identifiers cannot contain hyphens, so use values such as `hello_world`, not `hello-world`.
