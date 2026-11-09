#!/usr/bin/env bash
# Language container DNS on Exasol Personal: the official script language
# containers ship etc/resolv.conf and etc/hosts EMPTY, so Java in the database
# (every virtual schema adapter) resolves no hostname. The kit points them at
# /conf after every database start, because every start rebuilds them.
#
# A stand-in engine CLI - the same script installed as `podman` and `docker` -
# keeps each container's etc/ as a real tar stream, so both routes are
# exercised byte for byte: the Python helper (Linux, WSL, Windows) and the
# POSIX sh script fed to the launcher VM's shell (macOS). Every call it gets is
# logged, so a test can say WHICH engine was asked and WHICH container.
#
# What it pins beyond the repair itself:
#   - the deployment's recorded engine is the one asked: a Docker deployment
#     (kit 0.2.4+) is invisible to Podman's CLI, and Podman stays the answer
#     when the record names none;
#   - the database container is exasol-db-<deployment id> (the launcher's own
#     name on both engines) and nothing else: not a sidecar
#     exasol-db-<id>-sidecar-<name>, not another deployment's exasol-db-*, not
#     a name that merely contains the id. Without an id (or the launcher's
#     "local"), a lone exasol-db-* that is not a sidecar; two are nocontainer;
#   - the id is read the way the launcher names the container: its own state
#     file first, trimmed, the top-level key only.
#
#   bash tests/personal-slc-dns.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Fake engine CLI: `ps --format {{.Names}}` prints FAKE_PS (space-separated,
# one name per line; a comma is kept, as Docker joins a container's names)
# unless FAKE_NO_CTR=1; `cp CTR:/exa/slc/F/etc -` streams $WORK/ctr/F/etc as
# tar; `cp - CTR:/exa/slc/F/etc/` extracts stdin there. Each call appends
# "<cli> <verb> <container>" to $WORK/calls.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/podman" <<EOF
#!/usr/bin/env python3
import io, os, sys, tarfile
root = "$WORK/ctr"
cli = os.path.basename(sys.argv[0])
a = sys.argv[1:]
def log(ctr):
    with open("$WORK/calls", "a") as f: f.write("%s %s %s\n" % (cli, a[0], ctr))
if a[0] == "ps":
    log("-")
    if a[1:] != ["--format", "{{.Names}}"]: sys.exit(3)
    print("" if os.environ.get("FAKE_NO_CTR") == "1" else "\n".join(os.environ.get("FAKE_PS", "exasol-db-test").split()))
    sys.exit(0)
if a[0] == "cp" and a[2] == "-":
    log(a[1].split(":")[0])
    flavor = a[1].split("/exa/slc/")[1].split("/")[0]
    path = os.path.join(root, flavor, "etc")
    if not os.path.isdir(path): sys.exit(1)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as t: t.add(path, arcname="etc")
    sys.exit(0)
if a[0] == "cp" and a[1] == "-":
    log(a[2].split(":")[0])
    if os.environ.get("FAKE_CP_FAILS") == "1": sys.exit(1)
    flavor = a[2].split("/exa/slc/")[1].split("/")[0]
    with tarfile.open(fileobj=io.BytesIO(sys.stdin.buffer.read())) as t:
        for m in t.getmembers():
            dest = os.path.join(root, flavor, "etc", m.name)
            if os.path.lexists(dest): os.remove(dest)
            os.symlink(m.linkname, dest)
    sys.exit(0)
