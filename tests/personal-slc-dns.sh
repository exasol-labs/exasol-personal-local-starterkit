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
#     name on both engines), never a sidecar exasol-db-<id>-sidecar-<name>
#     that happens to be listed first; without an id, the first exasol-db-*.
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
ctr; FAKE_PS="exasol-db-other $ID-db-1" helper --engine docker --deployment-id "$ID" java-17 >/dev/null
check "a name carrying the id the kit's way (<id>-db-1) wins over another exasol-db-*" "$ID-db-1" "$(target)"
ctr; FAKE_PS="exasol-db-abc-sidecar-minio exasol-db-abc" helper java-17 >/dev/null
check "the id unknown (an old record): the first exasol-db-*, never a sidecar" "exasol-db-abc" "$(target)"
ctr; FAKE_PS="exasol-db-test" helper --deployment-id "$ID" java-17 >/dev/null
check "an old-named container is still found when the id names none" "exasol-db-test" "$(target)"
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
# The container choice, case for case the Python helper's.
for case in "$PS_24|$ID|exasol-db-$ID" "exasol-db-other $ID-db-1|$ID|$ID-db-1" \
            "exasol-db-abc-sidecar-minio exasol-db-abc||exasol-db-abc" "exasol-db-test|$ID|exasol-db-test" \
            "legacy,exasol-db-$ID|$ID|exasol-db-$ID"; do
    _ps="${case%%|*}"; _rest="${case#*|}"; _id="${_rest%%|*}"; _want="${_rest#*|}"
    ctr; gen --deployment-id "$_id" java-17 | FAKE_PS="$_ps" PATH="$WORK/bin:$PATH" sh >/dev/null
    _sh="$(target)"
    ctr; FAKE_PS="$_ps" helper ${_id:+--deployment-id "$_id"} java-17 >/dev/null
    check "VM script and helper agree: [$_ps] id=[$_id]" "$_want $_want" "$_sh $(target)"
done
ctr; OUT="$(gen --deployment-id "$ID" java-17 | FAKE_PS="exasol-db-$ID-sidecar-minio" PATH="$WORK/bin:$PATH" sh)"
check "...only a sidecar: nocontainer" "EXAKIT_SLC_DNS - nocontainer" "$OUT"
ctr; gen --engine docker --deployment-id "$ID" java-17 | FAKE_PS="$PS_24" PATH="$WORK/bin:$PATH" sh >/dev/null
check "--engine docker: the script asks docker" "docker exasol-db-$ID" "$(clis) $(target)"
check "an id or engine the launcher would not write never reaches the script" "1 1" \
    "$(gen --deployment-id "x';rm -rf /;'" java-17 | grep -c "^ID=''$") $(gen --engine 'podman;id' java-17 | grep -c "^E='podman'$")"

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
# repair <bin dir> [VAR=value ...] - personal_slc_dns_repair with the record
# holding REC_ENGINE (none when unset); prints its output, then rc=N.
repair() {
    _bin="$1"; shift
    env "$@" STUB_PATH="$WORK/py:$_bin:$WORK/sys" WORK="$WORK" bash -c '
        EXAKIT_HOME="$WORK/home"; export EXAKIT_HOME
        . "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"
        detect_os() { printf "%s" "${STUB_OS:-linux}"; }
        personal_slc_installed_flavors() { printf "java-17"; }
        personal_cli() { printf "%s" "$WORK/launcher"; }
        manifest_get() { [ "$1" = runtime.engine ] && [ -n "${REC_ENGINE:-}" ] && printf "%s" "$REC_ENGINE"; }
        exakit_run_bounded() { shift; "$@"; }
        run_python_any() { python3 "$@"; }
        info() { printf "INFO %s\n" "$*"; }
        _exakit_log_file() { :; }
        EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/dep"
        PATH="$STUB_PATH"
        personal_slc_dns_repair; echo "rc=$?"' _ "$ROOT" 2>&1
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
check "this run's own choice (an install not recorded yet) wins" "docker" "$(clis)"
ctr; OUT="$(repair "$WORK/podman-only" REC_ENGINE=docker FAKE_PS="$PS_24")"
check "Docker recorded, no docker on PATH: exit 1, podman never asked" "rc=1|" "$(printf '%s\n' "$OUT" | tr '\n' '|')$(cat "$WORK/calls")"
check "...the java-17 file untouched" "regular" "$(link java-17 resolv.conf)"
ctr; OUT="$(repair "$WORK/none" FAKE_PS="$PS_24")"
check "no engine at all: exit 1, as before" "rc=1" "$OUT"
ctr; OUT="$(repair "$WORK/bin" STUB_OS=macos REC_ENGINE=docker FAKE_PS="$PS_24")"
check "macOS: the VM's podman, whatever a stale record says" "podman exasol-db-$ID rc=0" "$(clis) $(target) $(printf '%s\n' "$OUT" | tail -1)"

printf '\n== wiring ==\n'
check "every start repairs (bash)" "1" "$(sed -n '/^personal_start()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c '^ *personal_slc_dns_repair || true')"
check "every start repairs (PowerShell)" "1" "$(sed -n '/^function Start-Personal/,/^function Get-PersonalSlcInstalledFlavors/p' "$ROOT/setup/lib/runtime-personal.ps1" | grep -c 'try { \[void\](Repair-PersonalSlcDns) }')"
check "macOS feeds the VM shell inside the bounded command (stdin survives a background job)" "1" \
    "$(grep -c "exakit_run_bounded 90 sh -c 'exec \"\$0\" shell container < \"\$1\"'" "$ROOT/setup/lib/runtime-personal.sh")"
check "the repair no longer gates on podman alone" "0" \
    "$(sed -n '/^personal_slc_dns_repair()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c 'command -v podman')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
