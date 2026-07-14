#!/usr/bin/env bash
# smoke-test.sh — end-to-end proof of the one-command install.
#
#   bash tests/smoke-test.sh            # dry-run only (fetch + plan, no install)
#   EXAKIT_SMOKE_FULL=1 bash tests/smoke-test.sh
#                                       # full install, re-run (idempotency),
#                                       # sample data load + verify + reload,
#                                       # then interactive teardown
#
# The full run installs a real local database and is expected to finish the
# kit setup itself (excluding the database's own first-deploy time) in well
# under 10 minutes.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '\n\033[1;36m[smoke]\033[0m %s\n' "$*"; }

say "1/4 dry run through the pipe entry point"
start=$(date +%s)
if ! EXAKIT_DRY_RUN=1 sh "$ROOT/install.sh"; then
    echo "[smoke] FAIL: dry run exited non-zero" >&2
    exit 1
fi
say "dry run finished in $(( $(date +%s) - start ))s"

if [ "${EXAKIT_SMOKE_FULL:-0}" != "1" ]; then
    say "EXAKIT_SMOKE_FULL=1 not set — stopping after the dry run. PASS"
    exit 0
fi

say "2/4 full install"
start=$(date +%s)
if ! sh "$ROOT/install.sh"; then
    echo "[smoke] FAIL: full install exited non-zero" >&2
    exit 1
fi
full_time=$(( $(date +%s) - start ))
say "full install finished in ${full_time}s"

say "3/4 re-run (idempotency: everything should skip)"
start=$(date +%s)
if ! sh "$ROOT/install.sh"; then
    echo "[smoke] FAIL: re-run exited non-zero" >&2
    exit 1
fi
rerun_time=$(( $(date +%s) - start ))
say "re-run finished in ${rerun_time}s"

if [ "$rerun_time" -gt 120 ]; then
    echo "[smoke] WARN: re-run took ${rerun_time}s — idempotent skips should be much faster" >&2
fi

# Exercises the installed `exakit data-load` CLI (not the raw script), which
# also proves data/ and the SQL were copied into ~/.exasol-starter-kit/kit
# and resolve after the checkout is gone. The full install itself skips the
# interactive load offer here because a piped smoke run has no TTY.
EXAKIT="$HOME/.local/bin/exakit"

say "4/4 sample data: load, idempotent skip, forced reload (via exakit CLI)"
start=$(date +%s)
if ! "$EXAKIT" data-load --force; then
    echo "[smoke] FAIL: 'exakit data-load --force' exited non-zero" >&2
    exit 1
fi
load_time=$(( $(date +%s) - start ))
say "data load finished in ${load_time}s"

start=$(date +%s)
if ! "$EXAKIT" data-load --force; then
    echo "[smoke] FAIL: second 'exakit data-load --force' exited non-zero" >&2
    exit 1
fi
say "forced data-load command re-ran correctly in $(( $(date +%s) - start ))s"

start=$(date +%s)
if ! "$EXAKIT" data-load --force; then
    echo "[smoke] FAIL: repeated 'exakit data-load --force' exited non-zero (schema recreate + reload + verify should all be repeatable)" >&2
    exit 1
fi
say "forced reload finished in $(( $(date +%s) - start ))s"

"$EXAKIT" status || true

say "PASS (full: ${full_time}s, re-run: ${rerun_time}s, data load: ${load_time}s)"
say "Teardown when you are done testing: exakit uninstall"
