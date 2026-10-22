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
#   - the install is refused on a launcher older than 2.3.0, with the remedy
#     and nothing recorded (ML-1 preflight)
#   - udf-build checks for a running Docker or Podman (whose API socket it
#     hands to the build) and for the free disk estimate before anything
#     heavy runs (AC-ML1.3)
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
        run_python_any() { python3 "$@"; }
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

echo "the install itself is refused on an old launcher (ML-1 preflight):"
out="$(STUB_LAUNCHER=2.2.9 scenario 'manifest_del components.udf_devkit; udf_devkit_install; echo "rc=$?"; manifest_get components.udf_devkit.version || echo "no record"' 2>&1)"
contains "the install fails" "rc=1" "$out"
contains "naming the version it needs and the one it found" "needs Exasol launcher 2.3.0 or later; this machine has 2.2.9" "$out"
contains "and the remedy" "exakit update personal" "$out"
contains "nothing is recorded" "no record" "$out"
check "and nothing runs" "" "$(cat "$WORK/calls")"
out="$(STUB_LAUNCHER="" scenario 'personal_launcher_version() { return 1; }; manifest_del components.udf_devkit; udf_devkit_install; echo "rc=$?"' 2>&1)"
contains "no launcher answering is refused too" "this machine has none" "$out"
out="$(STUB_LAUNCHER=2.3.0 scenario 'exakit_db_reachable() { return 1; }; manifest_del components.udf_devkit; udf_devkit_install; echo "rc=$?"; manifest_get components.udf_devkit.version' 2>&1)"
contains "2.3.0 is enough" "rc=0" "$out"

echo "udf-build checks the container engine and the free disk before it starts (AC-ML1.3):"
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
stub() { # stub <name> <body>
    printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"
}
printf 'numpy==1.26.4\n' > "$WORK/pinned.txt"
build() { # build <extra scenario code> — udf-build up to its first heavy step, which is stubbed to stop it
    PATH="$STUBS:$PATH" scenario 'manifest_set components.udf_devkit.version 0.1.0
        notebook_installed_version() { echo 1.0.0; }
        _notebook_uv() { echo "preflight passed DOCKER_HOST=${DOCKER_HOST:-unset}" >&2; return 1; }
        '"$1"'
        cmd_udf_build "$WORK/pinned.txt" --yes' 2>&1
}
stub docker 'exit 1'
stub podman 'exit 1'
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 999999999 1 524288000 1% /"'
out="$(build '')"
contains "no engine answers: refused, naming both" "needs a running container engine, Docker or Podman, and none answers" "$out"
lacks_out="$(printf '%s' "$out" | grep -c 'preflight passed' || true)"
check "and nothing after the check runs" "0" "$lacks_out"
stub podman 'case "$*" in *"--format"*) echo /nonexistent/podman.sock ;; esac; exit 0'
out="$(build 'unset DOCKER_HOST')"
contains "Podman without its API socket: refused, with the remedy" "Podman answers, but not its Docker-compatible API" "$out"
python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$WORK/podman.sock"
stub podman 'case "$*" in *"machine inspect"*) echo "'"$WORK"'/podman.sock" ;; *"--format"*) echo /nonexistent ;; esac; exit 0'
out="$(build 'unset DOCKER_HOST')"
contains "the Podman the launcher installed is enough: its socket is handed to the build" "preflight passed DOCKER_HOST=unix://$WORK/podman.sock" "$out"
stub docker 'exit 0'
out="$(build '')"
contains "a running Docker passes" "preflight passed" "$out"
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 999999999 1 1048576 1% /"'
out="$(build '')"
contains "too little free disk: refused with the estimate and what is free" "needs about 25 GB free" "$out"
contains "...what is free" "has 1 GB" "$out"
check "and nothing after the check runs" "0" "$(printf '%s' "$out" | grep -c 'preflight passed' || true)"
rm -f "$STUBS/df" "$STUBS/docker" "$STUBS/podman"

echo "an uninstall leaves the containers to the launcher:"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; udf_devkit_uninstall 1' 2>&1)"
contains "the dry run says the containers stay" "containers stay installed in the database" "$out"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
