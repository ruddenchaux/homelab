{{/*
Common labels
*/}}
{{- define "media.labels" -}}
app.kubernetes.io/part-of: media-stack
app.kubernetes.io/managed-by: Helm
{{- end }}

{{/*
Selector labels for a given component
*/}}
{{- define "media.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/part-of: media-stack
{{- end }}

{{/*
LinuxServer.io environment variables
*/}}
{{- define "media.linuxserverEnv" -}}
- name: PUID
  value: {{ $.Values.linuxserver.puid | quote }}
- name: PGID
  value: {{ $.Values.linuxserver.pgid | quote }}
- name: TZ
  value: {{ $.Values.linuxserver.tz | quote }}
{{- end }}

{{/*
Media library volume mount (shared across all pods)
*/}}
{{- define "media.mediaVolumeMount" -}}
- name: media-library
  mountPath: /data/media
{{- end }}

{{/*
Media library volume definition
*/}}
{{- define "media.mediaVolume" -}}
- name: media-library
  persistentVolumeClaim:
    claimName: media-library
{{- end }}
