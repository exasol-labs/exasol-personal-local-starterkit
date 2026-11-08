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
# `docker ps` prints STUB_DOCKER_PS (container names) and is not counted.
# STUB_DOCKER_ERR replaces the stopped-daemon message, for the other causes.
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = ps ]; then printf '%s\n' "${STUB_DOCKER_PS:-}"; exit 0; fi
# `docker --version` is not a daemon probe and is not counted.
if [ "$1" = --version ]; then printf '%s\n' "${STUB_DOCKER_VERSION:-Docker version 29.1.0, build stub}"; exit 0; fi
n=0; [ -f "$STUB_DOCKER_CALLS" ] && n="$(cat "$STUB_DOCKER_CALLS")"
n=$((n + 1)); printf '%s' "$n" > "$STUB_DOCKER_CALLS"
if [ "$n" -le "${STUB_DOCKER_FAIL_FIRST:-0}" ]; then
    echo "${STUB_DOCKER_ERR:-Cannot connect to the Docker daemon at unix:///var/run/docker.sock}" >&2
    exit 1
fi
printf '%s\n' "${STUB_DOCKER_INFO:-linux 29.1.0}"
STUB
# podman: `ps` prints STUB_PODMAN_PS; the network backend is netavark (the one
# the WSL gate is about); anything else answers like `podman info` for arch.
cat > "$TMP/bin/podman" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = ps ]; then printf '%s\n' "${STUB_PODMAN_PS:-}"; exit 0; fi
case "$*" in *NetworkBackend*) printf 'netavark\n'; exit 0 ;; esac
printf 'arm64\n'
STUB
# launcher: records every call; `install local --help` names
# --container-engine only when STUB_HELP_ENGINE=1 (a 2.3 launcher does not).
cat > "$TMP/bin/exasol-stub" <<'STUB'
#!/usr/bin/env bash
printf 'LAUNCHER %s\n' "$*" >> "$STUB_CALLS"
# Shaped like the real 2.4 launcher: bare `install --help` lists the presets
# and NEVER the engine; only `install local --help` lists --container-engine.
# A stub that put the flag under bare `install --help` let the kit's wrong
# probe pass here while every real 2.4 launcher read as "cannot be told".
case "$*" in
    "install --help")
        echo "Available infrastructure presets: aws, azure, exoscale, local, stackit"
        echo "Flags:"
        echo "      --auto-approve"
        ;;
    "install local --help")
        echo "Infrastructure variable flags of preset \`local\`:"
        [ "${STUB_HELP_ENGINE:-1}" = 1 ] && echo "      --container-engine string   Container engine for the local deployment: auto, podman, docker."
        echo "Flags:"
        echo "      --auto-approve"
        ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/"*
# A machine with no docker at all: the same stubs minus that one, and a copy
# of the system tool directories WITHOUT docker. The harness keeps /usr/bin on
# PATH for grep, sed and friends, and on the GitHub ubuntu runner that is also
# where a Docker Engine 29+ lives - which answered for the "no docker" machine
# and made the kit choose Docker. Symlinks, so the copy costs nothing.
mkdir -p "$TMP/bin-nodocker" && cp "$TMP/bin/podman" "$TMP/bin/exasol-stub" "$TMP/bin-nodocker/"
mkdir -p "$TMP/sysbin-nodocker"
for _t in /usr/bin/* /bin/*; do
    case "${_t##*/}" in docker|podman) continue ;; esac
    ln -s "$_t" "$TMP/sysbin-nodocker/" 2>/dev/null || true
done

