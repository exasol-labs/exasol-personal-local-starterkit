#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty: the marketplace's add-ons
# table with the notebook add-on's tools as CHILD ROWS of its row (JupyterLab,
# Marimo, Positron, one level deeper), ticked right there, and then the same
# table filling in each tool's own status as the notebook install settles it.
#
# exakit_marketplace_menu, the table, its key handling and
# _exakit_marketplace_apply are shipping code, and so are notebook.sh's
# notebook_table_children / _picked and notebook_front_ends_setup. What is
# faked is everything that would reach outside: the registry (notebook first,
# so its row is a tee, then a demo add-on), the add-on states, the About text,
# the notebook's real install (it records what it was handed and then settles
# the tools through the real notebook_front_ends_setup), and the probes that
# find a JupyterLab or a Positron on this machine.
#
#   NBT_JUPYTER=own|none     a JupyterLab on PATH, or none (default none)
#   NBT_POSITRON=yes|no      a Positron on this machine (default no)
#   NBT_STOP=menu            stop after the selection: the screen is then the
#                            selection table, and nothing installs
#   NBT_ONLY=notebook        the persona closing offer's filter
#                            (EXAKIT_MARKETPLACE_ONLY): the notebook is then the
#                            only row, so it is drawn as the corner
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_MARKETPLACE_ONLY EXAKIT_NOTEBOOK_FRONTENDS \
      EXAKIT_NOTEBOOK_JUPYTER EXAKIT_NOTEBOOK_MARIMO
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/notebook.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"

# The registry and the add-on states.
exakit_marketplace_addons() { printf 'notebook|Notebooks\ndemo-alpha|Demo\n'; }
_exakit_addon_offerable() { return 0; }
exakit_marketplace_addon_installed() { return 1; }
_exakit_addon_system_present() { return 1; }
exakit_marketplace_addon_available() { return 0; }
exakit_marketplace_addon_description() {
    case "$1" in
        notebook) printf 'Notebooks connected to the local Exasol database' ;;
        *) printf 'A demo add-on' ;;
    esac
}
exakit_component_available() { printf '3.1.0\n'; }
manifest_get() { return 1; }
manifest_set() { :; }
exakit_install_addon_skills() { :; }

# What is on this machine.
notebook_find_jupyter() {
    [ "${NBT_JUPYTER:-none}" = own ] || return 1
    printf 'own /opt/tools/bin/jupyter-lab\n'
}
notebook_find_positron() {
    [ "${NBT_POSITRON:-no}" = yes ] || return 1
    printf '/Applications/Positron.app\n'
}
notebook_marimo_installed() { [ -f "$W/marimo" ]; }

# The installs. The notebook's records the answer it was handed, and whether
# its question hook was asked; the tools then settle through the real
# notebook_front_ends_setup.
notebook_questions() { printf 'asked\n' >> "$W/asked"; }
notebook_offer_jupyter() { sleep 1; return 0; }
notebook_install_marimo() { : > "$W/marimo"; return 0; }
notebook_prepare_positron() { return 0; }
notebook_validate() { :; }
notebook_install() {
    printf 'notebook ' >> "$W/installed"
    printf '%s\n' "${EXAKIT_NOTEBOOK_FRONTENDS:-unset}" > "$W/frontends"
    sleep 1
    NOTEBOOK_FRONT_ENDS=""
    notebook_choose_front_ends
    notebook_front_ends_setup
    return 0
}
demo_alpha_install() { printf 'demo-alpha ' >> "$W/installed"; sleep 1; return 0; }

if [ "${NBT_STOP:-}" = menu ]; then
    _exakit_marketplace_apply() { printf '%s\n' "$1" > "$W/picked"; printf '%s\n' "${EXAKIT_NOTEBOOK_FRONTENDS:-unset}" > "$W/frontends"; }
fi

if [ -n "${NBT_ONLY:-}" ]; then
    heading "Add-ons for your personas"
    EXAKIT_MARKETPLACE_ONLY="$NBT_ONLY" exakit_marketplace_menu
else
    exakit_marketplace_menu
fi
printf 'PICKED=%s\n' "$(cat "$W/picked" 2>/dev/null || true)"
printf 'INSTALLED=%s\n' "$(cat "$W/installed" 2>/dev/null || true)"
printf 'FRONTENDS=%s\n' "$(cat "$W/frontends" 2>/dev/null || echo not-installed)"
printf 'QUESTIONS=%s\n' "$(cat "$W/asked" 2>/dev/null || echo none)"
rm -rf "$W"
