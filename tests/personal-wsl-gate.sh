#!/usr/bin/env bash
# personal-wsl-gate.sh — Podman on a WSL kernel without nftables, refused
# before anything changes; and Docker counted by preflight.
#
#   bash tests/personal-wsl-gate.sh
#
# What it pins, and why each one exists:
#   - Exasol Personal 2.4 puts a deployment on its own bridge network, which
#     Podman builds with the nftables firewall driver. The kernel WSL 2.6 and
#     older ship has none, so the deploy - or the first start after a launcher
#     update - fails with  netavark: nftables error: "nft" did not return
#     successfully while applying ruleset.  The kit reads `wsl.exe --version`
#     and refuses the fresh Podman deploy and the launcher update up front, with
#     `wsl --update` named. A machine that already runs Podman's iptables
#     driver passes; one whose wsl.exe cannot be run is warned and let through.
#   - wsl.exe writes UTF-16 and a localized label; only the number is read.
#   - After a launcher update to 2.4 an existing deployment is told what stays
#     the same (engine, password) and what moves (the network, at next start).
#   - Preflight counts a Docker Engine 29+ running Linux containers as the
#     engine; an older or stopped one does not count.
#
# Uses stub wsl.exe, docker and launcher binaries; never touches a real one.

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

command -v iconv >/dev/null 2>&1 || { echo "SKIP: iconv required to forge wsl.exe's UTF-16 output"; exit 0; }

# --- stub binaries ------------------------------------------------------------
# wsl.exe prints the bytes of STUB_WSL_OUT: UTF-16LE with a BOM and CRLF, as
# the real one does through a pipe.
mkdir -p "$TMP/bin" "$TMP/bin-nowsl" "$TMP/home"
utf16() { printf '\357\273\277%b' "$1" | iconv -f UTF-8 -t UTF-16 > "$2"; }
utf16 'WSL version: 2.6.1.0\r\nKernel version: 6.6.87.2-1\r\n'   "$TMP/wsl-2.6"
utf16 'WSL version: 2.7.0.0\r\nKernel version: 6.6.87.2-1\r\n'   "$TMP/wsl-2.7"
utf16 'WSL version: 3.1.0.0\r\n'                                 "$TMP/wsl-3.1"
utf16 'WSL-Version: 2.6.1.0\r\nKernelversion: 6.6.87.2-1\r\n'    "$TMP/wsl-de"
utf16 'Usage: wsl.exe [Argument] [Options...] [CommandLine]\r\n' "$TMP/wsl-inbox"
cat > "$TMP/bin/wsl.exe" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_WSL_OUT"
STUB
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_DOCKER_FAIL:-0}" = 1 ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
printf '%s\n' "${STUB_DOCKER_INFO:-linux 29.1.0}"
STUB
cat > "$TMP/bin/exasol-stub" <<'STUB'
#!/usr/bin/env bash
printf 'LAUNCHER %s\n' "$*" >> "$STUB_CALLS"
case "$*" in "install --help") echo "      --container-engine string" ;; esac
exit 0
STUB
chmod +x "$TMP/bin/"*
cp "$TMP/bin/exasol-stub" "$TMP/bin-nowsl/"

