#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty from tests/lakehouse-picker.sh:
# the `exakit connect` source menu alone (_exakit_vs_pick), shipping code with
# the catalog stubbed (the Lakehouse subtree is the connector's own
# settings), so the replay can assert the Lakehouse subtree a person
# is left looking at and what the menu hands on. The last line is the answer:
#   PICKED=<ids> CATALOG=<catalog> FILES=<files> RC=<rc>
set -u
ROOT="$1"
W="$(mktemp -d "${TMPDIR:-/tmp}/lakehouse-picker.XXXXXX")"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"

# The catalog as the unified engine lists it today - and, with
# PICKER_OLD_CATALOG=1, as main lists it before (iceberg-rest and unity still
# their own rows): the one Lakehouse row folds them either way.
_exakit_vs_catalog() {
    EXAKIT_VS_RESULT="$(python3 - <<'PY'
import json, os
ids = [("postgresql", "PostgreSQL"), ("mysql", "MySQL"), ("sqlserver", "SQL Server"), ("oracle", "Oracle"),
       ("snowflake", "Snowflake"), ("bigquery", "Google BigQuery"), ("s3", "Amazon S3"),
       ("azure-blob", "Azure Blob Storage"), ("databricks", "Databricks"),
       ("lakehouse", "Lakehouse (Iceberg / Delta)")]
if os.environ.get("PICKER_OLD_CATALOG") == "1":
    ids += [("iceberg-rest", "Iceberg REST catalog"), ("unity", "Unity Catalog (lakehouse engine)")]
ids += [("mongodb", "MongoDB")]
print(json.dumps({"connectors": [{"id": i, "name": n, "status": "candidate"} for i, n in ids]}))
PY
)"
}
_exakit_vs_clock_check() { :; }

_exakit_vs_pick "$W"
rc=$?
# What the forms are handed (exakit_vs_preset), as connect does after the pick.
_EXAKIT_VS_PRESET=""
_exakit_vs_lakehouse_handoff
printf 'PRESET=%s\n' "$(printf '%s' "$_EXAKIT_VS_PRESET" | paste -sd';' -)"
printf 'PICKED=%s CATALOG=%s FILES=%s RC=%s\n' "${EXAKIT_VS_PICKED:-}" "${EXAKIT_VS_LAKEHOUSE_CATALOG:-}" \
    "${EXAKIT_VS_LAKEHOUSE_FILES:-}" "$rc"
rm -rf "$W"
