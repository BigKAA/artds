{{/*
Expand the name of the chart.
*/}}
{{- define "artds.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "artds.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "artds.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "artds.labels" -}}
helm.sh/chart: {{ include "artds.chart" . }}
{{ include "artds.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "artds.selectorLabels" -}}
app.kubernetes.io/name: {{ include "artds.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "artds.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "artds.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Exporter container definition
*/}}
{{- define "artds.exporterContainer" -}}
- name: exporter
  image: "{{ .Values.monitoring.exporter.repository }}:{{ .Values.monitoring.exporter.tag }}"
  imagePullPolicy: {{ .Values.monitoring.exporter.pullPolicy }}
  ports:
  - name: metrics
    containerPort: 9313
    protocol: TCP
  env:
  - name: LDAP_URI
    value: "ldap://localhost:3389"
  - name: BIND_DN
    value: "cn=Directory Manager"
  - name: BIND_PASSWORD
    valueFrom:
      secretKeyRef:
        {{- if .Values.ds.adminSecretName }}
        name: {{ .Values.ds.adminSecretName }}
        {{- else }}
        name: {{ include "artds.fullname" . }}-secret
        {{- end }}
        key: DS_DM_PASSWORD
  - name: SERVER_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  volumeMounts:
  - name: exporter-config
    mountPath: /etc/389ds-exporter
    readOnly: true
  resources:
    {{- toYaml .Values.monitoring.resources | nindent 4 }}
  livenessProbe:
    httpGet:
      path: /metrics
      port: metrics
    initialDelaySeconds: 30
    periodSeconds: 30
  readinessProbe:
    httpGet:
      path: /metrics
      port: metrics
    initialDelaySeconds: 10
    periodSeconds: 10
{{- end }}
