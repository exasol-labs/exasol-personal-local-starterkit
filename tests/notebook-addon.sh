#!/usr/bin/env bash
# notebook-addon.sh — the notebook add-on's own behaviour in
# setup/lib/notebook.sh (the generic marketplace layer is tests/marketplace.sh).
#
#   bash tests/notebook-addon.sh
#
# What it pins:
#   - one uv resolution: the connector pinned with its extras, the companion
#     packages, and the two packages the kit carries (exakit.nb, exasol-mlflow);
#     the front ends the kit installs at their versions.json pins (JupyterLab
#     through the connector's jupyter extra), which an update follows
#   - the kit's notebooks are copied once into their persona folders (Jupyter
#     and Marimo); one the user already has is never overwritten
#   - the notebook tools are one checklist, all three ticked; the variables
#     answer it; Positron is configured (settings kept, bad JSON left alone)
#   - `exakit notebook` refuses an unknown option and a bad --port, and says so
#     before touching anything when the add-on is not installed
#   - an uninstall keeps the user's notebooks, and its dry run says so
#   - the shipped notebooks, helpers and kit scripts name no address and no
#     credential, the scripts compile, and each .ipynb is built from its .py
#
# A sandboxed kit home; no database, no network, no real venv.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"


check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin" EXAKIT_EXAPUMP_CONFIG_DIR="$WORK/home/.exapump"
unset EXAKIT_NOTEBOOK_VENV EXAKIT_NOTEBOOK_HOME EXAKIT_NOTEBOOK_DIR EXAKIT_UNINSTALL_NOTEBOOKS EXAKIT_MARIMO_PORT
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1
# Whatever a check below leaves running goes when the suite ends.
cleanup() {
    for _cl_pidfile in "$EXAKIT_HOME/notebook/jupyter.pid" "$EXAKIT_HOME/notebook/marimo.pid"; do
        [ -f "$_cl_pidfile" ] && kill "$(cat "$_cl_pidfile")" 2>/dev/null
    done
    pkill -f "$WORK/kit/notebook-venv/bin/" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "the install is one pinned resolution:"
EXAKIT_NOTEBOOK_VERSION="3.1.0"
specs="$(_notebook_specs)"
check "the connector, pinned, with its extras (notebook-dependencies: ipywidgets, ipyfilechooser, matplotlib, wordcloud, stopwatch.py - the AI Lab notebooks' first cell)" \
    "exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy,notebook-dependencies]==3.1.0" "$(printf '%s\n' "$specs" | head -1)"
contains "the kernel package" "ipykernel>=6.29,<8" "$specs"
contains "the client model library matches the container" "scikit-learn==1.9.0" "$specs"
contains "the MLflow client, not the server" "mlflow-skinny>=3,<4" "$specs"
contains "Langfuse SDK major 5" "langfuse>=5,<6" "$specs"
check "the kit's helper package" "$ROOT/notebook/package" "$(printf '%s\n' "$specs" | tail -2 | head -1)"
check "the kit's MLflow client package" "$ROOT/packages/exasol-mlflow" "$(printf '%s\n' "$specs" | tail -1)"
check "JupyterLab is not in it" "" "$(printf '%s\n' "$specs" | grep -i jupyterlab || true)"
check "Marimo is not in it" "" "$(printf '%s\n' "$specs" | grep -i marimo || true)"

echo "the front ends are pinned in versions.json and join the one resolution:"
PIN_J="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["notebook"]["frontends"]["jupyterlab"])' "$ROOT/versions.json")"
PIN_M="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["notebook"]["frontends"]["marimo"])' "$ROOT/versions.json")"
check "the JupyterLab pin is read from versions.json" "$PIN_J" "$(notebook_frontend_pin jupyterlab)"
check "the Marimo pin is read from versions.json" "$PIN_M" "$(notebook_frontend_pin marimo)"
check "EXAKIT_NOTEBOOK_MARIMO_VERSION outranks the pin" "0.26.1" "$(EXAKIT_NOTEBOOK_MARIMO_VERSION=0.26.1 notebook_frontend_pin marimo)"
check "a pin outside the safe charset is no pin" "1" "$(EXAKIT_NOTEBOOK_MARIMO_VERSION='1; rm' notebook_frontend_pin marimo >/dev/null; echo $?)"
specs="$(NOTEBOOK_ADD_JUPYTERLAB=1 _notebook_specs)"
check "JupyterLab ticked: the connector's jupyter extra, no separate spec" \
    "exasol-notebook-connector[bucketfs,ibis,pyexasol,sqlalchemy,notebook-dependencies,jupyter]==3.1.0" "$(printf '%s\n' "$specs" | head -1)"
check "and its version held by the pin" "jupyterlab==$PIN_J" "$(printf '%s\n' "$specs" | grep '^jupyterlab')"
check "Marimo ticked: marimo at its pin" "marimo==$PIN_M" "$(NOTEBOOK_ADD_MARIMO=1 _notebook_specs | grep '^marimo')"
check "Marimo with no pin is left out, and said" "|1" \
    "$( (notebook_frontend_pin() { return 1; }; NOTEBOOK_ADD_MARIMO=1 _notebook_specs 2>"$WORK/pin.err" | grep '^marimo'; printf '|%s' "$(grep -c 'No Marimo version is pinned' "$WORK/pin.err")") )"
check "tools/notebooks.py converts with the Marimo the add-on installs" "marimo==$(notebook_frontend_pin marimo)" \
    "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import notebooks; print(notebooks.marimo_pin())' "$ROOT/tools")"
check "ticked tools, no JupyterLab of the user's: the kit brings both" "1 1" \
    "$( (NOTEBOOK_FRONT_ENDS=jupyterlab,marimo; notebook_find_jupyter() { return 1; }; notebook_plan_front_ends; printf '%s %s' "$NOTEBOOK_ADD_JUPYTERLAB" "$NOTEBOOK_ADD_MARIMO") )"
check "the user's own JupyterLab is used, not installed" "0 0" \
    "$( (NOTEBOOK_FRONT_ENDS=jupyterlab,positron; notebook_find_jupyter() { echo "own /usr/local/bin/jupyter-lab"; }; notebook_plan_front_ends; printf '%s %s' "$NOTEBOOK_ADD_JUPYTERLAB" "$NOTEBOOK_ADD_MARIMO") )"

echo "notebooks are copied once, into persona folders, never over the user's:"
NB="$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks"
mkdir -p "$NB/data-scientist"
printf 'mine' > "$NB/data-scientist/00_quickstart.ipynb"
added="$(notebook_copy_notebooks | tr '\n' ' ')"
check "what is missing comes, each in its persona's folder, the shared cells too" \
    "00_shared/data_paths.ipynb data-scientist/01_explore.ipynb data-scientist/02_ask_your_data.ipynb data-scientist/03_share.ipynb ml-engineer/00_quickstart.ipynb ml-engineer/01_train.ipynb ml-engineer/03_score_external_model.ipynb " "$added"
check "the user's own stays" "mine" "$(cat "$NB/data-scientist/00_quickstart.ipynb")"
check "a second run adds nothing" "" "$(notebook_copy_notebooks)"
contains "a README names each persona's order" "00. \`ml-engineer/00_quickstart.ipynb\` - Quickstart" "$(cat "$NB/README.md")"
contains "under the persona's title" "## ml-engineer/ (ML Engineer)" "$(cat "$NB/README.md")"
contains "...the score notebook last on the ML Engineer's path" "03_score_external_model.ipynb" "$(cat "$NB/README.md")"
check "the README names no notebook this kit copy lacks" "" \
    "$(grep -o '[0-9][0-9]_[a-z_]*\.ipynb' "$NB/README.md" | sort -u | while read -r f; do find "$ROOT/notebook/notebooks" -name "$f" | grep -q . || printf ' %s' "$f"; done)"
check "every catalog entry ships its notebook (or its .py is not in the tree yet)" "" \
    "$(python3 "$ROOT/notebook/kit/notebooks.py" list "$ROOT" | while IFS='|' read -r _ p _ j m; do
        [ -f "$ROOT/notebook/notebooks/$p/${j%.ipynb}.py" ] || continue
        [ -z "$j" ] || [ -f "$ROOT/notebook/notebooks/$p/$j" ] || printf ' %s' "$j"
        [ -z "$m" ] || [ -f "$ROOT/notebook/marimo/$p/$m" ] || printf ' %s' "$m"; done)"
