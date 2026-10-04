{{/* the namespace of the shard: the namespace of the release, which must be named <prefix>-<shard> (see validate.yaml) */}}
{{- define "cinim-shard.ns" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{/* the name the namespace of the release must have */}}
{{- define "cinim-shard.expectedNs" -}}
{{- printf "%s-%s" .Values.namespacePrefix .Values.shard -}}
{{- end -}}

{{/* where the core finds rqlite and the log circuit: the subcharts' services unless a value says otherwise */}}
{{- define "cinim-shard.rqliteUrl" -}}
{{- default "http://rqlite" .Values.rqliteUrl -}}
{{- end -}}

{{- define "cinim-shard.victoriaLogsUrls" -}}
{{- if .Values.logs.victoriaLogsUrls -}}
{{- join "," .Values.logs.victoriaLogsUrls -}}
{{- else -}}
http://victorialogs-0:9428,http://victorialogs-1:9428
{{- end -}}
{{- end -}}

{{- define "cinim-shard.vlagentUrl" -}}
{{- default "http://vlagent:9429/insert/jsonline" .Values.logs.vlagentUrl -}}
{{- end -}}

{{/* the base path without the trailing slash: "" for "/" */}}
{{- define "cinim-shard.base" -}}
{{- trimSuffix "/" .Values.basePath -}}
{{- end -}}

{{/* the name of the ClusterRole of the job controllers; one per shard, so that two shards of a cluster do not share it */}}
{{- define "cinim-shard.stepRunner" -}}
{{- printf "%s-step-runner" (include "cinim-shard.ns" .) -}}
{{- end -}}

{{/* the user name of the core's ServiceAccount, as the API server sees it */}}
{{- define "cinim-shard.coreUser" -}}
{{- printf "system:serviceaccount:%s:cinim-core" (include "cinim-shard.ns" .) -}}
{{- end -}}

{{- define "cinim-shard.publicUrl" -}}
{{- default (printf "https://%s%s" .Values.domain (include "cinim-shard.base" .)) .Values.publicUrl -}}
{{- end -}}

{{- define "cinim-shard.image" -}}
{{- printf "%s:%s" (required "image.repository is required" .Values.image.repository) .Values.image.tag -}}
{{- end -}}

{{/* the image of the job controllers: `controller.image`, by default the controller image next to the shard image (<repository>-controller:<tag>) */}}
{{- define "cinim-shard.controllerImage" -}}
{{- default (printf "%s-controller:%s" (required "image.repository is required" .Values.image.repository) .Values.image.tag) .Values.controller.image -}}
{{- end -}}

{{- define "cinim-shard.labels" -}}
app.kubernetes.io/part-of: cinim
cinim.io/shard: {{ .Values.shard | quote }}
{{- end -}}

{{/* the objects of the monitoring operator in use: Prometheus (ServiceMonitor, PodMonitor) or VictoriaMetrics (VMServiceScrape, VMPodScrape) */}}
{{- define "cinim-shard.monitorApi" -}}
{{- if eq .Values.metrics.monitor.operator "victoriametrics" -}}operator.victoriametrics.com/v1beta1{{- else -}}monitoring.coreos.com/v1{{- end -}}
{{- end -}}
{{- define "cinim-shard.serviceMonitorKind" -}}
{{- if eq .Values.metrics.monitor.operator "victoriametrics" -}}VMServiceScrape{{- else -}}ServiceMonitor{{- end -}}
{{- end -}}
{{- define "cinim-shard.podMonitorKind" -}}
{{- if eq .Values.metrics.monitor.operator "victoriametrics" -}}VMPodScrape{{- else -}}PodMonitor{{- end -}}
{{- end -}}
