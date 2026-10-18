# Contributing

Thanks for looking. This is a small project with a narrow purpose: a
MongoDB-compatible database for Kubernetes that an operator can run, and offer,
without SSPL obligations.

## What's in scope

- Chart correctness and hardening, Kustomize/Compose parity, backup and restore
  paths, documentation, and compatibility findings.
- Support for additional consumption surfaces (Flux, Terraform, a platform
  descriptor field you need).

## What's out of scope

- **Changes that put an SSPL image in the default path.** The default engine
  carrying no SSPL component is the entire premise;
  `scripts/verify-licenses.sh` enforces it and will reject the PR.
- **Vendoring upstream source.** This repository deploys FerretDB, DocumentDB
  and Postgres; it does not fork them. Protocol and storage bugs belong
  upstream — we will help you work out which one.
- **An operator/CRD.** See the closing section of [docs/architecture.md](docs/architecture.md)
  for why; if you disagree, open an issue before writing code.

## Setting up

```bash
git clone https://github.com/PrincipalForce/mongo-cloud-pod.git
cd mongo-cloud-pod
cp .env.example .env
docker compose up -d
./scripts/smoke-test.sh
```

You need `helm` 3.14+, `kubectl`, Docker, and `mongosh` for the smoke test. A
local cluster (kind, k3d, minikube) is needed only for chart changes.

## Before you open a PR

Run what CI runs:

```bash
helm lint charts/mongo-cloud-pod
./scripts/verify-licenses.sh      # no SSPL in the default render, gate intact
./scripts/check-eol.sh            # offered versions still supported
./scripts/render-manifests.sh     # regenerate k8s/base, then commit it
kubectl kustomize k8s/overlays/production > /dev/null
```

And against a real cluster, for chart changes:

```bash
helm install pod charts/mongo-cloud-pod -n test --create-namespace --wait
helm test pod -n test
```

### Chart changes specifically

- `k8s/base` is **generated**. Edit the chart and re-run
  `./scripts/render-manifests.sh`; CI rejects a hand-edited copy.
- Render every engine, not just the default. Several bugs have been
  engine-specific, and `helm lint` renders default values only.
- Watch for duplicate YAML keys when overriding a block from `values.yaml`.
  Helm and the API server accept them; `kubectl kustomize` does not, and the
  last one silently wins. Use `merge` rather than appending a key.
- Probe `exec` commands get no `$(VAR)` expansion from the container's
  environment — only `command` and `args` do.
- If you add a value that can be set to something incoherent, make it fail at
  render time in `mongo-cloud-pod.validate` with a message that says what to do
  instead. A CrashLoopBackOff twenty minutes later is a worse teacher.

### Version bumps

Follow [docs/versions.md](docs/versions.md). New images need an upstream EOL
date; the guard test depends on it.

## Commit and PR style

Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`). In the PR, say what
breaks for an existing deployment, if anything — upgrades that need a
dump-and-restore must be called out in `CHANGELOG.md`.

## Reporting compatibility gaps

Include the smallest `mongosh` snippet that reproduces it, what MongoDB does,
what this does, and your chart version. If it is something
[docs/compatibility.md](docs/compatibility.md) lists as supported, it is a bug
here. If it is listed as unsupported, open the issue anyway — upstream
prioritises by demand.

## Licence

Apache-2.0. By contributing, you agree your contribution is licensed under it.
No CLA.
