#!/usr/bin/env bash
# Fail when an image this project offers as a `default` is within
# `eolWarningDays` of its upstream end-of-life.
#
# The point is lead time. An expiring dependency should surface as a CI failure
# months before patches stop, while there is room to pick a successor, test a
# provision and ship it — not on the morning a CVE lands against a version
# nobody is patching any more.
#
#   ./scripts/check-eol.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="${REPO_ROOT}/versions.yaml"

command -v python3 >/dev/null 2>&1 && PY=python3 || PY=python
"${PY}" - "${VERSIONS}" <<'PYEOF'
import datetime
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    spec = yaml.safe_load(fh)

warn_days = spec.get("eolWarningDays", 180)
today = datetime.date.today()
problems = []
checked = 0

for engine_name, engine in spec["engines"].items():
    for comp_name, comp in engine["components"].items():
        defaults = [v for v in comp["versions"] if v["status"] == "default"]
        # Exactly one default per component, or resolution is ambiguous and
        # two call sites can disagree about what "the default" means.
        if len(defaults) != 1:
            problems.append(
                f"{engine_name}/{comp_name}: expected exactly one 'default' "
                f"version, found {len(defaults)}"
            )
        for version in comp["versions"]:
            checked += 1
            eol = datetime.date.fromisoformat(version["eol"])
            days = (eol - today).days
            label = f"{engine_name}/{comp_name} {version['image']}"
            if version["status"] == "deprecated":
                # Deprecated entries exist so that an already-running
                # deployment pinned to them still resolves. Their EOL is
                # expected to pass; that is what deprecating them was for.
                continue
            if days < 0:
                problems.append(f"{label}: EOL {version['eol']} has passed ({-days} days ago)")
            elif days < warn_days:
                problems.append(f"{label}: EOL {version['eol']} is {days} days away (< {warn_days})")

print(f"checked {checked} image versions against {today.isoformat()}")

if problems:
    print()
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("Pick a successor version, add it to versions.yaml with status")
    print("'default', demote the current one to 'deprecated', and update the")
    print("chart's default image tag. See docs/versions.md.")
    sys.exit(1)

# ASCII only: this runs on developer machines too, and a Windows
# console in cp1252 raises UnicodeEncodeError on a checkmark.
print("OK: every offered version is comfortably inside its support window")
PYEOF