# --- harness ------------------------------------------------------------------
# Source the real module with the loggers and the common-layer helpers stubbed,
# then run one expression. Everything after HARNESS-time is the module's code.
cat > "$TMP/harness.sh" <<HARNESS
# The stubs and the system tools only: a real docker further down PATH would
# answer for the "no docker" case.
export PATH="\${STUB_BIN:-$TMP/bin}:\${STUB_SYSBIN:-/usr/bin:/bin}"
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
personal_cli(){ printf '%s' "\${STUB_CLI:-$TMP/bin/exasol-stub}"; }
export EXAKIT_DOCKER_WAIT_STEP=0
personal_podman_running(){ printf 'RUN podman_running\n' >> "\$STUB_CALLS"; return 0; }
personal_install_podman(){ printf 'RUN install_podman\n' >> "\$STUB_CALLS"; return 0; }
personal_deployment_exists(){ [ "\${STUB_EXISTS:-0}" = 1 ]; }
# STUB_DEPLOYED: the version the deployment's state names ("" = unreadable).
personal_deployed_version(){ [ -n "\${STUB_DEPLOYED-2.4.0}" ] && printf '%s' "\${STUB_DEPLOYED-2.4.0}"; }
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
out="$(probe STUB_BIN="$TMP/bin-nodocker" STUB_SYSBIN="$TMP/sysbin-nodocker" -- "$RESOLVE")"
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

echo
echo "personal_clear_stale_record: a Personal record keeps its engine (LNX-01)"
SEED_MANIFEST='runtime.type=personal\nruntime.engine=docker\n'
out="$(probe -- 'personal_clear_stale_record; printf "recorded=%s\n" "$(personal_engine_recorded)"')"
contains "resumed install keeps runtime.engine=docker" "runtime.engine=docker" "$(manifest)"
lacks    "  and copies nothing to legacy"              "legacy.engine" "$(manifest)"
contains "  so the record still says docker"           "recorded=docker" "$out"
out="$(probe -- 'personal_record_manifest healthy; personal_record_manifest healthy')"
contains "two records in a row keep docker"            "runtime.engine=docker" "$(manifest)"
lacks    "  with no phantom legacy.engine"             "legacy.engine" "$(manifest)"
SEED_MANIFEST='runtime.engine=docker\nruntime.container=exasol-nano\n'
out="$(probe -- 'personal_clear_stale_record')"
contains "a nano record still moves its engine"        "legacy.engine=docker" "$(manifest)"
lacks    "  out of runtime.*"                          "runtime.engine" "$(manifest)"
SEED_MANIFEST=""

echo
echo "Docker only when the launcher can be told (LNX-02)"
out="$(probe STUB_HELP_ENGINE=0 -- "$RESOLVE")"
check "Docker usable, 2.3 launcher -> podman"  podman "$(engine_of "$out")"
contains "  and says why, once"                "cannot be told which engine to use, so the database runs on Podman" "$out"
out="$(probe STUB_HELP_ENGINE=0 EXAKIT_CONTAINER_ENGINE=docker -- "$RESOLVE")"
check "docker named, 2.3 launcher -> refused"  1 "$(printf '%s' "$out" | sed -n 's/^rc=\([0-9]*\) engine=.*/\1/p' | tail -1)"
contains "  with that reason"                  "NOTE EXAKIT_CONTAINER_ENGINE=docker but this Exasol launcher cannot be told" "$(calls)"
out="$(probe STUB_CLI="$TMP/not-yet-downloaded" -- "$RESOLVE")"
check "no launcher yet (the kit's own comes) -> docker" docker "$(engine_of "$out")"

echo
echo "personal_docker_usable keeps the reason (LNX-03)"
DENIED="permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="$DENIED" STUB_TTY=1 -- "$RESOLVE")"
check "permission denied -> podman"            podman "$(engine_of "$out")"
contains "  says it before deploying (LNXR-06)" "Docker is running but your user cannot use it (permission denied on its socket), so this install continues on Podman." "$out"
contains "  and that re-running will not move it" "Joining the docker group and re-running will not move this deployment to Docker" "$out"
contains "  names the way that does"           "'exakit uninstall' and reinstall with EXAKIT_CONTAINER_ENGINE=docker" "$out"
lacks    "  never says start Docker"           "Start Docker" "$out"
lacks    "  and never prompts"                 "PROMPT" "$(calls)"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg." STUB_TTY=1 -- "$RESOLVE")"
check "podman-docker shim -> podman"           podman "$(engine_of "$out")"
lacks    "  silently, no Docker to start"      "INFO" "$out"
# /etc/containers/nodocker silences the banner (LNXR-02): Podman then fails
# docker's info template, and `docker --version` names podman.
TEMPLATE_ERR="Error: template: info:1:2: executing \"info\" at <.OSType>: can't evaluate field OSType in type *define.Info"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="$TEMPLATE_ERR" STUB_TTY=1 -- "$RESOLVE")"
check "quiet podman-docker (template error) -> podman" podman "$(engine_of "$out")"
lacks    "  silently"                          "INFO" "$out"
lacks    "  and never prompts"                 "PROMPT" "$(calls)"
check    "  one docker probe"                  1 "$(cat "$TMP/docker-calls")"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_VERSION="podman version 5.2.2" STUB_TTY=1 -- "$RESOLVE")"
check "quiet podman-docker (--version) -> podman" podman "$(engine_of "$out")"
lacks    "  never 'not running'"               "not running" "$out"
lacks    "  and never prompts"                 "PROMPT" "$(calls)"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_VERSION="podman version 5.2.2" -- 'personal_docker_usable; printf "kind=%s\n" "$_pdu_kind"')"
contains "  kind is missing"                   "kind=missing" "$out"