# --- harness ------------------------------------------------------------------
cat > "$TMP/harness.sh" <<HARNESS
export PATH="\${STUB_BIN:-$TMP/bin}:/usr/bin:/bin"
export STUB_CALLS="$TMP/calls"
export HOME="$TMP/home"
unset XDG_CONFIG_HOME
MF="$TMP/manifest"
source "$ROOT/setup/lib/detect.sh"
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
manifest_get(){ grep "^\$1=" "\$MF" 2>/dev/null | tail -1 | cut -d= -f2-; grep -q "^\$1=" "\$MF" 2>/dev/null; }
manifest_set(){ { grep -v "^\$1=" "\$MF" 2>/dev/null || true; } > "\$MF.n"; mv "\$MF.n" "\$MF"; printf '%s=%s\n' "\$1" "\$2" >> "\$MF"; }
manifest_del(){ { grep -v "^\$1=" "\$MF" 2>/dev/null || true; } > "\$MF.n"; mv "\$MF.n" "\$MF"; }
detect_os(){ printf '%s' "\${STUB_OS:-wsl}"; }
_exakit_prompt_tty(){ return 0; }
exakit_note_failure(){ printf 'NOTE %s\n' "\$*" >> "\$STUB_CALLS"; }
exakit_install_command(){ printf 'bash install.sh'; }
exakit_run_bounded(){ shift; "\$@"; }
exakit_component_available(){ printf '%s' "\${STUB_LATEST:-2.4.0}"; }
exakit_major_version(){ printf '%s' "\${1%%.*}"; }
EXAKIT_BIN_DIR="$TMP/bin"
EXAKIT_PERSONAL_DEPLOY_DIR="$TMP/no-deployment"
source "$ROOT/setup/lib/runtime-personal.sh"
EXAKIT_PERSONAL_BIN="$TMP/never-deleted"
personal_cli(){ printf '%s' "$TMP/bin/exasol-stub"; }
personal_install_launcher(){ printf 'RUN install_launcher\n' >> "\$STUB_CALLS"; }
personal_record_manifest(){ :; }
personal_install_podman(){ printf 'RUN install_podman\n' >> "\$STUB_CALLS"; return 0; }
personal_podman_running(){ printf 'RUN podman_running\n' >> "\$STUB_CALLS"; return 0; }
personal_deployment_exists(){ [ "\${STUB_EXISTS:-0}" = 1 ]; }
eval "\$@"
HARNESS
probe() { # probe <ENV=val ...> -- <shell to eval>; echoes stdout then "rc=N"
    _envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do _envs[${#_envs[@]}]="$1"; shift; done
    shift
    : > "$TMP/calls"; : > "$TMP/manifest"
    [ -n "${SEED_MANIFEST:-}" ] && printf '%b' "$SEED_MANIFEST" > "$TMP/manifest"
    _out="$(env ${_envs[@]+"${_envs[@]}"} bash "$TMP/harness.sh" "$@" 2>&1)"; _rc=$?
    printf '%s\nrc=%s' "$_out" "$_rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
calls() { cat "$TMP/calls" 2>/dev/null; }
GATE='personal_wsl_podman_network_ok "exakit update personal"'

echo "detect_wsl_release: the number out of wsl.exe's UTF-16, whatever the label"
check "English label"  "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-2.6" -- 'detect_wsl_release' | sed '$d')"
check "German label"   "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-de" -- 'detect_wsl_release' | sed '$d')"
check "inbox WSL: ran, no number" "" "$(probe STUB_WSL_OUT="$TMP/wsl-inbox" -- 'detect_wsl_release' | sed '$d')"
check "  with exit 0"  0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-inbox" -- 'detect_wsl_release')")"
check "no wsl.exe: exit 1" 1 "$(rc_of "$(probe STUB_BIN="$TMP/bin-nowsl" -- 'detect_wsl_release')")"
check "not WSL: exit 1"    1 "$(rc_of "$(probe STUB_OS=linux STUB_WSL_OUT="$TMP/wsl-2.6" -- 'detect_wsl_release')")"

echo
echo "personal_wsl_podman_network_ok: 2.7 or newer, or the iptables driver, else refused"
out="$(probe STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")"
check "WSL 2.6 -> refused"                 1 "$(rc_of "$out")"
contains "  names the error"               "nft did not return successfully" "$out"
contains "  names the fix"                 "wsl --update" "$out"
contains "  then wsl --shutdown"           "wsl --shutdown" "$out"
contains "  and the re-run"                "exakit update personal" "$out"
contains "  offers the iptables driver"    'firewall_driver = "iptables"' "$out"
contains "  changed nothing"               "Nothing was changed." "$out"
contains "  noted the failure"             "NOTE WSL 2.6.1.0 is older than 2.7" "$(calls)"
check "German label -> refused too"        1 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-de" -- "$GATE")")"
check "inbox WSL -> refused"               1 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-inbox" -- "$GATE")")"
check "WSL 2.7 -> ok"                      0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-2.7" -- "$GATE")")"
check "WSL 3.1 -> ok"                      0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-3.1" -- "$GATE")")"
mkdir -p "$TMP/home/.config/containers"
printf '[network]\nfirewall_driver = "iptables"\n' > "$TMP/home/.config/containers/containers.conf"
out="$(probe STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")"
check "WSL 2.6 with the iptables driver -> ok" 0 "$(rc_of "$out")"
lacks "  silently"                         "WARN" "$out"
rm -f "$TMP/home/.config/containers/containers.conf"
out="$(probe STUB_BIN="$TMP/bin-nowsl" -- "$GATE")"
check "no wsl.exe -> let through"          0 "$(rc_of "$out")"
contains "  with a warning"                "WSL release is unknown" "$out"
out="$(probe STUB_OS=linux -- "$GATE")"
check "not WSL -> ok"                      0 "$(rc_of "$out")"
check "  without running anything"         "" "$(printf '%s' "$out" | sed '$d')"
check "macOS -> ok"                        0 "$(rc_of "$(probe STUB_OS=macos -- "$GATE")")"

echo
echo "exakit update personal: the gate before the swap, the notice after it"
SEED_MANIFEST='runtime.version=2.3.0\n'
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_update')"
check "Podman deployment on WSL 2.6 -> not updated" 1 "$(rc_of "$out")"
contains "  says so"                       "DIE Exasol Personal was not updated" "$out"
lacks "  launcher untouched"               "install_launcher" "$(calls)"
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.7" -- 'personal_update')"
check "WSL 2.7 -> updated"                 0 "$(rc_of "$out")"
contains "  launcher swapped"              "install_launcher" "$(calls)"
contains "  engine and password stay"      "keeps its engine (podman) and its database password" "$out"
contains "  network moves at next start"   "exakit stop' followed by 'exakit start' moves the containers" "$out"
SEED_MANIFEST='runtime.version=2.3.0\nruntime.engine=docker\n'
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_update')"
check "Docker deployment on WSL 2.6 -> updated, never asks" 0 "$(rc_of "$out")"
contains "  names docker"                  "keeps its engine (docker)" "$out"
SEED_MANIFEST='runtime.version=2.3.0\n'
out="$(probe STUB_EXISTS=1 STUB_LATEST=2.3.1 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_update')"
check "a 2.3.1 update -> no gate"          0 "$(rc_of "$out")"
lacks "  and no notice"                    "keeps its engine" "$out"
out="$(probe STUB_EXISTS=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_update')"
check "no deployment -> no gate"           0 "$(rc_of "$out")"
lacks "  and no notice"                    "keeps its engine" "$out"
out="$(probe STUB_OS=macos STUB_EXISTS=1 -- 'personal_update')"
check "macOS -> updated"                   0 "$(rc_of "$out")"
lacks "  no engine notice there"           "keeps its engine" "$out"
SEED_MANIFEST=""

