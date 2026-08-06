# Harness GitOps: one agent and one root Application per cluster

## Flow

```text
Harness GitOps agent in each cluster
  -> root-<cluster> Application
     -> <cluster>-appset ApplicationSet
        -> one generated Application per clusters/<cluster>/apps/*.yaml
```

All root Applications, ApplicationSets, and generated Applications are standard Argo CD resources and are visible through the Harness GitOps agent.

## Repository layout

```text
applications/<app>/                 Helm charts and application values.yaml
environments/<env>/values.yaml     Layer 2 common environment defaults
clusters/<cluster>/cluster.yaml    Cluster metadata
clusters/<cluster>/apps/*.yaml     Applications selected for the cluster
clusters/<cluster>/values/*.yaml   Layer 3 cluster overrides
platform/appset/                   Reusable Helm chart that creates the ApplicationSet
roots/root-<cluster>.yaml          Root Application installed in each agent cluster
```

## Helm value precedence

The generated Application loads files in this order:

1. `applications/<app>/values.yaml`
2. `environments/<env>/values.yaml`
3. `clusters/<cluster>/values/<app-values-file>.yaml`

Helm applies the last file with the highest precedence.

## Initial setup

1. Install one Harness GitOps agent in every target cluster.
2. Ensure the agent namespace exists. This example uses `harness-gitops`.
3. Register this Git repository with every agent. Private repositories require credentials.
4. Replace the sample repository URL:

```bash
./scripts/set-repo-url.sh https://github.com/YOUR_ORG/YOUR_REPOSITORY.git
```

5. Commit and push the repository.
6. Apply only the matching root Application to each cluster:

```bash
kubectl apply -f roots/root-dev-cluster01.yaml
kubectl apply -f roots/root-sit-cluster01.yaml
kubectl apply -f roots/root-uat-cluster01.yaml
kubectl apply -f roots/root-prd-cluster01.yaml
```

Do not apply every root manifest to every cluster.

## Add a new application chart

Create:

```text
applications/payment-api/
  Chart.yaml
  values.yaml
  templates/
```

Select it for a cluster by adding:

```yaml
# clusters/dev-cluster01/apps/payment-api.yaml
app:
  name: payment-api
  chartPath: applications/payment-api
  namespace: payment-api
  releaseName: payment-api
  valuesFile: payment-api.yaml
```

Add the cluster override file:

```yaml
# clusters/dev-cluster01/values/payment-api.yaml
global:
  clusterName: dev-cluster01
replicaCount: 2
```

No ApplicationSet template change is required.

## Add a new cluster

1. Create `clusters/new-cluster/cluster.yaml`.
2. Add selected app files under `clusters/new-cluster/apps/`.
3. Add cluster override files under `clusters/new-cluster/values/`.
4. Copy a root manifest to `roots/root-new-cluster.yaml` and change the cluster name.
5. Install a Harness GitOps agent in that cluster and apply only its root manifest.

## Add a new environment

1. Add `environments/perf/values.yaml`.
2. Set `cluster.environment: perf` in the relevant cluster file.

No ApplicationSet template change is required.

## Validate

```bash
./scripts/validate.sh
```
