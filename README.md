# mongo-cloud-pod

**A MongoDB-compatible document database for Kubernetes, under licences you can
actually build a product on.**

`mongo-cloud-pod` is an Apache-2.0 Kubernetes bundle that speaks the MongoDB
wire protocol on port `27017` — so `mongosh`, Mongoose, PyMongo, the Go driver
and the rest connect to it unchanged — while containing **no SSPL-licensed
component**. Under the hood it is [FerretDB][ferretdb] (Apache-2.0) in front of
[PostgreSQL][pg] (PostgreSQL licence) with the [DocumentDB][documentdb]
extension (MIT).

It ships as a Helm chart, a set of Kustomize manifests, a machine-readable pod
descriptor for platforms that provision databases programmatically (such as
[Launchmatic][launchmatic]), and a Docker Compose file for local development.

```bash
helm install mongo-pod ./charts/mongo-cloud-pod -n my-app --create-namespace --wait
helm test mongo-pod -n my-app        # real insert → index → aggregate → delete

kubectl get secret mongo-pod-mongo-cloud-pod -n my-app \
  -o jsonpath='{.data.connectionString}' | base64 -d
# mongodb://mongouser:…@mongo-pod-mongo-cloud-pod:27017/appdb
```

---

## First, the thing people expect this to be

**You cannot make MongoDB open source.** Its licence is MongoDB Inc.'s to
choose, and since 4.0 that choice has been the Server Side Public License. No
chart or wrapper changes that.

What you *can* choose is what sits behind the wire protocol, and that splits
cleanly by what you're doing:

| | `engine: ferretdb` (default) | `engine: mongodb-community` |
| --- | --- | --- |
| What runs | FerretDB → Postgres + DocumentDB | `mongod` |
| Licences | Apache-2.0, MIT, PostgreSQL | SSPL-1.0 |
| OSI-approved | ✅ | ❌ |
| Cost | Free | Free |
| **Offer as a service to others** | ✅ | ❌ SSPL §13 applies |
| MongoDB feature coverage | High, with [gaps](docs/compatibility.md) | Complete |
| Requires acknowledgement | No | `sspl.acknowledged: true` |

Both are in this chart, behind one Service name and one connection-string
shape, so switching is a `helm upgrade` rather than an application change.

- Running a database for **your own app**, even a commercial closed-source one?
  SSPL costs you nothing and imposes nothing. Either engine is fine.
- Giving databases to **your users** — a hosting platform, an IDP, a
  multi-tenant SaaS? That is exactly what SSPL §13 reaches. Use the default.

That second case is why this exists. Launchmatic marks its `MONGODB` engine
`retired` for precisely this reason; `mongo-cloud-pod` is the engine it can
offer instead. See [docs/licensing.md](docs/licensing.md) for the full
reasoning, and [docs/launchmatic.md](docs/launchmatic.md) for the integration.

The SSPL engine refuses to deploy unless you say so explicitly:

```console
$ helm install pod ./charts/mongo-cloud-pod --set engine=mongodb-community
Error: mongo-cloud-pod: engine "mongodb-community" requires sspl.acknowledged=true.
…
If you are offering databases to other people, use the default engine
(ferretdb), which carries no such restriction. See docs/licensing.md.
```

`scripts/verify-licenses.sh` keeps the default honest in CI: it fails the build
if a default render contains any MongoDB Inc. server image, if the storage
image lacks the DocumentDB extension, or if that gate ever stops rejecting an
unacknowledged install.

## What you get

- **Wire-protocol compatibility** — MongoDB 5.0+. CRUD, aggregation pipelines,
  indexes (compound, TTL, text, vector), transactions, cursors, and
  `SCRAM-SHA-256` auth. Gaps are catalogued in
  [docs/compatibility.md](docs/compatibility.md) — change streams, sharding,
  GridFS and `$out`/`$merge` are the notable ones.
- **A database you can run** — persistent volumes, startup/readiness/liveness
  probes, non-root containers with all capabilities dropped, default-deny
  NetworkPolicy, resource limits, and a PodDisruptionBudget for the stateless
  tier.
- **Backups** — a CronJob to a PVC or S3-compatible storage, with retention, a
  zero-byte-dump guard, and a restore procedure that has been written down
  ([docs/operations.md](docs/operations.md)).
- **Credentials that survive upgrades** — the password is generated once and
  read back from the live Secret on upgrade, never silently rotated. CI asserts
  this, because the alternative locks your app out at the next pod restart.
- **Four consumption surfaces** — Helm, Kustomize, Argo CD, and a `pod.yaml`
  descriptor for platforms that build manifests from a catalog entry.

