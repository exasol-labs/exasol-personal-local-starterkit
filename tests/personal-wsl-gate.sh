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
#     and refuses the fresh Podman deploy up front, with `wsl --update` named.
#     The launcher UPDATE is not gated: it changes no data, and a failed start
#     after it names `wsl --update` from the launcher's own nft error. A machine that already runs Podman's iptables
#     driver (read as Podman reads containers.conf: [network] only, the last
#     file wins, drop-ins included, with iptables installed), or a Podman not
#     on netavark, passes; one whose release cannot be
#     read (wsl.exe missing, interop off, a failed or timed-out probe, usage
#     text, no output) is warned and let through - unknown is not old.
#   - Replacing a Podman deployment (EXAKIT_REPLACE_DB, exakit repair-runtime)
#     is checked BEFORE the destroy: refused, nothing is deleted.
#   - wsl.exe writes UTF-16LE and a localized label: decoded, and only a
#     dotted release is read (Japanese and Russian labels once leaked digits).
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
mkdir -p "$TMP/bin" "$TMP/bin-nowsl" "$TMP/bin-badexec" "$TMP/bin-podman" "$TMP/bin-ipt" "$TMP/home" "$TMP/sys"
# Built as Windows writes it: the UTF-16LE byte order mark, then UTF-16LE.
utf16() { { printf '\377\376'; printf '%b' "$1" | iconv -f UTF-8 -t UTF-16LE; } > "$2"; }
utf16 'WSL version: 2.6.1.0\r\nKernel version: 6.6.87.2-1\r\n'   "$TMP/wsl-2.6"
utf16 'WSL version: 2.7.0.0\r\nKernel version: 6.6.87.2-1\r\n'   "$TMP/wsl-2.7"
utf16 'WSL version: 2.10.1.0\r\nKernel version: 6.6.87.2-1\r\n'  "$TMP/wsl-2.10"
utf16 'WSL version: 3.1.0.0\r\n'                                 "$TMP/wsl-3.1"
utf16 'WSL-Version: 2.6.1.0\r\nKernelversion: 6.6.87.2-1\r\n'    "$TMP/wsl-de"
utf16 'Version WSL : 2.6.1.0\r\nVersion du noyau : 6.6.87.2-1\r\n' "$TMP/wsl-fr"
utf16 'WSL バージョン: 2.7.0.0\r\nカーネル バージョン: 6.6.87.2-1\r\n' "$TMP/wsl-ja"
utf16 'Версия WSL: 2.6.1.0\r\nВерсия ядра: 6.6.87.2-1\r\n'       "$TMP/wsl-ru"
utf16 'WSL 版本： 2.6.1.0\r\n内核版本： 6.6.87.2-1\r\n'           "$TMP/wsl-zh"
utf16 'Usage: wsl.exe [Argument] [Options...] [CommandLine]\r\n' "$TMP/wsl-inbox"
# WSL_UTF8=1 makes wsl.exe write plain UTF-8: no NULs, so no UTF-16 decode.
printf 'WSL version: 2.6.1.0\r\nKernel version: 6.6.87.2-1\r\n' > "$TMP/wsl-utf8"
: > "$TMP/wsl-empty"
# STUB_WSL_RC: the exit status, after writing STUB_WSL_OUT (if any) to stdout
# and a line to stderr - interop failing answers on stderr only.
cat > "$TMP/bin/wsl.exe" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_WSL_OUT:-}" ] && cat "$STUB_WSL_OUT"
if [ "${STUB_WSL_RC:-0}" != 0 ]; then echo "UtilBindVsockAnyPort: socket failed 1" >&2; exit "$STUB_WSL_RC"; fi
exit 0
STUB
# Interop off: wsl.exe is found (the Windows PATH and /mnt/c stay) but the
# exec fails - a PE header the kernel does not run.
printf 'MZ\220\000\003\000\000\000' > "$TMP/bin-badexec/wsl.exe"
chmod +x "$TMP/bin-badexec/wsl.exe"
# Podman that answers its network backend with STUB_PODMAN_BACKEND, or
# nothing (and exit 1) when that is unset.
# STUB_PODMAN_OLD=1: Podman 3.4 (Ubuntu 22.04's), whose info has no
# NetworkBackend field - a template error on stderr and exit 125.
cat > "$TMP/bin-podman/podman" <<'STUB'
#!/usr/bin/env bash
printf 'PODMAN %s\n' "$*" >> "$STUB_CALLS"
if [ "${STUB_PODMAN_OLD:-0}" = 1 ]; then
    echo 'Error: template: info:1:7: executing "info" at <.Host.NetworkBackend>: can'"'"'t evaluate field NetworkBackend in type *define.HostInfo' >&2
    exit 125
fi
[ -n "${STUB_PODMAN_BACKEND:-}" ] || exit 1
printf '%s\n' "$STUB_PODMAN_BACKEND"
STUB
chmod +x "$TMP/bin-podman/podman"
# iptables on PATH: the iptables-driver exemption needs the binary too.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin-ipt/iptables"
chmod +x "$TMP/bin-ipt/iptables"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_DOCKER_FAIL:-0}" = 1 ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
printf '%s\n' "${STUB_DOCKER_INFO:-linux 29.1.0}"
STUB
cat > "$TMP/bin/exasol-stub" <<'STUB'
#!/usr/bin/env bash
printf 'LAUNCHER %s\n' "$*" >> "$STUB_CALLS"
case "$*" in "install local --help") echo "      --container-engine string" ;; esac
exit 0
STUB
chmod +x "$TMP/bin/"*
cp "$TMP/bin/exasol-stub" "$TMP/bin-nowsl/"

