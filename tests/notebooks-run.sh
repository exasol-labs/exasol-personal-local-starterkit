#!/usr/bin/env bash
# notebooks-run.sh — the kit's notebooks executed headless against the local
# database, on both reference datasets, with the text step on a stub model
# (AC-DS3.1, AC-ML3.1).
#
#   bash tests/notebooks-run.sh                       # every catalog notebook, pharma_trials and banking_complaints
#   bash tests/notebooks-run.sh notebook/notebooks/data-scientist/01_explore.py
#   EXAKIT_NOTEBOOK_DATASETS="pharma_trials" bash tests/notebooks-run.sh
#
# Needs an installed kit with a running database, the notebook add-on and the
# datasets loaded (the quickstarts load a missing one themselves). Without a
# database that answers it SKIPs (exit 0), like mcp-readonly-sql-matrix.sh and
# with its probe - a real query as the read-only user through an isolated
# exapump profile, because a port that answers is not a database that answers.
# With EXAKIT_REQUIRE_DB=1 (the CI job that deploys a database) a missing
# prerequisite is a FAILURE with exit 3: distinct from 1, which is what a
# notebook that did not run exits with, so a CI log never reads a silent skip
# as a pass and never mistakes "no database" for "a cell failed".
#
# What the run sees: EXAKIT_NB_MODEL / OPENAI_BASE_URL / OPENAI_API_KEY point at
# tests/lib/stub_model_server.py (started here on a free port, stopped at the
# end); LANGFUSE_* are dropped by --run; MLFLOW_TRACKING_URI passes through when
# set, else MLflow writes a local store in the run's temporary folder. Nothing
# is written in the tree. The executed notebooks, outputs included, land in
# EXAKIT_NOTEBOOK_RUN_OUTPUT when it is set (CI keeps them as an artifact).
#
#   EXAKIT_NOTEBOOK_DATASETS     space-separated ids (default: both reference datasets)
#   EXAKIT_NOTEBOOK_CELL_TIMEOUT seconds one cell may take (default 900)
#   EXAKIT_NOTEBOOK_RUN_OUTPUT   folder for the executed .ipynb files (default: none kept)
#   EXAKIT_NOTEBOOK_PYTHON       the kit's notebook Python (default: the manifest's, else EXAKIT_HOME/notebook-venv)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
CREDS="$EXAKIT_HOME/credentials"
MANIFEST="$EXAKIT_HOME/manifest.json"
DATASETS="${EXAKIT_NOTEBOOK_DATASETS:-pharma_trials banking_complaints}"

# The skip that CI can turn into a failure (tests/lib/require.sh explains why),
# with exit 3 rather than require.sh's 1: here 1 means a notebook failed.
skip() {
    if [ "${EXAKIT_REQUIRE_DB:-0}" = "1" ] || [ "${EXAKIT_REQUIRE_ALL:-0}" = "1" ]; then
        printf 'FAIL %s\n' "$1" >&2
        printf 'This environment declared EXAKIT_REQUIRE_DB=1, so a missing prerequisite is a failure, not a skip.\n' >&2
        exit 3
    fi
    printf 'SKIP %s\n' "$1"
    printf '  (set EXAKIT_REQUIRE_DB=1 to make this a failure instead)\n'
    exit 0
}

# --- the database answers: the same probe as mcp-readonly-sql-matrix.sh -------
EXAPUMP="$(command -v exapump || echo "$HOME/.local/bin/exapump")"
[ -x "$EXAPUMP" ] || skip "exapump not found (kit not installed)"
[ -f "$CREDS/mcp_readonly_password" ] || skip "no mcp_readonly credential (kit not installed)"
[ -f "$MANIFEST" ] || skip "no manifest at $MANIFEST"
DSN="$(grep -oE '"dsn"[[:space:]]*:[[:space:]]*"[^"]+"' "$MANIFEST" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
HOSTP="${DSN%%:*}"; PORTP="${DSN##*:}"
HOSTP="${HOSTP:-127.0.0.1}"; PORTP="${PORTP:-8563}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/exakit-nb-run.XXXXXX")"
STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/.exapump"
printf '[mcpro]\nhost = "%s"\nport = %s\nuser = "mcp_readonly"\npassword = "%s"\ntls = true\nvalidate_certificate = false\n' \
    "$HOSTP" "$PORTP" "$(cat "$CREDS/mcp_readonly_password")" > "$TMP/.exapump/config.toml"
