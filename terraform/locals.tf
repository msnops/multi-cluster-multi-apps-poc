locals {
  clusters = {
    dev-cluster01 = {
      org_id      = "default"
      project_id  = "default_project"
      environment = "dev"

      cluster_name      = "dev-cluster01"
      gitops_agent_id   = "devcluster01"
      gitops_agent_name = "dev-cluster01"

      delegate_selector = "dev-cluster01"
      namespace         = "argocd"

      pipeline_id   = "bootstrap_gitops_agent"
      pipeline_name = "Bootstrap GitOps Agent"
    }

    sit-cluster01 = {
      org_id      = "default"
      project_id  = "nonprod"
      environment = "sit"

      cluster_name      = "sit-cluster01"
      gitops_agent_id   = "sitcluster01"
      gitops_agent_name = "sit-cluster01"

      delegate_selector = "sit-cluster01"
      namespace         = "argocd"

      pipeline_id   = "bootstrap_gitops_agent"
      pipeline_name = "Bootstrap GitOps Agent"
    }
  }

  #
  # One project entry, regardless of how many clusters are in it.
  #
  harness_projects = {
    for project_id in distinct([
      for cluster in values(local.clusters) :
      cluster.project_id
    ]) :

    project_id => {
      org_id = one([
        for cluster in values(local.clusters) :
        cluster.org_id
        if cluster.project_id == project_id
      ])

      project_id = project_id
    }
  }

  #
  # Only non-secret cluster identity goes from Terraform to Harness.
  #
  pipeline_input_yaml = {
    for key, cluster in local.clusters :

    key => yamlencode({
      pipeline = {
        identifier = cluster.pipeline_id

        variables = [
          {
            name  = "clusterName"
            type  = "String"
            value = cluster.cluster_name
          },
          {
            name  = "environment"
            type  = "String"
            value = cluster.environment
          },
          {
            name  = "gitopsAgentId"
            type  = "String"
            value = cluster.gitops_agent_id
          },
          {
            name  = "delegateSelector"
            type  = "String"
            value = cluster.delegate_selector
          },
          {
            name  = "namespace"
            type  = "String"
            value = cluster.namespace
          }
        ]
      }
    })
  }
}