check "the personas' first prompts name quickstarts that ship" "" \
    "$(for p in data-scientist ml-engineer; do [ -f "$ROOT/notebook/notebooks/$p/00_quickstart.ipynb" ] || printf ' %s' "$p"
        grep -q "$p/00_quickstart.ipynb" "$ROOT/personas/$p.json" || printf ' %s-prompt' "$p"; done)"
check "the Marimo ones go to marimo/<persona>/, no README" \
    "00_shared/data_paths.py data-scientist/00_quickstart.py data-scientist/01_explore.py data-scientist/02_ask_your_data.py data-scientist/03_share.py ml-engineer/00_quickstart.py ml-engineer/01_train.py ml-engineer/03_score_external_model.py |no" \
    "$(notebook_copy_notebooks marimo | tr '\n' ' ')|$([ -e "$EXAKIT_NOTEBOOK_DIR/marimo/README.md" ] && echo yes || echo no)"

echo "the notebook tools: one checklist, all three ticked:"
check "without a terminal the ticks stand" "jupyterlab,marimo,positron" \
    "$( (unset EXAKIT_NOTEBOOK_FRONTENDS EXAKIT_NOTEBOOK_JUPYTER EXAKIT_NOTEBOOK_MARIMO; notebook_choose_front_ends >/dev/null 2>&1 </dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "EXAKIT_NOTEBOOK_MARIMO=skip leaves Marimo out" "jupyterlab,positron" \
    "$( (unset EXAKIT_NOTEBOOK_FRONTENDS; EXAKIT_NOTEBOOK_MARIMO=skip; notebook_choose_front_ends >/dev/null 2>&1 </dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "EXAKIT_NOTEBOOK_FRONTENDS answers it" "marimo,positron" \
    "$( (EXAKIT_NOTEBOOK_FRONTENDS="Marimo, positron"; notebook_choose_front_ends; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"

echo "Positron is configured, never installed:"
mkdir -p "$EXAKIT_NOTEBOOK_DIR/.vscode"
printf '{"editor.fontSize": 14}' > "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json"
notebook_prepare_positron
settings="$(cat "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json")"
contains "the folder names the kit's Python" "\"python.defaultInterpreterPath\": \"$(notebook_venv_python)\"" "$settings"
contains "the user's own settings stay" '"editor.fontSize": 14' "$settings"
printf '{not json' > "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json"
check "a file that is not JSON is left alone" "1|{not json" \
    "$(notebook_prepare_positron && echo 0 || echo 1)|$(cat "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json")"
check "no positron and no app: none found" "1" "$( (PATH=/usr/bin:/bin; HOME="$WORK/nohome"; notebook_find_positron >/dev/null && echo 0 || echo 1) )"

echo "exakit notebook refuses what it does not know:"
for args in "--frob" "--port" "--port abc" "--port 80" "--marimo --positron" "marimo positron" "jupyterlab marimo" "Marimo"; do
    # shellcheck disable=SC2086
    out="$( (notebook_cmd $args) 2>&1)"; rc=$?
    check "refuses: $args" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
done
out="$( (notebook_cmd --check) 2>&1)"
contains "not installed names the marketplace" "exakit marketplace notebook" "$out"

echo "an uninstall keeps the notebooks:"
out="$(notebook_uninstall 1 2>&1)"
contains "the dry run says so" "your notebooks stay in $EXAKIT_NOTEBOOK_DIR" "$out"
notebook_uninstall >/dev/null 2>&1
check "the notebooks are still there" "mine" "$(cat "$NB/data-scientist/00_quickstart.ipynb")"

echo "the copy: a notebook the user deleted stays deleted; one that cannot be copied is named:"
rm -f "$NB/data-scientist/01_explore.ipynb"
check "a deleted kit notebook is not copied again" "|no" "$(notebook_copy_notebooks)|$([ -e "$NB/data-scientist/01_explore.ipynb" ] && echo yes || echo no)"
COPYDIR="$WORK/copy-blocked"; mkdir -p "$COPYDIR/starter-kit-notebooks"
printf 'a file' > "$COPYDIR/starter-kit-notebooks/data-scientist"
out="$( (EXAKIT_NOTEBOOK_DIR="$COPYDIR"; notebook_copy_notebooks; echo "rc=$?") 2>&1)"
contains "a file where a persona folder should be is named" "could not copy data-scientist/00_quickstart.ipynb" "$out"
contains "the copy says it failed" "rc=1" "$out"
contains "the other personas are still copied" "ml-engineer/01_train.ipynb" "$out"
out="$( (EXAKIT_NOTEBOOK_DIR="$COPYDIR"; _notebook_report_copied "$COPYDIR/starter-kit-notebooks") 2>&1)"
contains "the command does not hide it" "could not be copied" "$out"
check "copy wants the notebooks folder named" "2" "$(python3 "$ROOT/notebook/kit/notebooks.py" copy jupyter "$ROOT" >/dev/null 2>&1; echo $?)"

echo "the notebook tools: a recorded choice stands, the variable is checked:"
check "names in any case, jupyter as jupyterlab, any whitespace, unknown ones dropped" "jupyterlab,positron|1" \
    "$(_notebook_front_ends_given "$(printf 'Jupyter\tPOSITRON ,frob')" 2>"$WORK/fe.err")|$(grep -c "'frob' is not a notebook tool" "$WORK/fe.err")"
check "none alone is none" "none" "$(_notebook_front_ends_given " none ")"
manifest_set components.notebook.front_ends "jupyterlab,positron"
check "a reinstall keeps the recorded choice" "jupyterlab,positron" \
    "$( (unset EXAKIT_NOTEBOOK_FRONTENDS; notebook_choose_front_ends >/dev/null 2>&1 </dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "the variable still overrides it" "marimo" \
    "$( (EXAKIT_NOTEBOOK_FRONTENDS="marimo"; notebook_choose_front_ends 2>/dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
check "a variable naming nothing known falls back to the record" "jupyterlab,positron" \
    "$( (EXAKIT_NOTEBOOK_FRONTENDS="frob"; notebook_choose_front_ends 2>/dev/null </dev/null; printf '%s' "$NOTEBOOK_FRONT_ENDS") )"
_notebook_front_end_add marimo
check "a tool added later joins the record" "jupyterlab,marimo,positron" "$(manifest_get components.notebook.front_ends)"
manifest_del components.notebook.front_ends

echo "an update reinstalls the kit's own packages, the connector pin unchanged:"
check "the kit's packages are reinstalled, in the same resolution" \
    "pip install --python $(notebook_venv_python) --reinstall-package exakit-nb --reinstall-package exasol-mlflow exasol-notebook-connector" \
    "$( (run_logged() { shift; printf '%s ' "$@"; }; _notebook_uv() { echo uv; }; detect_os() { echo macos; }
         notebook_sync_packages | cut -d'[' -f1) )"

echo "a front end the kit installed follows its pin through an update:"
UPV="$WORK/upvenv"; mkdir -p "$UPV/bin"
printf '#!/bin/sh\nexit 0\n' > "$UPV/bin/marimo"; cp "$UPV/bin/marimo" "$UPV/bin/jupyter-lab"; chmod +x "$UPV/bin/marimo" "$UPV/bin/jupyter-lab"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$UV_LOG"\n' > "$WORK/uv-stub"; chmod +x "$WORK/uv-stub"
update_with() { # update_with <log> [VAR=value ...] - exakit update notebook, the connector pin unchanged, uv stubbed
    _uw_log="$1"; shift
    ( export UV_LOG="$_uw_log" EXAKIT_NOTEBOOK_VENV="$UPV" "$@"
      _notebook_uv() { printf '%s\n' "$WORK/uv-stub"; }; detect_os() { echo macos; }; run_logged() { "$@"; }
      exakit_component_available() { echo 3.1.0; }; notebook_installed_version() { echo 3.1.0; }
      notebook_copy_notebooks() { :; }; notebook_register_kernel() { :; }; notebook_validate() { :; }
      notebook_update ) 2>&1
}
out="$(update_with "$WORK/uv1.log")"
contains "the update says the add-on is current" "already current" "$out"
check "its resolution keeps Marimo at the versions.json pin" "1" "$(grep -c "marimo==$PIN_M" "$WORK/uv1.log")"
check "and JupyterLab, through the connector's extra" "1|1" \
    "$(grep -c 'sqlalchemy,notebook-dependencies,jupyter\]==3.1.0' "$WORK/uv1.log")|$(grep -c "jupyterlab==$PIN_J" "$WORK/uv1.log")"
update_with "$WORK/uv2.log" EXAKIT_NOTEBOOK_MARIMO_VERSION=0.26.1 >/dev/null
check "a changed Marimo pin is what the update installs" "1|0" \
    "$(grep -c 'marimo==0.26.1' "$WORK/uv2.log")|$(grep -c "marimo==$PIN_M" "$WORK/uv2.log")"
check "the kit's own packages are reinstalled in the same call" "1" "$(grep -c -- '--reinstall-package exakit-nb --reinstall-package exasol-mlflow' "$WORK/uv2.log")"
rm -f "$UPV/bin/marimo" "$UPV/bin/jupyter-lab"
update_with "$WORK/uv3.log" >/dev/null
check "a front end the kit did not install stays out" "0|0" \
    "$(grep -c 'marimo==' "$WORK/uv3.log")|$(grep -c 'jupyter' "$WORK/uv3.log")"

echo "the store's write keeps its exit status:"
check "a failed write fails" "1" \
    "$( (manifest_get() { case "$1" in (runtime.dsn) echo h:8563 ;; (runtime.password_file) echo /x ;; esac; }
         _notebook_py() { echo partial; return 4; }; notebook_write_connection >/dev/null 2>&1; echo $?) )"

