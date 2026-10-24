{{- define "platform-lib.hpa" -}}
{{- $v := .values -}}
{{- if $v.autoscaling.enabled -}}
{{- $a := $v.autoscaling -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "platform-lib.componentName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "platform-lib.componentName" . }}
  minReplicas: {{ $a.minReplicas }}
  maxReplicas: {{ $a.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ $a.targetCPUUtilizationPercentage }}
    {{- with $a.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60
{{- end -}}
{{- end -}}

{{- define "platform-lib.pdb" -}}
{{- $v := .values -}}
{{- if $v.pdb.enabled -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "platform-lib.componentName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
spec:
  {{- if $v.pdb.maxUnavailable }}
  maxUnavailable: {{ $v.pdb.maxUnavailable }}
  {{- else }}
  minAvailable: {{ $v.pdb.minAvailable | default 1 }}
  {{- end }}
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" . | nindent 6 }}
{{- end -}}
{{- end -}}

{{- define "platform-lib.servicemonitor" -}}
{{- $v := .values -}}
{{- if $v.serviceMonitor.enabled -}}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "platform-lib.componentName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
    {{- with $v.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      path: {{ $v.serviceMonitor.path }}
      interval: {{ $v.serviceMonitor.interval }}
      scrapeTimeout: {{ $v.serviceMonitor.scrapeTimeout }}
{{- end -}}
{{- end -}}

{{/* helm test: curl the service's health endpoint from inside the namespace. */}}
{{- define "platform-lib.test" -}}
{{- $v := .values -}}
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "platform-lib.componentName" . }}-test-health
  labels:
    {{- include "platform-lib.labels" (dict "root" .root "component" "test") | nindent 4 }}
  annotations:
    helm.sh/hook: test
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: {{ $v.tests.image | quote }}
      args:
        - --fail
        - --silent
        - --show-error
        - --retry
        - "10"
        - --retry-delay
        - "3"
        - --retry-all-errors
        - {{ printf "http://%s:%v%s" (include "platform-lib.componentName" .) $v.service.port $v.tests.path | quote }}
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
{{- end -}}
