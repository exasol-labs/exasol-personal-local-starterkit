#!/usr/bin/env bash
# exapump-glibc-shim.sh — exapump_install_glibc_shim (setup/lib/exapump.sh)
# runs the exapump release binary in a container when this system's glibc is
# too old for it, on whichever engine the machine has.
#
#   bash tests/exapump-glibc-shim.sh
#
# What it pins, and why:
#   - Since Exasol Personal 2.4 a Docker-only box never gets Podman, and the
#     shim used to require it: Debian 12, Ubuntu 22.04 and RHEL 9 with Docker
#     lost the data-loading CLI (LNXR-01). Docker must do.
#   - The database's engine comes first (the record), then Podman, then Docker.
#   - Podman runs with --userns=keep-id; Docker has no such flag and runs as
#     the user's uid:gid (rootless Docker as its root, which is the user).
#   - Neither engine: one die naming both.
#
# Stub docker, podman and ldd on PATH; never touches a real engine, and HOME
# and every kit path live in a temp dir.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s contains "%s"\n' "$1" "$2" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s lacks "%s"\n' "$1" "$2" ;;
    esac
}

# --- stubs --------------------------------------------------------------------
# One engine stub, installed as docker and/or podman. `info` answers unless
# STUB_<ENGINE>_DOWN=1; `run` prints the version the shim checks; every call
# is logged to $STUB_LOG as "<engine> <args>".
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/engine" <<'STUB'
#!/usr/bin/env bash
me="${0##*/}"
printf '%s %s\n' "$me" "$*" >> "$STUB_LOG"
up="$(printf '%s' "$me" | tr '[:lower:]' '[:upper:]')"
eval "down=\${STUB_${up}_DOWN:-0}"
case "$1" in
    --version) [ "$me" = docker ] && echo "${STUB_DOCKER_VERSION:-Docker version 29.1.0}" || echo "podman version 5.2.2" ;;
    info)
        [ "$down" = 1 ] && { echo "Cannot connect to the $me daemon" >&2; exit 1; }
        case "$*" in *SecurityOptions*) echo "${STUB_DOCKER_SECOPTS:-[name=seccomp,profile=builtin]}" ;; *) echo ok ;; esac ;;
    pull) exit 0 ;;
    run) echo "exapump 9.9.9" ;;
esac
exit 0
STUB
printf '#!/bin/sh\necho "ldd (Ubuntu GLIBC 2.35-0ubuntu3) 2.35"\n' > "$TMP/stubs/ldd"
chmod +x "$TMP/stubs/engine" "$TMP/stubs/ldd"
# The system tools without any real docker or podman.
mkdir -p "$TMP/sysbin"
for _t in /usr/bin/* /bin/*; do
    case "${_t##*/}" in docker|podman|ldd) continue ;; esac
    ln -s "$_t" "$TMP/sysbin/" 2>/dev/null || true
done

# shim <engines: docker,podman,none> [ENV=val ...] -> output, then rc=N; the
# generated wrapper is left at $TMP/home/bin/exapump.
shim() {
    _engines="$1"; shift
    rm -rf "$TMP/home" "$TMP/bin"; mkdir -p "$TMP/home/bin" "$TMP/bin"
    cp "$TMP/stubs/ldd" "$TMP/bin/"
    case "$_engines" in *docker*) cp "$TMP/stubs/engine" "$TMP/bin/docker" ;; esac
    case "$_engines" in *podman*) cp "$TMP/stubs/engine" "$TMP/bin/podman" ;; esac
    printf '#!/bin/sh\necho "exapump: /lib/x86_64-linux-gnu/libc.so.6: version GLIBC_2.38 not found" >&2\nexit 1\n' \
        > "$TMP/home/bin/exapump"
    chmod +x "$TMP/home/bin/exapump"
    : > "$TMP/log"; : > "$TMP/manifest"
    [ -n "${SEED_MANIFEST:-}" ] && printf '%b' "$SEED_MANIFEST" > "$TMP/manifest"
    env -i PATH="$TMP/bin:$TMP/sysbin" HOME="$TMP/home" TMPDIR="$TMP" STUB_LOG="$TMP/log" \
        EXAKIT_HOME="$TMP/home/kit" EXAKIT_BIN_DIR="$TMP/home/bin" MF="$TMP/manifest" "$@" \
        bash -c '
        info(){ printf "INFO %s\n" "$*"; }; ok(){ printf "OK %s\n" "$*"; }; warn(){ printf "WARN %s\n" "$*"; }
        die(){ printf "DIE %s\n" "$*"; exit 1; }
        run_logged(){ "$@" >/dev/null 2>&1; }
        manifest_get(){ grep "^$1=" "$MF" 2>/dev/null | tail -1 | cut -d= -f2-; grep -q "^$1=" "$MF" 2>/dev/null; }
        manifest_set(){ printf "%s=%s\n" "$1" "$2" >> "$MF"; }
        . "$0/setup/lib/detect.sh"
        . "$0/setup/lib/exapump.sh"
        exapump_install_glibc_shim' "$ROOT" 2>&1
    printf '\nrc=%s' "$?"
}
wrapper() { cat "$TMP/home/bin/exapump" 2>/dev/null; }
runline() { grep '^exec ' "$TMP/home/bin/exapump" 2>/dev/null; grep -A1 '^exec ' "$TMP/home/bin/exapump" 2>/dev/null | tail -1; }

