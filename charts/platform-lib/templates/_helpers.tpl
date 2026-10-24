{{/*
Naming and labels.

Component templates receive a context dict instead of the chart root:
  root       the chart's top-level context ($)
  component  "" for the main workload, or a suffix such as "worker"
  values     the effective values for that component
For the main workload pass .Values; for a sub-component pass
(include "platform-lib.componentValues" ... | fromYaml).
*/}}

{{- define "platform-lib.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform-lib.fullname" -}}
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

{{/*
Effective values for a sub-component. Image, pod-level settings, env and
network policy are inherited from the chart values; the component's own block
must define everything workload-specific (replicas, resources, probes,
autoscaling, pdb, command). Inherited keys are merged with mergeOverwrite, so
they can be changed but not reset to false/empty by the component.
*/}}
{{- define "platform-lib.componentValues" -}}
{{- $root := .root -}}
{{- $base := pick (deepCopy $root.Values) "image" "imagePullSecrets" "podSecurityContext" "securityContext" "env" "extraEnv" "nodeSelector" "tolerations" "affinity" "priorityClassName" "terminationGracePeriodSeconds" "tmpSizeLimit" "preStopSleepSeconds" "podAnnotations" "topologySpread" "networkPolicy" "serviceMonitor" -}}
{{- $override := index $root.Values .component | default dict -}}
{{- toYaml (mergeOverwrite $base (deepCopy $override)) -}}
{{- end -}}

{{- define "platform-lib.componentName" -}}
{{- $full := include "platform-lib.fullname" .root -}}
{{- if .component -}}
{{- printf "%s-%s" $full .component | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $full -}}
{{- end -}}
{{- end -}}

{{- define "platform-lib.global" -}}
{{- toYaml (.root.Values.global | default dict) -}}
{{- end -}}

{{- define "platform-lib.partOf" -}}
{{- $g := include "platform-lib.global" . | fromYaml -}}
{{- $g.partOf | default "commerce-platform" -}}
{{- end -}}

{{- define "platform-lib.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform-lib.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component | default "server" }}
{{- end -}}

{{- define "platform-lib.labels" -}}
{{- $g := include "platform-lib.global" . | fromYaml -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "platform-lib.selectorLabels" . }}
app.kubernetes.io/part-of: {{ include "platform-lib.partOf" . }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- if .values }}{{ with .values.image }}
app.kubernetes.io/version: {{ include "platform-lib.imageTag" (dict "root" $.root "values" $.values) | trunc 63 | trimSuffix "-" | quote }}
{{- end }}{{ end }}
{{- with $g.environment }}
platform.akibullah.dev/environment: {{ . }}
{{- end }}
{{- with $g.team }}
platform.akibullah.dev/team: {{ . }}
{{- end }}
{{- end -}}

{{/*
Image reference. The tag defaults to the chart's appVersion; "latest" and empty
tags fail at render time (the conftest policy enforces the same rule on any
manifest that reaches the cluster by another route).
*/}}
{{- define "platform-lib.imageTag" -}}
{{- $tag := .values.image.tag | default .root.Chart.AppVersion | toString -}}
{{- if or (eq $tag "") (eq $tag "latest") -}}
{{- fail (printf "image.tag for %s must be pinned (got %q)" .root.Chart.Name $tag) -}}
{{- end -}}
{{- $tag -}}
{{- end -}}

{{- define "platform-lib.image" -}}
{{- $img := .values.image -}}
{{- $ref := printf "%s:%s" $img.repository (include "platform-lib.imageTag" .) -}}
{{- if $img.digest -}}
{{- $ref = printf "%s@%s" $ref $img.digest -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{- define "platform-lib.serviceAccountName" -}}
{{- $sa := .root.Values.serviceAccount | default dict -}}
{{- if $sa.create -}}
{{- default (include "platform-lib.fullname" .root) $sa.name -}}
{{- else -}}
{{- default "default" $sa.name -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret holding application secrets, or "" when there is none. */}}
{{- define "platform-lib.appSecretName" -}}
{{- if .root.Values.existingSecret -}}
{{- .root.Values.existingSecret -}}
{{- else if .root.Values.secrets -}}
{{- include "platform-lib.fullname" .root -}}
{{- end -}}
{{- end -}}