# --- harness ------------------------------------------------------------------
# A copy of the system tool directories WITHOUT docker. Every machine this
# suite describes runs on Podman unless its stub docker answers, and the
# harness keeps the system tools on PATH for grep, sed and friends - but on
# the GitHub ubuntu runner that is also where a Docker Engine 29+ lives, which
# answered for the "no docker" machines and made the kit choose Docker.
# Symlinks, so the copy costs nothing.
mkdir -p "$TMP/sysbin-nodocker"
for _t in /usr/bin/* /bin/*; do
    case "${_t##*/}" in docker|podman|iptables*|ip6tables*) continue ;; esac
    ln -s "$_t" "$TMP/sysbin-nodocker/" 2>/dev/null || true
done

cat > "$TMP/harness.sh" <<HARNESS
export PATH="\${STUB_BIN:-$TMP/bin}:$TMP/sysbin-nodocker"
export STUB_CALLS="$TMP/calls"
export HOME="$TMP/home"
unset XDG_CONFIG_HOME
MF="$TMP/manifest"
source "$ROOT/setup/lib/detect.sh"
# Podman's system containers.conf files, read from $TMP/sys instead of the
# runner's own /usr/share and /etc: the REAL file list and order, hermetic.
eval "\$(declare -f _detect_podman_conf_files | sed -e "s#/usr/share/containers#$TMP/sys/usr/share/containers#g" -e "s#/etc/containers#$TMP/sys/etc/containers#g")"
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
manifest_get(){ grep "^\$1=" "\$MF" 2>/dev/null | tail -1 | cut -d= -f2-; grep -q "^\$1=" "\$MF" 2>/dev/null; }
manifest_set(){ { grep -v "^\$1=" "\$MF" 2>/dev/null || true; } > "\$MF.n"; mv "\$MF.n" "\$MF"; printf '%s=%s\n' "\$1" "\$2" >> "\$MF"; }
manifest_del(){ { grep -v "^\$1=" "\$MF" 2>/dev/null || true; } > "\$MF.n"; mv "\$MF.n" "\$MF"; }
detect_os(){ printf '%s' "\${STUB_OS:-wsl}"; }
_exakit_prompt_tty(){ return 0; }
exakit_note_failure(){ printf 'NOTE %s\n' "\$*" >> "\$STUB_CALLS"; }
exakit_install_command(){ printf 'bash install.sh'; }
# STUB_PROBE_TIMEOUT=1: every bounded probe is cut off, as the real runner
# answers a hang - 124 and no output.
exakit_run_bounded(){ shift; [ "\${STUB_PROBE_TIMEOUT:-0}" = 1 ] && return 124; "\$@"; }
confirm_env(){ eval "[ \"\\\${\$1:-0}\" = 1 ]"; }
exakit_component_available(){ printf '%s' "\${STUB_LATEST:-2.4.0}"; }
exakit_major_version(){ printf '%s' "\${1%%.*}"; }
EXAKIT_BIN_DIR="$TMP/bin"
EXAKIT_PERSONAL_DEPLOY_DIR="$TMP/no-deployment"
source "$ROOT/setup/lib/runtime-personal.sh"
EXAKIT_PERSONAL_BIN="$TMP/never-deleted"
personal_cli(){ printf '%s' "$TMP/bin/exasol-stub"; }
personal_install_launcher(){ printf 'RUN install_launcher\n' >> "\$STUB_CALLS"; }
personal_record_manifest(){ :; }
# The credential before and after the swap: the same value unless
# STUB_CRED_AFTER names a second one, nothing at all under STUB_CRED_EMPTY=1.
read_credential(){
    _n=0; [ -f "\$STUB_CALLS.cred" ] && _n="\$(cat "\$STUB_CALLS.cred")"
    _n=\$((_n + 1)); printf '%s' "\$_n" > "\$STUB_CALLS.cred"
    [ "\${STUB_CRED_EMPTY:-0}" = 1 ] && return 0
    if [ -n "\${STUB_CRED_AFTER:-}" ] && [ "\$_n" -ge 2 ]; then printf '%s' "\$STUB_CRED_AFTER"; else printf 'same-pw'; fi
}
# The deployment's secrets.json answers a password (no file in this harness).
_personal_update_secrets_readable(){ [ "\${STUB_CRED_EMPTY:-0}" != 1 ]; }
personal_install_podman(){ printf 'RUN install_podman\n' >> "\$STUB_CALLS"; return 0; }
personal_podman_running(){ printf 'RUN podman_running\n' >> "\$STUB_CALLS"; return 0; }
personal_deployment_exists(){ [ "\${STUB_EXISTS:-0}" = 1 ]; }
eval "\$@"
HARNESS
probe() { # probe <ENV=val ...> -- <shell to eval>; echoes stdout then "rc=N"
    _envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do _envs[${#_envs[@]}]="$1"; shift; done
    shift
    : > "$TMP/calls"; rm -f "$TMP/calls.cred"; : > "$TMP/manifest"
    [ -n "${SEED_MANIFEST:-}" ] && printf '%b' "$SEED_MANIFEST" > "$TMP/manifest"
    _out="$(env ${_envs[@]+"${_envs[@]}"} bash "$TMP/harness.sh" "$@" 2>&1)"; _rc=$?
    printf '%s\nrc=%s' "$_out" "$_rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
calls() { cat "$TMP/calls" 2>/dev/null; }
GATE='personal_wsl_podman_network_ok "$(exakit_install_command)"'

echo "detect_wsl_release: the number out of wsl.exe's UTF-16, whatever the label"
check "English label"  "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-2.6" -- 'detect_wsl_release' | sed '$d')"
check "German label"   "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-de" -- 'detect_wsl_release' | sed '$d')"
check "French label"   "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-fr" -- 'detect_wsl_release' | sed '$d')"
# Katakana's UTF-16 high byte is 0x30 ("0") and Cyrillic а..й's low byte is
# 0x30-0x39: a NUL strip alone read these as "0" and "5".
check "Japanese label" "2.7.0.0" "$(probe STUB_WSL_OUT="$TMP/wsl-ja" -- 'detect_wsl_release' | sed '$d')"
check "Russian label"  "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-ru" -- 'detect_wsl_release' | sed '$d')"
check "Chinese label"  "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-zh" -- 'detect_wsl_release' | sed '$d')"
check "two-digit minor" "2.10.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-2.10" -- 'detect_wsl_release' | sed '$d')"
check "plain UTF-8 (WSL_UTF8=1)" "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-utf8" -- 'detect_wsl_release' | sed '$d')"
# Without iconv the NUL strip is the fallback; the dotted-number rule alone
# still keeps a stray label byte out of the release.
check "Japanese, no iconv" "2.7.0.0" "$(probe STUB_WSL_OUT="$TMP/wsl-ja" -- 'iconv(){ return 127; }; command(){ [ "$1 $2" = "-v iconv" ] && return 1; builtin command "$@"; }; detect_wsl_release' | sed '$d')"
check "Russian, no iconv"  "2.6.1.0" "$(probe STUB_WSL_OUT="$TMP/wsl-ru" -- 'command(){ [ "$1 $2" = "-v iconv" ] && return 1; builtin command "$@"; }; detect_wsl_release' | sed '$d')"
out="$(probe STUB_WSL_OUT="$TMP/wsl-inbox" -- 'detect_wsl_release')"
check "inbox WSL (usage text): unknown, exit 1" 1 "$(rc_of "$out")"
check "  prints nothing"  "" "$(printf '%s' "$out" | sed '$d')"
check "no wsl.exe: exit 1" 1 "$(rc_of "$(probe STUB_BIN="$TMP/bin-nowsl" -- 'detect_wsl_release')")"
check "wsl.exe cannot exec (interop off): exit 1" 1 "$(rc_of "$(probe STUB_BIN="$TMP/bin-badexec" -- 'detect_wsl_release')")"
check "wsl.exe exits 1, stderr only: exit 1" 1 "$(rc_of "$(probe STUB_WSL_RC=1 -- 'detect_wsl_release')")"
check "wsl.exe exits 1 after a version: exit 1" 1 "$(rc_of "$(probe STUB_WSL_RC=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'detect_wsl_release')")"
check "probe timed out: exit 1" 1 "$(rc_of "$(probe STUB_PROBE_TIMEOUT=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'detect_wsl_release')")"
# THE REAL BOUNDED RUNNER (WSL3-05), not the harness stub: a wsl.exe that
# hangs is cut off at EXAKIT_ENGINE_PROBE_TIMEOUT and read as unknown.
mkdir -p "$TMP/bin-hang"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$TMP/bin-hang/wsl.exe"
chmod +x "$TMP/bin-hang/wsl.exe"
_RB="$(sed -n '/^exakit_run_bounded() {/,/^}/p' "$ROOT/setup/lib/common.sh")"
printf '%s\n' "$_RB" > "$TMP/run-bounded.sh"
_rb_t0="$(date +%s)"
out="$(probe STUB_BIN="$TMP/bin-hang:$TMP/bin" -- ". '$TMP/run-bounded.sh'; EXAKIT_ENGINE_PROBE_TIMEOUT=2; detect_wsl_release")"
_rb_t1="$(date +%s)"
check "a hanging wsl.exe, the real bounded runner: exit 1" 1 "$(rc_of "$out")"
check "  prints nothing"  "" "$(printf '%s' "$out" | sed '$d')"
check "  cut off well before the hang ends" yes "$([ $((_rb_t1 - _rb_t0)) -lt 20 ] && echo yes || echo no)"
check "empty output: exit 1" 1 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-empty" -- 'detect_wsl_release')")"
check "not WSL: exit 1"    1 "$(rc_of "$(probe STUB_OS=linux STUB_WSL_OUT="$TMP/wsl-2.6" -- 'detect_wsl_release')")"

