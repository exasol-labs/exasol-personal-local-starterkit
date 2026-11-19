#!/usr/bin/env bash
# The install's add-ons table while the early install (exakit_addons_early_begin)
# is still going: drawn at once, the two rows it started follow it
# (_exakit_addons_early_follow) and end "Auto installed" when it is over; the
# row it never started (a persona's add-on) installs after it, through the
# shipping adapter. Run by tests/marketplace.sh under tty-replay.py.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
manifest_init >/dev/null 2>&1
. "$ROOT/tests/lib/mock-addon-events.sh"

demo_gamma_install() { sleep 1; return 0; }
demo_gamma_summary() { printf 'a persona add-on\n'; }
# The early run's two are in once it is over.
exakit_marketplace_addon_installed() { case "$1" in demo-alpha|demo-beta) return 0 ;; esac; return 1; }

# What exakit_addons_early_begin leaves behind: its marks, and a run that takes a while.
_ed="$(_exakit_addons_early_dir)"; mkdir -p "$_ed"
printf 'demo-alpha,demo-beta\n' > "$_ed/ids"
( sleep 3; printf '0\n' > "$_ed/rc" ) &
printf '%s\n' "$!" > "$_ed/pid"

EXAKIT_ADDON_TABLE_STATE="$W/addons"
EXAKIT_ADDON_TABLE_NO_GROUP=1
_exakit_addon_table_build "$EXAKIT_ADDON_TABLE_STATE" demo-alpha demo-beta demo-gamma
UI_TABLE_TITLE="Marketplace add-ons"
UI_TABLE_COL1="Add-on"
# The Version column the real menu has (exakit_marketplace_menu): with it the
# Status column comes and goes, which is what RAD-01's race needed.
UI_TABLE_COL2="Version"
UI_TABLE_COL2_YIELDS=1
# As the install's table starts its first stage (exakit_marketplace_menu).
UI_TABLE_LINES=0
printf '\n\n'
EXAKIT_ADDONS_EARLY_FOLLOW=1 EXAKIT_ADDON_TABLE_KEEP=1 _exakit_marketplace_apply_python "demo-alpha,demo-beta,demo-gamma"
_exakit_addon_table_cleanup
wait
rm -rf "$W"
