{{/*
platform-lib.app renders every object for a chart's main component. App charts call it from a single template:

  {{ include "platform-lib.app" . }}

Sub-components (for example a worker) are rendered with
platform-lib.component, which merges the component's values block over the
chart values.
*/}}
{{- define "platform-lib.app" -}}
{{- $ctx := dict "root" . "component" "" "values" .Values -}}
{{- $docs := list
  (include "platform-lib.serviceaccount" $ctx)
  (include "platform-lib.configmap" $ctx)
  (include "platform-lib.secret" $ctx)
  (include "platform-lib.deployment" $ctx)
  (include "platform-lib.service" $ctx)
  (include "platform-lib.ingress" $ctx)
  (include "platform-lib.hpa" $ctx)
  (include "platform-lib.pdb" $ctx)
  (include "platform-lib.servicemonitor" $ctx)
  (include "platform-lib.networkpolicy" $ctx)
-}}
{{- range $docs }}
{{- if trim . }}
---
{{ trim . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
platform-lib.component renders a sub-component without its own Service unless
it declares a containerPort. Usage:
  {{ include "platform-lib.component" (dict "root" . "component" "worker") }}
*/}}
{{- define "platform-lib.component" -}}
{{- $vals := include "platform-lib.componentValues" . | fromYaml -}}
{{- if $vals.enabled -}}
{{- $ctx := dict "root" .root "component" .component "values" $vals -}}
{{- $docs := list
  (include "platform-lib.configmap" $ctx)
  (include "platform-lib.deployment" $ctx)
  (include "platform-lib.hpa" $ctx)
  (include "platform-lib.pdb" $ctx)
  (include "platform-lib.networkpolicy" $ctx)
-}}
{{- if $vals.containerPort -}}
{{- $docs = append $docs (include "platform-lib.service" $ctx) -}}
{{- end -}}
{{- range $docs }}
{{- if trim . }}
---
{{ trim . }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
