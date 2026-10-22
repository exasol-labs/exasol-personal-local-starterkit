#!/usr/bin/env bash
# notebook-launcher.sh — `exakit notebook` as a launcher (setup/lib/notebook.sh):
# what it checks before it opens anything, the "Open which notebook tools?"
# multi-select, and the edge cases a user meets after a lost connection or a
# tool deleted by accident.
#
#   bash tests/notebook-launcher.sh
#
# What it pins:
#   - the menu: its title, one row per tool saying the tool's state (running /
#     ready / missing / not installed; Positron found, or a disabled "!" row with
#     where to get it), Skip as the exclusive answer, the default ticks (the
#     recorded tools that can open, JupyterLab when none); two picked open both,
#     one line each, then one line naming how to stop them; Skip opens nothing
#   - without a terminal nothing is asked: plain `exakit notebook` opens
#     JupyterLab as before, and what it cannot fix is one line naming the
#     command that does, and a non-zero exit
#   - the edge cases, each found before anything opens: the database down or
#     the connection lost (started after a yes, then the notebooks' connection
#     checked), JupyterLab or Marimo removed (reinstalled after a yes), the
#     notebook environment gone or not importing (repaired after a yes), Positron
#     uninstalled (a disabled row, its folder settings kept), a port another
#     program holds (the next free one, unless --port named it), the notebooks
#     folder deleted (made again, the kit's notebooks back), the connection
#     store or its master password deleted (a new store), the kernel removed
#     (registered again), a stale pid file, no browser, a server already running
#
# The launcher's own code runs; what would reach outside is stubbed: the
# database, the servers, the browser, Positron, the package installs, the
# questions (they record what was asked and answer from T_* variables). A
# sandboxed kit home; no database, no network, no real server.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
LISTENER=""
cleanup() { [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

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
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: did not expect "%s" in [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}

PY3="$(command -v python3)"
export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin" EXAKIT_EXAPUMP_CONFIG_DIR="$WORK/home/.exapump"
unset EXAKIT_NOTEBOOK_VENV EXAKIT_NOTEBOOK_HOME EXAKIT_NOTEBOOK_DIR EXAKIT_MARIMO_PORT EXAKIT_NOTEBOOK_JUPYTER \
      EXAKIT_NOTEBOOK_MARIMO EXAKIT_NOTEBOOK_FRONTENDS EXAKIT_NOTEBOOK_PORT_TRIES
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# A PATH that holds no JupyterLab and no Positron unless a check puts one there:
# python3 and curl, and the system's own tools.
mkdir -p "$WORK/sysbin" "$WORK/ownbin"
ln -s "$PY3" "$WORK/sysbin/python3"
ln -s "$(command -v curl)" "$WORK/sysbin/curl"
PATH="$WORK/ownbin:$WORK/sysbin:/usr/bin:/bin:/usr/sbin:/sbin"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
CALLS="$WORK/calls"

# The real implementations a check below needs back after the stubs.
eval "real_$(declare -f notebook_server_state)"
eval "real_$(declare -f notebook_install)"

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# The notebook venv's Python: the import check answers from a flag file, and
# anything else (notebooks.py) runs in the real python3.
cat > "$WORK/fakepython" <<EOF
#!/bin/sh
case "\$*" in
    *"import exasol.nb_connector"*) [ -f "$WORK/imports-ok" ] && exit 0; echo "No module named 'exasol'" >&2; exit 1 ;;
esac
exec "$PY3" "\$@"
EOF
chmod +x "$WORK/fakepython"
VENV_BIN="$EXAKIT_NOTEBOOK_VENV/bin"
mkstub() { mkdir -p "$VENV_BIN"; printf '#!/bin/sh\nexit 0\n' > "$VENV_BIN/$1"; chmod +x "$VENV_BIN/$1"; }
# rm -f first: cp, like >, writes through a symlink to a real interpreter.
make_venv() { mkdir -p "$VENV_BIN"; rm -f "$VENV_BIN/python"; cp "$WORK/fakepython" "$VENV_BIN/python"; : > "$EXAKIT_NOTEBOOK_VENV/pyvenv.cfg"; }

# reset_kit [front_ends] [jupyter-lab|-] [marimo|-] — a fresh kit home with the
# add-on recorded as installed, the database up, the environment importing, and
# the tools named present in the kit's venv.
reset_kit() {
    rm -rf "$EXAKIT_HOME" "$WORK/imports-ok" "$WORK/db-up" "$WORK/jstate" "$WORK/mstate"
    rm -f "$WORK/ownbin/jupyter-lab"
    mkdir -p "$EXAKIT_HOME"
    manifest_init >/dev/null 2>&1
    printf 'pw' > "$WORK/pw"
    manifest_set runtime.dsn "db.test:8563"
    manifest_set runtime.password_file "$WORK/pw"
    manifest_set components.notebook.version 3.1.0
    [ -n "${1:-}" ] && manifest_set components.notebook.front_ends "$1"
    manifest_set components.notebook.port "$(free_port)"
    manifest_set components.notebook.marimo_port "$(free_port)"
    make_venv
    [ "${2:--}" = - ] || mkstub jupyter-lab
    [ "${3:--}" = - ] || mkstub marimo
    : > "$WORK/imports-ok"
    : > "$WORK/db-up"
    : > "$CALLS"
}

# --- the stubs: everything that would reach outside the kit home ---------------
_notebook_on_terminal() { [ "${T_TERMINAL:-0}" = 1 ]; }
confirm() {
    printf 'confirm:%s\n' "$1" >> "$CALLS"
    case "${T_ANSWER:-${2:-y}}" in y) return 0 ;; *) return 1 ;; esac
}
ui_checkbox_menu() {
    _st_t="$1"; _st_d="$2"; shift 2
    printf 'menu:%s|defaults=%s|exclusive=%s' "$_st_t" "$_st_d" "${EXAKIT_CHECKBOX_EXCLUSIVE:-}" >> "$CALLS"
    for _st_l in "$@"; do printf '|%s' "$_st_l" >> "$CALLS"; done
    printf '\n' >> "$CALLS"
    EXAKIT_CHECKBOX_SELECTION="${T_PICK:-$_st_d}"
    EXAKIT_CHECKBOX_EXCLUSIVE=""
}
exakit_db_reachable() { [ -f "$WORK/db-up" ]; }
exakit_init_logging() { :; }
_start_database() {
    printf 'start-db\n' >> "$CALLS"
    [ "${T_START_FAILS:-0}" = 1 ] || : > "$WORK/db-up"
}
_notebook_py() {
    case "$1" in
        write_store.py)
            printf 'store\n' >> "$CALLS"
            [ -f "$WORK/store-fails" ] && return 1
            # A store written under another master cannot be opened.
            [ -f "$SCS_FILE" ] && grep -q OLD "$SCS_FILE" && return 1
            printf 'NEW\n' > "$SCS_FILE"
            printf 'same\n' ;;
        register_kernel.py) printf 'kernel\n' >> "$CALLS" ;;
        check_connection.py) printf 'connected\n' >> "$CALLS"; [ "${T_CONNECT_FAILS:-0}" = 1 ] && return 1; return 0 ;;
        *) return 1 ;;
    esac
}
notebook_server_state() { cat "$WORK/jstate" 2>/dev/null || echo stopped; }
notebook_server_start() {
    printf 'jstart:%s\n' "$1" >> "$CALLS"
    echo running > "$WORK/jstate"
    manifest_set components.notebook.port "$1"
}
notebook_marimo_state() {
    notebook_marimo_installed || { echo 'not installed'; return 0; }
    cat "$WORK/mstate" 2>/dev/null || echo stopped
}
notebook_marimo_start() {
    printf 'mstart:%s\n' "$1" >> "$CALLS"
    echo running > "$WORK/mstate"
    manifest_set components.notebook.marimo_port "$1"
}
_notebook_open_browser() {
    printf 'browser:%s\n' "$1" >> "$CALLS"
    [ "${T_NO_BROWSER:-0}" = 1 ] && return 1
    return 0
}
notebook_find_positron() {
    [ "${T_POSITRON:-0}" = 1 ] || return 1
    printf '/Applications/Positron.app\n'
}
notebook_open_positron() { printf 'positron-open\n' >> "$CALLS"; }
notebook_sync_packages() {
    printf 'sync:J=%s:M=%s\n' "${NOTEBOOK_ADD_JUPYTERLAB:-0}" "${NOTEBOOK_ADD_MARIMO:-0}" >> "$CALLS"
    [ "${T_SYNC_FAILS:-0}" = 1 ] && return 1
    [ "${NOTEBOOK_ADD_JUPYTERLAB:-0}" = 1 ] && mkstub jupyter-lab
    [ "${NOTEBOOK_ADD_MARIMO:-0}" = 1 ] && mkstub marimo
    return 0
}
_notebook_frontends_installed() { [ -x "$VENV_BIN/jupyter-lab" ] && printf 'jupyterlab=4.4.9\n'; return 0; }
notebook_install() {
    printf 'install:%s:%s\n' "${EXAKIT_NOTEBOOK_VERSION:-}" "${EXAKIT_FORCE_COMPONENT_INSTALL:-}" >> "$CALLS"
    [ "${T_INSTALL_FAILS:-0}" = 1 ] && return 1
    make_venv; mkstub jupyter-lab; : > "$WORK/imports-ok"
}