## Quickstart

### Local (Docker Compose)

```bash
cp .env.example .env
docker compose up -d
mongosh "mongodb://mongouser:localdevpassword@localhost:27017/appdb"
./scripts/smoke-test.sh
```

To compare behaviour against real MongoDB on the same port and credentials:

```bash
docker compose down && docker compose --profile mongodb-community up -d
```

### Kubernetes (Helm)

```bash
helm install mongo-pod ./charts/mongo-cloud-pod \
  --namespace my-app --create-namespace \
  --set auth.username=appuser \
  --set auth.database=appdb \
  --set postgres.persistence.size=20Gi \
  --set backup.enabled=true \
  --wait

helm test mongo-pod -n my-app
```

### Kubernetes (Kustomize, no Helm)

```bash
kubectl apply -k k8s/overlays/production   # create the credentials Secret first
```

`k8s/base` is generated from the chart by `scripts/render-manifests.sh`, and CI
fails if the two drift — there is no second copy to keep in sync by hand.

### GitOps (Argo CD)

```bash
kubectl apply -f deploy/argocd/mongo-cloud-pod-application.yaml
```

## Using it from a platform

[`pod.yaml`](pod.yaml) is the machine-readable contract: engine identity,
images with their upstream EOL dates, ports, required environment variables,
data paths, probes, the connection-string template, and the backup/restore
commands. A provisioner can render a StatefulSet from it without shelling out
to Helm — which is how Launchmatic's `db-worker` already builds Postgres and
Redis instances.

[`charts/mongo-cloud-pod/values-launchmatic.yaml`](charts/mongo-cloud-pod/values-launchmatic.yaml)
is the multi-tenant preset: platform-owned credentials, per-namespace network
isolation, no ServiceAccount token, S3 backups, metrics on.

## Configuration

Every knob is documented inline in
[`values.yaml`](charts/mongo-cloud-pod/values.yaml). The ones that matter:

| Value | Default | Notes |
| --- | --- | --- |
| `engine` | `ferretdb` | Or `mongodb-community`, with `sspl.acknowledged=true`. |
| `auth.username` / `auth.database` | `mongouser` / `appdb` | |
| `auth.password` | *(generated)* | Or point `auth.existingSecret` at your own. |
| `postgres.persistence.size` | `10Gi` | Grow it early; shrinking isn't possible. |
| `postgres.persistence.storageClass` | *(cluster default)* | Use SSD — this is OLTP with fsync on the write path. |
| `gateway.replicaCount` | `1` | Stateless; raise for HA. |
| `backup.enabled` | `false` | Turn on before it holds anything real. |
| `networkPolicy.enabled` | `true` | Default-deny; allow-list via `allowedNamespaces`. |
| `metrics.serviceMonitor.enabled` | `false` | Needs the Prometheus Operator CRDs. |

## Versions and support

[`versions.yaml`](versions.yaml) is the single source of truth for images, each
with its upstream EOL date and a `default`/`available`/`deprecated` status.
Tags float within a major (you get CVE fixes) but never across one (a Postgres
major bump rewrites the data directory). CI fails when a default comes within
180 days of EOL, so an expiring dependency surfaces months ahead.
See [docs/versions.md](docs/versions.md).

## Documentation

| | |
| --- | --- |
| [Licensing](docs/licensing.md) | What SSPL §13 actually says, why FerretDB, why not old AGPL MongoDB |
| [Compatibility](docs/compatibility.md) | Supported, partial and unsupported — check before migrating |
| [Architecture](docs/architecture.md) | How the pieces fit, and what the chart deliberately doesn't do |
| [Operations](docs/operations.md) | Backups, restores, upgrades, scaling, diagnostics |
| [Versions](docs/versions.md) | Image policy and how to bump one |
| [Launchmatic](docs/launchmatic.md) | Integrating with a provisioning platform |

## Project status

Beta. The chart and the protocol surface are stable enough for non-critical
workloads. Take backups, pin your image tags, and read the compatibility notes
before migrating anything that uses change streams or sharding.

## Contributing

Issues and pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). One
rule above the others: nothing that puts an SSPL image in the default path.

## Licence

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). MONGODB is a
registered trademark of MongoDB, Inc.; this project is not affiliated with or
endorsed by them, and "MongoDB-compatible" is a factual claim about wire
protocol and driver support.

[ferretdb]: https://github.com/FerretDB/FerretDB
[documentdb]: https://github.com/microsoft/documentdb
[pg]: https://www.postgresql.org/
[launchmatic]: https://launchmatic.com