echo
echo "the Docker-stopped prompt in the platform's words (LNXR-09)"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_TTY=1 STUB_ANSWER=p -- "$RESOLVE")"
lacks    "native Linux: no Docker Desktop"     "Docker Desktop" "$out"
contains "  names the service"                 "sudo systemctl start docker" "$out"
out="$(probe STUB_OS=wsl STUB_DOCKER_FAIL_FIRST=9 STUB_TTY=1 STUB_ANSWER=p -- "$RESOLVE")"
contains "WSL: Docker Desktop on Windows"      "Start Docker Desktop on Windows" "$out"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="The command 'docker' could not be found in this WSL 2 distro." -- "$RESOLVE")"
contains "WSL shim -> Docker Desktop not running" "Docker Desktop is not running" "$out"

echo
echo "Docker-stopped prompt waits for a slow Docker (WSL-08)"
out="$(probe STUB_DOCKER_FAIL_FIRST=3 STUB_TTY=1 -- "$RESOLVE")"
check "answers on the third re-probe -> docker" docker "$(engine_of "$out")"
check "  1 probe + 3 re-probes"                 4 "$(cat "$TMP/docker-calls")"
contains "  says it is waiting"                 "trying again for about 30 s" "$out"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_TTY=1 -- "$RESOLVE")"
contains "never answers -> says so"             "Docker still did not answer after about 30 s - the database will run on Podman" "$out"

echo
echo "adopting a deployment the kit did not record (LNX-06)"
mkdir -p "$TMP/dep"
printf '{"deploymentId":"exa-7f3a","dbPort":8563}\n' > "$TMP/dep/deployment.json"
ADOPT='EXAKIT_PERSONAL_DEPLOY_DIR="'"$TMP/dep"'"; printf "engine=%s\n" "$(personal_engine_existing)"'
out="$(probe STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "Docker lists its containers -> docker" "engine=docker" "$out"
contains "  and says so"                         "Adopting the existing deployment" "$out"
out="$(probe STUB_DOCKER_PS="something-else" -- "$ADOPT")"
contains "Docker does not list it -> podman"     "engine=podman" "$out"
out="$(probe STUB_BIN="$TMP/bin-nodocker" STUB_SYSBIN="$TMP/sysbin-nodocker" -- "$ADOPT")"
contains "no Docker at all -> podman"            "engine=podman" "$out"
SEED_MANIFEST='runtime.engine=podman\n'
out="$(probe STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "a recorded engine wins"                "engine=podman" "$out"
SEED_MANIFEST=""

