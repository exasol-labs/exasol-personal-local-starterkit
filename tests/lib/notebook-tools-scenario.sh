#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty: the marketplace's add-ons
# table with the notebook add-on's tools as CHILD ROWS of its row (JupyterLab,
# Marimo, Positron, one level deeper), ticked right there, and then the same
# table filling in each tool's own status as the notebook install settles it.
#
# exakit_marketplace_menu, the table, its key handling and
# _exakit_marketplace_apply and Python-backed notebook child rows are shipping code. What is
# faked is everything that would reach outside: the registry (notebook first,
# so its row is a tee, then a demo add-on), the add-on states, the About text,
# the notebook install (it records the answer and settles the tool rows), and
# test executables used to probe JupyterLab and Positron.
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
EXAKIT_VERSION_POLICY=pinned; export EXAKIT_VERSION_POLICY
printf '{}\n' > "$EXAKIT_HOME/manifest.json"
unset EXAKIT_MARKETPLACE_ADDONS EXAKIT_MARKETPLACE_ONLY EXAKIT_NOTEBOOK_FRONTENDS \
      EXAKIT_NOTEBOOK_JUPYTER EXAKIT_NOTEBOOK_MARIMO
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
exakit_marketplace_list() { return 1; }

# The registry and the add-on states.
exakit_marketplace_addons() { printf 'notebook|Notebooks\ndemo-alpha|Demo\n'; }
_exakit_addon_offerable() { return 0; }
_exakit_addon_visible() { return 0; }
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
if [ "${NBT_JUPYTER:-none}" = own ]; then
    printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_BIN_DIR/jupyter-lab"
    chmod +x "$EXAKIT_BIN_DIR/jupyter-lab"
fi
if [ "${NBT_POSITRON:-no}" = yes ]; then
    printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_BIN_DIR/positron"
    chmod +x "$EXAKIT_BIN_DIR/positron"
fi
PATH="$EXAKIT_BIN_DIR:$PATH"; export PATH

# The installs. The notebook's records the answer it was handed, and whether
# its question hook was asked; the stub settles each tool row.
notebook_questions() { printf 'asked\n' >> "$W/asked"; }
notebook_validate() { :; }
notebook_summary() { printf 'notebooks: exakit notebook\n'; }
notebook_install() {
    printf 'notebook ' >> "$W/installed"
    printf '%s\n' "${EXAKIT_NOTEBOOK_FRONTENDS:-unset}" > "$W/frontends"
    sleep 1
    case ",${EXAKIT_NOTEBOOK_FRONTENDS:-}," in
        *,jupyterlab,*)
            if [ "${NBT_JUPYTER:-none}" = own ]; then
                exakit_addon_table_child jupyterlab done "yours, kernel added"
            else
                exakit_addon_table_child jupyterlab done "installed $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["notebook"]["frontends"]["jupyterlab"])' "$ROOT/versions.json")"
            fi ;;
        *) exakit_addon_table_child jupyterlab skipped skipped ;;
    esac
    case ",${EXAKIT_NOTEBOOK_FRONTENDS:-}," in
        *,marimo,*) exakit_addon_table_child marimo done "installed $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["notebook"]["frontends"]["marimo"])' "$ROOT/versions.json")" ;;
        *) exakit_addon_table_child marimo skipped skipped ;;
    esac
    case ",${EXAKIT_NOTEBOOK_FRONTENDS:-}," in
        *,positron,*)
            if [ "${NBT_POSITRON:-no}" = yes ]; then
                exakit_addon_table_child positron done configured
            else
                exakit_addon_table_child positron skipped "not on this machine - folder ready"
            fi ;;
        *) exakit_addon_table_child positron skipped skipped ;;
    esac
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