# run_cmd [VAR=value ...] -- [notebook_cmd args] — notebook_cmd in a subshell
# with the T_* answers given; sets OUT (what it said), RC and DID (the calls).
run_cmd() {
    _rc_vars=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do _rc_vars="$_rc_vars $1"; shift; done
    [ "${1:-}" = "--" ] && shift
    : > "$CALLS"
    OUT="$( ( for _rc_kv in $_rc_vars; do export "$_rc_kv"; done; notebook_cmd "$@" ) 2>&1 )"
    RC=$?
    DID="$(cat "$CALLS")"
}
menu_line() { printf '%s\n' "$DID" | grep '^menu:' | head -1; }
# servers_stopped — what the last check started is gone.
servers_stopped() { rm -f "$WORK/jstate" "$WORK/mstate"; }

echo "the menu, on a terminal:"
reset_kit "jupyterlab,marimo,positron" jupyter-lab marimo
run_cmd T_TERMINAL=1 T_POSITRON=1 T_PICK=4 --
contains "titled 'Open which notebook tools?'" "menu:Open which notebook tools?|" "$(menu_line)"
contains "JupyterLab: ready, the kit's, its version" "|JupyterLab - ready (the kit's 4.4.9)|" "$(menu_line)"
contains "Marimo: ready" "|Marimo - ready|" "$(menu_line)"
contains "Positron: found" "|Positron - found - opens on the notebooks folder|" "$(menu_line)"
contains "Skip is the last row" "|Skip - open nothing" "$(menu_line)"
contains "...and the exclusive one" "exclusive=4" "$(menu_line)"
contains "the recorded tools are ticked" "defaults=1,2,3" "$(menu_line)"
check "Skip opens nothing" "0|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(jstart|mstart|positron-open|browser)')"
contains "...and says so" "Nothing opened" "$OUT"