sys.exit(2)
EOF
chmod +x "$WORK/bin/podman"
cp "$WORK/bin/podman" "$WORK/bin/docker"
ctr() { rm -rf "$WORK/ctr"; mkdir -p "$WORK/ctr/java-17/etc" "$WORK/ctr/python-3.12/etc"; : > "$WORK/ctr/java-17/etc/resolv.conf"; : > "$WORK/ctr/java-17/etc/hosts"; printf 'nameserver 9.9.9.9\n' > "$WORK/ctr/python-3.12/etc/resolv.conf"; : > "$WORK/calls"; }
link() { readlink "$WORK/ctr/$1/etc/$2" 2>/dev/null || echo "regular"; }
# The engines asked, and the containers copied from or to, since the last ctr.
clis() { cut -d' ' -f1 "$WORK/calls" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
target() { awk '$2 == "cp" { print $3 }' "$WORK/calls" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
HELPER="$ROOT/setup/lib/personal-slc-dns.py"
helper() { PATH="$WORK/bin:$PATH" python3 "$HELPER" "$@"; }
# A 2.4 deployment with a sidecar, listed first because it is the newer
# container, and another deployment's database.
ID=exa-7f3a
PS_24="exasol-db-$ID-sidecar-minio exasol-db-other exasol-db-$ID"

printf '\n== the Python helper (Linux, WSL, Windows) ==\n'
ctr
OUT="$(helper java-17 python-3.12 r-4.4)"; RC=$?
check "an empty resolv.conf is repaired" "EXAKIT_SLC_DNS java-17 repaired" "$(printf '%s\n' "$OUT" | grep java-17)"
check "...both files now point at /conf" "/conf/resolv.conf /conf/hosts" "$(link java-17 resolv.conf) $(link java-17 hosts)"
check "a container that already has DNS is left alone" "EXAKIT_SLC_DNS python-3.12 ok regular" "$(printf '%s\n' "$OUT" | grep python) $(link python-3.12 resolv.conf)"
check "a flavor that is not there is absent, not an error" "EXAKIT_SLC_DNS r-4.4 absent" "$(printf '%s\n' "$OUT" | grep r-4.4)"
check "...exit 0" "0" "$RC"
check "...no engine named: Podman, as before Docker deployments" "podman" "$(clis)"
OUT="$(helper java-17)"
check "a second run changes nothing" "EXAKIT_SLC_DNS java-17 ok" "$OUT"
ctr; OUT="$(FAKE_CP_FAILS=1 helper java-17)"; RC=$?
check "a copy that fails is reported, exit 1" "EXAKIT_SLC_DNS java-17 failed 1" "$OUT $RC"
OUT="$(FAKE_NO_CTR=1 helper java-17)"
check "no database container: said, not guessed" "EXAKIT_SLC_DNS - nocontainer" "$OUT"

printf '\n== the helper on the deployment engine ==\n'
ctr; OUT="$(helper --engine docker java-17)"
check "--engine docker repairs through docker" "EXAKIT_SLC_DNS java-17 repaired" "$OUT"
check "...and never asks podman" "docker" "$(clis)"
ctr; helper --engine podman java-17 >/dev/null
check "--engine podman: podman only" "podman" "$(clis)"
ctr; OUT="$(helper --podman docker java-17)"
check "--podman, the old spelling, still names the CLI" "EXAKIT_SLC_DNS java-17 repaired docker" "$OUT $(clis)"

printf '\n== which container is the database ==\n'
ctr; OUT="$(FAKE_PS="$PS_24" helper --engine docker --deployment-id "$ID" java-17)"
check "2.4: exasol-db-<id>, past a sidecar listed first and another deployment" "exasol-db-$ID" "$(target)"
check "...repaired there" "EXAKIT_SLC_DNS java-17 repaired" "$OUT"
ctr; FAKE_PS="$PS_24" helper --deployment-id "$ID" java-17 >/dev/null
check "...the same on podman" "exasol-db-$ID podman" "$(target) $(clis)"
ctr; FAKE_PS="$PS_24" helper "--deployment-id= $ID " java-17 >/dev/null
check "the id trimmed as the launcher trims it (TrimSpace)" "exasol-db-$ID" "$(target)"
ctr; OUT="$(FAKE_PS="exasol-db--x7" helper --deployment-id=-x7 java-17)"
check "an id starting with - is a value in the = form" "exasol-db--x7" "$(target)"
# Never another deployment's database: the id known, only its own name.
ctr; OUT="$(FAKE_PS="exasol-db-ffff0000" helper --engine docker --deployment-id 1a2b3c4d java-17)"
check "id known, only another deployment's exasol-db-* runs: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
check "...nothing copied in or out of it, the file untouched" " regular" "$(target) $(link java-17 resolv.conf)"
ctr; OUT="$(FAKE_PS="exasol-db-test" helper --deployment-id "$ID" java-17)"
check "...an old-named exasol-db-* that is not this id: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
for _n in "$ID-app" "$ID-db-1" "x-$ID" "xexasol-db-$ID" "exasol-db-$ID-sidecar-$ID" "$ID"; do
    ctr; OUT="$(FAKE_PS="$_n" helper --deployment-id "$ID" java-17)"
    check "a name that merely contains the id is not the database: $_n" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
done
# Without an id: a lone exasol-db-* that is not a sidecar, or nothing.
ctr; FAKE_PS="exasol-db-abc-sidecar-minio exasol-db-abc" helper java-17 >/dev/null
check "no id: the lone exasol-db-*, never a sidecar" "exasol-db-abc" "$(target)"
ctr; OUT="$(FAKE_PS="exasol-db-abc exasol-db-def" helper java-17)"
check "no id, two exasol-db-*: nocontainer, not the first" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; OUT="$(FAKE_PS="x-local" helper --deployment-id local java-17)"
check "the launcher's \"local\" is no id: x-local is not taken" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; FAKE_PS="exasol-db-abc" helper --deployment-id local java-17 >/dev/null
check "...and a lone exasol-db-* is" "exasol-db-abc" "$(target)"
ctr; FAKE_PS="exasol-db-abc" helper "--deployment-id=   " java-17 >/dev/null
check "a blank id is no id" "exasol-db-abc" "$(target)"
ctr; FAKE_PS="legacy,exasol-db-$ID" helper --engine docker --deployment-id "$ID" java-17 >/dev/null
check "Docker's comma-joined names are split" "exasol-db-$ID" "$(target)"
ctr; OUT="$(FAKE_PS="exasol-db-$ID-sidecar-minio" helper --deployment-id "$ID" java-17)"
check "only a sidecar runs: no database container" "EXAKIT_SLC_DNS - nocontainer" "$OUT"

printf '\n== the sh script for the launcher VM (macOS) ==\n'
gen() { bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; shift; personal_slc_dns_script "$@"' _ "$ROOT" "$@"; }
GEN="$(gen java-17 python-3.12 r-4.4)"
ctr
OUT="$(printf '%s\n' "$GEN" | PATH="$WORK/bin:$PATH" sh)"
check "the same outcomes from the VM script" \
    "EXAKIT_SLC_DNS java-17 repaired|EXAKIT_SLC_DNS python-3.12 ok|EXAKIT_SLC_DNS r-4.4 absent|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"
check "...the same two links" "/conf/resolv.conf /conf/hosts" "$(link java-17 resolv.conf) $(link java-17 hosts)"
check "...through podman, the VM's engine, by default" "podman" "$(clis)"
OUT="$(printf '%s\n' "$GEN" | PATH="$WORK/bin:$PATH" sh)"
check "...and idempotent" "EXAKIT_SLC_DNS java-17 ok" "$(printf '%s\n' "$OUT" | grep java-17)"
# The container choice, case for case the Python helper's ("" = nocontainer).
for case in "$PS_24|$ID|exasol-db-$ID" "exasol-db-ffff0000|1a2b3c4d|" "exasol-db-test|$ID|" \
            "$ID-app xexasol-db-$ID exasol-db-$ID-sidecar-$ID $ID-db-1|$ID|" "x-local|local|" \
            "exasol-db-abc|local|exasol-db-abc" "exasol-db-abc-sidecar-minio exasol-db-abc||exasol-db-abc" \
            "exasol-db-abc exasol-db-def||" "$PS_24| $ID |exasol-db-$ID"; do
    _ps="${case%%|*}"; _rest="${case#*|}"; _id="${_rest%%|*}"; _want="${_rest#*|}"
    ctr; gen --deployment-id "$_id" java-17 | FAKE_PS="$_ps" PATH="$WORK/bin:$PATH" sh >/dev/null
    _sh="$(target)"
    ctr; FAKE_PS="$_ps" helper "--deployment-id=$_id" java-17 >/dev/null
    check "VM script and helper agree: [$_ps] id=[$_id] -> [$_want]" "$_want $_want" "$_sh $(target)"
done
ctr; OUT="$(gen --deployment-id "$ID" java-17 | FAKE_PS="exasol-db-$ID-sidecar-minio" PATH="$WORK/bin:$PATH" sh)"
check "...only a sidecar: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; gen --engine docker --deployment-id "$ID" java-17 | FAKE_PS="$PS_24" PATH="$WORK/bin:$PATH" sh >/dev/null
check "--engine docker: the script asks docker" "docker exasol-db-$ID" "$(clis) $(target)"
check "an id or engine the launcher would not write never reaches the script" "1 1" \
    "$(gen --deployment-id "x';rm -rf /;'" java-17 | grep -c "^ID=''$") $(gen --engine 'podman;id' java-17 | grep -c "^E='podman'$")"
check "...nor the launcher's \"local\"" "1" "$(gen --deployment-id local java-17 | grep -c "^ID=''$")"
check "the VM script needs no tr (the VM's Podman never joins names)" "0" "$(gen java-17 | grep -c 'tr ')"
# A trailing option with no value used to loop for ever: `shift 2` with one
# argument left shifts nothing. perl's alarm bounds the run.
_trail="$(perl -e 'alarm 10; exec @ARGV' bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; personal_slc_dns_script --engine docker --deployment-id' _ "$ROOT" | head -2 | tr '\n' ' ')"
check "a trailing --deployment-id with no value ends, the option dropped" "E='docker' ID='' " "$_trail"
_trail="$(perl -e 'alarm 10; exec @ARGV' bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; personal_slc_dns_script --engine' _ "$ROOT" | head -2 | tr '\n' ' ')"
check "...and a trailing --engine" "E='podman' ID='' " "$_trail"

printf '\n== the repair asks the deployment engine (personal_slc_dns_repair) ==\n'
# Only the stubs and the system tools on PATH: a real docker (Docker Desktop's
# CLI in /usr/local/bin, the Engine in a CI runner's /usr/bin) must never
# answer. sys/ is /usr/bin and /bin without docker or podman; py/ is the
# python3 this suite runs with.
mkdir -p "$WORK/sys" "$WORK/py" "$WORK/podman-only" "$WORK/none" "$WORK/dep"
for _t in /usr/bin/* /bin/*; do
    case "${_t##*/}" in docker|podman) continue ;; esac
    ln -s "$_t" "$WORK/sys/" 2>/dev/null || true
done
ln -s "$(command -v python3)" "$WORK/py/python3"
cp "$WORK/bin/podman" "$WORK/podman-only/podman"
printf '{"deploymentId": "%s", "dbPort": 8563}\n' "$ID" > "$WORK/dep/deployment.json"
# A launcher whose `shell container` runs its stdin, as the VM's shell does.
cat > "$WORK/launcher" <<'EOF'
#!/bin/sh
[ "$1 $2" = "shell container" ] && exec sh
exit 2
EOF
chmod +x "$WORK/launcher"
# repair <bin dir> [VAR=value ...] - personal_slc_dns_repair (or CALL) with the
# record holding REC_ENGINE and REC_CONTAINER (none when unset) and the
# deployment folder DEP; prints its output, then rc=N.
repair() {
    _bin="$1"; shift
    env STUB_BIN="$_bin" "$@" WORK="$WORK" bash -c '
        EXAKIT_HOME="$WORK/home"; export EXAKIT_HOME
        . "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"
        detect_os() { printf "%s" "${STUB_OS:-linux}"; }
        personal_slc_installed_flavors() { printf "java-17"; }
        personal_cli() { printf "%s" "$WORK/launcher"; }
        manifest_get() {
            case "$1" in
                runtime.engine) [ -n "${REC_ENGINE:-}" ] && printf "%s" "$REC_ENGINE" ;;
                runtime.container) [ -n "${REC_CONTAINER:-}" ] && printf "%s" "$REC_CONTAINER" ;;
                *) return 1 ;;
            esac
        }
        # REAL_RB=1: the real exakit_run_bounded, timeout(1) and all.
        if [ -z "${REAL_RB:-}" ]; then exakit_run_bounded() { shift; "$@"; }; fi
        run_python_any() { python3 "$@"; }
        info() { printf "INFO %s\n" "$*"; }
        _exakit_log_file() { [ -z "${SHOW_LOG:-}" ] || printf "LOG %s\n" "$*"; return 0; }
        EXAKIT_PERSONAL_DEPLOY_DIR="${DEP:-$WORK/dep}"
        PATH="${PY_DIR:-$WORK/py}:$STUB_BIN:$WORK/sys"
        ${CALL:-personal_slc_dns_repair}; echo "rc=$?"' _ "$ROOT" 2>&1
}
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "a Docker-recorded deployment is repaired through docker" "docker" "$(clis)"
check "...in its database container" "exasol-db-$ID" "$(target)"
check "...and says so, exit 0" "INFO Gave the java-17 language container the deployment's DNS|rc=0|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=podman FAKE_PS="$PS_24")"
check "a Podman-recorded deployment: podman" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"
ctr; OUT="$(repair "$WORK/bin" FAKE_PS="$PS_24")"
check "no engine recorded (before kit 0.2.4): podman, as before" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"
ctr; repair "$WORK/bin" EXAKIT_PERSONAL_ENGINE=docker FAKE_PS="$PS_24" >/dev/null
check "nothing recorded: this run's choice (an install not recorded yet)" "docker" "$(clis)"
ctr; repair "$WORK/bin" REC_ENGINE=podman EXAKIT_PERSONAL_ENGINE=docker FAKE_PS="$PS_24" >/dev/null
check "the record beats a stray EXAKIT_PERSONAL_ENGINE in the environment" "podman" "$(clis)"
ctr; repair "$WORK/bin" REC_ENGINE=docker REC_CONTAINER=exasol-nano FAKE_PS="$PS_24" >/dev/null
check "a nano record's engine is the old database's: podman" "podman" "$(clis)"
ctr; repair "$WORK/bin" REC_ENGINE=docker REC_CONTAINER=null FAKE_PS="$PS_24" >/dev/null
check "...runtime.container null (manifest_get says \"null\") is a nano record too" "podman" "$(clis)"
ctr; OUT="$(repair "$WORK/podman-only" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "Docker recorded, no docker on PATH: exit 1, podman never asked" "rc=1|" "$(printf '%s\n' "$OUT" | tr '\n' '|')$(cat "$WORK/calls")"
check "...the java-17 file untouched" "regular" "$(link java-17 resolv.conf)"
ctr; OUT="$(repair "$WORK/none" FAKE_PS="$PS_24")"
check "no engine at all: exit 1, as before" "rc=1" "$OUT"
ctr; OUT="$(repair "$WORK/bin" STUB_OS=macos REC_ENGINE=docker FAKE_PS="$PS_24")"
check "macOS: the VM's podman, whatever a stale record says" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"

