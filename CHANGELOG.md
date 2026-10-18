# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Upgrades that require a dump and restore are called out under a **Breaking**
heading. Anything that changes the Postgres major is one of those.

## [Unreleased]

## [0.1.0] — 2026-10-17

Initial release.

### Added

- **Helm chart** (`charts/mongo-cloud-pod`) with two engines behind one
  Service on 27017:
  - `ferretdb` (default) — FerretDB 2.x over PostgreSQL 17 with the DocumentDB
    extension. Apache-2.0 / PostgreSQL / MIT; no SSPL component, so a
    deployment may be offered to third parties as a service.
  - `mongodb-community` — MongoDB Community 8.x, gated behind
    `sspl.acknowledged: true`. For first-party self-hosted use and for parity
    testing.
- Generated password on first install, read back from the live Secret on
  upgrade so an upgrade never rotates a running application's credential.
- `auth.existingSecret` for platforms that mint their own credentials.
- Backup CronJob (`pg_dump` or `mongodump`) to a PVC or S3-compatible storage,
  with retention, a zero-byte-dump guard, and a documented restore path.
- Hardening by default: non-root, all capabilities dropped, no privilege
  escalation, `RuntimeDefault` seccomp, no ServiceAccount token, read-only root
  filesystem on the gateway, default-deny NetworkPolicy on 27017.
- Optional Prometheus `ServiceMonitor` on a separate, non-public Service.
- `helm test` hook performing a real insert/index/aggregate/update/delete
  round-trip over the wire protocol.
- **Kustomize manifests** (`k8s/`) generated from the chart by
  `scripts/render-manifests.sh`, with development and production overlays. CI
  fails if the generated output drifts from the chart.
- **Platform descriptor** (`pod.yaml`) — images, ports, env vars, data paths,
  probes, connection-string templates and backup commands, for platforms that
  provision from a catalog rather than by running Helm.
- **Docker Compose** stack for local development, with a
  `mongodb-community` profile for side-by-side comparison.
- **Argo CD** Application example.
- `scripts/verify-licenses.sh` — fails if a default render contains an SSPL
  image, if the storage image lacks the DocumentDB extension, or if the SSPL
  gate stops rejecting unacknowledged installs. Runs in CI and again at
  release.
- `scripts/check-eol.sh` — fails when an offered image is within 180 days of
  its upstream end of life. Runs weekly.
- Documentation: licensing rationale, compatibility matrix, architecture,
  operations runbook, version policy, and a Launchmatic integration guide.

### Known limitations

The default engine does not support change streams, sharding, `$out`/`$merge`,
GridFS, server-side JavaScript, or capped collections. See
[docs/compatibility.md](docs/compatibility.md) before migrating.

[Unreleased]: https://github.com/PrincipalForce/mongo-cloud-pod/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/PrincipalForce/mongo-cloud-pod/releases/tag/v0.1.0
