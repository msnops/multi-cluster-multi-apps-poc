{{- define "vso-infra.labels" -}}
app.kubernetes.io/name: vault-secrets-operator
app.kubernetes.io/part-of: eks-platform
app.kubernetes.io/managed-by: argocd
{{- end -}}

{{- define "vso-infra.vaultConnectionName" -}}
{{- .Values.vsoInfrastructure.vaultConnectionName | default "default" -}}
{{- end -}}

{{- define "vso-infra.serviceAccountName" -}}
{{- .Values.vsoInfrastructure.serviceAccountName | default "vault-auth" -}}
{{- end -}}

{{- define "vso-infra.authMount" -}}
{{- .Values.vsoInfrastructure.authMount | default "jwt" -}}
{{- end -}}
