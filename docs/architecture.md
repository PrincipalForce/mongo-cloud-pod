# Architecture

## The stack

```
┌─────────────────────────────────────────────────────────────┐
│ application pod                                             │
│   mongoose / pymongo / mongo-go-driver / mongosh            │
└───────────────────────────┬─────────────────────────────────┘
                            │ MongoDB wire protocol (OP_MSG), 27017
                            │ SCRAM-SHA-256
┌───────────────────────────▼─────────────────────────────────┐
│ Service  <release>                     ClusterIP :27017     │
│   selector: mongo-cloud-pod.io/endpoint=true                │
└───────────────────────────┬─────────────────────────────────┘
                            │
       engine: ferretdb     │     engine: mongodb-community
       ┌────────────────────┴───────────────────┐
       ▼                                        ▼
┌──────────────────────┐              ┌──────────────────────┐
│ Deployment           │              │ StatefulSet          │
│ <release>-gateway    │              │ <release>-mongodb    │
│   FerretDB 2.x       │              │   mongod 8.x         │
│   Apache-2.0         │              │   SSPL-1.0, gated    │
│   stateless, N≥1     │              │   single writer      │
└──────────┬───────────┘              └──────────┬───────────┘
           │ SQL :5432                           │
           ▼                                     ▼
┌──────────────────────┐              ┌──────────────────────┐
│ StatefulSet          │              │ PVC  data            │
│ <release>-postgres   │              │   /data/db           │
│   Postgres 17        │              └──────────────────────┘
│   + DocumentDB (MIT) │
│   PVC → /var/lib/…   │
└──────────────────────┘
```

## Why the Service selects on a label instead of a component

Both engines label their protocol-terminating pod
`mongo-cloud-pod.io/endpoint: "true"`, and the Service selects on that rather
than on `app.kubernetes.io/component`. The consequence is that the Service
name, port, DNS record and connection string are identical in both modes — so
switching engines is a `helm upgrade`, not an application change. That property
is what makes the SSPL engine useful as a comparison baseline (see
[compatibility](compatibility.md)) rather than a separate deployment.

## Why the gateway is a Deployment and the storage is a StatefulSet

FerretDB holds no durable state: every byte lives in Postgres. It can be
scaled, rescheduled and rolled without coordination, which is what a Deployment
expresses. Postgres is a single writer against one volume — a second replica
sharing an RWO PVC does not start, and a second replica with its own PVC is a
second, unrelated database. Expressing that as `replicas: 1` on a StatefulSet
is a statement about correctness, not a capacity default.

HA for the storage layer therefore means Postgres HA — streaming replication,
or an operator like CloudNativePG — not more replicas here. That is deliberate:
it is a solved problem in the Postgres ecosystem, and solving it a second time
inside this chart would solve it worse.

## Credentials

One Secret holds `username`, `password`, `database`, `host`, `port` and a
composed `connectionString`. Every workload reads it through `secretKeyRef`;
nothing takes a password through a values file at runtime.

The password is rendered in exactly one template (`secret.yaml`), and on
upgrade it is read back from the live Secret via Helm's `lookup`. Without that,
every `helm upgrade` would mint a new password: the Secret would change,
running pods would keep the old value in their environment, and the next pod
restart — hours or weeks later, during something unrelated — would lock the
application out. CI asserts the password survives an upgrade.

The gateway's Postgres DSN is assembled by Kubernetes' `$(VAR)` expansion from
separate `PGUSER`/`PGPASSWORD` env vars rather than stored pre-composed. That
is what lets `auth.existingSecret` work with a Secret that a platform created
for its own schema, without requiring it to contain a `postgres://` key.

One consequence worth knowing: the password lands inside a URI. The chart
generates alphanumeric passwords for that reason. If you bring your own Secret,
percent-encode anything exotic.

## Network posture

Default-deny ingress on 27017, allow-listed to the release's own namespace plus
anything named in `networkPolicy.allowedNamespaces`. The storage node accepts
connections only from the gateway and from backup jobs — nothing in the cluster
should be speaking SQL to it directly.

NetworkPolicy is enforced by the CNI. On a cluster without a policy-aware CNI,
these objects are accepted by the API server and do nothing at all. Verify
before relying on them.

## Pod hardening

Non-root (uid 999), `runAsNonRoot`, all capabilities dropped, no privilege
escalation, `RuntimeDefault` seccomp, and no ServiceAccount token mounted — a
database pod has no business holding a cluster API credential, particularly one
that an operator can `kubectl exec` into on a user's behalf.

The gateway additionally runs with a read-only root filesystem, since it writes
nothing outside `/tmp`. Postgres and mongod both write outside their volumes,
so they do not.

The namespace in `k8s/base` enforces the `restricted` Pod Security Standard.
The workloads already satisfy it; enforcing it means a future patch that
loosens a securityContext is rejected by the API server rather than merged.

## Failure modes worth knowing

| Symptom | Cause | Fix |
| --- | --- | --- |
| Gateway `CrashLoopBackOff`, logs mention the DocumentDB extension | Storage image is stock `postgres`, not `postgres-documentdb` | Use the image from `versions.yaml`; `scripts/verify-licenses.sh` checks this |
| Storage pod `CrashLoopBackOff` after an image bump, logs mention an incompatible data directory | Postgres major changed under an existing volume | Restore from a dump into a fresh volume ([operations](operations.md)) |
| Application authenticates, then every write fails | Gateway talking to a database without the extension installed | Confirm `POSTGRES_DB=postgres`; DocumentDB installs there |
| Everything works in-cluster, nothing from outside | ClusterIP by design | `kubectl port-forward`, or a deliberate LoadBalancer with source ranges |
| Clients time out under load | Postgres `max_connections` exhausted | Raise it in `postgres.extraArgs` and the memory limit with it |

## What this chart deliberately does not do

- **An operator/CRD.** A Helm release per database is enough for the single-
  instance case, and platforms that want programmatic control have
  [`pod.yaml`](../pod.yaml). A CRD would add a control loop to maintain for
  something `helm upgrade` already does.
- **Postgres HA.** Deferred to CloudNativePG and friends, which do it properly.
- **Sharding.** FerretDB has no sharding layer; pretending otherwise in the
  chart would be a lie with a `values.yaml` key.
- **TLS termination at the gateway.** Use a service mesh or a sidecar; this is
  a policy decision that belongs with the platform, not the database.
