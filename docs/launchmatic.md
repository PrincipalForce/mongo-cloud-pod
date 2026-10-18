# Consuming mongo-cloud-pod from Launchmatic

Launchmatic retired its `MONGODB` engine over licensing, not technology. From
`packages/shared/src/db-versions.ts`:

> MONGODB is retired over licensing, not technology. MongoDB Community is
> SSPL-only across 7, 8 and 9 — there is no AGPL option as there is for
> Redis 8 — and SSPL §13 speaks to offering the software's functionality as a
> service, which is what a tenant database is.

That reasoning is correct and this project does not ask anyone to revisit it.
What it offers instead is a different engine behind the same wire protocol —
one with no field-of-use restriction — so tenants whose code speaks MongoDB can
be served without MongoDB.

This page describes integrating it. Nothing here requires changes to this
repository; it is all on the platform side.

## The shape of the integration

Launchmatic provisions a database as one StatefulSet plus one Service per
`DatabaseInstance`, in the team's namespace, with credentials the platform
generated (`apps/db-worker/src/services/kubernetes.service.ts`). A
mongo-cloud-pod instance is the same thing with one extra workload — a
stateless gateway in front of the storage node.

There are two ways to render it, and the right one depends on whether the
platform wants Helm in the provisioning path.

### Option A — Helm release per instance (less code)

```bash
helm install "db-${instanceId}" oci://ghcr.io/principalforce/charts/mongo-cloud-pod \
  --namespace "team-${teamSlug}" \
  --values values-launchmatic.yaml \
  --set auth.existingSecret="db-${instanceId}-credentials" \
  --set postgres.persistence.size="${storageSize}Mi" \
  --wait
```

The platform keeps owning credentials: it creates
`db-<instanceId>-credentials` with `username`, `password`, `database` (and
optionally `connectionString`) exactly as it does today, and the chart consumes
it rather than generating anything.

`charts/mongo-cloud-pod/values-launchmatic.yaml` presets the rest: ClusterIP,
no ServiceAccount token, default-deny NetworkPolicy with no cross-namespace
allowance, S3 backups, ServiceMonitor on, Helm test hook off.

### Option B — render from `pod.yaml` (no Helm dependency)

[`pod.yaml`](../pod.yaml) is the machine-readable contract for exactly this:
images and their EOL dates, ports, env vars, data paths, probes, resource
defaults, the connection-string template, and the backup/restore commands. A
provisioner reads it and builds the same objects in TypeScript, the way
`createDatabaseStatefulSet` already does for Postgres and Redis.

This keeps `kubernetes.service.ts` as the single place that talks to the
cluster API, which is the existing convention.

## Changes on the platform side

### 1. A new engine, rather than un-retiring the old one

In `packages/shared/src/db-versions.ts`, `MONGODB` stays retired. Add a
distinct engine so the two are never confused in a row, a metric or a support
conversation:

```ts
export type DbEngine =
  | "POSTGRESQL" | "POSTGIS" | "REDIS" | "MONGODB" | "MONGODB_COMPATIBLE";

MONGODB_COMPATIBLE: [
  // FerretDB over Postgres+DocumentDB. Apache-2.0 / MIT / PostgreSQL —
  // no SSPL, so this one may be offered to tenants. `version` is the
  // FerretDB major; the Postgres major travels with the storage image.
  { version: "2", image: "ghcr.io/ferretdb/ferretdb:2", eol: "2027-06-30", status: "default",
    label: "MongoDB-compatible" },
],

export const DB_ENGINE_STATUS = {
  // …
  MONGODB: "retired",            // SSPL — unchanged
  MONGODB_COMPATIBLE: "available",
};
```

Keeping `MONGODB` retired matters: `assertEngineOfferable` is the guard that
stops the several creation paths (explicit API, Lightspeed plans, multi-service
deploy, workflow actions, builder auto-provision) from provisioning it. That
guard should keep refusing SSPL.

Two versions, not one, is the catch here — a `MONGODB_COMPATIBLE` instance has
a gateway major *and* a storage major. Either store the pair, or store the
FerretDB major and resolve the storage image from `versions.yaml` alongside it.
The second is less to migrate.

### 2. Port and connection string

Port 27017 and the familiar `mongodb://` URL, so repo detection
(`packages/shared/src/db-detection.ts`) and the generated skill
(`apps/api/skills/express-mongodb-api.md`) need no changes — a Mongoose app
connects to this unchanged. Note that `authSource=admin` must **not** be
appended for this engine; see `spec.connection.templates` in `pod.yaml`.

### 3. Backups

The existing backup worker shells into the database pod and runs
`pg_dump`/`mongodump`. For `MONGODB_COMPATIBLE`, run `pg_dump` in the
**storage** container, not `mongodump` through the gateway:

```
container: storage
dump:    pg_dump --format=custom --dbname=postgres --file=<target>
restore: pg_restore --clean --if-exists --dbname=postgres <source>
```

`pg_dump` captures the index metadata DocumentDB keeps alongside the BSON
tables; a `mongodump` through the gateway does not. Both commands are in
`spec.backup` in `pod.yaml` so the worker can look them up rather than hardcode
them.

The backup storage key convention (`packages/shared/src/backup-storage-key.ts`)
needs no change beyond accepting the new engine string.

### 4. UI and docs

The database wizard reads `offerableEngines()`, so the new engine appears
automatically once it is `available`. Two things are worth saying in the UI,
because a user choosing this will ask:

- it speaks the MongoDB wire protocol, so their existing code works unchanged;
- change streams, sharding, GridFS and `$out`/`$merge` are not available —
  link to [compatibility.md](compatibility.md).

Resource quotas: a `MONGODB_COMPATIBLE` instance is two pods, so it consumes
roughly `DB_CPU + 50m` and `DB_MEMORY + 128Mi` against the team's quota. Worth
reflecting in the cluster memory breakdown rather than discovering it when a
namespace quota rejects a provision.

## What this does not solve

- **Tenants who genuinely need MongoDB itself** — change streams, Atlas
  Search, sharding. For them the answer is still an external Atlas connection
  string, not a hosted instance.
- **Existing `MONGODB` rows.** They stay retired and keep running under
  whatever arrangement they exist under today; this adds an engine rather than
  migrating one. A tenant moving across would do it with `mongodump` from the
  old instance and `mongorestore` into the new one through the gateway.

## Verification before offering it

```bash
helm install smoke oci://ghcr.io/principalforce/charts/mongo-cloud-pod \
  -n smoke --create-namespace --wait
helm test smoke -n smoke          # wire-protocol round-trip
```

Then point a representative tenant application's integration suite at it. The
compatibility table is a starting point; a real test suite is the decision.