printf '\n== the real bounded runner, with timeout(1) on PATH ==\n'
# THE HARNESS STUB HID IT. `repair` above swaps exakit_run_bounded for
# `shift; "$@"`, and the repair handed it a shell FUNCTION (run_python_any).
# timeout(1) - coreutils, on every Linux and WSL host - execs its command, and
# a function is no file: "failed to run command 'run_python_any': No such file
# or directory", exit 127, the repair never ran, and only "DNS could not be
# repaired" surfaced. The stand-in behaves like coreutils (it can run a file,
# nothing else) and notes what it ran, so a stock macOS proves it too.
mkdir -p "$WORK/timeout-bin"
cat > "$WORK/timeout-bin/timeout" <<'EOF'
#!/bin/sh
shift
[ -z "${TIMEOUT_LOG:-}" ] || printf '%s\n' "$1" >> "$TIMEOUT_LOG"
command -v "$1" >/dev/null 2>&1 || { printf "timeout: failed to run command '%s': No such file or directory\n" "$1" >&2; exit 127; }
exec "$@"
EOF
chmod +x "$WORK/timeout-bin/timeout"
# bounded <PATH> <limit> <command...> - the real runner alone; prints the
# command's output, then rc=N.
bounded() {
    _bp="$1"; shift
    PATH="$_bp" TIMEOUT_LOG="$WORK/timeout.log" bash -c '
        . "$1/setup/lib/common.sh"; shift
        greet() { printf "ran %s" "$1"; }
        exakit_run_bounded "$@"; echo " rc=$?"' _ "$ROOT" "$@" 2>&1
}
: > "$WORK/timeout.log"
check "a shell function is refused out loud: exit 2, the reason on stderr (was 127, or a silent run)" \
    "exakit_run_bounded needs an executable, not the shell function greet| rc=2|" \
    "$(bounded "$WORK/timeout-bin:$WORK/sys" 5 greet x | tr '\n' '|')"
