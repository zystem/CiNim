{{- define "cinim-storage.image" -}}
{{- printf "%s:%s" (required "image.repository is required" .Values.image.repository) .Values.image.tag -}}
{{- end -}}

{{/* the Secret that holds the module's secrets */}}
{{- define "cinim-storage.secret" -}}
{{- default "cinim-storage" .Values.secrets.existingSecret -}}
{{- end -}}

{{/* <shard>=<secret>;<shard>=<secret>, in the order of the shards' names */}}
{{- define "cinim-storage.shards" -}}
{{- $parts := list -}}
{{- range $shard := (keys .Values.secrets.shards | sortAlpha) -}}
{{- $parts = append $parts (printf "%s=%s" $shard (index $.Values.secrets.shards $shard)) -}}
{{- end -}}
{{- join ";" $parts -}}
{{- end -}}

{{- define "cinim-storage.moduleUrl" -}}
http://cinim-storage:18090
{{- end -}}

{{- define "cinim-storage.labels" -}}
app.kubernetes.io/part-of: cinim-storage
{{- end -}}

{{/* the environment of every container that talks to the module's admin API */}}
{{- define "cinim-storage.adminEnv" -}}
- name: ADMIN_TOKEN
  valueFrom: {secretKeyRef: {name: {{ include "cinim-storage.secret" . }}, key: adminToken}}
- {name: MODULE_URL, value: {{ include "cinim-storage.moduleUrl" . | quote }}}
{{- end -}}

{{/* the shell function that registers a store: register <name> <json>; tries again until the module takes it */}}
{{- define "cinim-storage.registerFn" -}}
register() {
  n=0
  until wget -qO- --header="Authorization: Bearer $ADMIN_TOKEN" --header="Content-Type: application/json" --post-data="$2" "$MODULE_URL/v1/admin/stores/$1" >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -lt "${REGISTER_TRIES:-120}" ] || { echo "storage: the module did not take the store $1"; return 1; }
    sleep 5
  done
  echo "storage: store $1 registered"
}
{{- end -}}