echo "the connection is re-read on every launch: a changed database port reaches the store (AC-DS1.5):"
# The launch path (_notebook_preflight, what exakit notebook runs before any
# server starts) writes the kit's recorded connection into the connector's
# store every time. Here the manifest's runtime.dsn changes between two
# launches - what a database moved to another port looks like (a language
# container install and a port change leave the kit's record as the only
# truth) - and write_store.py, stubbed, records the host:port it was handed.
# No database, no real store: the assertion is on the launcher's arguments.
: > "$WORK/store-writes"
launch_store_write() { # launch_store_write <dsn> <what the write answers> - the preflight with the launcher's other steps stubbed; its output
    ( manifest_set runtime.dsn "$1"; manifest_set runtime.user sys; manifest_set runtime.password_file "$WORK/pw"
      _lsw_answer="$2"
      _notebook_py() { printf '%s %s:%s\n' "$1" "$EXAKIT_NB_HOST" "$EXAKIT_NB_PORT" >> "$WORK/store-writes"; printf '%s\n' "$EXAKIT_NB_SCHEMA" > "$WORK/store-schema"; printf '%s\n' "$_lsw_answer"; }
      notebook_env_state() { echo ok; }; _notebook_on_terminal() { return 1; }; exakit_db_reachable() { return 0; }
      notebook_register_kernel() { return 0; }; _notebook_report_copied() { :; }; notebook_copy_notebooks() { :; }
      _notebook_preflight; echo "rc=$?" ) 2>&1
}
out="$(launch_store_write 127.0.0.1:8563 same)"
contains "the first launch runs through" "rc=0" "$out"
check "and hands the store the recorded port" "write_store.py 127.0.0.1:8563" "$(cat "$WORK/store-writes")"
out="$(launch_store_write 127.0.0.1:8564 changed)"
contains "the next launch runs through too" "rc=0" "$out"
check "the store is written again, now with the new port: nothing is cached between launches" \
    "write_store.py 127.0.0.1:8563|write_store.py 127.0.0.1:8564" "$(tr '\n' '|' < "$WORK/store-writes" | sed 's/|$//')"
