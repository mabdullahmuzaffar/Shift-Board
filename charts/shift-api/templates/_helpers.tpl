{{/*
Standard name/label helpers. Kept verbose rather than clever so a reader can
see exactly what lands on each object.
*/}}

{{- define "shift-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "shift-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "shift-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "shift-api.labels" -}}
helm.sh/chart: {{ include "shift-api.chart" . }}
{{ include "shift-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: shiftboard
{{- end -}}

{{- define "shift-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "shift-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "shift-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "shift-api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the image reference. A digest wins over a tag, because a digest is
the only truly immutable reference -- a tag can be moved.
*/}}
{{- define "shift-api.image" -}}
{{- $repo := required "image.repository must be set (e.g. myacr.azurecr.io/shiftboard/shift-api)" .Values.image.repository -}}
{{- if .Values.imageDigest -}}
{{- printf "%s@%s" $repo .Values.imageDigest -}}
{{- else -}}
{{- $tag := required "either image.tag or imageDigest must be set; 'latest' is not acceptable" .Values.image.tag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}
