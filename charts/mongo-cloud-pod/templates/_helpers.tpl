{{/*
Chart name, overridable.
*/}}
{{- define "mongo-cloud-pod.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully-qualified release name. Also the Service name, and therefore the host in
every connection string the chart hands out — renaming a release moves the
endpoint, so don't.
*/}}
{{- define "mongo-cloud-pod.fullname" -}}
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

{{- define "mongo-cloud-pod.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels on every object. `mongo-cloud-pod.io/engine` is here so an operator can
tell at a glance which licence a running deployment is under:
  kubectl get pods -A -l mongo-cloud-pod.io/engine=mongodb-community
*/}}
{{- define "mongo-cloud-pod.labels" -}}
helm.sh/chart: {{ include "mongo-cloud-pod.chart" . }}
app.kubernetes.io/name: {{ include "mongo-cloud-pod.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mongo-cloud-pod
mongo-cloud-pod.io/engine: {{ .Values.engine }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector for a given component. Call as:
  include "mongo-cloud-pod.selectorLabels" (dict "ctx" . "component" "gateway")
*/}}
{{- define "mongo-cloud-pod.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongo-cloud-pod.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
The Service on 27017 must select whichever workload terminates the wire
protocol — the FerretDB gateway in one mode, mongod in the other. Rather than
making the Service engine-aware, both carry this label and the Service selects
on it. Switching engines therefore keeps the same Service, the same DNS name
and the same connection string.
*/}}
{{- define "mongo-cloud-pod.endpointLabels" -}}
app.kubernetes.io/name: {{ include "mongo-cloud-pod.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
mongo-cloud-pod.io/endpoint: "true"
{{- end -}}

{{/*
Component object names.
*/}}
{{- define "mongo-cloud-pod.gatewayName" -}}
{{- printf "%s-gateway" (include "mongo-cloud-pod.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mongo-cloud-pod.postgresName" -}}
{{- printf "%s-postgres" (include "mongo-cloud-pod.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mongo-cloud-pod.mongodbName" -}}
{{- printf "%s-mongodb" (include "mongo-cloud-pod.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The Secret holding credentials: either the user's own, or ours.
*/}}
{{- define "mongo-cloud-pod.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "mongo-cloud-pod.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
The password, resolved in precedence order:

  1. auth.password, if set explicitly.
  2. The password already stored in our Secret, read back via `lookup`. Without
     this an upgrade would mint a fresh password on every `helm upgrade` — the
     Secret would change, running pods would keep the old credential in their
     env, and the next pod restart would lock the application out.
  3. A new random password, on first install.

Rendered in exactly one place (secret.yaml) so that step 3 cannot produce two
different values within one render. Everything else reads the Secret via
secretKeyRef.

`lookup` returns an empty dict during `helm template` and `--dry-run` without a
cluster, which is why rendered output off-cluster shows a throwaway password.
*/}}
{{- define "mongo-cloud-pod.password" -}}
{{- if .Values.auth.password -}}
{{- .Values.auth.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "mongo-cloud-pod.fullname" .) -}}
{{- if and $existing $existing.data (index $existing.data "password") -}}
{{- index $existing.data "password" | b64dec -}}
{{- else -}}
{{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Guard rails. Rendered by every template that creates a workload, so a bad
combination fails at `helm install` with an explanation rather than at runtime
with a CrashLoopBackOff.
*/}}
{{- define "mongo-cloud-pod.validate" -}}
{{- $engines := list "ferretdb" "mongodb-community" -}}
{{- if not (has .Values.engine $engines) -}}
{{- fail (printf "mongo-cloud-pod: engine must be one of %s, got %q" (join ", " $engines) .Values.engine) -}}
{{- end -}}
{{- if and (eq .Values.engine "mongodb-community") (not .Values.sspl.acknowledged) -}}
{{- fail (join "\n" (list
  ""
  "mongo-cloud-pod: engine \"mongodb-community\" requires sspl.acknowledged=true."
  ""
  "MongoDB Community Server is licensed under the Server Side Public License,"
  "which is not an OSI-approved open-source licence. SSPL section 13 requires"
  "anyone who offers the program's functionality to third parties as a service"
  "to release the complete source of that service under the same licence."
  ""
  "If this database serves only your own first-party workloads, you may accept"
  "MongoDB, Inc.'s terms yourself and re-run with:"
  ""
  "    --set engine=mongodb-community --set sspl.acknowledged=true"
  ""
  "If you are offering databases to other people, use the default engine"
  "(ferretdb), which carries no such restriction. See docs/licensing.md."
  "")) -}}
{{- end -}}
{{- if and .Values.auth.existingSecret .Values.auth.password -}}
{{- fail "mongo-cloud-pod: set either auth.password or auth.existingSecret, not both." -}}
{{- end -}}
{{- if and .Values.backup.enabled (eq .Values.backup.target "s3") (not .Values.backup.s3.bucket) -}}
{{- fail "mongo-cloud-pod: backup.target=s3 requires backup.s3.bucket." -}}
{{- end -}}
{{- if and .Values.backup.enabled (eq .Values.backup.target "s3") (not .Values.backup.s3.existingSecret) -}}
{{- fail "mongo-cloud-pod: backup.target=s3 requires backup.s3.existingSecret holding AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." -}}
{{- end -}}
{{- end -}}

{{/*
Credentials for backup jobs. PGPASSWORD is named for libpq's benefit in the
FerretDB case; the mongodump branch reads the same variable rather than
duplicating the secretKeyRef under a second name.
*/}}
{{- define "mongo-cloud-pod.backupEnv" -}}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "mongo-cloud-pod.secretName" . }}
      key: username
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "mongo-cloud-pod.secretName" . }}
      key: password
{{- end -}}

{{/*
The dump itself, shared by the PVC and S3 backup paths so the two cannot drift.
Writes exactly one timestamped file into /backups — the S3 uploader relies on
that being the only file there.
*/}}
{{- define "mongo-cloud-pod.dumpScript" -}}
# Timestamped, lexically sortable, and safe as a filename.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{{ if eq .Values.engine "ferretdb" -}}
# Dump Postgres, not the Mongo view of it: pg_dump captures the DocumentDB
# tables together with the index metadata the extension keeps alongside them,
# which a mongodump through the gateway does not see.
FILE="/backups/${STAMP}.dump"
pg_dump \
  --host={{ include "mongo-cloud-pod.postgresName" . }} \
  --username="${DB_USER}" \
  --dbname=postgres \
  --format=custom \
  --file="${FILE}"
{{- else -}}
FILE="/backups/${STAMP}.archive.gz"
mongodump \
  --host={{ include "mongo-cloud-pod.mongodbName" . }} \
  --port=27017 \
  --username="${DB_USER}" \
  --password="${PGPASSWORD}" \
  --authenticationDatabase=admin \
  --gzip \
  --archive="${FILE}"
{{- end }}
# A zero-byte dump is a failed backup wearing a success exit code.
if [ ! -s "${FILE}" ]; then
  echo "dump produced no data: ${FILE}" >&2
  exit 1
fi
echo "wrote ${FILE} ($(wc -c < "${FILE}") bytes)"
{{- end -}}

{{/*
Image pull secrets, shared by every pod spec.
*/}}
{{- define "mongo-cloud-pod.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Annotations on every object.
*/}}
{{- define "mongo-cloud-pod.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}