echo
echo "a stopped Docker never records Podman for good (LNXR-04, LNXR-05)"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "2.4 deployment, Docker down, Podman does not list it -> unknown" "engine=
rc=0" "$out"
lacks    "  never guessed as Docker"             "engine=docker" "$out"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_PODMAN_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "Docker down, Podman lists it -> podman" "engine=podman" "$out"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="$DENIED" -- "$ADOPT")"
lacks    "Docker denied, Podman silent -> not guessed as Docker" "engine=docker" "$out"
DEPLOY_ADOPT='EXAKIT_PERSONAL_DEPLOY_DIR="'"$TMP/dep"'"; personal_deploy_local; printf "rc=%s\n" "$?"'
out="$(probe STUB_EXISTS=1 STUB_DOCKER_FAIL_FIRST=9 -- "$DEPLOY_ADOPT")"
contains "  the deploy step stops"               "rc=1" "$out"
contains "  says the engine cannot be read"      "engine cannot be read" "$out"
contains "  and that nothing was changed"        "Nothing was changed." "$out"
lacks    "  and records no engine"               "runtime.engine" "$(manifest)"
lacks    "  nor installs Podman for it"          "install_podman" "$(calls)"
lacks    "  nor starts the deployment"           "LAUNCHER start" "$(calls)"
lacks    "  nor destroys it"                     "LAUNCHER destroy" "$(calls)"
contains "  Docker down -> start Docker"         "Start Docker (if the deployment is on Docker)" "$out"
# DENIED IS NOT DOWN (LNX4-03): Docker is running and refuses this user, so
# "Start Docker" sends them to start what is already up.
out="$(probe STUB_EXISTS=1 STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="$DENIED" -- "$DEPLOY_ADOPT")"
contains "Docker denied, deploy step -> the engine cannot be read" "engine cannot be read" "$out"
contains "  names access to Docker"              "give your user access to it (the docker group" "$out"
lacks    "  never 'Start Docker'"                "Start Docker" "$out"
lacks    "  nor destroys it"                     "LAUNCHER destroy" "$(calls)"

echo
echo "a deployment made before Exasol Personal 2.4 is Podman, period (WIN3-02, LNX3-01)"
for _v in 2.3.1 2.0.0 1.9.0; do
    out="$(probe STUB_DEPLOYED="$_v" STUB_DOCKER_FAIL_FIRST=9 -- "$ADOPT")"
    contains "$_v, Docker down, Podman silent -> podman" "engine=podman" "$out"
    out="$(probe STUB_DEPLOYED="$_v" STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
    contains "$_v, even with Docker listing its id -> podman" "engine=podman" "$out"
done
check    "  2.3 asks Docker nothing"             "" "$(cat "$TMP/docker-calls" 2>/dev/null)"
out="$(probe STUB_DEPLOYED="" STUB_DOCKER_FAIL_FIRST=9 -- "$ADOPT")"
contains "version unreadable, no engine in state -> podman" "engine=podman" "$out"
out="$(probe STUB_DEPLOYED="" STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "  even with Docker listing its id"     "engine=podman" "$out"
SEED_MANIFEST='runtime.deployment_version=2.3.0\n'
out="$(probe STUB_DEPLOYED="" STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "the record's deployment_version 2.3.0 -> podman" "engine=podman" "$out"
SEED_MANIFEST=""
out="$(probe STUB_DEPLOYED="2.10.0" STUB_DOCKER_PS="exa-7f3a-db-1" -- "$ADOPT")"
contains "2.10 counts as 2.4+ -> docker on evidence" "engine=docker" "$out"
mkdir -p "$TMP/dep-state2"
printf '{"deploymentId":"exa-7f3a","containerEngine":"docker"}\n' > "$TMP/dep-state2/.exasolLauncherState.json"
out="$(probe STUB_DEPLOYED="" STUB_DOCKER_FAIL_FIRST=9 -- 'EXAKIT_PERSONAL_DEPLOY_DIR="'"$TMP/dep-state2"'"; printf "engine=%s\n" "$(personal_engine_existing)"')"
contains "version unreadable, state names docker -> docker" "engine=docker" "$out"
out="$(probe STUB_DEPLOYED="2.3.1" STUB_EXISTS=1 STUB_DOCKER_FAIL_FIRST=9 -- "$DEPLOY_ADOPT")"
lacks    "2.3 deploy, Docker down -> no 'start Docker'" "Start Docker" "$out"
lacks    "  and no unknown-engine stop"          "engine cannot be read" "$out"
contains "  goes the Podman way"                 "podman_running" "$(calls)"

