{{/* the base path without the trailing slash: "" for "/" */}}
{{- define "cinim-router.base" -}}
{{- trimSuffix "/" .Values.basePath -}}
{{- end -}}
