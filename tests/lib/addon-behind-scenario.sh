#!/usr/bin/env bash
# The install's add-ons table while its own two install (EXAKIT_MARKETPLACE_AUTO_FIRST):
# the table asks at once, the two drawn checked and locked with their bars moving,
# and after Enter they stay checked while the row picked meanwhile installs.
# Run by tests/marketplace.sh under tty-replay.py.
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
export EXAKIT_ABOUT_OFFLINE=1 EXAKIT_VERSIONS_URL=http://offline.invalid/versions.json EXAKIT_ADDONS_EARLY=0
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
_exakit_marketplace_python_hooks; manifest_init >/dev/null 2>&1
exakit_marketplace_addon_installed() { return 1; }
_exakit_addon_system_present() { return 1; }
_exakit_addon_offerable() { return 0; }
. "$ROOT/tests/lib/mock-addon-events.sh"
# The two take a while; anything else installs at once.
for _id in $(exakit_marketplace_addons | cut -d'|' -f1); do
    eval "$(_exakit_addon_fn "$_id" install)() { return 0; }"
done
dash_server_install() { sleep 6; return 0; }
json_tables_install() { sleep 6; return 0; }
_all="$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
EXAKIT_MARKETPLACE_REASONS="$(_exakit_marketplace_catalog_about "$_all")" EXAKIT_MARKETPLACE_INSTALL_TABLE=1 \
    EXAKIT_MARKETPLACE_PRESELECT=none EXAKIT_MARKETPLACE_NO_TEXTUAL=1 \
    EXAKIT_MARKETPLACE_AUTO_FIRST="dash-server,json-tables" exakit_marketplace_menu
rm -rf "$W"