echo
echo "personal_wsl_podman_network_ok: 2.7 or newer, or the iptables driver, else refused"
out="$(probe STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")"
check "WSL 2.6 -> refused"                 1 "$(rc_of "$out")"
contains "  names the error"               "nft did not return successfully" "$out"
contains "  names the fix"                 "wsl --update" "$out"
contains "  then wsl --shutdown"           "wsl --shutdown" "$out"
contains "  and the re-run"                "re-run: bash install.sh" "$out"
contains "  offers the iptables driver"    'firewall_driver = "iptables"' "$out"
contains "  changed nothing"               "Nothing was changed." "$out"
contains "  noted the failure"             "NOTE WSL 2.6.1.0 is older than 2.7" "$(calls)"
check "German label -> refused too"        1 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-de" -- "$GATE")")"
check "French label -> refused too"        1 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-fr" -- "$GATE")")"
out="$(probe STUB_WSL_OUT="$TMP/wsl-ru" -- "$GATE")"
check "Russian label on 2.6 -> refused"    1 "$(rc_of "$out")"
contains "  names the real release"        "Podman on WSL 2.6.1.0 cannot" "$out"
check "Japanese label on 2.7 -> ok"        0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-ja" -- "$GATE")")"
check "Chinese label on 2.6 -> refused"    1 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-zh" -- "$GATE")")"
check "WSL 2.7 -> ok"                      0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-2.7" -- "$GATE")")"
check "WSL 2.10 -> ok"                     0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-2.10" -- "$GATE")")"
check "WSL 3.1 -> ok"                      0 "$(rc_of "$(probe STUB_WSL_OUT="$TMP/wsl-3.1" -- "$GATE")")"
# UNKNOWN IS NOT OLD. Every way the release can fail to be read warns and lets
# through; only a release read below 2.7 refuses.
for _case in "inbox WSL (usage text)|STUB_WSL_OUT=$TMP/wsl-inbox" \
             "interop off (exec fails)|STUB_BIN=$TMP/bin-badexec" \
             "interop failure (exit 1, stderr only)|STUB_WSL_RC=1" \
             "probe timed out|STUB_PROBE_TIMEOUT=1 STUB_WSL_OUT=$TMP/wsl-2.6" \
             "empty output|STUB_WSL_OUT=$TMP/wsl-empty"; do
    # shellcheck disable=SC2086
    out="$(probe ${_case#*|} -- "$GATE")"
    check "${_case%%|*} -> let through" 0 "$(rc_of "$out")"
    contains "  with a warning"        "so it is unknown" "$out"
    lacks    "  never 'older than'"    "older than 2.0" "$out"