echo "Podman only: the shim runs on Podman with keep-id"
out="$(shim podman)"
contains "rc 0"                               "rc=0" "$out"
contains "  says the engine"                  "exapump runs via the podman shim (exapump 9.9.9)" "$out"
contains "  wrapper execs podman"             "exec podman run" "$(wrapper)"
contains "  with --userns=keep-id"            "--userns=keep-id" "$(runline)"
contains "  as the user's uid:gid"            '-u "$(id -u):$(id -g)"' "$(runline)"
contains "  host network"                     "--network host" "$(runline)"
contains "  real binary moved aside"          "exapump-real" "$(wrapper)"
check    "  no placeholder left"              0 "$(grep -c '@[A-Z]*@' "$TMP/home/bin/exapump")"

echo
echo "Docker only (LNXR-01): the shim runs on Docker"
out="$(shim docker)"
contains "rc 0"                               "rc=0" "$out"
lacks    "  never asks for Podman"            "Podman is not available" "$out"
contains "  says the engine"                  "exapump runs via the docker shim" "$out"
contains "  wrapper execs docker"             "exec docker run" "$(wrapper)"
lacks    "  without --userns (Podman-only)"   "--userns" "$(runline)"
contains "  as the user's uid:gid"            '-u "$(id -u):$(id -g)"' "$(runline)"
contains "  host network, as Podman's"        "--network host" "$(runline)"
contains "  the kit's config is visible"      '-v "$HOME:$HOME"' "$(wrapper)"
contains "  HOME passed in"                   '-e HOME="$HOME"' "$(wrapper)"
contains "  pulled with docker"               "docker pull ubuntu:24.04" "$(cat "$TMP/log")"
check    "  no placeholder left"              0 "$(grep -c '@[A-Z]*@' "$TMP/home/bin/exapump")"
out="$(shim docker STUB_DOCKER_SECOPTS="[name=seccomp name=rootless name=cgroupns]")"
contains "rootless Docker runs as its root (the user)" "-u 0:0" "$(runline)"

echo
echo "both engines: the database's engine first, else Podman"
out="$(shim docker,podman)"
contains "no record -> podman"                "exec podman run" "$(wrapper)"
SEED_MANIFEST='runtime.engine=docker\n'
out="$(shim docker,podman)"
contains "recorded docker -> docker"          "exec docker run" "$(wrapper)"
SEED_MANIFEST='runtime.engine=docker\nruntime.container=exasol-nano\n'
out="$(shim docker,podman)"
contains "a nano record is ignored -> podman" "exec podman run" "$(wrapper)"
SEED_MANIFEST='runtime.engine=docker\n'
out="$(shim docker,podman STUB_DOCKER_DOWN=1)"
contains "recorded docker but down -> podman" "exec podman run" "$(wrapper)"
SEED_MANIFEST=""
out="$(shim docker,podman STUB_PODMAN_DOWN=1)"
contains "Podman not answering -> docker"     "exec docker run" "$(wrapper)"

echo
echo "Podman's docker emulation is not Docker"
out="$(shim docker STUB_DOCKER_VERSION="podman version 5.2.2")"
contains "podman-docker alone -> refused"     "DIE exapump cannot run on this system's glibc, and neither Podman nor Docker" "$out"

echo
echo "neither engine: one die naming both"
out="$(shim none)"
contains "rc 1"                               "rc=1" "$out"
contains "  names Podman and Docker"          "neither Podman nor Docker is available" "$out"
contains "  says the glibc"                   "GLIBC 2.35" "$out"
out="$(shim docker STUB_DOCKER_DOWN=1)"
contains "Docker down, no Podman -> refused"  "neither Podman nor Docker is available" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