echo
echo "the gate's 'Docker down' is asked again at the deploy (WIN3-01)"
out="$(probe STUB_DOCKER_FAIL_FIRST=1 -- 'personal_docker_usable; printf "gate=%s\n" "$?"; personal_deploy_local(){ [ "${_PERSONAL_PDU_RC:-}" = 1 ] && _personal_docker_uncache; personal_resolve_engine; }; personal_deploy_local; printf "deploy=%s\n" "$EXAKIT_PERSONAL_ENGINE"')"
contains "Docker down at the gate"               "gate=1" "$out"
contains "  up by the deploy -> docker"          "deploy=docker" "$out"
check    "  asked twice"                         2 "$(cat "$TMP/docker-calls")"
contains "the real deploy step drops a kept 'not usable'" '[ "${_PERSONAL_PDU_RC:-}" = 1 ] && _personal_docker_uncache' "$(sed -n '/^personal_deploy_local()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
out="$(probe -- 'personal_docker_usable; [ "${_PERSONAL_PDU_RC:-}" = 1 ] && _personal_docker_uncache; personal_docker_usable; printf "rc=%s\n" "$?"')"
check    "a kept 'usable' is not asked again"    1 "$(cat "$TMP/docker-calls")"
mkdir -p "$TMP/dep-state"
printf '{"deploymentId":"exa-7f3a","containerEngine":"docker"}\n' > "$TMP/dep-state/.exasolLauncherState.json"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_PODMAN_PS="exa-7f3a-db-1" -- 'EXAKIT_PERSONAL_DEPLOY_DIR="'"$TMP/dep-state"'"; printf "engine=%s\n" "$(personal_engine_existing)"')"
contains "the launcher's state names docker -> docker" "engine=docker" "$out"
check    "  without asking Docker"               "" "$(cat "$TMP/docker-calls" 2>/dev/null)"
printf '{"deploymentId":"exa"}\n' > "$TMP/dep-state/.exasolLauncherState.json"
NOTSUB='EXAKIT_PERSONAL_DEPLOY_DIR="'"$TMP/dep-state"'"; printf "engine=%s\n" "$(personal_engine_existing)"'
out="$(probe STUB_DOCKER_PS="exasol-nano
my-hexagon-app" -- "$NOTSUB")"
contains "id 'exa' is not a substring match"     "engine=podman" "$out"
for _n in exa exa-db-1 exa_db exasol_exa stack-exa; do
    out="$(probe STUB_DOCKER_PS="$_n" -- "$NOTSUB")"
    contains "  whole segment '$_n' matches"     "engine=docker" "$out"
done

echo
echo "personal_check_requirements: Podman checks only for a Podman deployment (LNX-05)"
REQ='detect_arch(){ echo x86_64; }; detect_ram_gb(){ echo 16; }; detect_free_disk_gb(){ echo 100; }
detect_free_disk_note(){ :; }; detect_wsl_version(){ echo 2; }; port_in_use(){ return 1; }
personal_podman_installable(){ return 1; }
personal_heal_rootless_podman(){ printf "RUN heal\n" >> "$STUB_CALLS"; }
personal_check_requirements'
out="$(probe -- "$REQ")"
lacks "Docker usable -> no rootless heal"        "RUN heal" "$(calls)"
out="$(probe STUB_BIN="$TMP/bin-nodocker" STUB_SYSBIN="$TMP/sysbin-nodocker" -- "$REQ")"
contains "no Docker -> rootless heal runs"       "RUN heal" "$(calls)"
out="$(probe EXAKIT_CONTAINER_ENGINE=podman -- "$REQ")"
contains "podman named -> rootless heal runs"    "RUN heal" "$(calls)"
mkdir -p "$TMP/bin-nopodman" && cp "$TMP/bin/docker" "$TMP/bin/exasol-stub" "$TMP/bin-nopodman/"
out="$(probe STUB_BIN="$TMP/bin-nopodman" STUB_SYSBIN="$TMP/sysbin-nodocker" -- "$REQ")"
lacks "Docker usable, no Podman -> no skip warning" "database step will be skipped" "$out"