done
# A PODMAN NOT ON NETAVARK cannot hit the nftables error: let through on 2.6.
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=cni STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")"
check "WSL 2.6, Podman on CNI -> ok"       0 "$(rc_of "$out")"
lacks "  silently"                         "WARN" "$out"
contains "  asked Podman"                  "PODMAN info --format {{.Host.NetworkBackend}}" "$(calls)"
check "WSL 2.6, Podman on netavark -> refused" 1 \
    "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
check "WSL 2.6, Podman that does not answer -> refused" 1 \
    "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
check "WSL 2.6, Podman 3.4 (template error, exit 125) -> refused" 1 \
    "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_OLD=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
# One predicate, shared with the preflight (detect.sh).
check "detect_podman_backend_not_netavark: cni"      0 "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=cni -- 'detect_podman_backend_not_netavark')")"
check "  netavark"                                   1 "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark -- 'detect_podman_backend_not_netavark')")"
check "  no answer"                                  1 "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" -- 'detect_podman_backend_not_netavark')")"
check "  Podman 3.4's template error"                1 "$(rc_of "$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_OLD=1 -- 'detect_podman_backend_not_netavark')")"
check "  no podman"                                  1 "$(rc_of "$(probe -- 'detect_podman_backend_not_netavark')")"
RTS="$(sed -n '/^personal_wsl_podman_network_ok()/,/^}$/p' "$ROOT/setup/lib/runtime-personal.sh")"
contains "the gate uses the shared predicate"        "detect_podman_backend_not_netavark && return 0" "$RTS"
lacks    "  and does not carry its own probe"        "NetworkBackend" "$RTS"
mkdir -p "$TMP/home/.config/containers"
printf '[network]\nfirewall_driver = "iptables"\n' > "$TMP/home/.config/containers/containers.conf"
out="$(probe STUB_BIN="$TMP/bin-ipt:$TMP/bin" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")"
check "WSL 2.6 with the iptables driver -> ok" 0 "$(rc_of "$out")"
lacks "  silently"                         "WARN" "$out"
rm -f "$TMP/home/.config/containers/containers.conf"
out="$(probe STUB_BIN="$TMP/bin-nowsl" -- "$GATE")"
check "no wsl.exe -> let through"          0 "$(rc_of "$out")"
contains "  with a warning"                "Could not read the WSL release" "$out"
out="$(probe STUB_OS=linux -- "$GATE")"
check "not WSL -> ok"                      0 "$(rc_of "$out")"
check "  without running anything"         "" "$(printf '%s' "$out" | sed '$d')"
check "macOS -> ok"                        0 "$(rc_of "$(probe STUB_OS=macos -- "$GATE")")"