run_cmd T_TERMINAL=1 T_PICK=1,2 --
check "two picked: both started" "2" "$(printf '%s\n' "$DID" | grep -cE '^(jstart|mstart):')"
check "...both opened logged in" "browser:$(_notebook_open_file jupyter) browser:$(_notebook_open_file marimo)" \
    "$(printf '%s\n' "$DID" | grep '^browser:' | tr '\n' ' ' | sed 's/ $//')"
contains "one line for JupyterLab, with its address" "JupyterLab is running: http://127.0.0.1:$(manifest_get components.notebook.port)/lab" "$OUT"
contains "one line for Marimo, with its address" "Marimo is running: http://127.0.0.1:$(manifest_get components.notebook.marimo_port)/" "$OUT"
check "then one line naming how to stop them" "1" "$(printf '%s\n' "$OUT" | grep -c 'To stop JupyterLab and Marimo: exakit notebook stop')"
lacks "...not one per tool" "(stop it with" "$OUT"
lacks "...and no extra lines between" "Marimo notebooks connect with" "$OUT"
check "exit 0" "0" "$RC"

echo "the menu's states:"
reset_kit "jupyterlab,marimo,positron" jupyter-lab marimo
echo running > "$WORK/jstate"; echo running > "$WORK/mstate"
run_cmd T_TERMINAL=1 T_PICK=4 --
contains "JupyterLab running: its address" "|JupyterLab - running at http://127.0.0.1:$(manifest_get components.notebook.port)/lab|" "$(menu_line)"
contains "Marimo running: its address" "|Marimo - running at http://127.0.0.1:$(manifest_get components.notebook.marimo_port)/|" "$(menu_line)"
contains "Positron not here: a disabled row saying where to get it" "|!Positron - not on this machine (get it at positron.posit.co)|" "$(menu_line)"
contains "...and not ticked although it is recorded" "defaults=1,2|" "$(menu_line)"
reset_kit "" - -
printf '#!/bin/sh\nexit 0\n' > "$WORK/ownbin/jupyter-lab"; chmod +x "$WORK/ownbin/jupyter-lab"
run_cmd T_TERMINAL=1 T_PICK=4 --
contains "the user's own JupyterLab: ready, yours, its path" "|JupyterLab - ready (yours: $WORK/ownbin/jupyter-lab)|" "$(menu_line)"
contains "Marimo never set up: not installed, installs it" "|Marimo - not installed - installs it|" "$(menu_line)"
contains "nothing recorded: JupyterLab ticked" "defaults=1|" "$(menu_line)"
reset_kit "jupyterlab,marimo" - -
run_cmd T_TERMINAL=1 T_PICK=4 --
contains "JupyterLab removed: missing, reinstall it" "|JupyterLab - missing - reinstall it into the kit's environment|" "$(menu_line)"
contains "Marimo removed: missing, reinstall it" "|Marimo - missing - reinstall it into the kit's environment|" "$(menu_line)"
contains "missing tools stay ticked: picking them reinstalls them" "defaults=1,2|" "$(menu_line)"
reset_kit "" - -
manifest_del components.notebook.front_ends
run_cmd T_TERMINAL=1 T_PICK=4 --
contains "JupyterLab never set up: not installed, installs it" "|JupyterLab - not installed - installs it into the kit's environment|" "$(menu_line)"
defaults_for() { manifest_set components.notebook.front_ends "$1"; notebook_menu_defaults "$2"; }
check "the defaults: the record, Positron only when it is here, else JupyterLab" "1,2,3|1,2|1|2|1" \
    "$(defaults_for jupyterlab,marimo,positron 1)|$(defaults_for jupyterlab,marimo,positron 0)|$(defaults_for positron 0)|$(defaults_for marimo 1)|$(defaults_for none 1)"

