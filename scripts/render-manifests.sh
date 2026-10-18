#!/usr/bin/env bash
# Regenerate the plain-manifest (Kustomize) base from the Helm chart.
#
# The chart is the single source of truth. Hand-maintaining a second copy of
# the same StatefulSets is how the two end up disagreeing six months later, so
# k8s/base is generated and CI fails if the committed output no longer matches
# what the chart renders (see .github/workflows/ci.yml).
#
#   ./scripts/render-manifests.sh          # regenerate and write
#   ./scripts/render-manifests.sh --check  # fail if regeneration would change
#
# The rendered Secret contains a placeholder password, deliberately: a
# generated password would make every render differ, and a checked-in real one
# would be worse. Overlays replace it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_ROOT}/charts/mongo-cloud-pod"
OUT="${REPO_ROOT}/k8s/base/mongo-cloud-pod.yaml"

# Fixed inputs so the output is byte-stable across machines and runs.
RELEASE="mongo-cloud-pod"
NAMESPACE="mongo-cloud-pod"
PLACEHOLDER_PASSWORD="REPLACE_ME_BEFORE_APPLY"

check=false
[[ "${1:-}" == "--check" ]] && check=true

command -v helm >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }

render() {
  cat <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# GENERATED FILE — DO NOT EDIT.
#
# Produced by scripts/render-manifests.sh from charts/mongo-cloud-pod.
# Edit the chart and re-run the script; CI rejects a hand-edited copy.
#
# The password below is a placeholder. k8s/overlays/* replace the Secret, and
# applying this base as-is gives you a database whose password is literally
# "${PLACEHOLDER_PASSWORD}".
# ─────────────────────────────────────────────────────────────────────────────
EOF
  helm template "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    --set "auth.password=${PLACEHOLDER_PASSWORD}" \
    --set tests.enabled=false \
    --skip-tests
}

if [[ "${check}" == true ]]; then
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' EXIT
  render > "${tmp}"
  if ! diff -u "${OUT}" "${tmp}"; then
    echo >&2
    echo "k8s/base is stale. Run ./scripts/render-manifests.sh and commit." >&2
    exit 1
  fi
  echo "k8s/base is up to date with the chart."
else
  mkdir -p "$(dirname "${OUT}")"
  render > "${OUT}"
  echo "wrote ${OUT}"
fi