echo
echo "exakit update personal: no WSL gate before the swap, the notice after it"
SEED_MANIFEST='runtime.version=2.3.0\n'
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- 'personal_update')"
check "Podman deployment on WSL 2.6 -> updated" 0 "$(rc_of "$out")"
contains "  launcher swapped"              "install_launcher" "$(calls)"
lacks "  never refused"                    "was not updated" "$out"
lacks "  no WSL warning at the update"     "cannot create the network" "$out"
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.7" -- 'personal_update')"
check "WSL 2.7 -> updated"                 0 "$(rc_of "$out")"
contains "  launcher swapped"              "install_launcher" "$(calls)"
contains "  engine and password stay"      "keeps its engine (podman) and its database password" "$out"
contains "  network moves at next start"   "exakit stop' followed by 'exakit start' moves the containers" "$out"
# The password line is a RESULT: said only when the credential read before the
# swap and the one re-read after it agree. A changed one is refreshed and said;
# one that could not be read is not claimed either way.
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.7" STUB_CRED_AFTER=new-pw -- 'personal_update')"
check "password changed on update -> still updated" 0 "$(rc_of "$out")"
contains "  the change is said"            "The database password changed with this update" "$out"
contains "  engine still named"            "keeps its engine (podman)." "$out"
lacks    "  password not claimed as kept"  "and its database password" "$out"
check    "  no password in the output"     0 "$(printf '%s' "$out" | grep -c 'new-pw\|same-pw')"
out="$(probe STUB_EXISTS=1 STUB_WSL_OUT="$TMP/wsl-2.7" STUB_CRED_EMPTY=1 -- 'personal_update')"
check "credential unreadable -> still updated" 0 "$(rc_of "$out")"
contains "  engine named"                  "keeps its engine (podman)." "$out"
lacks    "  nothing claimed about the password" "database password" "$out"
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
echo "personal_deploy_local: replacing a Podman deployment on WSL 2.6 deletes nothing"
# exakit repair-runtime and EXAKIT_REPLACE_DB=1 land on the replace path: the
# deployment exists, will not start, and its replacement deploys afresh - which
# on a kernel without nftables fails after the data is gone.
NOTRUN='run_logged(){ "$@"; }; personal_deployment_running(){ return 1; }; personal_launcher_state(){ echo stopped; }; personal_launcher_supports(){ return 1; }; personal_reap_orphan_daemon(){ return 1; }; personal_note_guest_rebuild(){ :; }; port_in_use(){ return 0; }; personal_deploy_local'
# port_in_use answers yes with nothing to reap: the step ends right after the
# destroy, instead of deploying and waiting out the database's whole budget.
out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$NOTRUN")"
check "replace on WSL 2.6 -> the step stops" 1 "$(rc_of "$out")"
lacks    "  nothing destroyed"             "LAUNCHER destroy" "$(calls)"
contains "  names the fix"                 "wsl --update" "$out"
contains "  says nothing was deleted"      "Nothing was deleted" "$out"
check    "  said once"                     1 "$(printf '%s\n' "$out" | grep -c 'Nothing was')"
lacks    "  never 'Nothing was changed'"   "Nothing was changed" "$out"
contains "  one next step: exakit start"   "then: exakit start" "$out"
lacks    "  not the installer re-run"      "bash install.sh" "$out"
out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.7" -- "$NOTRUN")"
contains "replace on WSL 2.7 -> destroyed and redeployed" "LAUNCHER destroy" "$(calls)"
# UNKNOWN REFUSES A DESTROY (WSLR-01). Interop off or a slow wsl.exe is not
# evidence of a new WSL, and the destroy cannot be undone.
for _case in "interop failure (exit 1)|STUB_WSL_RC=1" \
             "interop off (exec fails)|STUB_BIN=$TMP/bin-badexec" \
             "probe timed out|STUB_PROBE_TIMEOUT=1 STUB_WSL_OUT=$TMP/wsl-2.6"; do
    # shellcheck disable=SC2086
    out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 ${_case#*|} -- "$NOTRUN")"
    check    "replace, release unknown (${_case%%|*}) -> refused" 1 "$(rc_of "$out")"
    lacks    "  nothing destroyed"             "LAUNCHER destroy" "$(calls)"
    contains "  says the release was not read" "Could not read the WSL release" "$out"
    contains "  names wsl --version"           "wsl --version" "$out"
    contains "  and the 2.7 floor"             "2.7 or newer" "$out"
    check    "  one 'Nothing was' line"        1 "$(printf '%s\n' "$out" | grep -c 'Nothing was')"
done
contains "  noted for status"                "replacing the Podman deployment was refused" "$(calls)"
out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 EXAKIT_WSL_CHECKED=1 STUB_WSL_RC=1 -- "$NOTRUN")"
contains "replace, unknown, EXAKIT_WSL_CHECKED=1 -> destroyed" "LAUNCHER destroy" "$(calls)"
out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 EXAKIT_WSL_CHECKED=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$NOTRUN")"
lacks "  but never over a release read as 2.6" "LAUNCHER destroy" "$(calls)"
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=cni STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_RC=1 -- "$NOTRUN")"
contains "replace, unknown, Podman on CNI -> destroyed" "LAUNCHER destroy" "$(calls)"
# NO CONSENT POSSIBLE, NO REPLACE CHECK (WSL3-03): EXAKIT_REPLACE_DB unset and
# no terminal, so the question answers no by itself - a refusal for a replace
# nobody asked for hid the real advice.
out="$(probe STUB_EXISTS=1 EXAKIT_REUSE_DB=1 STUB_WSL_RC=1 -- "$NOTRUN")"
check    "failed reuse start, no replace consent, release unknown -> the step stops" 1 "$(rc_of "$out")"
lacks    "  no WSL refusal for a replace nobody asked for" "Could not read the WSL release" "$out"
contains "  the start advice instead"              "Start it yourself with 'exakit start'" "$out"
lacks    "  nothing destroyed"                     "LAUNCHER destroy" "$(calls)"
out="$(probe STUB_EXISTS=1 EXAKIT_REUSE_DB=1 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$NOTRUN")"
lacks    "  same on a release read as 2.6"         "Podman on WSL 2.6.1.0 cannot" "$out"
# THE START'S OWN EVIDENCE (WSL3-04): this run's start failed on netavark's
# nftables error, so a rebuild meets the same kernel whatever the release
# reads - refused before the question, nothing deleted.
NETSTART="EXAKIT_LOG_FILE='$TMP/start.log'; : > \"\$EXAKIT_LOG_FILE\"; "'run_logged(){ case "$2" in start) printf "%s\n" "Error: netavark: nftables error: \"nft\" did not return successfully while applying ruleset" >> "$EXAKIT_LOG_FILE"; return 1 ;; esac; "$@"; }; personal_deployment_running(){ return 1; }; personal_launcher_state(){ echo stopped; }; personal_launcher_supports(){ return 0; }; personal_reap_orphan_daemon(){ return 1; }; personal_note_guest_rebuild(){ :; }; port_in_use(){ return 0; }; personal_deploy_local'
SEED_MANIFEST='runtime.engine=podman\n'
out="$(probe STUB_EXISTS=1 EXAKIT_REUSE_DB=1 EXAKIT_REPLACE_DB=1 STUB_WSL_OUT="$TMP/wsl-2.7" -- "$NETSTART")"
check    "start failed on the nft error, replace on WSL 2.7 -> refused" 1 "$(rc_of "$out")"
lacks    "  nothing destroyed"                     "LAUNCHER destroy" "$(calls)"
contains "  names the kernel"                      "cannot create the deployment network" "$out"
contains "  offers the iptables driver too"        'firewall_driver = "iptables"' "$out"
contains "  says nothing was deleted"              "Nothing was deleted" "$out"
contains "  noted for status"                      "NOTE This WSL kernel cannot create the deployment network" "$(calls)"
SEED_MANIFEST=""
# The install path keeps "unknown -> warn and let through".
out="$(probe STUB_WSL_RC=1 -- "$GATE")"
check "install path, unknown -> still let through" 0 "$(rc_of "$out")"
SEED_MANIFEST='runtime.engine=docker\n'
out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "personal_engine_running(){ return 0; }; $NOTRUN")"
contains "replace a Docker deployment on WSL 2.6 -> never asks" "LAUNCHER destroy" "$(calls)"
SEED_MANIFEST=""
# NO GUESSED DOCKER SKIPS THE CHECK (WIN3-02, LNX3-01). An unrecorded
# deployment with Docker stopped and Podman listing nothing used to read as
# Docker, so the replace skipped this check and destroyed it.
mkdir -p "$TMP/dep23" "$TMP/dep24"
printf '{"deploymentId":"exa-7f3a","dbPort":8563}\n' > "$TMP/dep23/deployment.json"
printf '2.3.1' > "$TMP/dep23/.exasolLauncher.version"
cp "$TMP/dep23/deployment.json" "$TMP/dep24/"
printf '2.4.0' > "$TMP/dep24/.exasolLauncher.version"
out="$(probe STUB_EXISTS=1 STUB_DOCKER_FAIL=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "EXAKIT_PERSONAL_DEPLOY_DIR=$TMP/dep23; $NOTRUN")"
check    "2.3 deployment, Docker down, replace on WSL 2.6 -> refused" 1 "$(rc_of "$out")"
contains "  by the WSL check"              "wsl --update" "$out"
lacks    "  nothing destroyed"             "LAUNCHER destroy" "$(calls)"
out="$(probe STUB_EXISTS=1 STUB_DOCKER_FAIL=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "EXAKIT_PERSONAL_DEPLOY_DIR=$TMP/dep24; $NOTRUN")"
check    "2.4 deployment, engine unknown, replace -> the step stops" 1 "$(rc_of "$out")"
contains "  says the engine cannot be read" "engine cannot be read" "$out"
lacks    "  nothing destroyed"             "LAUNCHER destroy" "$(calls)"
lacks    "  nor started"                   "LAUNCHER start" "$(calls)"
contains "the replace check runs unless the engine is docker" '[ "${EXAKIT_PERSONAL_ENGINE:-}" != "docker" ] && \' "$(sed -n '/^personal_deploy_local()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"

