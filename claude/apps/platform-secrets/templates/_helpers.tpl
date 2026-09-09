{{- define "platform-secrets.labels" -}}
app.kubernetes.io/name: platform-secrets
app.kubernetes.io/part-of: eks-platform
app.kubernetes.io/managed-by: argocd
{{- end -}}

{{- define "platform-secrets.secretType" -}}
{{- .Values.defaults.secretType | default "kv-v2" -}}
{{- end -}}

{{- define "platform-secrets.refreshAfter" -}}
{{- .Values.defaults.refreshAfter | default "30s" -}}
{{- end -}}
