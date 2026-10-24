{{/*
platform-lib.deployment: a Deployment with secure defaults.
- non-root, read-only root filesystem, no privilege escalation, all capabilities dropped, RuntimeDefault seccomp
- writable /tmp as a size-limited emptyDir
- config checksum annotation so ConfigMap changes roll the pods
- preStop sleep so endpoints are removed before the process gets SIGTERM
*/}}
{{- define "platform-lib.deployment" -}}
{{- $v := .values -}}
{{- $name := include "platform-lib.componentName" . -}}
{{- $secret := include "platform-lib.appSecretName" . -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
  {{- with $v.workloadAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if not $v.autoscaling.enabled }}
  replicas: {{ $v.replicaCount }}
  {{- end }}
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 0
  selector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "platform-lib.labels" . | nindent 8 }}
      annotations:
        checksum/config: {{ include "platform-lib.configmap" . | sha256sum }}
        {{- with $v.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "platform-lib.serviceAccountName" . }}
      automountServiceAccountToken: false
      {{- with $v.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      securityContext:
        {{- toYaml $v.podSecurityContext | nindent 8 }}
      {{- if $v.topologySpread.enabled }}
      topologySpreadConstraints:
        {{- range $v.topologySpread.topologyKeys }}
        - maxSkew: 1
          topologyKey: {{ . }}
          whenUnsatisfiable: {{ $v.topologySpread.whenUnsatisfiable }}
          labelSelector:
            matchLabels:
              {{- include "platform-lib.selectorLabels" $ | nindent 14 }}
        {{- end }}
      {{- end }}
      {{- with $v.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: {{ $v.terminationGracePeriodSeconds }}
      containers:
        - name: {{ .component | default "app" }}
          image: {{ include "platform-lib.image" . | quote }}
          imagePullPolicy: {{ $v.image.pullPolicy }}
          {{- with $v.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if $v.containerPort }}
          ports:
            - name: http
              containerPort: {{ $v.containerPort }}
              protocol: TCP
          {{- end }}
          envFrom:
            - configMapRef:
                name: {{ $name }}
            {{- if $secret }}
            - secretRef:
                name: {{ $secret }}
            {{- end }}
          {{- $env := include "platform-lib.datastoreEnv" . | trim }}
          {{- if or $env $v.extraEnv }}
          env:
            {{- with $env }}
            {{- . | nindent 12 }}
            {{- end }}
            {{- with $v.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- end }}
          resources:
            {{- toYaml $v.resources | nindent 12 }}
          securityContext:
            {{- toYaml $v.securityContext | nindent 12 }}
          {{- with $v.probes.startup }}
          startupProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.probes.liveness }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.probes.readiness }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if $v.preStopSleepSeconds }}
          lifecycle:
            preStop:
              sleep:
                seconds: {{ $v.preStopSleepSeconds }}
          {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            {{- with $v.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: {{ $v.tmpSizeLimit | default "64Mi" }}
        {{- with $v.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
{{- end -}}

{{/* Non-secret environment for a component, rendered as a ConfigMap. */}}
{{- define "platform-lib.configmap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "platform-lib.componentName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
data:
  {{- range $k, $val := .values.env }}
  {{ $k }}: {{ $val | toString | quote }}
  {{- end }}
{{- end -}}

{{/*
Application secrets created by the chart. Intended for local and dev
clusters only; staging and prod set existingSecret and source it from
External Secrets or Sealed Secrets (see docs/secrets.md).
*/}}
{{- define "platform-lib.secret" -}}
{{- if and .root.Values.secrets (not .root.Values.existingSecret) -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "platform-lib.fullname" .root }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
    platform.akibullah.dev/demo-only: "true"
type: Opaque
stringData:
  {{- range $k, $val := .root.Values.secrets }}
  {{ $k }}: {{ $val | toString | quote }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/* Connection settings for external datastores. */}}
{{- define "platform-lib.datastoreEnv" -}}
{{- $root := .root -}}
{{- $db := $root.Values.database | default dict -}}
{{- if and $db.envVar $db.existingSecret }}
- name: {{ $db.envVar }}
  valueFrom:
    secretKeyRef:
      name: {{ $db.existingSecret }}
      key: {{ $db.existingSecretKey | default "url" }}
{{- end }}
{{- $cache := $root.Values.cache | default dict -}}
{{- if and $cache.envVar $cache.url }}
- name: {{ $cache.envVar }}
  value: {{ $cache.url | quote }}
{{- end }}
{{- end -}}

{{- define "platform-lib.serviceaccount" -}}
{{- $sa := .root.Values.serviceAccount | default dict -}}
{{- if $sa.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "platform-lib.serviceAccountName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
  {{- with $sa.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end -}}
{{- end -}}
