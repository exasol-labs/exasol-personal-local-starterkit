#!/usr/bin/env bash
# The INSTALLER's data-load shape, faithfully: the real loader, the real table,
# and — the part that differs from every other caller — each load inside its own
# SUBSHELL, the way exakit_maybe_offer_data_load runs them so a die() cannot end
# the install. Driven by tests/lib/tty-replay.py under a real pty.
set -u
ROOT="$1"; W="$(mktemp -d)"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"

# A stub engine: uploads and scripts succeed, a row count answers with the token
# the real one emits. No database, no network.
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUB'
#!/bin/sh
case "$1" in
    upload) exit 0 ;;
    sql)
        shift; shift; shift
        if [ -n "${1:-}" ]; then
            case "$1" in *EXAKIT_RC*) echo "EXAKIT_RC[3000]" ;; esac
            exit 0
        fi
        body="$(cat)"
        case "$body" in
            *CHECK_NAME*) echo "CHECK_NAME,STATUS,DETAIL"; echo "fk: x,OK,0 rows" ;;
        esac
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$EXAKIT_BIN_DIR/exapump"
exapump_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exapump"; }
EXAKIT_EXAPUMP_PROFILE="starter-kit"
manifest_get() { [ "$1" = "components.exapump.profile" ] && printf 'starter-kit\n'; return 0; }
manifest_set() { return 0; }
exakit_dataset_loaded() { return 1; }
exakit_schema_present() { return 0; }
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}

# Still the exapump step's title when the loads run: no begin_step happens in
# between, and it is what made the competing spinner's line 45 columns wide.
EXAKIT_ACTIVE_LABEL="Step 3/6  exapump (data loading CLI)"
EXAKIT_LOG_FILE="$W/install.log"
UI_TABLE_TITLE="Datasets to load"
EXAKIT_TABLE_STATE="$W/table"
exakit_data_table_build "$EXAKIT_TABLE_STATE"
ui_table_tick "$EXAKIT_TABLE_STATE" "$EXAKIT_TABLE_DEFAULTS"
EXAKIT_TABLE_SELECTION="$EXAKIT_TABLE_DEFAULTS"
# What ui_table_menu leaves behind when Enter is pressed.
ui_table_render "$EXAKIT_TABLE_STATE" 0

EXAKIT_TABLE_LIVE=0
ui_table_begin "$EXAKIT_TABLE_STATE" && EXAKIT_TABLE_LIVE=1
_row=0
while IFS= read -r _id; do
    _row=$(( _row + 1 ))
    [ -n "$_id" ] || continue
    [ "$_id" = "local" ] && continue
    case ",$EXAKIT_TABLE_SELECTION," in *",$_row,"*) ;; *) continue ;; esac
    # THE SUBSHELL, with the detach the installer really does (common.sh). It
    # matters: detach drops _UI_SPIN_PID, and without it in here the subshell
    # inherits the pid, so run_logged's ui_spin_begin nests into a no-op and no
    # competing spinner is ever created -- the very thing that corrupted the
    # frame on a real install could not happen in this scenario.
    ( ui_table_detach; exakit_load_dataset_dir "$ROOT" "$_id" ) || true
done <<IDS
$EXAKIT_TABLE_IDS
IDS
[ "$EXAKIT_TABLE_LIVE" = 1 ] && ui_table_end "$EXAKIT_TABLE_STATE"
rm -rf "$W"