echo
echo "personal_deploy_local: a fresh Podman deploy on WSL 2.6 is refused before Podman is installed"
out="$(probe STUB_BIN="$TMP/bin-nowsl" STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_deploy_local')"
# bin-nowsl has no docker and no wsl.exe: Podman it is, and the release is unknown - let through.
contains "unknown WSL release: Podman is still installed" "install_podman" "$(calls)"
: > "$TMP/calls"
cp "$TMP/bin/wsl.exe" "$TMP/bin-nowsl/wsl.exe"
out="$(probe STUB_BIN="$TMP/bin-nowsl" STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_deploy_local')"
check "WSL 2.6 -> the step stops"          1 "$(rc_of "$out")"
lacks "  before installing Podman"         "install_podman" "$(calls)"
lacks "  before asking the launcher"       "LAUNCHER install" "$(calls)"
contains "  re-run names the installer"    "re-run: bash install.sh" "$out"
rm -f "$TMP/bin-nowsl/wsl.exe"

echo
echo "detect_docker: Engine 29+ on Linux containers, else none"
DD='source "$ROOT/setup/lib/detect.sh"; detect_docker'
dd_probe() { env PATH="$TMP/bin:/usr/bin:/bin" "$@" bash -c "ROOT='$ROOT'; $DD" 2>&1; }
check "29.1.0 linux"        docker "$(dd_probe STUB_DOCKER_INFO='linux 29.1.0')"
check "28.3.1 linux"        none   "$(dd_probe STUB_DOCKER_INFO='linux 28.3.1')"
check "29 windows"          none   "$(dd_probe STUB_DOCKER_INFO='windows 29.0.0')"
check "daemon down"         none   "$(dd_probe STUB_DOCKER_FAIL=1)"
check "no docker"           none   "$(env PATH="$TMP/bin-nowsl:/usr/bin:/bin" bash -c "ROOT='$ROOT'; $DD" 2>&1)"
DETECT="$(cat "$ROOT/setup/lib/detect.sh")"
PF="$(printf '%s\n' "$DETECT" | sed -n '/^preflight_report()/,/^}$/p')"
contains "preflight asks detect_docker"              '$(detect_docker 2>/dev/null)" = "docker"' "$PF"
contains "  and honours EXAKIT_CONTAINER_ENGINE=podman" 'EXAKIT_CONTAINER_ENGINE:-}" != "podman"' "$PF"
contains "  the no-engine line names both"           "or Docker Engine 29 or newer" "$PF"

echo
echo "the Windows twin (source checks: the machine and wsl.exe are Windows-only)"
RTP="$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
UPD="$(printf '%s\n' "$RTP" | sed -n '/^function Update-Personal {/,/^}$/p')"
DEP="$(printf '%s\n' "$RTP" | sed -n '/^function Install-PersonalDeployment {/,/^}$/p')"
REL="$(printf '%s\n' "$RTP" | sed -n '/^function Get-PersonalWslRelease {/,/^}$/p')"
contains "the release probe strips UTF-16 NULs"      '-replace "`0", ""' "$REL"
contains "  and reads only the number"               '(\d+(?:\.\d+)*)' "$REL"
contains "update gates a Podman deployment"          '(Get-PersonalEngineRecorded) -eq "podman"' "$UPD"
contains "  through the WSL check"                   'Test-PersonalWslPodmanNetworkOk "exakit update personal"' "$UPD"
_gate=$(printf '%s\n' "$UPD" | grep -n 'Test-PersonalWslPodmanNetworkOk' | cut -d: -f1 | head -1)
_swap=$(printf '%s\n' "$UPD" | grep -n 'Install-PersonalLauncher' | cut -d: -f1 | head -1)
check "  before the launcher swap" yes "$([ -n "$_gate" ] && [ -n "$_swap" ] && [ "$_gate" -lt "$_swap" ] && echo yes || echo no)"
contains "  and says what stays the same"            "keeps its engine" "$UPD"
contains "the deploy gates a fresh Podman deployment" 'if (-not (Test-PersonalWslPodmanNetworkOk))' "$DEP"
contains "  but not a Docker one"                    'if ($script:PersonalEngine -ne "docker") {' "$DEP"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
