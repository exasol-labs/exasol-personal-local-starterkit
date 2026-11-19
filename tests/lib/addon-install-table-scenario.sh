#!/usr/bin/env bash
# The install's add-ons table when the two every kit gets are in already: one
# the early install got in during this run ("Auto installed"), one that was
# there before ("Installed"): the first checked and locked, the second with no
# checkbox; and the description of
# the row under the cursor under the hint (the table has no room for its
# Description column). Run by tests/marketplace.sh under tty-replay.py.
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
export EXAKIT_ABOUT_OFFLINE=1 EXAKIT_VERSIONS_URL=http://offline.invalid/versions.json
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
_exakit_marketplace_python_hooks; manifest_init >/dev/null 2>&1
exakit_marketplace_addon_installed() { case "$1" in dash-server|json-tables) return 0 ;; esac; return 1; }
_exakit_addon_system_present() { return 1; }
_exakit_marketplace_apply_python() { echo "APPLY $1"; }
# What _exakit_addons_early_collect leaves when the early run got Dash Server in.
EXAKIT_ADDONS_EARLY_DONE="dash-server"
_all="$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
EXAKIT_MARKETPLACE_REASONS="$(_exakit_marketplace_catalog_about "$_all")" EXAKIT_MARKETPLACE_INSTALL_TABLE=1 \
    EXAKIT_MARKETPLACE_PRESELECT=none EXAKIT_MARKETPLACE_NO_TEXTUAL=1 exakit_marketplace_menu
rm -rf "$W"
