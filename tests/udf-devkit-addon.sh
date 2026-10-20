#!/usr/bin/env bash
# udf-devkit-addon.sh — the udf-devkit add-on's own behaviour in
# setup/lib/udf-devkit.sh (the rules themselves: tests/test_udf_tool.py).
#
#   bash tests/udf-devkit-addon.sh
#
# What it pins:
#   - a container install is confirmed first; a decline changes nothing
#   - the running add-on services are stopped before it and started after the
#     database answers again, and the install is the launcher's own command
#   - an old launcher is refused with the remedy, before anything runs
#   - udf-file copies into the deployment's BucketFS folder (never outside the
#     bucket) and prints the path a UDF reads
#   - udf-use default says no prebuilt container is published; every command
#     refuses what it does not know, and names the marketplace when the add-on
#     is not installed
#
# A sandboxed kit home and deployment folder, a stub launcher; no database.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
export EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/deployment"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$EXAKIT_PERSONAL_DEPLOY_DIR/local/runtime/exa"

# One scenario per subshell: the real modules, the machine stubbed at its seams.
scenario() { # scenario <body>
    (
        # shellcheck disable=SC1091
        . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/udf-devkit.sh"
        EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
        CALLS="$WORK/calls"; : > "$CALLS"
        manifest_init >/dev/null 2>&1
        personal_cli() { printf '%s\n' "$WORK/exasol"; }
        personal_launcher_version() { printf '%s\n' "${STUB_LAUNCHER:-2.3.0}"; }
        personal_wait_ready() { echo "wait" >> "$CALLS"; }
        exakit_db_reachable() { return 0; }
        exakit_service_ids() { printf 'database\ndash-server\nexasol-scheduler\n'; }
        exakit_service_status() { case "$1" in dash-server) echo running ;; *) echo stopped ;; esac; }
        exakit_service_stop() { echo "stop $1" >> "$CALLS"; }
        exakit_service_start() { echo "start $1" >> "$CALLS"; }
        udf_devkit_smoke() { echo "smoke $*" >> "$CALLS"; }
        eval "$1"
    )
}
cat > "$WORK/exasol" <<'STUB'
#!/bin/sh
echo "launcher $*" >> "$CALLS_FILE"
case "$1 $2 $3" in "slc list --json") echo '[{"alias": "PYTHON3", "installed": false}]' ;; esac
exit 0
STUB
chmod +x "$WORK/exasol"
export CALLS_FILE="$WORK/calls"

echo "a container install is confirmed, and the services follow the restart:"
out="$(scenario 'confirm() { return 0; }; manifest_set components.udf_devkit.version 0.1.0; cmd_udf_setup' 2>&1)"
calls="$(grep -v "slc list" "$WORK/calls" | tr '\n' '|')"
check "stop, install, wait, start, smoke - in that order" \
    "stop dash-server|launcher slc install PYTHON3 --auto-approve --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR|wait|start dash-server|smoke PYTHON3|" "$calls"

out="$(scenario 'confirm() { return 1; }; manifest_set components.udf_devkit.version 0.1.0; cmd_udf_setup' 2>&1)"
contains "a decline says nothing changed" "was not started; nothing changed" "$out"
check "and installs nothing, stops nothing" "" "$(grep -v "slc list" "$WORK/calls" | grep -v smoke)"

echo "an old launcher is refused first:"
out="$(STUB_LAUNCHER=2.2.0 scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_setup' 2>&1)"
contains "names the remedy" "exakit update personal" "$out"
check "and runs nothing" "" "$(cat "$WORK/calls")"

echo "udf-file copies into the bucket and names the UDF path:"
printf 'weights' > "$WORK/model.pkl"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_file "$WORK/model.pkl" models/m.pkl' 2>&1)"
check "the file is in the bucket" "weights" "$(cat "$EXAKIT_PERSONAL_DEPLOY_DIR/local/runtime/exa/bucketfs/bfsdefault/default/models/m.pkl" 2>/dev/null)"
contains "and the UDF path is printed" "/buckets/bfsdefault/default/models/m.pkl" "$out"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_file "$WORK/model.pkl" ../escape.pkl' 2>&1)"
contains "never outside the bucket" "not a path inside the bucket" "$out"
check "nothing written outside" "" "$(ls "$EXAKIT_PERSONAL_DEPLOY_DIR/local/runtime/exa/bucketfs/bfsdefault/" 2>/dev/null | grep escape || true)"

echo "the commands refuse what they do not know:"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_use default' 2>&1)"
contains "default says none is published" "No prebuilt container" "$out"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_use nope.zip' 2>&1)"
contains "a tarball must be a tarball" "is not a container tarball" "$out"
printf 'numpy>=1\n' > "$WORK/req.txt"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_build "$WORK/req.txt"' 2>&1)"
contains "udf-build refuses an unpinned package before anything heavy" "not pinned" "$out"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_setup --frob' 2>&1)"
contains "udf-setup refuses an unknown option" "takes --force" "$out"
out="$(scenario 'manifest_del components.udf_devkit; cmd_udf_setup' 2>&1)"
contains "not installed names the marketplace" "exakit marketplace udf-devkit" "$out"

echo "an uninstall leaves the containers to the launcher:"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; udf_devkit_uninstall 1' 2>&1)"
contains "the dry run says the containers stay" "containers stay installed in the database" "$out"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
