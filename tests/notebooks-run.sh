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
#
# The AI Lab notebook (AC-DS1.4): after the kit's notebooks (or alone, or not
# at all - EXAKIT_NOTEBOOK_AI_LAB=1|only|0, 1 unless a notebook is named on the
# command line), one example notebook exasol-notebook-connector 3.1.0 ships
# (exasol/nb_connector/resources/notebooks/, what `ai-lab start` deploys) is
# run as shipped - a copy in a temporary folder, its bytes checked against the
# package's after the run - on the kit's kernel from the kit's store. Every AI
# Lab notebook opens its store with a widget (a path and a password typed in,
# an Open button that pushes `ai_lab_config` into the kernel), which nobody
# can click headless, so the run starts with one cell that does what that
# button does - `ai_lab_config` opened on the kit's store - and then runs the
# notebook's own cells, unchanged, in order. Default: first_steps.ipynb
# (EXAKIT_AI_LAB_NOTEBOOK names another, relative to that folder) through its
# connection cell (`jupysql.init(ai_lab_config)`; EXAKIT_AI_LAB_CELLS=all runs
# every cell, which for first_steps needs the Internet: its data is imported
# from a public CSV and an S3 bucket). The connector ships no example that
# runs on the local database alone, so the connection cell is the check.
#
#   EXAKIT_NOTEBOOK_AI_LAB       1 (default), only, or 0
#   EXAKIT_AI_LAB_NOTEBOOK       the notebook, under the connector's resources/notebooks/ (default first_steps.ipynb)
#   EXAKIT_AI_LAB_CELLS          connect (default: through the connection cell) or all

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
AI_LAB="${EXAKIT_NOTEBOOK_AI_LAB:-1}"
[ $# -gt 0 ] && [ "$AI_LAB" = 1 ] && AI_LAB=0        # named notebooks: only those
_out=""
[ -n "${EXAKIT_NOTEBOOK_RUN_OUTPUT:-}" ] && { mkdir -p "$EXAKIT_NOTEBOOK_RUN_OUTPUT"; _out="--output $EXAKIT_NOTEBOOK_RUN_OUTPUT"; }
rc=0
if [ "$AI_LAB" != only ]; then
    set -- "$@"
    _args=""
    for _ds in $DATASETS; do _args="$_args --dataset $_ds"; done
    # shellcheck disable=SC2086
    "$NB_PY" "$ROOT/tools/notebooks.py" --run "$@" $_args --timeout "${EXAKIT_NOTEBOOK_CELL_TIMEOUT:-900}" $_out
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "PASS every notebook ran on: $DATASETS"
    else
        echo "FAIL (exit $rc): see the failing cell above" >&2
    fi
fi

# --- the AI Lab notebook, as the connector ships it (AC-DS1.4) --------------------
# tools/notebooks.py's execute() runs it: the same nbclient on the same kernel,
# the same environment (LANGFUSE_* dropped) and a temporary working folder, as
# the kit's notebooks above. The .ipynb is taken as a file (--run builds from
# .py sources), so the notebook is never rebuilt, rewritten or tagged: the
# bytes that ran are the bytes the package ships, and the run checks that.
if [ "$AI_LAB" != 0 ]; then
    "$NB_PY" - "$ROOT" "${EXAKIT_AI_LAB_NOTEBOOK:-first_steps.ipynb}" "${EXAKIT_AI_LAB_CELLS:-connect}" \
        "${EXAKIT_NOTEBOOK_CELL_TIMEOUT:-900}" "${EXAKIT_NOTEBOOK_RUN_OUTPUT:-}" <<'PY'
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

root, name, cells_mode, timeout, output = sys.argv[1:6]
sys.path.insert(0, str(Path(root) / "tools"))
import notebooks                                    # noqa: E402  the kit's headless runner (execute, KERNEL)
import exasol.nb_connector.resources as resources   # noqa: E402  the AI Lab notebooks live in this package

CONNECT = "jupysql.init(ai_lab_config)"             # every AI Lab notebook's connection cell
shipped = Path(resources.__file__).parent / "notebooks" / name
label = f"AI Lab {name}"
if not shipped.is_file():
    print(f"FAIL {label}: the connector ships no such notebook under {shipped.parent}")
    sys.exit(2)
kernel = os.environ.get("EXAKIT_NOTEBOOK_KERNEL") or notebooks.KERNEL["name"]
digest = hashlib.sha256(shipped.read_bytes()).hexdigest()
# What the notebook's own access-store widget does when its Open button is
# clicked: ai_lab_config, a Secrets on the store, pushed into the kernel. The
# store is the kit's (the kernel's environment names it, as the kit's helpers
# read it); the password is read from its file, never printed.
opener = {"cell_type": "code", "metadata": {"tags": ["exakit-store"]}, "outputs": [], "execution_count": None,
          "source": ["# exakit: what the Open button of the access-store widget below does, for a run with nobody at it\n",
                     "from pathlib import Path\n",
                     "from exakit_nb._kit import setting\n",
                     "from exasol.nb_connector.secret_store import Secrets\n",
                     "ai_lab_config = Secrets(Path(setting('EXAKIT_NB_STORE')), "
                     "Path(setting('EXAKIT_NB_MASTER_FILE')).read_text(encoding='utf-8').strip())\n"]}
with tempfile.TemporaryDirectory(prefix="exakit-ai-lab-") as folder:
    copy = Path(folder) / shipped.name
    shutil.copyfile(shipped, copy)
    beside = shipped.with_suffix("")                # first_steps/ holds the files first_steps.ipynb reads
    if beside.is_dir():
        shutil.copytree(beside, Path(folder) / beside.name)
    doc = json.loads(copy.read_text(encoding="utf-8"))
    cells = doc["cells"]
    if cells_mode == "all":
        last, through = len(cells) - 1, "every cell"
    else:
        last = next((i for i, c in enumerate(cells) if c["cell_type"] == "code" and CONNECT in "".join(c["source"])), None)
        if last is None:
            print(f"FAIL {label}: no cell holds {CONNECT}, so there is no connection cell to run")
            sys.exit(2)
        through = f"its cells 0-{last}, through the connection cell"
    doc["cells"] = [opener] + cells[: last + 1]
    code = sum(c["cell_type"] == "code" for c in cells[: last + 1])
    print(f"run  {label}: {through} ({code} code cells, after the store-opening cell) on kernel {kernel}, in {folder}",
          flush=True)
    started = time.monotonic()
    try:
        executed, problem = notebooks.execute(doc, kernel, Path(folder), int(timeout))
    except Exception as broken:                     # not a cell: the kernel
        print(f"FAIL {label}: the run on kernel {kernel!r} did not finish ({type(broken).__name__}: {broken})")
        sys.exit(2)
    seconds = time.monotonic() - started
    unchanged = hashlib.sha256(copy.read_bytes()).hexdigest() == digest
if output:
    target = Path(output) / "ai-lab" / shipped.name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(executed, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
if problem:
    print(f"FAIL {label} after {seconds:.0f}s (cell 0 is the store-opening cell, so the notebook's own cell k is "
          f"cell k+1 here): {problem}", flush=True)
    sys.exit(1)
if not unchanged:
    print(f"FAIL {label}: the notebook changed while it ran (its bytes differ from the package's)")
    sys.exit(1)
print(f"ok   {label} ({through}, unchanged, {seconds:.0f}s)")
PY
    ai_rc=$?
    if [ "$ai_rc" -eq 0 ]; then
        echo "PASS the AI Lab notebook ran as the connector ships it"
    else
        echo "FAIL (exit $ai_rc): the AI Lab notebook, see above" >&2
        [ "$rc" -eq 0 ] && rc="$ai_rc"
    fi
fi
exit "$rc"
