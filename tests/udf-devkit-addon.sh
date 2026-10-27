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
#   - udf-use default picks the matrix row for the database's architecture
#     and version, takes the tarball from EXAKIT_UDF_CONTAINERS_MIRROR, verifies
#     size and sha256 before the launcher sees it, installs it as PYTHON3_ML
#     --language python, hands the pinned name==version to the smoke UDF and
#     records the url; the cached file is reused; --json is one object
#     (AC-ML1.2, AC-ML1.6)
#   - a digest that does not match is exit 4, step verify, and the file is gone;
#     no row for the architecture or the database version is exit 4, step
#     select-container, naming what did not match; a decline is exit 5
#   - EXAKIT_UDF_LANGUAGE=rust at install (and --language rust) takes the Rust
#     row to `slc custom install --alias RUST --language rust`, records the
#     language and says the smoke UDF is the next step; --language frob is exit 2
#   - every command refuses what it does not know, and names the marketplace
#     when the add-on is not installed
#
# A sandboxed kit home and deployment folder, a stub launcher, a test copy of
# versions.json whose rows point at a tiny fake tarball in a mirror folder; no
# database.

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
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_use default --language frob' 2>&1)"; rc=$?
contains "--language frob is refused" "must be python or rust, not 'frob'" "$out"
check "with exit 2" "2" "$rc"
out="$(EXAKIT_UDF_LANGUAGE=frob scenario 'manifest_set components.udf_devkit.version 0.1.0; cmd_udf_setup' 2>&1)"; rc=$?
contains "so is EXAKIT_UDF_LANGUAGE=frob" "EXAKIT_UDF_LANGUAGE" "$out"
check "with exit 2" "2" "$rc"
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

