#!/usr/bin/env bash
# personal-engine.sh — which container engine a NEW Exasol Personal deployment
# gets, and how an existing one keeps its own (setup/lib/runtime-personal.sh).
#
#   bash tests/personal-engine.sh
#
# What it pins, and why each one exists:
#   - Exasol Personal 2.4 deploys on Docker or Podman on Linux and Windows. The
#     kit's order is Docker when usable, else Podman - the reverse of the
#     launcher's own `auto` - and the choice is always passed explicitly as
#     --container-engine, so the launcher never decides behind the kit's back.
#   - "Usable" is the launcher's floor: the daemon answers, runs Linux
#     containers, and is Engine 29 or newer. Anything else goes to Podman with
#     the reason said once - never a hung prompt in a run with no terminal.
#   - A named engine (EXAKIT_CONTAINER_ENGINE) is never swapped for the other.
#   - A deployment that exists keeps the engine its record names, and a record
#     without one is Podman: every deployment from before kit 0.2.4.
#   - A nano-kit record names the OLD database's engine (docker) beside its
#     container; that must never leak into the Personal record.
#   - macOS has no engine to choose and records none.
#
# Uses stub docker, podman and launcher binaries; never touches a real one.

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

# --- stub binaries ------------------------------------------------------------
mkdir -p "$TMP/bin"
# docker: answers `docker info --format ...` from STUB_DOCKER_INFO, and fails
# the first STUB_DOCKER_FAIL_FIRST calls the way a stopped daemon does.
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
n=0; [ -f "$STUB_DOCKER_CALLS" ] && n="$(cat "$STUB_DOCKER_CALLS")"
n=$((n + 1)); printf '%s' "$n" > "$STUB_DOCKER_CALLS"
if [ "$n" -le "${STUB_DOCKER_FAIL_FIRST:-0}" ]; then
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
    exit 1
fi
printf '%s\n' "${STUB_DOCKER_INFO:-linux 29.1.0}"
STUB
cat > "$TMP/bin/podman" <<'STUB'
#!/usr/bin/env bash
printf 'arm64\n'
STUB
# launcher: records every call; `install --help` names --container-engine
# only when STUB_HELP_ENGINE=1 (a 2.3 launcher does not).
cat > "$TMP/bin/exasol-stub" <<'STUB'
#!/usr/bin/env bash
printf 'LAUNCHER %s\n' "$*" >> "$STUB_CALLS"
case "$*" in
    "install --help")
        echo "Flags:"
        echo "      --auto-approve"
        [ "${STUB_HELP_ENGINE:-1}" = 1 ] && echo "      --container-engine string   Container engine: auto, docker or podman"
        ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/"*
# A machine with no docker at all: the same stubs minus that one.
mkdir -p "$TMP/bin-nodocker" && cp "$TMP/bin/podman" "$TMP/bin/exasol-stub" "$TMP/bin-nodocker/"