check "...and timeout(1) was never handed it" "" "$(cat "$WORK/timeout.log")"
check "a file goes through timeout(1), as before" "ok rc=0|printf" \
    "$(bounded "$WORK/timeout-bin:$WORK/sys" 5 printf ok)|$(cat "$WORK/timeout.log")"
# The repair itself, through the real runner: the case the live test met. Its
# interpreter is an executable now (exakit_python_any_argv), so timeout(1)
# runs it - and on a real timeout(1) cuts off its whole process group.
: > "$WORK/timeout.log"
ctr; OUT="$(repair "$WORK/timeout-bin:$WORK/bin" REAL_RB=1 TIMEOUT_LOG="$WORK/timeout.log" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "the repair through the real runner and timeout(1): repaired, exit 0" \
    "docker exasol-db-$ID INFO Gave the java-17 language container the deployment's DNS|rc=0|" \
    "$(clis) $(target) $(printf '%s\n' "$OUT" | tr '\n' '|')"
check "...timeout(1) ran python3 itself, not a function" "python3" "$(cat "$WORK/timeout.log")"
check "...the java-17 file points at /conf now" "/conf/resolv.conf" "$(link java-17 resolv.conf)"
if [ -x "$WORK/sys/timeout" ]; then
    ctr; OUT="$(repair "$WORK/bin" REAL_RB=1 REC_ENGINE=docker FAKE_PS="$PS_24")"
    check "...and under the system's own timeout(1) too" "INFO Gave the java-17 language container the deployment's DNS|rc=0|" \
        "$(printf '%s\n' "$OUT" | tr '\n' '|')"
