#!/usr/bin/env bash
# load-data.sh — load the sample dataset into the local database.
#
#   bash setup/load-data.sh            # runs bundled sample schema + load + verify once
#   bash setup/load-data.sh --force    # re-runs bundled sample load even if already loaded
#
# Separate from the installer on purpose: the one-command install brings up
# the components; this script fills the database, and can be re-run any time
# (every run is fully logged — that is the repeatability story). The installer
# also offers a guided import menu, while `exakit data-load --force` invokes this same
# sample pipeline (exakit_load_sample_data in setup/lib/exapump.sh).
#
# Consumes files delivered with the kit, referenced by path:
#   data/datasets/tpch/01_create_schema.sql .. 03_verify_setup.sql
#   data/datasets/tpch/data/*.csv
# Missing files are reported as pending, not errors.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/exapump.sh"

EXAKIT_LOG_FILE="$EXAKIT_LOG_DIR/load-data-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$EXAKIT_LOG_DIR"
: > "$EXAKIT_LOG_FILE"

[ -f "$EXAKIT_MANIFEST" ] || die "No installation found. Run the installer first."
command -v "$(exapump_cli)" >/dev/null 2>&1 || [ -x "$(exapump_cli)" ] || \
    die "exapump is not installed. Run the installer first."

info "Loading the sample dataset (log: $EXAKIT_LOG_FILE)"
exakit_load_sample_data "$KIT_ROOT" "${1:-}"
