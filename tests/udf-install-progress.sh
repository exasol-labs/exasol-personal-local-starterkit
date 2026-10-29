#!/usr/bin/env bash
# Real restart wrapper, fake launcher: observe the row at the actual work boundary.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/udf-devkit.sh"
info(){ :; }; warn(){ :; }
exakit_service_ids(){ :; }
run_logged(){ "$@"; }
_UDF_YES=1
_UDF_PROGRESS_SECTION=primary
EXAKIT_ADDON_TABLE_STATE="$WORK/table"
EXAKIT_ADDON_TABLE_ROW=2
printf 'group|Select All|1|idle||||||||\ncorner|udf-devkit|1|running|0|65|40|1|installing|||\n' > "$WORK/table"
: > "$WORK/table.activity"
launcher(){ cut -d'|' -f9 "$WORK/table" | tail -1 > "$WORK/install-phase"; }
personal_wait_ready(){ cut -d'|' -f9 "$WORK/table" | tail -1 > "$WORK/restart-phase"; }
_udf_with_restart 'Installing official PYTHON3 container' launcher
[ "$(cat "$WORK/install-phase")" = 'Installing official PYTHON3 container' ] || { echo 'FAIL generic installing row hides the real launcher step'; exit 1; }
[ "$(cat "$WORK/restart-phase")" = 'Waiting for database restart' ] || { echo 'FAIL restart wait hides the real step'; exit 1; }
first="$(sed -n '2p' "$WORK/table" | cut -d'|' -f5)"
_UDF_PROGRESS_SECTION=ml
_udf_install_stage download 'Downloading Python ML container (842 MB)'
download="$(sed -n '2p' "$WORK/table" | cut -d'|' -f5)"
[ "$download" -gt "$first" ]
_udf_install_stage verify 'Verifying download checksum'
_udf_install_stage prepare 'Preparing the Python ML runtime'
_udf_with_restart 'Installing PYTHON3_ML container' launcher
_udf_install_stage smoke 'Checking packages in PYTHON3_ML'
[ "$(sed -n '2p' "$WORK/table" | cut -d'|' -f5)" -eq 63 ]
grep -q 'Checking packages in PYTHON3_ML' "$WORK/table.activity"
_UDF_PROGRESS_SECTION=""
cp "$WORK/table" "$WORK/before-validation"
_udf_install_stage smoke 'Validation checks'
cmp -s "$WORK/table" "$WORK/before-validation" # validation must not regress its 65% stage
echo 'PASS actual launcher/restart boundaries and ML stages update the row; validation never resets progress'