echo "without a terminal nothing is asked:"
reset_kit "jupyterlab,marimo,positron" jupyter-lab marimo
run_cmd --
check "plain exakit notebook opens JupyterLab, as it always did" "0|1" "$RC|$(printf '%s\n' "$DID" | grep -c '^jstart:')"
check "...asking nothing" "" "$(printf '%s\n' "$DID" | grep -E '^(menu|confirm):')"
contains "...with its stop line" "(stop it with: exakit notebook stop)" "$OUT"
servers_stopped
run_cmd T_TERMINAL=1 -- --port "$(free_port)"
check "--port on a terminal is JupyterLab's port: no menu" "|1" "$(menu_line)|$(printf '%s\n' "$DID" | grep -c '^jstart:')"
run_cmd T_TERMINAL=1 -- --marimo --no-browser
check "--marimo on a terminal: Marimo, no menu, no browser" "|1|0" \
    "$(menu_line)|$(printf '%s\n' "$DID" | grep -c '^mstart:')|$(printf '%s\n' "$DID" | grep -c '^browser:')"
run_cmd T_TERMINAL=1 -- --positron
check "--positron: Positron's folder, no menu" "|0" "$(menu_line)|$RC"
run_cmd T_TERMINAL=1 -- --stop
check "--stop: no menu, no checks" "" "$DID"
servers_stopped
run_cmd T_TERMINAL=1 -- marimo --no-browser
check "the word form, marimo: Marimo, no menu" "|1" "$(menu_line)|$(printf '%s\n' "$DID" | grep -c '^mstart:')"
run_cmd T_TERMINAL=1 -- stop
check "...stop as a word: no menu, no checks" "" "$DID"
servers_stopped
run_cmd T_TERMINAL=1 -- jupyterlab --no-browser
check "jupyterlab on a terminal: JupyterLab, no menu" "|1" "$(menu_line)|$(printf '%s\n' "$DID" | grep -c '^jstart:')"
run_cmd T_TERMINAL=1 -- stop

echo "a. the database is not running, or the connection was lost:"
reset_kit "jupyterlab" jupyter-lab -
rm -f "$WORK/db-up"
run_cmd --
check "no terminal: not started, nothing opened, exit non-zero" "1|" "$([ "$RC" -ne 0 ] && echo 1)|$(printf '%s\n' "$DID" | grep -E '^(start-db|jstart|confirm)')"
contains "...naming the command" "Start it with: exakit start" "$OUT"
run_cmd T_TERMINAL=1 T_PICK=1 --
contains "on a terminal: said" "The database is not running, or the connection to it was lost" "$OUT"
contains "...and offered" "confirm:Start the database now?" "$DID"
check "a yes starts it the way exakit start does, then the store, the connection, the tools" "start-db store connected kernel jstart" \
    "$(printf '%s\n' "$DID" | grep -E '^(start-db|store|connected|kernel|jstart)' | sed 's/:.*//' | tr '\n' ' ' | sed 's/ $//')"
check "...and exits 0" "0" "$RC"
rm -f "$WORK/db-up"
run_cmd T_TERMINAL=1 T_ANSWER=n --
check "a no: nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(start-db|jstart|menu)')"
contains "...naming the command" "Start it with: exakit start - then: exakit notebook" "$OUT"
run_cmd T_TERMINAL=1 T_START_FAILS=1 --
check "a start that does not bring it up: nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(jstart|menu)')"
contains "...pointing at exakit status and exakit logs" "see: exakit status   (and its log: exakit logs)" "$OUT"
rm -f "$WORK/db-up"
run_cmd T_TERMINAL=1 T_CONNECT_FAILS=1 --
check "up, but the notebooks still cannot connect: nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(jstart|menu)')"
contains "...said, with exakit status and exakit logs" "the notebooks cannot connect to it, so nothing was opened - see: exakit status" "$OUT"
run_cmd --
check "a database that is up: no connection probe, the launch stays quick" "0" "$(printf '%s\n' "$DID" | grep -c '^connected')"
_sd_range='/^_notebook_start_database() {/,/^}/p'      # assigned first: bash 3.2
contains "the start is the kit's own (_start_database, what exakit start database runs)" "_start_database )" \
    "$(sed -n "$_sd_range" "$ROOT/setup/lib/notebook.sh")"

echo "b. JupyterLab deleted:"
reset_kit "jupyterlab" - -
run_cmd --
check "no terminal: nothing installed, nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(sync|jstart|confirm)')"
contains "...one line naming the fix" "JupyterLab is missing (it was removed from this machine) - there is nothing to open the notebooks in. Install it with: exakit notebook setup" "$OUT"
run_cmd T_TERMINAL=1 T_PICK=1 --
contains "picked from the menu: a reinstall is offered" "confirm:Reinstall JupyterLab $(notebook_frontend_pin jupyterlab) into the kit's notebook environment?" "$DID"
check "...a yes installs the kit's (the connector's jupyter extra) and opens it" "sync:J=1:M=0 jstart" \
    "$(printf '%s\n' "$DID" | grep -E '^(sync|jstart)' | sed 's/^jstart:.*/jstart/' | tr '\n' ' ' | sed 's/ $//')"