echo
echo "the engine is decided once per process (LNXR-08)"
help_calls() { grep -c 'LAUNCHER install local --help' "$TMP/calls" 2>/dev/null || true; }
CHAIN="$REQ"'
personal_resolve_engine; printf "rc=%s engine=%s\n" "$?" "$EXAKIT_PERSONAL_ENGINE"
printf "flag=%s\n" "$(personal_engine_flag "$EXAKIT_PERSONAL_ENGINE")"
personal_engine_running docker && printf "running=yes\n"
printf "planned=%s\n" "$_PERSONAL_PLANNED"'
out="$(probe -- "$CHAIN")"
check "gate then deploy: engine"              docker "$(engine_of "$out")"
contains "  the plan matches the decision"    "planned=docker" "$out"
contains "  the flag is passed"               "flag=--container-engine docker" "$out"
check "  docker info asked once"              1 "$(cat "$TMP/docker-calls")"
check "  install local --help asked once"           1 "$(help_calls)"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 -- "$CHAIN")"
check "Docker down: engine"                   podman "$(engine_of "$out")"
check "  docker info asked once"              1 "$(cat "$TMP/docker-calls")"
out="$(probe STUB_DOCKER_FAIL_FIRST=9 STUB_TTY=1 -- "$CHAIN")"
check "Docker down, terminal: 1 + 3 re-probes" 4 "$(cat "$TMP/docker-calls")"
cp "$TMP/bin/exasol-stub" "$TMP/bin/exasol-stub2"
out="$(probe -- 'personal_launcher_takes_engine; STUB_CLI="'"$TMP/bin/exasol-stub2"'"; personal_launcher_takes_engine; personal_launcher_takes_engine')"
check "a new launcher is asked again, once"   2 "$(help_calls)"

echo
echo "preflight agrees with the deploy step (LNX-04, WSL-06, WSL-07, AGK-07)"
mkdir -p "$TMP/bin-wsl" && printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_WSL_OUT"\n' > "$TMP/bin-wsl/wsl.exe" && chmod +x "$TMP/bin-wsl/wsl.exe"
pf() { # pf <bin dir> <os> [ENV=val ...] -> the engine lines of the preflight
    _pf_b="$1"; _pf_os="$2"; shift 2
    rm -f "$TMP/docker-calls"
    env PATH="$_pf_b:$TMP/bin-wsl:$TMP/sysbin-nodocker" STUB_DOCKER_CALLS="$TMP/docker-calls" \
        HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" PF_OS="$_pf_os" "$@" bash -c '
        . "$0/setup/lib/detect.sh" >/dev/null 2>&1
        detect_os() { echo "$PF_OS"; }; detect_arch() { echo x86_64; }
        detect_ram_gb() { echo 16; }; detect_free_disk_gb() { echo 100; }
        detect_wsl_version() { echo 2; }; detect_wsl_drvfs_path() { return 1; }
        port_in_use() { return 1; }; curl() { return 0; }
        preflight_report' "$ROOT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -iE 'docker|podman|engine|WSL'
}
out="$(pf "$TMP/bin-nopodman" linux STUB_DOCKER_FAIL_FIRST=9)"
contains "docker down, no podman: says why"          "No usable container engine: Docker is installed but not running" "$out"
lacks    "  never 'none is on PATH'"                 "none is on PATH" "$out"
out="$(pf "$TMP/bin" linux STUB_DOCKER_FAIL_FIRST=9)"
contains "docker down, podman: a note with the reason" "not running ('docker info' did not answer) - a new Exasol Personal deployment will run on Podman" "$out"
contains "  and Podman is the engine"                "Podman: available" "$out"
out="$(pf "$TMP/bin" linux STUB_DOCKER_FAIL_FIRST=9 EXAKIT_CONTAINER_ENGINE=docker)"
contains "docker named, down: a bad line"            "EXAKIT_CONTAINER_ENGINE=docker, but Docker is installed but not running" "$out"
lacks    "  not a Podman pass"                       "Podman: available" "$out"
out="$(pf "$TMP/bin" linux EXAKIT_CONTAINER_ENGINE=lxc)"
contains "bogus value: a bad line"                   "EXAKIT_CONTAINER_ENGINE must be docker or podman, not 'lxc'" "$out"
out="$(pf "$TMP/bin" linux STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="$DENIED")"
contains "permission denied: the reason"             "Docker is running but your user cannot use it (permission denied on its socket)" "$out"
contains "  and the remedy, before anything exists"  "add your user to the docker group before installing" "$out"
out="$(pf "$TMP/bin" linux STUB_DOCKER_FAIL_FIRST=9 STUB_DOCKER_ERR="$TEMPLATE_ERR")"
lacks    "quiet podman-docker: never 'not running'"  "not running" "$out"
contains "  Podman is the engine"                    "Podman: available" "$out"
# A kept launcher on PATH that predates --container-engine (LNXR-03).
mkdir -p "$TMP/bin-l23" && cp "$TMP/bin/"* "$TMP/bin-l23/"
cat > "$TMP/bin-l23/exasol" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "install --help" ]; then
    echo "Available presets:"
    echo "  local       Deploy Exasol Personal on this machine"
    echo "Flags:"