echo
echo "the iptables-driver exemption reads containers.conf as Podman does (WSL4-04)"
# The exemption lets a REPLACE through on WSL 2.6, so a misread setting costs
# the database. Only firewall_driver inside [network] counts, the last file in
# Podman's order wins (vendor, admin, admin drop-ins, user, user drop-ins),
# both TOML quote styles are read, and iptables must be installed.
UCONF="$TMP/home/.config/containers/containers.conf"
UDROP="$TMP/home/.config/containers/containers.conf.d"
SCONF="$TMP/sys/etc/containers/containers.conf"
SDROP="$TMP/sys/etc/containers/containers.conf.d"
conf_reset() { rm -rf "$TMP/home/.config/containers" "$TMP/sys/etc" "$TMP/sys/usr"; mkdir -p "$UDROP" "$SDROP"; }
IPT="$TMP/bin-ipt:$TMP/bin"
conf_reset
printf '[engine]\nfirewall_driver = "iptables"\n' > "$UCONF"
check "[engine] firewall_driver = iptables -> refused"        1 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
conf_reset
printf '[network]\n# firewall_driver = "iptables"\n' > "$UCONF"
check "a commented-out line -> refused"                       1 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
conf_reset
printf '[network]\nfirewall_driver = "iptables"\n' > "$SCONF"
printf '[network]\nfirewall_driver = "nftables"\n' > "$UCONF"
check "admin file iptables, user file nftables -> refused"    1 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
check "  Podman's answer is the user's"                       nftables "$(probe -- 'detect_podman_firewall_driver' | sed '$d')"
conf_reset
printf '[network]\nfirewall_driver = "nftables"\n' > "$UCONF"
printf '[network]\nfirewall_driver = "iptables"\n' > "$UDROP/50-firewall.conf"
check "user drop-in iptables over a user nftables -> ok"      0 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
conf_reset
printf '[network]\nfirewall_driver = "iptables"\n' > "$SDROP/50-firewall.conf"
check "admin drop-in iptables, no user file -> ok"            0 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
printf '[network]\nfirewall_driver = "nftables"\n' > "$SDROP/90-later.conf"
check "  a later admin drop-in on nftables wins -> refused"  1 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
conf_reset
printf "[network]\nfirewall_driver = 'iptables'  # literal string\n" > "$UCONF"
check "single quotes -> ok"                                   0 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
conf_reset
printf '[network]\nfirewall_driver = "iptables"\n' > "$UCONF"
out="$(probe STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")"
check "the setting without iptables installed -> refused"     1 "$(rc_of "$out")"
contains "  says iptables is the missing half"                "iptables is not installed in this distro" "$out"
check "the setting with iptables installed -> ok"             0 "$(rc_of "$(probe STUB_BIN="$IPT" STUB_WSL_OUT="$TMP/wsl-2.6" -- "$GATE")")"
# THE DESTRUCTIVE PATH. A misread setting is refused BEFORE the replace
# question, so no consent is even asked and nothing is destroyed.
ASKLOG='confirm_env(){ printf "ASKED %s\n" "$1" >> "$STUB_CALLS"; eval "[ \"\${$1:-0}\" = 1 ]"; }; '
conf_reset
printf '[engine]\nfirewall_driver = "iptables"\n' > "$UCONF"
out="$(probe STUB_BIN="$IPT" STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$ASKLOG$NOTRUN")"
check    "replace on WSL 2.6, setting under [engine] -> refused" 1 "$(rc_of "$out")"
lacks    "  before the consent question"                     "ASKED EXAKIT_REPLACE_DB" "$(calls)"
lacks    "  nothing destroyed"                               "LAUNCHER destroy" "$(calls)"
contains "  names wsl --update"                              "wsl --update" "$out"
conf_reset
printf '[network]\nfirewall_driver = "iptables"\n' > "$UCONF"
out="$(probe STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$ASKLOG$NOTRUN")"
lacks    "replace on WSL 2.6, setting but no iptables -> no consent asked" "ASKED EXAKIT_REPLACE_DB" "$(calls)"
lacks    "  nothing destroyed"                               "LAUNCHER destroy" "$(calls)"
contains "  says iptables is not installed"                  "iptables is not installed in this distro" "$out"
out="$(probe STUB_BIN="$IPT" STUB_EXISTS=1 EXAKIT_REPLACE_DB=1 EXAKIT_REUSE_DB=0 STUB_WSL_OUT="$TMP/wsl-2.6" -- "$ASKLOG$NOTRUN")"
contains "replace on WSL 2.6, a real iptables setup -> asked"  "ASKED EXAKIT_REPLACE_DB" "$(calls)"
contains "  and replaced"                                    "LAUNCHER destroy" "$(calls)"
conf_reset