contains "and the launch says the notebooks use the new connection" "The database connection changed; the notebooks now use the new one" "$out"
check "the master password is in no argument the launcher records" "0" "$(grep -c "$(cat "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED")" "$WORK/store-writes" | tr -d ' ')"
# The store's schema: the connector's jupysql.init reads db_schema, so the
# write carries one - the kit's STARTER_KIT, or EXAKIT_NOTEBOOK_SCHEMA.
check "the store write carries the kit's schema, STARTER_KIT, by default" "STARTER_KIT" "$(cat "$WORK/store-schema")"
out="$(EXAKIT_NOTEBOOK_SCHEMA=MY_SCHEMA launch_store_write 127.0.0.1:8564 same)"
contains "a launch with EXAKIT_NOTEBOOK_SCHEMA runs through" "rc=0" "$out"
check "and hands the store that schema" "MY_SCHEMA" "$(cat "$WORK/store-schema")"
manifest_del runtime.dsn; manifest_del runtime.user; manifest_del runtime.password_file

echo "exakit logs notebook:"
out="$( (exakit_marketplace_installed_addons() { echo notebook; }; exakit_log_targets) )"
contains "JupyterLab's log is a target" "notebook|JupyterLab (exakit notebook)|file|$EXAKIT_LOG_DIR/notebook.log" "$out"
contains "Marimo's log is a target" "notebook-marimo|Marimo (notebook marimo)|file|$EXAKIT_LOG_DIR/notebook-marimo.log" "$out"
out="$( (exakit_marketplace_installed_addons() { echo notebook; }; mkdir -p "$EXAKIT_LOG_DIR"; echo line1 > "$EXAKIT_LOG_DIR/notebook.log"; exakit_logs_show notebook) 2>&1)"
check "exakit logs notebook shows it" "line1" "$out"

