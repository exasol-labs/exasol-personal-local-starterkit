#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py: the data question's table, then the load in
# the same table - which keeps only what was picked. Everything below the stubs
# is shipping code (exakit_data_load_menu); exapump and the database are faked.
set -u
ROOT="$1"; W="$(mktemp -d)"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUB'
case "$1" in
    upload) exit 0 ;;
    sql)
        shift; shift; shift
        if [ -n "${1:-}" ]; then
            case "$1" in *EXAKIT_RC*) echo "EXAKIT_RC[3000]" ;; esac
            exit 0
        fi
        body="$(cat)"
        case "$body" in *CHECK_NAME*) echo "CHECK_NAME,STATUS,DETAIL"; echo "fk: x,OK,0 rows" ;; esac
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
exakit_ensure_runtime_running() { return 0; }
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
EXAKIT_DATASETS_PRESELECT=energy,weather
exakit_data_load_menu
printf 'IDS=%s\n' "$(printf '%s' "$EXAKIT_TABLE_IDS" | tr '\n' ',')"
rm -rf "$W"