fi
if [ "$*" = "install local --help" ]; then
    [ "${STUB_HELP_ENGINE:-1}" = 1 ] && echo "      --container-engine string   Container engine"
fi
exit 0
STUB
chmod +x "$TMP/bin-l23/exasol"
out="$(pf "$TMP/bin-l23" linux STUB_HELP_ENGINE=0)"
lacks    "2.3 launcher: no green Docker line"        "Docker: available" "$out"
contains "  says why, once"                          "Docker is usable, but this Exasol launcher cannot be told which engine to use - a new Exasol Personal deployment will run on Podman" "$out"
contains "  and judges Podman"                       "Podman: available" "$out"
out="$(pf "$TMP/bin-l23" linux STUB_HELP_ENGINE=0 EXAKIT_CONTAINER_ENGINE=docker)"
contains "2.3 launcher, docker named: a bad line"    "EXAKIT_CONTAINER_ENGINE=docker, but this Exasol launcher cannot be told" "$out"
lacks    "  not a Podman pass"                       "Podman: available" "$out"
out="$(pf "$TMP/bin-l23" linux STUB_HELP_ENGINE=1)"
contains "2.4 launcher: Docker"                      "Docker: available" "$out"
out="$(pf "$TMP/bin-l23" linux STUB_HELP_ENGINE=0 EXAKIT_FORCE_COMPONENT_INSTALL=1)"
contains "forced launcher install: Docker"           "Docker: available" "$out"
# Podman named and not installed, on a box with a working Docker (LNXR-11).
out="$(pf "$TMP/bin-nopodman" linux EXAKIT_CONTAINER_ENGINE=podman)"
lacks    "podman named, missing: never 'none is on PATH'" "none is on PATH" "$out"
contains "  says it is named and will be installed"  "EXAKIT_CONTAINER_ENGINE=podman, and Podman is not installed yet - the database step installs it" "$out"
out="$(pf "$TMP/bin-nopodman" linux EXAKIT_CONTAINER_ENGINE=podman EXAKIT_INSTALL_PODMAN=0)"
contains "  with EXAKIT_INSTALL_PODMAN=0: a bad line" "EXAKIT_INSTALL_PODMAN=0 stops the installer installing it" "$out"
out="$(pf "$TMP/bin" wsl STUB_DOCKER_FAIL_FIRST=9 STUB_WSL_OUT="WSL version: 2.6.1.0")"
contains "WSL 2.6 + Podman: a bad line"              "WSL 2.6.1.0: Podman on this WSL kernel cannot create the network" "$out"
out="$(pf "$TMP/bin" wsl STUB_DOCKER_FAIL_FIRST=9 STUB_WSL_OUT="WSL version: 2.7.0.0")"
lacks    "WSL 2.7 + Podman: no WSL line"             "Podman on this WSL kernel" "$out"
out="$(pf "$TMP/bin" wsl STUB_DOCKER_FAIL_FIRST=9 STUB_WSL_OUT="usage: wsl.exe")"
contains "WSL release unknown: a note"               "The WSL release could not be read" "$out"
out="$(pf "$TMP/bin" wsl STUB_WSL_OUT="WSL version: 2.6.1.0")"
lacks    "WSL 2.6 + Docker: no WSL gate"             "Podman on this WSL kernel" "$out"

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