echo "the servers: no inherited stdio, stale pids, one server, the token off the command line:"
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
# A stand-in JupyterLab and Marimo: Python scripts that answer like the real
# ones (/api with a version, /health), so their command lines look like the real
# ones too. STUB_DIE makes one exit at once; STUB_DELAY makes it slow to start.
mkdir -p "$EXAKIT_NOTEBOOK_VENV/bin"
ln -sf "$(command -v python3)" "$EXAKIT_NOTEBOOK_VENV/bin/python"
cat > "$EXAKIT_NOTEBOOK_VENV/bin/jupyter-lab" <<'STUB'
#!/usr/bin/env python3
import http.server, os, sys, time
port = int([a.split("=", 1)[1] for a in sys.argv if a.startswith("--ServerApp.port=") or a.startswith("--port=")][0])
if os.environ.get("STUB_DIE"):
    sys.exit(3)
time.sleep(float(os.environ.get("STUB_DELAY", "0")))
open(os.environ["STUB_SEEN"], "w").write("token in env: %s\n" % bool(os.environ.get("JUPYTER_TOKEN")))
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"version": "stub"}')
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
STUB
sed 's/a.startswith("--ServerApp.port=") or a.startswith("--port=")/False/; s/^port = .*/port = int(sys.argv[sys.argv.index("--port") + 1])/' \
    "$EXAKIT_NOTEBOOK_VENV/bin/jupyter-lab" > "$EXAKIT_NOTEBOOK_VENV/bin/marimo"
