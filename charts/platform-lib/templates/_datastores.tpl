{{/*
In-chart PostgreSQL and Redis for local, CI and dev clusters. They follow the
same security rules as the services (non-root, read-only root filesystem,
dropped capabilities, resource limits, probes, NetworkPolicy). Staging and prod
point at managed instances through database.existingSecret / cache.url instead.
*/}}

{{- define "platform-lib.postgresql.secretName" -}}
{{- $pg := .Values.postgresql -}}
{{- $pg.auth.existingSecret | default (printf "%s-postgresql" (include "platform-lib.fullname" .)) -}}
{{- end -}}

{{- define "platform-lib.postgresql" -}}
{{- $root := . -}}
{{- $pg := .Values.postgresql -}}
{{- if $pg.enabled -}}
{{- $name := printf "%s-postgresql" (include "platform-lib.fullname" .) -}}
{{- $ctx := dict "root" . "component" "postgresql" -}}
{{- if not $pg.auth.existingSecret }}
{{- /* Reuse the password on upgrades; lookup returns nothing under `helm template`
       (Argo CD), which is why the ApplicationSet ignores this Secret's data. */}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name }}
{{- $password := "" }}
{{- if and $existing $existing.data (hasKey $existing.data "password") }}
{{- $password = index $existing.data "password" | b64dec }}
{{- else }}
{{- $password = $pg.auth.password | default (randAlphaNum 24) }}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
  labels:
    {{- include "platform-lib.labels" $ctx | nindent 4 }}
    platform.akibullah.dev/generated: "true"
type: Opaque
data:
  password: {{ $password | b64enc | quote }}
---
{{- end }}
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  labels:
    {{- include "platform-lib.labels" $ctx | nindent 4 }}
spec:
  clusterIP: None
  selector:
    {{- include "platform-lib.selectorLabels" $ctx | nindent 4 }}
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $name }}
  labels:
    {{- include "platform-lib.labels" $ctx | nindent 4 }}
spec:
  serviceName: {{ $name }}
  replicas: 1
  selector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "platform-lib.labels" $ctx | nindent 8 }}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgresql
          image: {{ $pg.image | quote }}
          imagePullPolicy: IfNotPresent
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: {{ $pg.auth.username | quote }}
            - name: POSTGRES_DB
              value: {{ $pg.auth.database | quote }}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "platform-lib.postgresql.secretName" . }}
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          resources:
            {{- toYaml $pg.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-U", {{ $pg.auth.username | quote }}, "-d", {{ $pg.auth.database | quote }}]
            periodSeconds: 5
            timeoutSeconds: 3
          livenessProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-U", {{ $pg.auth.username | quote }}]
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: run
              mountPath: /var/run/postgresql
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: run
          emptyDir: {}
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          {{- include "platform-lib.selectorLabels" $ctx | nindent 10 }}
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- with $pg.storageClass }}
        storageClassName: {{ . }}
        {{- end }}
        resources:
          requests:
            storage: {{ $pg.storage }}
---
{{ include "platform-lib.datastoreNetworkPolicy" (dict "root" . "component" "postgresql" "port" 5432) }}
{{- end -}}
{{- end -}}

{{- define "platform-lib.redis" -}}
{{- $r := .Values.redis -}}
{{- if $r.enabled -}}
{{- $name := printf "%s-redis" (include "platform-lib.fullname" .) -}}
{{- $ctx := dict "root" . "component" "redis" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  labels:
    {{- include "platform-lib.labels" $ctx | nindent 4 }}
spec:
  selector:
    {{- include "platform-lib.selectorLabels" $ctx | nindent 4 }}
  ports:
    - name: redis
      port: 6379
      targetPort: redis
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "platform-lib.labels" $ctx | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "platform-lib.labels" $ctx | nindent 8 }}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: redis
          image: {{ $r.image | quote }}
          imagePullPolicy: IfNotPresent
          args: ["--save", "", "--appendonly", "no", "--maxmemory", {{ $r.maxmemory | quote }}, "--maxmemory-policy", "allkeys-lru"]
          ports:
            - name: redis
              containerPort: 6379
          resources:
            {{- toYaml $r.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: redis
            initialDelaySeconds: 10
            periodSeconds: 15
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir:
            sizeLimit: 128Mi
---
{{ include "platform-lib.datastoreNetworkPolicy" (dict "root" . "component" "redis" "port" 6379) }}
{{- end -}}
{{- end -}}

{{/* Only pods of the same release may reach a datastore. */}}
{{- define "platform-lib.datastoreNetworkPolicy" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ printf "%s-%s" (include "platform-lib.fullname" .root) .component }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/instance: {{ .root.Release.Name }}
      ports:
        - port: {{ .port }}
          protocol: TCP
{{- end -}}