echo
echo "detect_docker: Engine 29+ on Linux containers, else none"
DD='source "$ROOT/setup/lib/detect.sh"; detect_docker'
dd_probe() { env PATH="$TMP/bin:$TMP/sysbin-nodocker" "$@" bash -c "ROOT='$ROOT'; $DD" 2>&1; }
check "29.1.0 linux"        docker "$(dd_probe STUB_DOCKER_INFO='linux 29.1.0')"
check "28.3.1 linux"        none   "$(dd_probe STUB_DOCKER_INFO='linux 28.3.1')"
check "29 windows"          none   "$(dd_probe STUB_DOCKER_INFO='windows 29.0.0')"
check "daemon down"         none   "$(dd_probe STUB_DOCKER_FAIL=1)"
check "no docker"           none   "$(env PATH="$TMP/bin-nowsl:$TMP/sysbin-nodocker" bash -c "ROOT='$ROOT'; $DD" 2>&1)"
echo
echo "preflight_report: the WSL line applies the deploy gate's exemptions (WSLR-03)"
# EXAKIT_CONTAINER_ENGINE=podman: the stub docker in $TMP/bin answers 29 and
# would otherwise be the engine, which skips the WSL line altogether.
# curl is stubbed: the reachability lines would otherwise go to the network.
PFW='EXAKIT_CONTAINER_ENGINE=podman; curl(){ return 0; }; preflight_report 2>&1 | grep -i "wsl\|Podman:" || true'
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=cni STUB_WSL_OUT="$TMP/wsl-2.6" -- "$PFW")"
lacks    "Podman on CNI, WSL 2.6 -> no failure line" "Podman on this WSL kernel cannot" "$out"
contains "  while Podman is the engine checked"    "Podman" "$out"
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark STUB_WSL_OUT="$TMP/wsl-2.6" -- "$PFW")"
contains "Podman on netavark, WSL 2.6 -> failure line" "WSL 2.6.1.0: Podman on this WSL kernel cannot" "$out"
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark STUB_WSL_RC=1 -- "$PFW")"
contains "release unknown -> a note"                 "The WSL release could not be read" "$out"
lacks    "  not a failure"                           "Podman on this WSL kernel cannot" "$out"
mkdir -p "$TMP/home/.config/containers"
printf '[network]\nfirewall_driver = "iptables"\n' > "$TMP/home/.config/containers/containers.conf"
out="$(probe STUB_BIN="$TMP/bin-ipt:$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark STUB_WSL_OUT="$TMP/wsl-2.6" -- "$PFW")"
lacks    "iptables driver, WSL 2.6 -> no failure line" "Podman on this WSL kernel cannot" "$out"
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark STUB_WSL_OUT="$TMP/wsl-2.6" -- "$PFW")"
contains "  but without iptables installed -> the failure line" "Podman on this WSL kernel cannot" "$out"
rm -f "$TMP/home/.config/containers/containers.conf"
# AN EXISTING DEPLOYMENT IS NOT REFUSED (DOC4): the deploy step gates only a
# fresh Podman deployment and the launcher update is not gated, so the preview
# notes the coming start instead of failing a re-run the deploy accepts.
out="$(probe STUB_BIN="$TMP/bin-podman:$TMP/bin" STUB_PODMAN_BACKEND=netavark STUB_WSL_OUT="$TMP/wsl-2.6" -- "EXAKIT_PERSONAL_DEPLOY_DIR=$TMP/dep23; $PFW")"
lacks    "existing Podman deployment, WSL 2.6 -> no failure line" "Podman on this WSL kernel cannot" "$out"
contains "  a note about its next start instead" "WSL 2.6.1.0: the existing Podman deployment is kept" "$out"

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
contains "  and reads only a dotted release"         '(\d+\.\d+\.\d+(?:\.\d+)*)' "$REL"
contains "  passing --version unquoted"              '-ArgumentString "--version"' "$REL"
lacks    "  never through -Arguments"                '-Arguments' "$REL"
REQ="$(printf '%s\n' "$RTP" | sed -n '/^function Test-PersonalRequirements {/,/^}$/p')"
_wsl=$(printf '%s\n' "$REQ" | grep -n 'Test-PersonalWslPodmanNetworkOk' | cut -d: -f1 | head -1)
check "the compatibility gate still asks WSL" yes "$([ -n "$_wsl" ] && echo yes || echo no)"
lacks    "  and makes no Podman-machine offer"       'Repair-PersonalRootfulPodmanMachine' "$REQ"
lacks    "  nor reads the machine's Rootful"         '{{.Rootful}}' "$REQ"
_wsl=$(printf '%s\n' "$DEP" | grep -n 'Test-PersonalWslPodmanNetworkOk' | cut -d: -f1 | tail -1)
_run=$(printf '%s\n' "$DEP" | grep -n '(Test-PersonalPodmanRunning)' | cut -d: -f1 | head -1)
check "the deploy asks WSL before starting the machine" yes "$([ -n "$_wsl" ] && [ -n "$_run" ] && [ "$_wsl" -lt "$_run" ] && echo yes || echo no)"
_wsl=$(printf '%s\n' "$DEP" | grep -n 'Test-PersonalWslPodmanNetworkOk' | cut -d: -f1 | head -1)
_destroy=$(printf '%s\n' "$DEP" | grep -n 'destroy --remove' | cut -d: -f1 | head -1)
check "a replaced deployment is checked before its destroy" yes "$([ -n "$_wsl" ] && [ -n "$_destroy" ] && [ "$_wsl" -lt "$_destroy" ] && echo yes || echo no)"
lacks    "update runs no WSL check before the swap"  'Test-PersonalWslPodmanNetworkOk' "$UPD"
lacks    "  and never refuses for WSL"               'was not updated: update WSL first' "$UPD"
START="$(printf '%s\n' "$RTP" | sed -n '/^function Start-Personal {/,/^}$/p')"
contains "a failed start names wsl --update from the nft error" 'Test-PersonalStartNetworkBlocked -LogOffset $logOffset) { Stop-PersonalStartNetworkBlocked }' "$START"
contains "  and says what stays the same"            "keeps its engine" "$UPD"
contains "the deploy gates a fresh Podman deployment" '$wslOk = Test-PersonalWslPodmanNetworkOk' "$DEP"
contains "  but not a Docker one"                    '} elseif ($script:PersonalEngine -ne "docker") {' "$DEP"

# The Windows twin's behaviour, wherever a PowerShell is at hand to run it.
if command -v pwsh >/dev/null 2>&1; then
    echo
    if pwsh -NoProfile -NonInteractive -File "$ROOT/tests/personal-wsl-gate-ps.ps1"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL personal-wsl-gate-ps.ps1"
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