chmod +x "$EXAKIT_NOTEBOOK_VENV/bin/jupyter-lab" "$EXAKIT_NOTEBOOK_VENV/bin/marimo"
export STUB_SEEN="$WORK/stub-seen"
notebook_installed_version() { echo 3.1.0; }
manifest_set components.notebook.version 3.1.0
# The launcher's own checks are tests/notebook-launcher.sh's: here the
# environment imports and nobody is at a terminal.
notebook_env_state() { echo ok; }
_notebook_on_terminal() { return 1; }
exakit_db_reachable() { return 0; }
notebook_write_connection() { echo same; }
notebook_register_kernel() { return 0; }
_notebook_open_browser() { printf '%s\n' "$1" > "$WORK/opened"; }
EXAKIT_NOTEBOOK_START_TIMEOUT=20
JPORT="$(free_port)"; MPORT="$(free_port)"
# returns_within <seconds> <out file> <command...> — the command, piped into
# cat, in the background; 0 when the pipe closed in time.
returns_within() {
    _rw_limit="$1"; _rw_out="$2"; shift 2
    ( "$@" 2>&1 | cat > "$_rw_out" ) &
    _rw_pid=$!
    _rw_i=0
    while kill -0 "$_rw_pid" 2>/dev/null && [ "$_rw_i" -lt $((_rw_limit * 2)) ]; do sleep 0.5; _rw_i=$((_rw_i + 1)); done
    if kill -0 "$_rw_pid" 2>/dev/null; then kill "$_rw_pid" 2>/dev/null; return 1; fi
    wait "$_rw_pid" 2>/dev/null
    return 0
}
check "exakit notebook | cat returns (the server holds no pipe)" "0" "$(returns_within 25 "$WORK/j1" notebook_cmd --port "$JPORT"; echo $?)"
contains "JupyterLab answers" "JupyterLab is running: http://127.0.0.1:$JPORT/lab" "$(cat "$WORK/j1")"
jpid="$(cat "$(_notebook_pidfile)" 2>/dev/null)"
contains "the pid file names the server itself" "jupyter-lab --no-browser --ServerApp.ip=127.0.0.1" "$(ps -p "$jpid" -o command= 2>/dev/null)"
check "the token reached it through its environment" "token in env: True" "$(cat "$STUB_SEEN" 2>/dev/null)"
tok="$(read_credential "$EXAKIT_NOTEBOOK_TOKEN_CRED")"
check "and is on no command line" "0" "$(ps -ax -o command= | grep -c "[${tok%"${tok#?}"}]${tok#?}" | tr -d " ")"
opened="$(cat "$WORK/opened" 2>/dev/null)"
check "the browser is handed a file, not the address" "$(_notebook_open_file jupyter)" "$opened"
check "the file is the user's only" "-rw-------" "$(ls -l "$opened" 2>/dev/null | cut -c1-10)"
contains "the file carries the logged-in address" "lab?token=$(read_credential "$EXAKIT_NOTEBOOK_TOKEN_CRED")" "$(cat "$opened" 2>/dev/null)"
OTHER="$(free_port)"
out="$(notebook_cmd --no-browser --port "$OTHER" 2>&1)"
contains "a second call names the port it runs on" "JupyterLab is running: http://127.0.0.1:$JPORT/lab" "$out"
contains "and says the asked-for port is ignored" "--port $OTHER is ignored" "$out"
check "and starts no second server" "$jpid" "$(cat "$(_notebook_pidfile)")"
notebook_server_stop >/dev/null 2>&1
check "stop stops it" "no" "$(kill -0 "$jpid" 2>/dev/null && echo yes || echo no)"
check "and removes the login file" "no" "$([ -e "$opened" ] && echo yes || echo no)"

sleep 60 &
bystander=$!
echo "$bystander" > "$(_notebook_pidfile)"
check "a pid file naming another program is stale: stopped" "stopped" "$(notebook_server_state)"
check "the stale pid file is gone" "no" "$([ -e "$(_notebook_pidfile)" ] && echo yes || echo no)"
echo "$bystander" > "$(_notebook_pidfile)"
contains "stop does not touch that program" "JupyterLab is not running" "$(notebook_server_stop 2>&1)"
check "it is still running" "yes" "$(kill -0 "$bystander" 2>/dev/null && echo yes || echo no)"
echo "$bystander" > "$(_notebook_marimo_pidfile)"
notebook_marimo_stop quiet >/dev/null 2>&1
check "neither does Marimo's stop" "yes" "$(kill -0 "$bystander" 2>/dev/null && echo yes || echo no)"
kill "$bystander" 2>/dev/null; wait "$bystander" 2>/dev/null

t0="$(date +%s)"
out="$(STUB_DIE=1 notebook_cmd --no-browser --port "$(free_port)" 2>&1)"; rc=$?
check "a server that dies while starting fails the command" "1" "$rc"
contains "and is reported at once" "JupyterLab stopped while it was starting" "$out"
check "without waiting out the timeout" "yes" "$([ $(( $(date +%s) - t0 )) -lt 15 ] && echo yes || echo no)"

check "exakit notebook marimo | cat returns" "0" "$(returns_within 25 "$WORK/m1" notebook_cmd --marimo --port "$MPORT"; echo $?)"
contains "Marimo answers" "Marimo is running: http://127.0.0.1:$MPORT/" "$(cat "$WORK/m1")"
mpid="$(cat "$(_notebook_marimo_pidfile)" 2>/dev/null)"
contains "Marimo's pid file names its wrapper" "marimo_wrapper.py" "$(ps -p "$mpid" -o command= 2>/dev/null)"
check "the browser is handed Marimo's file" "$(_notebook_open_file marimo)" "$(cat "$WORK/opened" 2>/dev/null)"
notebook_marimo_stop >/dev/null 2>&1
check "Marimo stops" "no" "$(kill -0 "$mpid" 2>/dev/null && echo yes || echo no)"

MPORT="$(free_port)"
( STUB_DELAY=3 notebook_cmd --marimo --no-browser --port "$MPORT" >"$WORK/m2" 2>&1 ) &
first=$!
# The second call comes once the first has started its Marimo (its pid file is
# there), not after a fixed second: the copy before the start can take longer.
_w=0
while [ ! -s "$(_notebook_marimo_pidfile)" ] && [ "$_w" -lt 40 ]; do sleep 0.25; _w=$((_w + 1)); done
out="$(notebook_cmd --marimo --no-browser 2>&1)"
wait "$first"
contains "a second --marimo while the first starts waits for it" "Marimo is running: http://127.0.0.1:$MPORT/" "$out"
check "and leaves one Marimo, not two" "1" "$(ps -ax -o command= | grep -c "[m]arimo_wrapper.py.*--port $MPORT" | tr -d ' ')"
notebook_marimo_stop >/dev/null 2>&1
check "which stops" "0" "$(ps -ax -o command= | grep -c "[m]arimo_wrapper.py.*--port $MPORT" | tr -d ' ')"

echo "an uninstall takes the kit's settings out of the Positron folder, keeps the user's:"
printf '{"editor.fontSize": 14}' > "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json"
notebook_prepare_positron
notebook_uninstall >/dev/null 2>&1
check "only the user's setting is left" '{"editor.fontSize": 14}' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json")"

echo "a full kit uninstall keeps the notebooks:"
full_uninstall() { # full_uninstall <dry> — the real engine with the externals stubbed
    ( exakit_service_ids() { :; }; exakit_mcp_operation() { :; }; exakit_mcp_clients_from_args() { :; }
      _exakit_remove_installed_skills() { :; }; exakit_marketplace_installed_addons() { echo notebook; }
      exakit_marketplace_addons() { echo "notebook|x"; }
      exakit_uninstall_run "$1" )
}
seed_kit() {
    manifest_init >/dev/null 2>&1
    manifest_set components.notebook.version 3.1.0
    mkdir -p "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow" "$EXAKIT_HOME/logs" "$EXAKIT_HOME/pyexasol-venv"
    printf 'precious' > "$EXAKIT_NOTEBOOK_DIR/my-work/analysis.ipynb"
    printf 'runs' > "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow/mlflow.db"
}
seed_kit
out="$(full_uninstall 1 2>&1)"
contains "the dry run says the notebooks stay" "your notebooks stay in $EXAKIT_HOME/notebooks" "$out"
check "the dry run removes nothing" "yes" "$([ -f "$EXAKIT_HOME/manifest.json" ] && echo yes || echo no)"
out="$(full_uninstall 0 2>&1)"
contains "the real run says so" "your notebooks were kept in $EXAKIT_HOME/notebooks" "$out"
check "the user's notebook and MLflow store are still there" "precious|runs" \
    "$(cat "$EXAKIT_NOTEBOOK_DIR/my-work/analysis.ipynb" 2>/dev/null)|$(cat "$EXAKIT_NOTEBOOK_DIR/my-work/mlflow/mlflow.db" 2>/dev/null)"
check "everything else in the kit home is gone" "notebooks" "$(ls -A "$EXAKIT_HOME" | tr '\n' ' ' | sed 's/ $//')"
out="$(full_uninstall 1 2>&1)"; rc=$?
check "a home holding only kept notebooks is still a kit home to the guard" "0" "$rc"
seed_kit
out="$(EXAKIT_UNINSTALL_NOTEBOOKS=remove full_uninstall 1 2>&1)"
contains "EXAKIT_UNINSTALL_NOTEBOOKS=remove: the dry run says they go" "will remove: your notebooks in $EXAKIT_NOTEBOOK_DIR" "$out"
EXAKIT_UNINSTALL_NOTEBOOKS=remove full_uninstall 0 >/dev/null 2>&1
check "and the real run removes the whole kit home" "no" "$([ -e "$EXAKIT_HOME" ] && echo yes || echo no)"
mkdir -p "$EXAKIT_HOME"

echo "the shipped files and the generated workflow logs hold no address and no credential:"
# The workflow logs the helpers write ($EXAKIT_HOME/workflows/*.jsonl, X-1) are
# generated files too: one written here, with a statement in it, joins the
# sweep, so the log's own refusals (tests/test_workflow.py) are backed by the
# same grep that covers everything else the kit generates (AC-DS1.2, X1.2).
PYTHONPATH="$ROOT/notebook/package" python3 -c 'import importlib; w = importlib.import_module("exakit_nb.workflow"); w.workflow("secret-grep"); w.log_event(w.SQL, sql="SELECT 1", rows=1)' >/dev/null
found=""
for f in $(find "$ROOT/notebook/notebooks" "$ROOT/notebook/marimo" "$ROOT/notebook/package" "$ROOT/notebook/kit" -type f \( -name '*.py' -o -name '*.ipynb' -o -name '*.json' \) | sort) \
         $(find "$EXAKIT_HOME/workflows" -type f -name '*.jsonl' 2>/dev/null | sort) \
         $(find "$EXAKIT_HOME/handoffs" -type f -name '*.json' 2>/dev/null | sort) \
         $(find "$EXAKIT_HOME/descriptors" -type f \( -name '*.yaml' -o -name 'current' \) 2>/dev/null | sort); do
    for needle in 127.0.0.1 localhost :8563 'password=' 'dsn='; do
        grep -qF -- "$needle" "$f" && found="$found $(basename "$f"):$needle"
    done
done
check "no address or credential" "" "$found"
check "a workflow log was in the sweep" "yes" "$([ -n "$(find "$EXAKIT_HOME/workflows" -name 'wf-*.jsonl' 2>/dev/null)" ] && echo yes || echo no)"

if command -v python3 >/dev/null 2>&1; then
    check "the kit scripts compile" "ok" "$(python3 -m py_compile "$ROOT"/notebook/kit/*.py && echo ok)"
    check "each .ipynb is built from its .py" "ok" "$(python3 "$ROOT/tools/notebooks.py" --check && echo ok)"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