chmod 600 "$TMP/.exapump/config.toml"
if ! printf 'SELECT 1;' | HOME="$TMP" "$EXAPUMP" sql -p mcpro >/dev/null 2>&1; then
    skip "the database did not answer a query as mcp_readonly at $HOSTP:$PORTP (start it with: exakit start)"
fi

# --- the notebook add-on: its Python, its kernel, nbclient -------------------
NB_PY="${EXAKIT_NOTEBOOK_PYTHON:-}"
if [ -z "$NB_PY" ]; then
    NB_PY="$(grep -oE '"python"[[:space:]]*:[[:space:]]*"[^"]+notebook-venv[^"]+"' "$MANIFEST" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
fi
[ -n "$NB_PY" ] || NB_PY="$EXAKIT_HOME/notebook-venv/bin/python"
[ -x "$NB_PY" ] || skip "the notebook add-on is not installed (no $NB_PY): exakit marketplace notebook"
if ! "$NB_PY" -c 'import nbclient, nbformat' >/dev/null 2>&1; then
    skip "nbclient is not in the kit's notebook environment - add it with: uv pip install --python $NB_PY nbclient"
fi
if ! "$NB_PY" -c 'import exakit.nb' >/dev/null 2>&1; then
    skip "exakit.nb does not import with $NB_PY: exakit notebook check"
fi

# --- the stub model endpoint ---------------------------------------------------
"$NB_PY" "$ROOT/tests/lib/stub_model_server.py" --port 0 --quiet > "$TMP/stub.out" 2> "$TMP/stub.err" &
STUB_PID=$!
PORT=""
_i=0
while [ "$_i" -lt 40 ]; do
    PORT="$(sed -n 's/^port=//p' "$TMP/stub.out" 2>/dev/null | head -1)"
    [ -n "$PORT" ] && break
    kill -0 "$STUB_PID" 2>/dev/null || break
    sleep 0.25
    _i=$((_i + 1))
done
if [ -z "$PORT" ]; then
    echo "FAIL the stub model server did not start: $(cat "$TMP/stub.err" 2>/dev/null | tail -3)" >&2
    exit 1
fi
export EXAKIT_NB_MODEL="stub" OPENAI_BASE_URL="http://127.0.0.1:$PORT/v1" OPENAI_API_KEY="stub-key"
echo "stub model endpoint on $OPENAI_BASE_URL (tests/lib/stub_model_server.py)"
echo "database $HOSTP:$PORTP answers; notebook Python: $NB_PY"
if [ -n "${MLFLOW_TRACKING_URI:-}" ]; then
    echo "MLflow runs go to MLFLOW_TRACKING_URI (set by the caller)"
else
    echo "MLflow runs go to a local store in each run's temporary folder (MLFLOW_TRACKING_URI unset)"
fi

# --- the run -------------------------------------------------------------------
set -- "$@"
_args=""
for _ds in $DATASETS; do _args="$_args --dataset $_ds"; done
_out=""
[ -n "${EXAKIT_NOTEBOOK_RUN_OUTPUT:-}" ] && { mkdir -p "$EXAKIT_NOTEBOOK_RUN_OUTPUT"; _out="--output $EXAKIT_NOTEBOOK_RUN_OUTPUT"; }
# shellcheck disable=SC2086
"$NB_PY" "$ROOT/tools/notebooks.py" --run "$@" $_args --timeout "${EXAKIT_NOTEBOOK_CELL_TIMEOUT:-900}" $_out
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "PASS every notebook ran on: $DATASETS"
else
    echo "FAIL (exit $rc): see the failing cell above" >&2
fi
exit "$rc"
