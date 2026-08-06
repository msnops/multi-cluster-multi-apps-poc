{{- define "nginx-demo.name" -}}
nginx-demo
{{- end }}

{{- define "nginx-demo.fullname" -}}
{{ include "nginx-demo.name" . }}
{{- end }}