check "...recorded as the kit's" "kit" "$(manifest_get components.notebook.jupyter)"
reset_kit "jupyterlab" - -
run_cmd T_TERMINAL=1 T_PICK=1 T_ANSWER=n --
check "...a no: nothing installed, nothing opened, not a failure" "0|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(sync|jstart)')"
contains "...and the way back said" "Add it any time with: exakit notebook setup" "$OUT"
run_cmd -- --setup
check "--setup without a terminal installs it: it is the command named" "0|1|0" \
    "$RC|$(printf '%s\n' "$DID" | grep -c '^sync:J=1')|$(printf '%s\n' "$DID" | grep -c '^jstart')"
reset_kit "jupyterlab" - -
run_cmd T_SYNC_FAILS=1 -- --setup
check "a reinstall that fails: exit 1, the retry named" "1" "$RC"
contains "...the retry named" "retry with: exakit notebook setup" "$OUT"
reset_kit "jupyterlab" - -
printf '#!/bin/sh\nexit 0\n' > "$WORK/ownbin/jupyter-lab"; chmod +x "$WORK/ownbin/jupyter-lab"
check "the user's own on PATH: ready" "own $WORK/ownbin/jupyter-lab" "$(notebook_jupyter_state)"
rm -f "$WORK/ownbin/jupyter-lab"
check "...gone from PATH: missing" "missing" "$(notebook_jupyter_state)"

echo "c. Marimo removed from the environment:"
reset_kit "jupyterlab,marimo" jupyter-lab -
manifest_set components.notebook.marimo kit
run_cmd T_TERMINAL=1 T_PICK=2 --
contains "picked: a reinstall is offered" "confirm:Marimo is missing (it was removed from the kit's notebook environment). Reinstall it?" "$DID"
check "...a yes installs it at its pin and opens it" "sync:J=0:M=1 mstart" \
    "$(printf '%s\n' "$DID" | grep -E '^(sync|mstart)' | sed 's/^mstart:.*/mstart/' | tr '\n' ' ' | sed 's/ $//')"
reset_kit "jupyterlab,marimo" jupyter-lab -
run_cmd T_TERMINAL=1 T_PICK=1,2 T_ANSWER=n --
check "...a no: JupyterLab still opens, Marimo does not, exit 0" "0|1|0" \
    "$RC|$(printf '%s\n' "$DID" | grep -c '^jstart')|$(printf '%s\n' "$DID" | grep -c '^mstart')"
contains "...and only JupyterLab is named in the stop line" "To stop JupyterLab: exakit notebook stop" "$OUT"
reset_kit "jupyterlab,marimo" jupyter-lab -
run_cmd T_TERMINAL=1 T_PICK=1,2 T_SYNC_FAILS=1 --
check "...an install that fails: the other tool still opens, exit 1" "1|1" "$RC|$(printf '%s\n' "$DID" | grep -c '^jstart')"
contains "...the retry named" "retry with: exakit notebook marimo" "$OUT"

echo "d. the notebook environment deleted or broken:"
reset_kit "jupyterlab" jupyter-lab -
rm -rf "$EXAKIT_NOTEBOOK_VENV"
check "deleted: missing" "missing" "$(notebook_env_state)"
run_cmd --
check "no terminal: not repaired, nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(install|jstart|confirm)')"
contains "...one line naming the repair" "The notebook environment is missing (its Python, $(notebook_venv_python), is gone) - nothing was opened. Repair it with: exakit update notebook" "$OUT"
run_cmd T_TERMINAL=1 T_PICK=1 --
contains "on a terminal: the repair is offered" "confirm:Repair it now?" "$DID"
check "...a yes installs it again at the recorded version, the whole way, then opens" "install:3.1.0:1 jstart" \
    "$(printf '%s\n' "$DID" | grep -E '^(install|jstart)' | sed 's/^jstart:.*/jstart/' | tr '\n' ' ' | sed 's/ $//')"
contains "...and says so" "The notebook environment is repaired" "$OUT"
reset_kit "jupyterlab" jupyter-lab -
rm -f "$WORK/imports-ok"
check "the connector or the helpers do not import: broken" "broken" "$(notebook_env_state)"
run_cmd T_TERMINAL=1 T_ANSWER=n --
check "...a no: nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(install|jstart|menu)')"
contains "...the repair named" "Repair it any time with: exakit update notebook" "$OUT"
run_cmd T_TERMINAL=1 T_INSTALL_FAILS=1 --
check "...a repair that fails: nothing opened, exit 1" "1|" "$RC|$(printf '%s\n' "$DID" | grep -E '^(jstart|menu)')"
reset_kit "jupyterlab" jupyter-lab -
rm -rf "$EXAKIT_NOTEBOOK_VENV"
run_cmd -- --stop
check "--stop works with the environment gone" "0" "$RC"
check "the add-on not recorded: not installed, as before" "1" "$( (manifest_del components.notebook; notebook_cmd >/dev/null 2>&1); echo $?)"
# The install the repair runs makes a venv whose Python is gone again from
# nothing: uv would not create one over it.
reset_kit "jupyterlab" jupyter-lab -
rm -f "$VENV_BIN/python"; : > "$EXAKIT_NOTEBOOK_VENV/leftover"
out="$( ( eval "$(declare -f real_notebook_install | sed '1s/^real_//')"
          _notebook_uv() { echo uv; }; detect_os() { echo macos; }
          run_logged() {
              [ "$2" = venv ] || return 0
              mkdir -p "$5/bin"; rm -f "$5/bin/python"; cp "$WORK/fakepython" "$5/bin/python"
          }
          notebook_package_version() { echo 3.1.0; }; _notebook_report_copied() { :; }; notebook_front_ends_setup() { :; }
          EXAKIT_NOTEBOOK_VERSION=3.1.0 EXAKIT_FORCE_COMPONENT_INSTALL=1 notebook_install ) 2>&1 )"
