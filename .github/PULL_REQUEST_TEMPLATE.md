## What this changes

<!-- One or two sentences. -->

## Why

<!-- The problem, not the patch. -->

## Impact on existing deployments

<!-- Delete what doesn't apply. -->
- [ ] No impact — new installs behave identically
- [ ] Rolling restart only
- [ ] Requires a dump and restore (**add a Breaking entry to CHANGELOG.md**)
- [ ] Changes a default value (say which, and what it was)

## Checks

- [ ] `helm lint charts/mongo-cloud-pod`
- [ ] Rendered with **both** engines, not just the default
- [ ] `./scripts/verify-licenses.sh` passes — no SSPL in the default path
- [ ] `./scripts/check-eol.sh` passes (if versions changed)
- [ ] `./scripts/render-manifests.sh` run and `k8s/base` committed (if the chart changed)
- [ ] `helm test` passes against a real cluster (if the chart changed)