echo "udf-use default: the matrix row for this database, verified before it is installed (AC-ML1.2):"
MIRROR="$WORK/mirror"; mkdir -p "$MIRROR"
printf 'fake python container' > "$MIRROR/py-fake.tar.gz"
printf 'fake rust container' > "$MIRROR/lc-rust-fake.tar.gz"
fake_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
fake_size() { wc -c < "$1" | tr -d ' '; }
# A test copy of the kit's versions.json: the same document, its container rows
# replaced by ones that point at the fake tarballs (sha256 and size real).
matrix() { # matrix <out-file> <python sha256> [arches]
    python3 - "$ROOT/versions.json" "$1" "$2" "$(fake_size "$MIRROR/py-fake.tar.gz")" \
        "$(fake_sha "$MIRROR/lc-rust-fake.tar.gz")" "$(fake_size "$MIRROR/lc-rust-fake.tar.gz")" "${3:-x86_64 aarch64}" <<'MATRIX'
import json, sys
src, out, py_sha, py_size, rs_sha, rs_size, arches = sys.argv[1:]
doc = json.load(open(src))
rows = []
for arch in arches.split():
    rows.append({"language": "python", "alias": "PYTHON3_ML", "kind": "prebuilt", "arch": arch, "db_versions": ">=2026.1",
                 "runtime": {"python": "3.12"}, "packages": {"scikit-learn": "1.9.0", "numpy": "2.4.6"},
                 "url": "https://example.invalid/containers/py-fake.tar.gz", "sha256": py_sha, "size": int(py_size)})
    rows.append({"language": "rust", "alias": "RUST", "kind": "prebuilt", "arch": arch, "db_versions": ">=2026.1",
                 "runtime": {"rustc": "1.98.1"}, "crates": {"exasol-udf-sdk": "0.33.0"},
                 "url": "https://example.invalid/containers/lc-rust-fake.tar.gz", "sha256": rs_sha, "size": int(rs_size)})
doc["components"]["udf-devkit"]["containers"] = rows
json.dump(doc, open(out, "w"), indent=2)
MATRIX
}
matrix "$WORK/versions.json" "$(fake_sha "$MIRROR/py-fake.tar.gz")"
matrix "$WORK/versions-bad-digest.json" "$(printf '0%.0s' $(seq 1 64))"
matrix "$WORK/versions-aarch64-only.json" "$(fake_sha "$MIRROR/py-fake.tar.gz")" aarch64
export EXAKIT_UDF_CONTAINERS_MIRROR="$MIRROR" EXAKIT_UDF_ARCH=aarch64
CACHE="$EXAKIT_HOME/cache/containers"
# The matrix scenario: the test versions document, a database that answers its
# version, the smoke UDF stubbed with what it would report.
mscenario() { # mscenario <versions doc> <body>
    scenario '_EXAKIT_VERSIONS_DOC="'"$1"'"
        _udf_db_version() { printf "%s\n" "${STUB_DB:-2026.2.0-nano.3}"; }
        udf_devkit_smoke() { echo "smoke $*" >> "$CALLS"; UDF_SMOKE_LINES="python 3.12.3
scikit-learn 1.9.0
numpy 2.4.6"; }
        confirm() { return "${STUB_DECLINE:-0}"; }
        manifest_set components.udf_devkit.version 0.1.0
        '"$2"
}
rm -rf "$CACHE"
out="$(mscenario "$WORK/versions.json" 'cmd_udf_use default; echo "rc=$?"; manifest_get components.udf_devkit.containers.PYTHON3_ML; manifest_get components.udf_devkit.languages' 2>&1)"
calls="$(grep -v "slc list" "$WORK/calls" | tr '\n' '|')"
check "the mirror's tarball goes to the launcher as PYTHON3_ML, --language python, then the pins to the smoke UDF" \
    "stop dash-server|launcher slc custom install --source $CACHE/py-fake.tar.gz --alias PYTHON3_ML --language python --auto-approve --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR|wait|start dash-server|smoke PYTHON3_ML scikit-learn==1.9.0 numpy==2.4.6|" "$calls"
contains "the row is the database's (aarch64, its version)" "Container for python on aarch64, database 2026.2.0-nano.3: py-fake.tar.gz" "$out"
contains "verified before the install" "Verified py-fake.tar.gz (sha256" "$out"
contains "exit 0" "rc=0" "$out"
contains "the container's url is recorded under its alias" "https://example.invalid/containers/py-fake.tar.gz" "$out"
check "and the language" "python" "$(printf '%s\n' "$out" | tail -1)"
check "the verified file is in the cache" "fake python container" "$(cat "$CACHE/py-fake.tar.gz" 2>/dev/null)"
out="$(mscenario "$WORK/versions.json" 'cmd_udf_use default' 2>&1)"
contains "a second run reuses the cached file" "Using the cached container $CACHE/py-fake.tar.gz (digest verified)" "$out"
json="$(mscenario "$WORK/versions.json" 'cmd_udf_use default --json' 2>/dev/null)"; rc=$?
check "--json: exit 0" "0" "$rc"
check "--json: one object - ok, language, alias, container (url, sha256, arch, db_versions), smoke (package, version)" \
    "True python PYTHON3_ML ['arch', 'db_versions', 'sha256', 'url'] aarch64 >=2026.1 https://example.invalid/containers/py-fake.tar.gz [('python', '3.12.3'), ('scikit-learn', '1.9.0'), ('numpy', '2.4.6')]" \
    "$(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); c = d["container"]; print(d["ok"], d["language"], d["alias"], sorted(c), c["arch"], c["db_versions"], c["url"], [(s["package"], s["version"]) for s in d["smoke"]])' 2>&1)"

echo "a digest that does not match is refused before the launcher sees the file:"
rm -rf "$CACHE"
out="$(mscenario "$WORK/versions-bad-digest.json" 'cmd_udf_use default' 2>&1)"; rc=$?
check "exit 4" "4" "$rc"
contains "naming the mismatch" "does not match its pinned digest (sha256 expected 0000" "$out"
contains "and the remedy" "Run this again" "$out"
check "the launcher saw nothing" "" "$(grep -v "slc list" "$WORK/calls")"
check "and the file is gone" "" "$(ls "$CACHE" 2>/dev/null)"
json="$(mscenario "$WORK/versions-bad-digest.json" 'cmd_udf_use default --json' 2>/dev/null)"; rc=$?
check "--json: exit 4" "4" "$rc"
check "--json: ok false, language, step verify, reason, remedy" "False python verify True exakit udf-use default" \
    "$(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["ok"], d["language"], d["step"], "pinned digest" in d["reason"], d["remedy"])' 2>&1)"

echo "no row for this architecture or database version is refused, naming what did not match:"
out="$(EXAKIT_UDF_ARCH=x86_64 mscenario "$WORK/versions-aarch64-only.json" 'cmd_udf_use default' 2>&1)"; rc=$?
check "exit 4" "4" "$rc"
contains "no row for the arch" "no python container for x86_64" "$out"
json="$(EXAKIT_UDF_ARCH=x86_64 mscenario "$WORK/versions-aarch64-only.json" 'cmd_udf_use default --json' 2>/dev/null)"
check "--json: step select-container" "False python select-container exakit update" \
    "$(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["ok"], d["language"], d["step"], d["remedy"])' 2>&1)"
out="$(STUB_DB=2025.3 mscenario "$WORK/versions.json" 'cmd_udf_use default' 2>&1)"; rc=$?
check "an older database: exit 4" "4" "$rc"
contains "naming the range and the version" "container needs database >=2026.1, this one is 2025.3" "$out"
out="$(mscenario "$WORK/versions.json" '_udf_db_version() { :; }; cmd_udf_use default' 2>&1)"; rc=$?
check "no database version: exit 5" "5" "$rc"
contains "asks for the status" "exakit status" "$out"
out="$(STUB_DECLINE=1 mscenario "$WORK/versions.json" 'cmd_udf_use default' 2>&1)"; rc=$?
check "a decline: exit 5" "5" "$rc"
contains "and nothing changed" "nothing changed" "$out"
out="$(EXAKIT_UDF_CONTAINERS_MIRROR="$WORK/empty-mirror" mscenario "$WORK/versions.json" 'rm -rf "$CACHE"; cmd_udf_use default --json' 2>/dev/null)"; rc=$?
check "a mirror without the file: exit 5" "5" "$rc"
contains "step download" '"step": "download"' "$out"

echo "EXAKIT_UDF_LANGUAGE=rust takes the Rust row (alias RUST), with no smoke UDF yet:"
rm -rf "$CACHE"
out="$(EXAKIT_UDF_LANGUAGE=rust mscenario "$WORK/versions.json" 'manifest_del components.udf_devkit; udf_devkit_install; echo "rc=$?"; echo "languages=$(manifest_get components.udf_devkit.languages)"; manifest_get components.udf_devkit.containers.RUST; echo "validated=$(manifest_get components.udf_devkit.validated)"; udf_devkit_summary' 2>&1)"
calls="$(grep -v "slc list" "$WORK/calls" | tr '\n' '|')"
check "the install goes down the rust path: slc custom install --alias RUST --language rust, no smoke" \
    "stop dash-server|launcher slc custom install --source $CACHE/lc-rust-fake.tar.gz --alias RUST --language rust --auto-approve --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR|wait|start dash-server|" "$calls"
contains "the install succeeds" "rc=0" "$out"
contains "rustc and the sdk crate are named" "rustc 1.98.1, exasol-udf-sdk 0.33.0" "$out"
contains "the smoke UDF is the next step" "The Rust smoke UDF arrives with the next kit step; until then: exasol slc list shows RUST" "$out"
contains "the language is recorded" "languages=rust" "$out"
contains "the url under the alias" "lc-rust-fake.tar.gz" "$out"
contains "validated false until the smoke UDF exists" "validated=false" "$out"
contains "and the summary names both languages" "Rust UDFs: alias RUST" "$out"
out="$(mscenario "$WORK/versions.json" 'manifest_set components.udf_devkit.languages python; cmd_udf_setup --language rust --json; manifest_get components.udf_devkit.languages >&2' 2>"$WORK/err")"
check "udf-setup --language rust --json: ok, alias RUST, an empty smoke list" "True rust RUST []" \
    "$(printf '%s' "$out" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["ok"], d["language"], d["alias"], d["smoke"])' 2>&1)"
contains "a second language joins the record" "python,rust" "$(cat "$WORK/err")"
out="$(mscenario "$WORK/versions.json" 'udf_devkit_installed_aliases() { echo RUST; }; cmd_udf_use default --language rust --yes' 2>&1)"
contains "an installed RUST is updated, not installed twice" "slc custom update --source $CACHE/lc-rust-fake.tar.gz --alias RUST" "$(cat "$WORK/calls")"

echo "udf-setup --json answers with the same shape for the official container:"
json="$(mscenario "$WORK/versions.json" 'cmd_udf_setup --json' 2>/dev/null)"; rc=$?
check "exit 0" "0" "$rc"
check "ok, python, PYTHON3, no url (the launcher's own), the smoke lines" "True python PYTHON3 None aarch64 3" \
    "$(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["ok"], d["language"], d["alias"], d["container"]["url"], d["container"]["arch"], len(d["smoke"]))' 2>&1)"
json="$(STUB_LAUNCHER=2.2.0 mscenario "$WORK/versions.json" 'cmd_udf_setup --json' 2>/dev/null)"; rc=$?
check "an old launcher: exit 5, step install" "5 install exakit update personal" \
    "$rc $(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["step"], d["remedy"])' 2>&1)"
json="$(mscenario "$WORK/versions.json" 'manifest_del components.udf_devkit; cmd_udf_use default --json' 2>/dev/null)"; rc=$?
check "not installed: exit 5 naming the marketplace" "5 exakit marketplace udf-devkit" \
    "$rc $(printf '%s' "$json" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["remedy"])' 2>&1)"
unset EXAKIT_UDF_CONTAINERS_MIRROR EXAKIT_UDF_ARCH

echo "an uninstall leaves the containers to the launcher:"
out="$(scenario 'manifest_set components.udf_devkit.version 0.1.0; udf_devkit_uninstall 1' 2>&1)"
contains "the dry run says the containers stay" "containers stay installed in the database" "$out"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