else
    check "...no timeout(1) on this system (stock macOS): the stand-in stood for it" "skip" "skip"
fi
# No python3 at all: the uv-managed runtime, as run_python would run it - one
# command, `uv run --python <v> --no-project python <helper> ...`. The stand-in
# uv checks those words and hands the rest to this suite's python3.
mkdir -p "$WORK/fake-uv"
cat > "$WORK/fake-uv/uv" <<EOF
#!/bin/sh
[ "\$1 \$2 \$4 \$5" = "run --python --no-project python" ] || { echo "fake uv: unexpected \$*" >&2; exit 9; }
shift 5
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$WORK/fake-uv/uv"
: > "$WORK/timeout.log"
ctr; OUT="$(repair "$WORK/timeout-bin:$WORK/bin" REAL_RB=1 TIMEOUT_LOG="$WORK/timeout.log" EXAKIT_DISABLE_SYSTEM_PYTHON=1 \
    _EXAKIT_UV_VETTED="$WORK/fake-uv/uv" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "no python3: the repair runs on uv's Python, through timeout(1), exit 0" \
    "$WORK/fake-uv/uv INFO Gave the java-17 language container the deployment's DNS|rc=0|" \
    "$(cat "$WORK/timeout.log") $(printf '%s\n' "$OUT" | tr '\n' '|')"