# --- harness ------------------------------------------------------------------
# Source the real module with the loggers and the common-layer helpers stubbed,
# then run one expression. Everything after HARNESS-time is the module's code.
cat > "$TMP/harness.sh" <<HARNESS
# The stubs and the system tools only: a real docker further down PATH would
# answer for the "no docker" case.
export PATH="\${STUB_BIN:-$TMP/bin}:/usr/bin:/bin"
export STUB_CALLS="$TMP/calls" STUB_DOCKER_CALLS="$TMP/docker-calls"
MF="$TMP/manifest"
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
manifest_get(){ grep "^\$1=" "\$MF" 2>/dev/null | tail -1 | cut -d= -f2-; grep -q "^\$1=" "\$MF" 2>/dev/null; }
manifest_set(){ { grep -v "^\$1=" "\$MF" 2>/dev/null || true; } > "\$MF.n"; mv "\$MF.n" "\$MF"; printf '%s=%s\n' "\$1" "\$2" >> "\$MF"; }
manifest_del(){ { grep -v "^\$1=" "\$MF" 2>/dev/null || true; } > "\$MF.n"; mv "\$MF.n" "\$MF"; }
detect_os(){ printf '%s' "\${STUB_OS:-linux}"; }
_exakit_prompt_tty(){ [ "\${STUB_TTY:-0}" = 1 ] && printf 'stdin\n'; return 0; }
prompt_text(){ printf 'PROMPT %s\n' "\$1" >> "\$STUB_CALLS"; printf '%s\n' "\${STUB_ANSWER:-}"; }
exakit_note_failure(){ printf 'NOTE %s\n' "\$*" >> "\$STUB_CALLS"; }
exakit_install_command(){ printf 'bash install.sh'; }
exakit_run_bounded(){ shift; "\$@"; }
require_python3(){ :; }
run_python(){ :; }
store_credential(){ :; }
EXAKIT_BIN_DIR="$TMP/bin"
EXAKIT_CREDS_DIR="$TMP"
EXAKIT_PERSONAL_DEPLOY_DIR="$TMP/no-deployment"
source "$ROOT/setup/lib/runtime-personal.sh"
personal_cli(){ printf '%s' "$TMP/bin/exasol-stub"; }
personal_podman_running(){ printf 'RUN podman_running\n' >> "\$STUB_CALLS"; return 0; }
personal_install_podman(){ printf 'RUN install_podman\n' >> "\$STUB_CALLS"; return 0; }
personal_deployment_exists(){ [ "\${STUB_EXISTS:-0}" = 1 ]; }
personal_deployed_version(){ printf '2.4.0'; }
personal_launcher_version(){ printf '2.4.0'; }
personal_status(){ printf 'running'; }
EXAKIT_PERSONAL_PORT=8563
eval "\$@"
HARNESS
probe() { # probe <ENV=val ...> -- <shell to eval>; echoes stdout then "rc=N"
    _envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do _envs[${#_envs[@]}]="$1"; shift; done
    shift
    : > "$TMP/calls"; rm -f "$TMP/docker-calls"; : > "$TMP/manifest"
    [ -n "${SEED_MANIFEST:-}" ] && printf '%b' "$SEED_MANIFEST" > "$TMP/manifest"
    _out="$(env ${_envs[@]+"${_envs[@]}"} bash "$TMP/harness.sh" "$@" 2>&1)"; _rc=$?
    printf '%s\nrc=%s' "$_out" "$_rc"
}
rc_of()    { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
calls()    { cat "$TMP/calls" 2>/dev/null; }
manifest() { cat "$TMP/manifest" 2>/dev/null; }
RESOLVE='personal_resolve_engine; printf "rc=%s engine=%s\n" "$?" "$EXAKIT_PERSONAL_ENGINE"'
engine_of() { printf '%s' "$1" | sed -n 's/^rc=[0-9]* engine=//p' | tail -1; }

echo "personal_resolve_engine: Docker when usable, else Podman, said once"
out="$(probe -- "$RESOLVE")"
check "Docker 29 on Linux -> docker"           docker "$(engine_of "$out")"
out="$(probe STUB_DOCKER_INFO="linux 28.3.1" -- "$RESOLVE")"
check "Docker 28 -> podman"                    podman "$(engine_of "$out")"
contains "  and says why"                      "older than 29" "$out"
out="$(probe STUB_DOCKER_INFO="windows 29.0.0" -- "$RESOLVE")"
check "Windows containers -> podman"           podman "$(engine_of "$out")"
contains "  and says why"                      "Linux containers" "$out"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 -- "$RESOLVE")"
check "daemon down, no terminal -> podman"     podman "$(engine_of "$out")"
contains "  and says why"                      "not running" "$out"
lacks    "  without asking anyone"             "PROMPT" "$(calls)"
out="$(probe STUB_DOCKER_FAIL_FIRST=1 STUB_TTY=1 -- "$RESOLVE")"
check "daemon down, terminal, started -> docker" docker "$(engine_of "$out")"
contains "  after one question"                "PROMPT Press Enter" "$(calls)"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_TTY=1 -- "$RESOLVE")"
check "daemon down, terminal, still down -> podman" podman "$(engine_of "$out")"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_TTY=1 STUB_ANSWER=p -- "$RESOLVE")"
check "terminal answers p -> podman, no retry" podman "$(engine_of "$out")"
check "  one docker probe only"                1 "$(cat "$TMP/docker-calls")"
out="$(probe STUB_BIN="$TMP/bin-nodocker" -- "$RESOLVE")"
check "no docker at all -> podman"             podman "$(engine_of "$out")"
lacks    "  silently"                          "INFO" "$out"
out="$(probe STUB_OS=macos -- "$RESOLVE")"
check "macOS -> no engine"                     "" "$(engine_of "$out")"
check "  rc 0"                                 0 "$(rc_of "$out")"

