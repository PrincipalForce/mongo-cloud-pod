# Versions

[`versions.yaml`](../versions.yaml) is the single source of truth for the
images this project offers. The chart's defaults, the docs and any platform
reading [`pod.yaml`](../pod.yaml) all trace back to it.

## Two rules

**1. Tags float within a major, never below it.**

`ghcr.io/ferretdb/postgres-documentdb:17` picks up patch releases — including
CVE fixes — on the next pod restart, and can never move a deployment across a
Postgres major. That matters because a major bump rewrites the on-disk data
directory, so an image tag that crossed one would turn a routine restart into a
`CrashLoopBackOff` with the data still on the volume.

For production, pin the full tag from the `pinned` field. A floating tag is the
right default (you get fixes) and the wrong thing during an incident (you want
to know exactly what is running).

**2. Every entry carries its upstream EOL date.**

`scripts/check-eol.sh` fails CI when anything offered as `default` or
`available` is within `eolWarningDays` (180) of end of life, and CI runs
weekly. The lead time is the point: six months is enough to pick a successor,
test a provision and ship it. A dependency that expires quietly is one you
find out about from a CVE feed.

Entries marked `deprecated` are exempt — they exist so that a deployment
already pinned to them still resolves, and their EOL passing is expected.

## Statuses

| Status | Meaning |
| --- | --- |
| `default` | What a new deployment gets. Exactly one per component; the EOL guard enforces that. |
| `available` | Offerable; ask for it explicitly. |
| `deprecated` | Not offered for new deployments, still resolvable for existing ones. |

## Why these versions

**FerretDB 2.x, not 1.x.** 2.x is a rewrite on top of the DocumentDB extension
and is substantially more compatible. The two have incompatible on-disk
layouts — a 1.x gateway against a 2.x storage image does not work, and the
reverse loses data.

**Postgres 17 as the default, not 18.** The DocumentDB extension's builds track
Postgres majors on their own schedule, and the default should be a combination
with real production mileage rather than the newest thing that exists.

**MongoDB 8, not 9, for the SSPL engine.** MongoDB ships rapid releases (8.1,
8.2, 8.3) with roughly twelve months of support alongside long-support majors:
8.2 was released 2025-09-30 and was already EOL by 2026-07-31. Only long-support
majors belong in a catalog. 9.0 is offerable but should not be what someone
gets by accident.

## Changing a version

1. Add the new entry to `versions.yaml` with `status: default`, its image, its
   `pinned` tag, and its upstream EOL date from endoflife.date.
2. Demote the previous default to `available`, or to `deprecated` if it should
   no longer be offered.
3. Update the matching default in `charts/mongo-cloud-pod/values.yaml`.
4. Bump the chart `version` in `Chart.yaml` (and `appVersion` if the FerretDB
   major moved).
5. Run `./scripts/render-manifests.sh` so `k8s/base` matches, and
   `./scripts/check-eol.sh`.
6. If the Postgres major changed, say so in `CHANGELOG.md` under a heading
   people will notice — it is a dump-and-restore for every existing user. See
   [operations.md](operations.md#postgres-major-upgrades).
