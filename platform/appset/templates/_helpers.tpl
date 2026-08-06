{{- define "cluster-appset.name" -}}
{{- required "values.clusterName is required" .Values.clusterName | lower | replace "_" "-" | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "cluster-appset.fullname" -}}
{{- printf "%s-appset" (include "cluster-appset.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