echo
echo "EXAKIT_CONTAINER_ENGINE names one and is never swapped"
out="$(probe EXAKIT_CONTAINER_ENGINE=podman -- "$RESOLVE")"
check "podman named, Docker usable -> podman"  podman "$(engine_of "$out")"
check "  no docker probe"                      "" "$(cat "$TMP/docker-calls" 2>/dev/null)"
out="$(probe EXAKIT_CONTAINER_ENGINE=docker -- "$RESOLVE")"
check "docker named, usable -> docker"         docker "$(engine_of "$out")"
out="$(probe EXAKIT_CONTAINER_ENGINE=docker STUB_DOCKER_FAIL_FIRST=9 -- "$RESOLVE")"
check "docker named, down -> refused"          1 "$(printf '%s' "$out" | sed -n 's/^rc=\([0-9]*\) engine=.*/\1/p' | tail -1)"
check "  engine stays empty"                   "" "$(engine_of "$out")"
contains "  failure noted"                     "NOTE EXAKIT_CONTAINER_ENGINE=docker" "$(calls)"
out="$(probe EXAKIT_CONTAINER_ENGINE=lxc -- "$RESOLVE")"
contains "anything else dies"                  "DIE EXAKIT_CONTAINER_ENGINE must be docker or podman" "$out"

echo
echo "personal_engine_flag: passed only to a launcher that takes it"
check "2.4 launcher" "--container-engine docker" "$(probe -- 'personal_engine_flag docker' | sed '$d')"
check "2.3 launcher" ""                          "$(probe STUB_HELP_ENGINE=0 -- 'personal_engine_flag docker' | sed '$d')"
check "no engine"    ""                          "$(probe -- 'personal_engine_flag ""' | sed '$d')"
check "never on macOS, whatever the record says" "" "$(probe STUB_OS=macos -- 'personal_engine_flag podman' | sed '$d')"
check "the deploy passes it with install local" 1 \
    "$(grep -A1 '"$(personal_cli)" install local $(personal_auto_approve_flag install)' "$ROOT/setup/lib/runtime-personal.sh" | grep -c 'personal_engine_flag "$EXAKIT_PERSONAL_ENGINE"')"

echo
echo "personal_engine_recorded: the record's engine, Podman when it has none"
check "no record -> podman"      podman "$(probe -- 'personal_engine_recorded' | sed '$d')"
SEED_MANIFEST='runtime.engine=docker\n'
check "docker recorded"          docker "$(probe -- 'personal_engine_recorded' | sed '$d')"
SEED_MANIFEST='runtime.engine=docker\nruntime.container=exasol-nano\n'
check "nano record -> podman"    podman "$(probe -- 'personal_engine_recorded' | sed '$d')"
SEED_MANIFEST=""

echo
echo "personal_record_manifest: runtime.engine written on engine platforms only"
out="$(probe EXAKIT_PERSONAL_ENGINE=docker -- 'personal_record_manifest healthy')"
contains "this run chose docker"           "runtime.engine=docker" "$(manifest)"
SEED_MANIFEST='runtime.engine=docker\n'
out="$(probe -- 'personal_record_manifest healthy')"
contains "an update keeps docker"          "runtime.engine=docker" "$(manifest)"
SEED_MANIFEST='runtime.engine=docker\nruntime.container=exasol-nano\n'
out="$(probe EXAKIT_PERSONAL_ENGINE=podman -- 'personal_record_manifest healthy')"
contains "nano record crossed -> podman"   "runtime.engine=podman" "$(manifest)"
contains "  old engine kept as legacy"     "legacy.engine=docker" "$(manifest)"
SEED_MANIFEST=""
out="$(probe -- 'personal_record_manifest healthy')"
contains "pre-0.2.4 record -> podman"      "runtime.engine=podman" "$(manifest)"
out="$(probe STUB_OS=macos -- 'personal_record_manifest healthy')"
lacks    "macOS records no engine"         "runtime.engine" "$(manifest)"

echo
echo "personal_deploy_local: an existing deployment keeps its engine"
DEPLOY_GATE='personal_deploy_local; printf "rc=%s engine=%s\n" "$?" "$EXAKIT_PERSONAL_ENGINE"'
SEED_MANIFEST='runtime.engine=docker\n'
out="$(probe STUB_EXISTS=1 STUB_DOCKER_FAIL_FIRST=9 -- "$DEPLOY_GATE")"
check "docker deployment, daemon down -> stops" 1 "$(printf '%s' "$out" | sed -n 's/^rc=\([0-9]*\) engine=.*/\1/p' | tail -1)"
contains "  names the engine"               "runs on Docker" "$out"
lacks    "  never installs Podman for it"   "install_podman" "$(calls)"
lacks    "  never asks the launcher"        "LAUNCHER install" "$(calls)"
SEED_MANIFEST=""

# The Windows twin, wherever a PowerShell is at hand to run it.
if command -v pwsh >/dev/null 2>&1; then
    echo
    if pwsh -NoProfile -NonInteractive -File "$ROOT/tests/personal-engine-ps.ps1"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL personal-engine-ps.ps1"
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