check "a broken venv is made again from nothing" "no|yes" \
    "$([ -e "$EXAKIT_NOTEBOOK_VENV/leftover" ] && echo yes || echo no)|$([ -x "$VENV_BIN/python" ] && echo yes || echo no)"

echo "e. Positron uninstalled after it was set up:"
reset_kit "jupyterlab,positron" jupyter-lab -
notebook_prepare_positron
run_cmd T_TERMINAL=1 T_PICK=4 --
contains "a disabled row, with where to get it" "|!Positron - not on this machine" "$(menu_line)"
contains "...its folder settings stay" "\"python.defaultInterpreterPath\": \"$(notebook_venv_python)\"" "$(cat "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json")"
run_cmd T_TERMINAL=1 T_POSITRON=1 T_PICK=3 --
check "found again: picking it opens it on the folder" "1|0" "$(printf '%s\n' "$DID" | grep -c '^positron-open')|$RC"
contains "...one line" "Positron opened on $EXAKIT_NOTEBOOK_DIR" "$OUT"
lacks "...no stop line for Positron alone" "To stop" "$OUT"

echo "f. a port another program holds:"
reset_kit "jupyterlab,marimo" jupyter-lab marimo
TAKEN="$(free_port)"
python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(120)' "$TAKEN" &
LISTENER=$!
_w=0; while ! _notebook_port_in_use "$TAKEN" && [ "$_w" -lt 40 ]; do sleep 0.25; _w=$((_w + 1)); done
check "it is seen as in use" "0" "$(_notebook_port_in_use "$TAKEN"; echo $?)"
check "a free one is not" "1" "$(_notebook_port_in_use "$(free_port)"; echo $?)"
manifest_set components.notebook.port "$TAKEN"
run_cmd --
NEXT="$(manifest_get components.notebook.port)"
check "not given with --port: the next free port is used" "yes|jstart:$NEXT" \
    "$([ "$NEXT" -gt "$TAKEN" ] && [ "$NEXT" -le $((TAKEN + 20)) ] && echo yes)|$(printf '%s\n' "$DID" | grep '^jstart:')"
contains "...said in one line" "Port $TAKEN is in use by another program, so JupyterLab uses port $NEXT" "$OUT"
check "...and recorded: the next start begins there" "$NEXT" "$(manifest_get components.notebook.port)"
echo stopped > "$WORK/jstate"
run_cmd -- --port "$TAKEN"
check "given with --port: refused, nothing started, exit 1" "1|0" "$RC|$(printf '%s\n' "$DID" | grep -c '^jstart')"
contains "...as before: pick another" "Port $TAKEN is in use by another program - pick another with: exakit notebook --port <number>" "$OUT"
manifest_set components.notebook.marimo_port "$TAKEN"
run_cmd -- --marimo --no-browser
check "Marimo too steps over it" "1" "$(printf '%s\n' "$DID" | grep -c "^mstart:$((TAKEN + 1))\$")"
servers_stopped
run_cmd -- --marimo --port "$TAKEN"
contains "...and refuses it when --port named it" "pick another with: exakit notebook marimo --port <number>" "$OUT"
manifest_set components.notebook.port "$TAKEN"
run_cmd EXAKIT_NOTEBOOK_PORT_TRIES=0 --
contains "no free port in the range: said, with --port" "all in use by other programs - pick a free one with: exakit notebook --port <number>" "$OUT"
check "...exit 1" "1" "$RC"
kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null; LISTENER=""

echo "g. the notebooks folder deleted:"
reset_kit "jupyterlab" jupyter-lab -
run_cmd --
check "the first launch copies the kit's notebooks" "yes" "$([ -f "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks/ml-engineer/01_train.ipynb" ] && echo yes)"
rm -f "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks/ml-engineer/01_train.ipynb"
run_cmd --
check "one notebook the user deleted stays deleted" "no" "$([ -e "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks/ml-engineer/01_train.ipynb" ] && echo yes || echo no)"
rm -rf "$EXAKIT_NOTEBOOK_DIR"
servers_stopped
run_cmd --
check "the whole folder deleted: made again, every notebook back" "yes|yes" \
    "$([ -f "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks/ml-engineer/01_train.ipynb" ] && echo yes)|$([ -f "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks/data-scientist/00_quickstart.ipynb" ] && echo yes)"
contains "...in one line" "The notebooks folder was gone, so it was made again with the kit's notebooks: $EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks" "$OUT"
lacks "...not the list of every notebook" "New notebooks in" "$OUT"
check "...and JupyterLab still opens" "0|1" "$RC|$(printf '%s\n' "$DID" | grep -c '^jstart')"

