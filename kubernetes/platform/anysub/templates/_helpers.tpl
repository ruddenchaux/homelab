{{/*
Common labels applied to all anysub objects.
*/}}
{{- define "anysub.labels" -}}
app.kubernetes.io/part-of: anysub
app.kubernetes.io/managed-by: Helm
{{- end }}

{{/*
Selector labels for a given component name (called with a string).
Kept minimal so selector.matchLabels stays stable across chart upgrades.
*/}}
{{- define "anysub.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
{{- end }}
