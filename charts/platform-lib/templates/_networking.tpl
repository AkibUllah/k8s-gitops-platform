{{- define "platform-lib.service" -}}
{{- $v := .values -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "platform-lib.componentName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
  {{- with $v.service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $v.service.type }}
  selector:
    {{- include "platform-lib.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ $v.service.port }}
      targetPort: http
      protocol: TCP
{{- end -}}

{{- define "platform-lib.ingress" -}}
{{- $v := .values -}}
{{- if $v.ingress.enabled -}}
{{- $svc := include "platform-lib.componentName" . -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $svc }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
  {{- with $v.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with $v.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with $v.ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range $v.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range (.paths | default (list (dict "path" "/" "pathType" "Prefix"))) }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $svc }}
                port:
                  name: http
          {{- end }}
    {{- end }}
{{- end -}}
{{- end -}}

{{/*
Default-deny NetworkPolicy for a component.
Ingress: only to the http port, from pods of the same platform (part-of label)
in this namespace and from the listed namespaces (ingress controller, monitoring).
Egress (optional): DNS, the release's own datastores and the listed CIDRs
(each with its own ports, defaulting to egress.ports).
*/}}
{{- define "platform-lib.networkpolicy" -}}
{{- $v := .values -}}
{{- if $v.networkPolicy.enabled -}}
{{- $np := $v.networkPolicy -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "platform-lib.componentName" . }}
  labels:
    {{- include "platform-lib.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "platform-lib.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    {{- if $np.egress.enabled }}
    - Egress
    {{- end }}
  {{- if not $v.containerPort }}
  ingress: []
  {{- else }}
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/part-of: {{ include "platform-lib.partOf" . }}
        {{- range $np.ingressNamespaces }}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ . }}
        {{- end }}
      ports:
        - port: http
          protocol: TCP
  {{- end }}
  {{- if $np.egress.enabled }}
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/instance: {{ .root.Release.Name }}
    {{- range $np.egress.cidrs }}
    - to:
        - ipBlock:
            cidr: {{ .cidr }}
            {{- with .except }}
            except:
              {{- toYaml . | nindent 14 }}
            {{- end }}
      ports:
        {{- range (.ports | default $np.egress.ports) }}
        - port: {{ . }}
          protocol: TCP
        {{- end }}
    {{- end }}
  {{- end }}
{{- end -}}
{{- end -}}