echo "h. the connection store or its master password deleted:"
reset_kit "jupyterlab" jupyter-lab -
STORE="$(notebook_store_file)"
check "a first write" "same" "$(notebook_write_connection 2>/dev/null)"
MASTER="$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED"
check "...made its master password" "yes" "$([ -s "$MASTER" ] && echo yes)"
printf 'OLD\n' > "$STORE"; rm -f "$MASTER"
check "the master deleted: a new store" "new|NEW" "$(notebook_write_connection 2>/dev/null)|$(cat "$STORE")"
check "...under a new master" "yes" "$([ -s "$MASTER" ] && echo yes)"
printf 'OLD\n' > "$STORE"
check "a store that will not open: a new one, the old one kept beside it" "new|NEW|OLD" \
    "$(notebook_write_connection 2>/dev/null)|$(cat "$STORE")|$(cat "$STORE.unreadable" 2>/dev/null)"
printf 'OLD\n' > "$STORE"; : > "$WORK/store-fails"
check "a failure that is not the store's: the old store put back, the write fails" "1|OLD|no" \
    "$(notebook_write_connection >/dev/null 2>&1; echo $?)|$(cat "$STORE")|$([ -e "$STORE.unreadable" ] && echo yes || echo no)"
rm -f "$WORK/store-fails" "$STORE"
check "the store deleted: written again" "same|NEW" "$(notebook_write_connection 2>/dev/null)|$(cat "$STORE")"
printf 'OLD\n' > "$STORE"; rm -f "$MASTER"
run_cmd --
contains "the launcher says so in one line" "so a new one was written from the kit's connection" "$OUT"
check "...and goes on" "0|1" "$RC|$(printf '%s\n' "$DID" | grep -c '^jstart')"
lacks "...never a secret on screen" "$(cat "$MASTER")" "$OUT"
check "an uninstall takes the kept store too" "no" \
    "$(printf 'x' > "$STORE.unreadable"; notebook_uninstall >/dev/null 2>&1; [ -e "$STORE.unreadable" ] && echo yes || echo no)"

echo "i. the kernel spec removed:"
reset_kit "jupyterlab,marimo" jupyter-lab marimo
for form in "" "--marimo" "--check"; do
    # shellcheck disable=SC2086
    run_cmd -- $form
    check "registered again on every launch: exakit notebook $form" "1" "$(printf '%s\n' "$DID" | grep -c '^kernel$')"
done
run_cmd T_TERMINAL=1 T_PICK=4 --
check "...on the menu's path too, before it asks" "kernel menu" "$(printf '%s\n' "$DID" | grep -E '^(kernel|menu)' | sed 's/:.*//' | tr '\n' ' ' | sed 's/ $//')"

echo "j. a stale pid file:"
reset_kit "jupyterlab" jupyter-lab -
sleep 60 &
BYSTANDER=$!
mkdir -p "$EXAKIT_NOTEBOOK_HOME"; echo "$BYSTANDER" > "$(_notebook_pidfile)"
out="$( ( eval "$(declare -f real_notebook_server_state | sed '1s/^real_//')"; notebook_jupyter_state ) )"
check "a pid file naming another program: JupyterLab is not running, ready" "kit 4.4.9" "$out"
check "...the stale file removed" "no" "$([ -e "$(_notebook_pidfile)" ] && echo yes || echo no)"
echo "$BYSTANDER" > "$(_notebook_pidfile)"
run_cmd T_TERMINAL=1 T_PICK=1 --
check "...through the menu, a new one is started" "1" "$(printf '%s\n' "$DID" | grep -c '^jstart')"
check "...and that program left alone" "yes" "$(kill -0 "$BYSTANDER" 2>/dev/null && echo yes || echo no)"
kill "$BYSTANDER" 2>/dev/null; wait "$BYSTANDER" 2>/dev/null
_js_range='/^notebook_jupyter_state() {/,/^}/p'      # assigned first: bash 3.2
contains "the menu's state reads the pid-checked server state" "notebook_server_state" "$(sed -n "$_js_range" "$ROOT/setup/lib/notebook.sh")"

echo "k. the browser cannot be opened:"
reset_kit "jupyterlab,marimo" jupyter-lab marimo
run_cmd T_TERMINAL=1 T_PICK=1,2 T_NO_BROWSER=1 --
contains "JupyterLab: its address and where the login token is" \
    "Open http://127.0.0.1:$(manifest_get components.notebook.port)/lab - the login token is in $EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_TOKEN_CRED" "$OUT"
contains "Marimo: the same" \
    "Open http://127.0.0.1:$(manifest_get components.notebook.marimo_port)/ - the login token is in $EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MARIMO_CRED" "$OUT"
lacks "...the token itself never on screen" "$(read_credential "$EXAKIT_NOTEBOOK_TOKEN_CRED")" "$OUT"
lacks "...nor Marimo's" "$(read_credential "$EXAKIT_NOTEBOOK_MARIMO_CRED")" "$OUT"
check "...and the command still succeeds" "0" "$RC"
servers_stopped
run_cmd T_TERMINAL=1 T_PICK=1,2 -- --no-browser
check "--no-browser through the menu: no browser" "0|2" "$(printf '%s\n' "$DID" | grep -c '^browser:')|$(printf '%s\n' "$DID" | grep -cE '^(jstart|mstart):')"

