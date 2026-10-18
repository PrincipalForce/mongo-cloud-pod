# Operations

Running this thing. Backups, restores, upgrades, scaling, and what to do when
it breaks.

## Backups

Off by default, which is the right default for a chart that gets installed to
try something out and the wrong one for anything you care about. Turn it on:

```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"
  target: s3            # or "pvc"
  retentionCount: 7
  s3:
    bucket: my-backups
    prefix: mongo-cloud-pod/production
    region: eu-west-1
    existingSecret: backup-aws-credentials   # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
```

What the job does, per engine:

| Engine | Tool | Where it runs | Output |
| --- | --- | --- | --- |
| `ferretdb` | `pg_dump --format=custom` | storage image, same Postgres major | `20260117T020000Z.dump` |
| `mongodb-community` | `mongodump --gzip --archive` | server image | `20260117T020000Z.archive.gz` |

**Back up Postgres, not the Mongo view of it.** `mongodump` through the gateway
works and produces a portable archive, but it does not capture the index
metadata DocumentDB keeps alongside the BSON tables — a restore from one leaves
you rebuilding indexes by hand. The exception is migrating *away* from this
project, where a portable `mongodump` archive is exactly what you want.

The job fails loudly on a zero-byte dump. A backup that silently succeeds while
producing nothing is worse than no backup, because you stop looking.

### Verify a restore, not a backup

A backup you have never restored is a hypothesis. Monthly, into a scratch
namespace:

```bash
helm install restore-test charts/mongo-cloud-pod -n restore-test --create-namespace --wait
kubectl -n restore-test cp ./20260117T020000Z.dump restore-test-mongo-cloud-pod-postgres-0:/tmp/
kubectl -n restore-test exec restore-test-mongo-cloud-pod-postgres-0 -- \
  pg_restore --clean --if-exists --username=mongouser --dbname=postgres /tmp/20260117T020000Z.dump
helm test restore-test -n restore-test
```

Then point `mongosh` at it and check that a collection you recognise has the
row count you expect.

### Restoring over a live database

```bash
# 1. Stop writes. Scale the gateway to zero — the storage node stays up so
#    pg_restore can connect, but nothing else can reach it.
kubectl -n prod scale deployment/pod-mongo-cloud-pod-gateway --replicas=0

# 2. Restore.
kubectl -n prod exec pod-mongo-cloud-pod-postgres-0 -- \
  pg_restore --clean --if-exists --username=mongouser --dbname=postgres /backups/<file>.dump

# 3. Bring it back.
kubectl -n prod scale deployment/pod-mongo-cloud-pod-gateway --replicas=1
```

`--clean --if-exists` drops the existing objects first. That is destructive and
intended; without it you get a half-merged database that looks fine until a
unique index fires.

For `mongodb-community`, `mongorestore --drop --gzip --archive=<file>` is the
equivalent, and there is no gateway to scale — stop your application instead.

## Upgrades

### Chart upgrades

```bash
helm upgrade pod charts/mongo-cloud-pod -n prod --reuse-values --wait
```

The password survives (read back from the live Secret). CI asserts this on
every run, because the alternative — a silent credential rotation that only
surfaces at the next pod restart — is a genuinely nasty outage.

### FerretDB major upgrades

The gateway is stateless, so this is a rolling restart. Check the FerretDB
release notes first: 1.x → 2.x changed the storage layout entirely and is a
dump-and-restore, not an upgrade.

### Postgres major upgrades

**This is not an in-place operation.** A Postgres major rewrites the on-disk
data directory; pointing a new major at an old volume gives you a pod in
`CrashLoopBackOff` with "database files are incompatible with server" in the
logs. The floating `:17` tag never crosses a major for this reason.

To move majors:

```bash
# 1. Dump from the old instance.
kubectl -n prod exec pod-mongo-cloud-pod-postgres-0 -- \
  pg_dump --format=custom --username=mongouser --dbname=postgres --file=/tmp/pre-upgrade.dump
kubectl -n prod cp pod-mongo-cloud-pod-postgres-0:/tmp/pre-upgrade.dump ./pre-upgrade.dump

# 2. Install a new release on the new major, with a fresh volume.
helm install pod-v18 charts/mongo-cloud-pod -n prod \
  --set postgres.image.tag=18 --set auth.password="$(…same password…)" --wait

# 3. Restore, verify, then cut your application's connection string over.
```

Keep the old release until you have verified the new one. The PVC is retained
on uninstall precisely so that a hasty cutover is recoverable.

## Scaling

| Pressure | What to do |
| --- | --- |
| Many client connections | Raise `gateway.replicaCount`; it is stateless. Watch Postgres `max_connections` — the gateways share it. |
| Slow queries | Add indexes. `log_min_duration_statement=1000` in `postgres.extraArgs` shows you which. |
| CPU-bound storage | Raise `postgres.resources.limits.cpu`, and `shared_buffers` to ~25% of the memory limit. |
| Disk filling | Expand the PVC if your CSI driver supports it (`kubectl edit pvc`), then restart the pod. Shrinking is not possible on any common driver — plan upward. |
| Need real HA | Move the storage layer to CloudNativePG and point `FERRETDB_POSTGRESQL_URL` at it. This chart's storage node is deliberately single-writer. |

Note that `volumeClaimTemplates` are immutable on an existing StatefulSet:
changing `postgres.persistence.size` affects new installs only. Resize the PVC
object directly.

## Observability

```yaml
metrics:
  serviceMonitor:
    enabled: true     # requires the Prometheus Operator CRDs
```

Scrapes FerretDB's debug listener (`:8088/debug/metrics`) through a separate,
non-public Service — the application-facing Service exposes 27017 and nothing
else, so a misconfigured scrape target can never become a path to the database
port.

`mongodb-community` has no Prometheus endpoint without a separate exporter
sidecar; enabling the ServiceMonitor with that engine fails the render rather
than quietly producing a target that returns 404.

Worth alerting on: storage pod restarts, PVC utilisation above ~80%, backup
CronJob failures (`kube_job_status_failed`), and connection count against
`max_connections`.

## Diagnostics

```bash
# Is everything up?
kubectl -n prod get pods,pvc -l app.kubernetes.io/part-of=mongo-cloud-pod

# Gateway logs — protocol errors and unsupported commands show up here.
kubectl -n prod logs deployment/pod-mongo-cloud-pod-gateway --tail=200

# Storage logs — the real cause of most gateway failures.
kubectl -n prod logs statefulset/pod-mongo-cloud-pod-postgres --tail=200

# Talk to it directly.
kubectl -n prod port-forward svc/pod-mongo-cloud-pod 27017:27017
mongosh "$(kubectl -n prod get secret pod-mongo-cloud-pod \
  -o jsonpath='{.data.connectionString}' | base64 -d | sed 's|@[^:]*:|@localhost:|')"

# Drop to SQL when you need to see what DocumentDB is actually storing.
kubectl -n prod exec -it pod-mongo-cloud-pod-postgres-0 -- psql -U mongouser -d postgres
```

A command your application uses that FerretDB does not implement appears in the
gateway log as an unsupported-command error, with the command name. That is
usually the fastest route from "it works on MongoDB" to the relevant row of
[compatibility.md](compatibility.md).

## Uninstalling without losing data

```bash
helm uninstall pod -n prod
```

PVCs and the credentials Secret are annotated `helm.sh/resource-policy: keep`
and survive. Reinstalling the same release name into the same namespace picks
up both — the data, and the password it was written with. To actually delete
the data, delete the PVCs explicitly:

```bash
kubectl -n prod delete pvc -l app.kubernetes.io/part-of=mongo-cloud-pod
```
