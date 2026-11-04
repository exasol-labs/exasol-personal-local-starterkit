#!/usr/bin/env bash
# ci-wiring.sh - every test in tests/ is run by a workflow: a suite no workflow names is a suite nobody runs, and
# test_ml_train sat red for weeks that way (audit QAT-01).
#
#   bash tests/ci-wiring.sh
#
# A Python suite counts when a workflow names it, or a `unittest discover -p` pattern there matches it; a shell or
# PowerShell test when a workflow names its file. tests/lib/ holds helpers, not suites.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Run by hand on purpose, each with its reason: a real install from the network, a live database.
MANUAL="marketplace-e2e.sh model-live-check.sh"
workflows="$(cat "$ROOT"/.github/workflows/*.yml)"
patterns="$(printf '%s\n' "$workflows" | sed -n "s/.*unittest discover .*-p '\([^']*\)'.*/\1/p")"
missing=""
for path in "$ROOT"/tests/test_*.py "$ROOT"/tests/*.sh "$ROOT"/tests/*.ps1; do
    [ -e "$path" ] || continue
    name="$(basename "$path")"
    case " ci-wiring.sh $MANUAL " in *" $name "*) continue ;; esac
    case "$workflows" in *"$name"*|*"${name%.py}"*) continue ;; esac
    matched=0
    for pattern in $patterns; do
        # shellcheck disable=SC2254
        case "$name" in $pattern) matched=1 ;; esac
    done
    [ "$matched" = 1 ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
    echo "Tests no workflow runs:$missing"
    echo "Add each to .github/workflows (versions.yml lists the suites by shard)."
    exit 1
fi
echo "ci-wiring.sh: every test in tests/ is run by a workflow"