echo "l. a tool already running:"
reset_kit "jupyterlab,marimo" jupyter-lab marimo
echo running > "$WORK/jstate"; echo running > "$WORK/mstate"
JP="$(manifest_get components.notebook.port)"; MP="$(manifest_get components.notebook.marimo_port)"
run_cmd T_TERMINAL=1 T_PICK=1,2 --
check "picked from the menu: no second server" "0" "$(printf '%s\n' "$DID" | grep -cE '^(jstart|mstart):')"
contains "...JupyterLab opened where it runs" "JupyterLab is running: http://127.0.0.1:$JP/lab" "$OUT"
contains "...and Marimo" "Marimo is running: http://127.0.0.1:$MP/" "$OUT"
check "...both opened in the browser" "2" "$(printf '%s\n' "$DID" | grep -c '^browser:')"
check "...no question about ports" "0" "$(printf '%s\n' "$OUT" | grep -c 'in use by another program')"

echo "the shell twin says what the Windows twin says:"
PS1F="$(cat "$ROOT/setup/lib/notebook.ps1")"
for text in "Open which notebook tools?" "Skip - open nothing" "missing - reinstall it into the kit's environment" \
            "Positron - found - opens on the notebooks folder" "!Positron - not on this machine (get it at positron.posit.co)" \
            "Marimo - not installed - installs it" "not installed - installs it into the kit's environment" \
            "is in use by another program, so " "The notebooks folder was gone, so it was made again with the kit's notebooks: " \
            "Repair it with: exakit update notebook" "there is nothing to open the notebooks in. Install it with: exakit notebook setup" \
            "Start the database now?" "so a new one was written from the kit's connection"; do
    contains "both say: $text" "$text" "$PS1F"
done

echo "on a real terminal (a pty): the multi-select, then the open lines:"
. "$ROOT/tests/lib/utf8-locale.sh"
# replay <keys> [VAR=value ...] — the scenario under a pty; sets SCREEN.
replay() {
    _r_keys="$1"; shift
    SCREEN="$(env "$@" python3 "$ROOT/tests/lib/tty-replay.py" "$ROOT/tests/lib/notebook-launcher-scenario.sh" \
        "$ROOT" "Open which notebook tools?" "$_r_keys" 2>&1 | sed -n '/=== FINAL SCREEN ===/,/=== NO BOX\|=== tables on screen/p')"
}
if [ -z "${EXAKIT_TEST_UTF8_LOCALE:-}" ]; then
    check "a UTF-8 locale for the pty replay" "skipped" "skipped"
else
    replay '\r'
    check "the question, once" "1" "$(printf '%s\n' "$SCREEN" | grep -c 'Open which notebook tools?')"
    contains "JupyterLab ticked, saying it is ready" "[✓] JupyterLab - ready (the kit's 4.4.9)" "$SCREEN"
    contains "Marimo ticked, ready" "[✓] Marimo - ready" "$SCREEN"
    contains "Positron shown, not pickable, with where to get it" "[ ] Positron - not on this machine (get it at positron.posit.co)" "$SCREEN"
    contains "Skip, unticked" "[ ] Skip - open nothing" "$SCREEN"
    check "every row drawn once" "1|1|1" \
        "$(printf '%s\n' "$SCREEN" | grep -c 'JupyterLab - ready')|$(printf '%s\n' "$SCREEN" | grep -c 'Positron - not on')|$(printf '%s\n' "$SCREEN" | grep -c 'Skip - open nothing')"
    contains "Enter: JupyterLab opens, its address said" "JupyterLab is running: http://127.0.0.1:" "$SCREEN"
    contains "...and Marimo" "Marimo is running: http://127.0.0.1:" "$SCREEN"
    contains "...then how to stop them" "To stop JupyterLab and Marimo: exakit notebook stop" "$SCREEN"
    contains "...exit 0" "RC=0" "$SCREEN"
    replay 'jj\r'
    check "down twice steps over Positron to Skip; Enter there opens nothing" "1|0" \
        "$(printf '%s\n' "$SCREEN" | grep -c 'Nothing opened')|$(printf '%s\n' "$SCREEN" | grep -c 'is running')"
    check "...the menu redrawn in place, not stacked" "1" "$(printf '%s\n' "$SCREEN" | grep -c 'JupyterLab - ready')"
    replay '\ry\r' NLS_JUPYTER=missing
    contains "JupyterLab removed: the row says so" "[✓] JupyterLab - missing - reinstall it into the kit's environment" "$SCREEN"
    contains "...Enter, then the reinstall is asked" "Reinstall JupyterLab $(notebook_frontend_pin jupyterlab) into the kit's notebook environment? [Y/n] y" "$SCREEN"
    contains "...installed" "installed into the kit's notebook environment" "$SCREEN"
    contains "...and opened" "JupyterLab is running: http://127.0.0.1:" "$SCREEN"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