# A repair that cannot run leaves one log line with the reason: every caller
# ignores its exit code, so this line is all a reader of the log gets.
mkdir -p "$WORK/badpy"
printf '#!/bin/sh\necho "python3: no such helper" >&2\nexit 2\n' > "$WORK/badpy/python3"
chmod +x "$WORK/badpy/python3"
ctr; OUT="$(repair "$WORK/timeout-bin:$WORK/bin" REAL_RB=1 SHOW_LOG=1 PY_DIR="$WORK/badpy" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "a repair that did not run: exit 1, one WARN line naming exit and reason" \
    "LOG WARN  language container DNS repair did not run (exit 2): python3: no such helper|rc=1|" \
    "$(printf '%s\n' "$OUT" | tr '\n' '|')"
check "the repair hands the runner no function" "0" \
    "$(sed -n '/^personal_slc_dns_repair()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c 'exakit_run_bounded [0-9]* run_python')"

printf '\n== the id the container is named by (personal_slc_container_id) ==\n'
# st <dir> <state json or -> <deployment.json or -> - a deployment folder.
st() { rm -rf "$1"; mkdir -p "$1"; [ "$2" = - ] || printf '%s\n' "$2" > "$1/.exasolLauncherState.json"; [ "$3" = - ] || printf '%s\n' "$3" > "$1/deployment.json"; }
cid() { repair "$WORK/none" DEP="$1" CALL=personal_slc_container_id | sed '$d'; }
st "$WORK/d1" '{"currentWorkflowState": {"running": {}}, "deploymentId": "  '"$ID"' "}' '{"deploymentId": "local"}'
check "the launcher's state file first, trimmed; deployment.json's \"local\" ignored" "$ID" "$(cid "$WORK/d1")"
st "$WORK/d2" '{"deploymentId": "aaaa1111"}' '{"deploymentId": "bbbb2222"}'
check "...state and deployment.json disagree: the state's id (the one the launcher names by)" "aaaa1111" "$(cid "$WORK/d2")"
st "$WORK/d3" '{"nested": {"deploymentId": "nested-id"}, "deploymentId": "top-id", "x": {"deploymentId": "later-id"}}' -
check "the top-level key, not an occurrence before or after it" "top-id" "$(cid "$WORK/d3")"
st "$WORK/d4" '{"nested": {"deploymentId": "nested-id"}}' '{"deploymentId": "bbbb2222"}'
check "a state file with none at the top: deployment.json's" "bbbb2222" "$(cid "$WORK/d4")"
st "$WORK/d5" '{not json' '{"deploymentId": "bbbb2222"}'
check "an unreadable state file: deployment.json's" "bbbb2222" "$(cid "$WORK/d5")"
st "$WORK/d6" '{"deploymentId": "   "}' -
check "a blank id is none" "" "$(cid "$WORK/d6")"
st "$WORK/d7" - -
check "no state at all: none" "" "$(cid "$WORK/d7")"
ctr; repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/d1" FAKE_PS="$PS_24" >/dev/null
check "the repair targets the state file's id over deployment.json's \"local\"" "exasol-db-$ID" "$(target)"
ctr; OUT="$(repair "$WORK/bin" REC_ENGINE=docker DEP="$WORK/d7" FAKE_PS="$PS_24")"
check "no id and two exasol-db-* listed: nothing written, exit 1" "rc=1 " "$(printf '%s\n' "$OUT" | tail -1) $(target)"

printf '\n== wiring ==\n'
check "every start repairs (bash)" "1" "$(sed -n '/^personal_start()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c '^ *personal_slc_dns_repair || true')"
check "every start repairs (PowerShell)" "1" "$(sed -n '/^function Start-Personal/,/^function Get-PersonalSlcInstalledFlavors/p' "$ROOT/setup/lib/runtime-personal.ps1" | grep -c 'try { \[void\](Repair-PersonalSlcDns) }')"
check "macOS feeds the VM shell inside the bounded command (stdin survives a background job)" "1" \
    "$(grep -c "exakit_run_bounded 90 sh -c 'exec \"\$0\" shell container < \"\$1\"'" "$ROOT/setup/lib/runtime-personal.sh")"
check "the repair no longer gates on podman alone" "0" \
    "$(sed -n '/^personal_slc_dns_repair()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c 'command -v podman')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
