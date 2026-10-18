#!/usr/bin/env bash
# The claim this project makes is that its default deployment contains no SSPL
# component. This script is what keeps that claim true.
#
# It renders the chart with default values and fails if any resulting container
# image is a MongoDB Inc. distribution of the server. An innocuous-looking
# values change — swapping the gateway image, "simplifying" the storage image
# back to stock postgres — would otherwise silently break either the licence
# claim or the deployment itself.
#
#   ./scripts/verify-licenses.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_ROOT}/charts/mongo-cloud-pod"

command -v helm >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }

fail=0
note() { printf '  %s\n' "$*"; }

# Images that may never appear in a default render. Matched as substrings
# against the full image reference.
SSPL_IMAGES=(
  "mongo:"
  "mongodb/mongodb-community-server"
  "percona/percona-server-mongodb"   # Percona's server is SSPL too
  "bitnami/mongodb"
)

echo "→ rendering chart with default values"
images="$(helm template verify "${CHART}" --skip-tests \
  | grep -E '^\s+image:' \
  | sed -E 's/^\s+image:\s*//; s/^"//; s/"$//' \
  | sort -u)"

echo "  images in a default deployment:"
while IFS= read -r img; do
  [[ -z "${img}" ]] && continue
  note "- ${img}"
done <<< "${images}"

echo "→ checking for SSPL components"
while IFS= read -r img; do
  [[ -z "${img}" ]] && continue
  for bad in "${SSPL_IMAGES[@]}"; do
    if [[ "${img}" == *"${bad}"* ]]; then
      echo "FAIL: ${img} is an SSPL-licensed MongoDB distribution and must not" >&2
      echo "      appear in a default render. The default engine exists so that" >&2
      echo "      a deployment can be offered as a service; see docs/licensing.md." >&2
      fail=1
    fi
  done
done <<< "${images}"

# The storage image must carry the DocumentDB extension. Stock postgres passes
# the SSPL check above while producing a database where every write fails, so
# the licence check alone is not sufficient.
echo "→ checking storage image provides the DocumentDB extension"
if ! grep -q "postgres-documentdb" <<< "${images}"; then
  echo "FAIL: no postgres-documentdb image in the default render. FerretDB 2.x" >&2
  echo "      requires the DocumentDB extension; stock postgres will start and" >&2
  echo "      then fail every write." >&2
  fail=1
fi

# The SSPL engine must stay behind its gate.
echo "→ checking the SSPL engine refuses to render without acknowledgement"
if helm template verify "${CHART}" --set engine=mongodb-community >/dev/null 2>&1; then
  echo "FAIL: engine=mongodb-community rendered without sspl.acknowledged=true." >&2
  echo "      The licence gate in templates/_helpers.tpl is not working." >&2
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "✓ default deployment is free of SSPL components, and the SSPL engine is gated"
else
  exit 1
fi
