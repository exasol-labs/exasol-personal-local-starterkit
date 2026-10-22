#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty: plain `exakit notebook` on
# a terminal - the "Open which notebook tools?" multi-select, each row saying
# its tool's state, and then the tools picked opened, one line each, and one
# line naming how to stop them.
#
# notebook_cmd, its preflight, the menu, ui_checkbox_menu and confirm are
# shipping code. What is faked is everything that would reach outside: the
# database (up), the store and kernel scripts, the servers (they "start" at
# once), the browser, the package install, and Positron (not on this machine,
# so its row is the disabled one).
#
#   NLS_JUPYTER=kit|missing   the kit's JupyterLab is in its venv, or was
#                             removed (default kit)
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
unset EXAKIT_NOTEBOOK_VENV EXAKIT_NOTEBOOK_HOME EXAKIT_NOTEBOOK_DIR EXAKIT_MARIMO_PORT EXAKIT_NOTEBOOK_JUPYTER \
      EXAKIT_NOTEBOOK_MARIMO EXAKIT_NOTEBOOK_FRONTENDS
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
manifest_init >/dev/null 2>&1
printf 'pw' > "$W/pw"
manifest_set runtime.dsn "db.test:8563"
manifest_set runtime.password_file "$W/pw"
manifest_set components.notebook.version 3.1.0
manifest_set components.notebook.front_ends "jupyterlab,marimo,positron"
manifest_set components.notebook.port "$(free_port)"
manifest_set components.notebook.marimo_port "$(free_port)"

# The kit's venv: a Python whose packages import, and the tools asked for.
VB="$EXAKIT_NOTEBOOK_VENV/bin"; mkdir -p "$VB"; rm -f "$VB/python"
printf '#!/bin/sh\ncase "$*" in *"import exasol.nb_connector"*) exit 0 ;; esac\nexec python3 "$@"\n' > "$VB/python"
mktool() { printf '#!/bin/sh\nexit 0\n' > "$VB/$1"; chmod +x "$VB/$1"; }
chmod +x "$VB/python"
mktool marimo
[ "${NLS_JUPYTER:-kit}" = kit ] && mktool jupyter-lab

exakit_db_reachable() { return 0; }
_notebook_py() { case "$1" in write_store.py) printf 'same\n' ;; esac; return 0; }
notebook_server_state() { cat "$W/jstate" 2>/dev/null || echo stopped; }
notebook_server_start() { echo running > "$W/jstate"; manifest_set components.notebook.port "$1"; }
notebook_marimo_state() { cat "$W/mstate" 2>/dev/null || echo stopped; }
notebook_marimo_start() { echo running > "$W/mstate"; manifest_set components.notebook.marimo_port "$1"; }
_notebook_open_browser() { return 0; }
notebook_find_positron() { return 1; }
notebook_sync_packages() { [ "${NOTEBOOK_ADD_JUPYTERLAB:-0}" = 1 ] && mktool jupyter-lab; return 0; }
_notebook_frontends_installed() { [ -x "$VB/jupyter-lab" ] && printf 'jupyterlab=4.4.9\n'; return 0; }

# Installed as the add-on leaves it: the kit's notebooks already in their folders.
notebook_copy_notebooks >/dev/null 2>&1
notebook_copy_notebooks marimo >/dev/null 2>&1
notebook_cmd
printf 'RC=%s\n' "$?"
rm -rf "$W"
