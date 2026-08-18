{{- define "cluster-appset.name" -}}
{{- required "values.clusterName is required" .Values.clusterName | lower | replace "_" "-" | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "cluster-appset.fullname" -}}
{{- printf "%s-appset" (include "cluster-appset.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Global sync wave mapping for all clusters
Usage:
{{ include "cluster-appset.syncwave" "vault-secrets-operator" }}
*/}}
{{- define "cluster-appset.syncwave" -}}
{{- if eq . "namespaces" -}}
0
{{- else if eq . "vault-secrets-operator" -}}
10
{{- else if eq . "platform-secrets" -}}
20
{{- else if eq . "aws-load-balancer-controller" -}}
30
{{- else if eq . "nginx-ingress" -}}
40
{{- else if eq . "nginx-targetgroupbinding" -}}
50
{{- else if eq . "cluster-autoscaler" -}}
60
{{- else if eq . "storageclass" -}}
70
{{- else if eq . "hello-world" -}}
100
{{- else -}}
999
{{- end -}}
{{- end -}}
