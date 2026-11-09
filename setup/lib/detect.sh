#!/usr/bin/env bash
# detect.sh — environment detection for the Exasol Personal Local Starter Kit.
#
# Sourced by install.sh and setup-*.sh. Pure read-only checks, no side effects.
# Compatible with bash 3.2 and POSIX sh — every function here must also run
# under dash/ash. The one bash-only feature this file uses, the /dev/tcp probe
# in port_in_use, is now guarded by $BASH_VERSION and has a POSIX fallback, so
# the claim on this line is true rather than aspirational: read it before
# reaching for a bashism.

# detect_os — prints: macos | linux | wsl | unsupported
detect_os() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            # A UNION OF SIGNALS, not one grep. /proc/version is built from
            # the KERNEL's own strings, so a WSL2 distro booting a
            # user-supplied kernel (`kernel=` in .wslconfig - the normal route
            # for anyone needing a module the stock kernel lacks) has no
            # "microsoft" in it and was classified plain linux. Everything
            # WSL-specific then silently reverted to Linux advice that cannot
            # be followed there: a GRUB remedy for a distro with no GRUB, a
            # boot-flag remedy for a kernel it does not boot, and the loss of
            # "inside this distro; Docker Desktop on the Windows side does not
            # count" - the one sentence that matters most on this platform.
            # The reverse misfires too: an Azure-built Linux whose version
            # string carries "microsoft" was handed .wslconfig instructions for
            # a file it does not have.
            #
            # The other three signals come from WSL's init rather than the
            # kernel, so they survive a custom kernel: WSL_DISTRO_NAME is
            # exported into every login shell, and /run/WSL and the WSLInterop
            # binfmt handler are created by wsl-init regardless.
            if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -e /run/WSL ] ||
               [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] ||
               grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

# detect_wsl_version — 1 or 2 for a WSL distro; empty (and non-zero) elsewhere.
#
# /proc/version says "Microsoft" on BOTH WSL versions, so detect_os classifies
# them both as `wsl`, and the two need telling apart wherever a message depends
# on whether a Linux kernel is present at all. The kernel
# RELEASE is what tells them apart: WSL 2 ships a Microsoft kernel whose release
# carries "microsoft-standard" / "WSL2", while WSL 1's emulated release is the
# 4.4.x "-Microsoft" string. Anything unrecognised answers 2: this gates a hard
# refusal, and a guess must never be the thing that blocks a working install.
detect_wsl_version() {
    [ "$(detect_os)" = "wsl" ] || return 1
    _dwv="$(cat /proc/sys/kernel/osrelease 2>/dev/null)"
    case "$_dwv" in
        *WSL2*|*wsl2*|*microsoft-standard*) echo 2 ;;
        4.4.*Microsoft*|4.4.*microsoft*)    echo 1 ;;
        *)                                  echo 2 ;;
    esac
}

# detect_wsl_drvfs_path <path> — true when the path lives on a Windows drive
# mounted into the distro (DrvFs), rather than on the Linux filesystem.
#
# This matters for SECRETS. DrvFs is mounted without the `metadata` option by
# default, so `chmod 600` on it returns success and stores nothing: every file
# keeps mode 0777. The kit's database passwords are plaintext files protected by
# exactly that chmod, so a kit home under /mnt/c leaves them readable by every
# Windows user on the machine — and uploaded, when the profile is OneDrive-backed.
detect_wsl_drvfs_path() {
    [ "$(detect_os)" = "wsl" ] || return 1
    _ddp="${1:-$HOME}"
    case "$_ddp" in
        /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/*) return 0 ;;
    esac
    # A drive mounted somewhere else (or a bind): ask the mount table. DrvFs
    # reports the Windows device itself ("C:\") as its source.
    _ddp_src="$(df -P "$_ddp" 2>/dev/null | awk 'NR == 2 { print $1 }')"
    case "$_ddp_src" in
        [A-Za-z]:*|*drvfs*|*DrvFs*) return 0 ;;
    esac
    return 1
}

# detect_arch — prints: arm64 | x86_64 | unsupported
detect_arch() {
    _da_m="$(uname -m)"
    # UNDER ROSETTA 2, `uname -m` SAYS x86_64 - by design. A translated process
    # is told it is Intel because that is what it is pretending to be, and
    # nothing else in the kit asked a second question. So a kit installed from
    # a Rosetta shell - an iTerm window duplicated with "Open using Rosetta", a
    # terminal inside a translated IDE, anything launched from an Intel-only
    # tool - fetched the INTEL build of Exasol Personal onto Apple Silicon and
    # ran the whole database under emulation, with nothing on screen saying so.
    #
    # sysctl.proc_translated is the signal that separates the two. It is absent
    # on a native arm64 process and absent on real Intel hardware, so "1" is
    # the only answer that changes anything here, and the x86_64 guard keeps
    # the probe off every other platform's path.
    if [ "$_da_m" = "x86_64" ] && [ "$(uname -s)" = "Darwin" ] &&
       [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        _da_m="arm64"
    fi
    case "$_da_m" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        *)             echo "unsupported" ;;
    esac
}

# detect_macos_translated — true when this very process is running under
# Rosetta 2. Kept separate from detect_arch so that function stays a pure
# answer to "what should we download"; this one is for telling the user.
detect_macos_translated() {
    [ "$(uname -s)" = "Darwin" ] || return 1
    [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]
}

# detect_cpu_advertises_sve — true when a Linux aarch64 kernel advertises any
# SVE capability. Some hypervisors (seen: VirtualBox on Apple Silicon) expose
# SVE feature bits the host CPU cannot actually execute, so OpenSSL's runtime
# CPU detection picks an SVE code path and dies with SIGILL. Used by the
# pyexasol and MCP validation steps to recognize that crash and self-repair
# (pin OPENSSL_armcap=0 for the affected component).
detect_cpu_advertises_sve() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ "$(uname -m)" = "aarch64" ] || return 1
    grep -m1 '^Features' /proc/cpuinfo 2>/dev/null | grep -qE '(^| )sve'
}

# detect_sve_remedy_hint — the permanent, system-wide fix for the faked-SVE
# crash, printed wherever the per-component workaround is applied. Kernels
# before ~5.16 ignore arm64.nosve, hence the newer-kernel step.
#
# BRANCHED, because this used to print three Debian/Ubuntu commands to every
# aarch64 Linux: `apt-get`, `linux-generic-hwe-*`, `lsb_release` and
# `update-grub` do not exist on Fedora/RHEL, and NONE of them applies inside
# WSL, where the kernel comes from Windows and there is no GRUB at all. Three
# impossible instructions labelled "permanent fix" is worse than no hint.
detect_sve_remedy_hint() {
    info "This guest advertises SVE support its host CPU cannot execute (common with VirtualBox on Apple Silicon)."
    if [ "$(detect_os)" = "wsl" ]; then
        # WSL boots a kernel Windows supplies; the equivalent of a GRUB edit is
        # .wslconfig on the Windows side, and the equivalent of a reboot is
        # `wsl --shutdown`.
        info "Permanent fix (WSL): add the boot flags on the WINDOWS side, in %USERPROFILE%\\.wslconfig:"
        info "  [wsl2]"
        info "  kernelCommandLine = arm64.nosve arm64.nosme"
        info "Then apply it from PowerShell: wsl --shutdown  (reopen this distro afterwards)"
        return 0
    fi
    info "Permanent fix: run a kernel that honors arm64.nosve and disable SVE at boot:"
    if command -v apt-get >/dev/null 2>&1; then
        info "  sudo apt-get install -y linux-generic-hwe-\$(lsb_release -rs 2>/dev/null || echo 22.04)"
        info "  add 'arm64.nosve arm64.nosme' to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
        info "  sudo update-grub && sudo reboot"
    elif command -v grubby >/dev/null 2>&1; then
        info "  sudo grubby --update-kernel=ALL --args='arm64.nosve arm64.nosme'"
        info "  sudo reboot"
    else
        info "  add 'arm64.nosve arm64.nosme' to this machine's kernel command line, then reboot"
        info "  (Debian/Ubuntu: /etc/default/grub then 'sudo update-grub'; Fedora/RHEL: 'sudo grubby --update-kernel=ALL --args=...')"
    fi
    info "A kernel newer than 5.16 is required for the flag to be honored."
}

# detect_ram_gb — total physical memory in whole GB. ALWAYS prints a
# non-negative integer, and 0 when it cannot be determined. This matters:
# callers compare it with `-lt`/`-ge`, and an empty value there makes the test
# error out ("integer expression expected") AND evaluate false — silently
# skipping the requirement guard. Returning 0 instead fails closed.
detect_ram_gb() {
    if [ "$(uname -s)" = "Darwin" ]; then
        _dr_bytes="$(sysctl -n hw.memsize 2>/dev/null)"
        case "$_dr_bytes" in
            ''|*[!0-9]*) _dr_ram=0 ;;
            *)           _dr_ram=$(( _dr_bytes / 1073741824 )) ;;
        esac
    else
        # Rounded to the nearest GB, not truncated: MemTotal is always a little
        # under the installed RAM (the kernel keeps some), so truncating read
        # every 8 GB machine - and WSL's default VM on a 16 GB laptop - as 7 GB
        # and refused it. Same rule as the Windows twin (runtime-personal.ps1).
        _dr_ram="$(awk '/MemTotal/ { printf "%d", ($2 / 1048576) + 0.5 }' /proc/meminfo 2>/dev/null)"
    fi
    case "$_dr_ram" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dr_ram" ;;
    esac
}

# detect_free_disk_gb <path> — free space in whole GB. Same fail-closed
# contract as detect_ram_gb: always a non-negative integer, 0 if unknown.
_detect_free_disk_gb_raw() {
    _dd="$(df -Pk "${1:-$HOME}" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"
    case "$_dd" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dd" ;;
    esac
}

# detect_wsl_backing_drive - the Windows drive whose free space actually binds
# a path inside a WSL2 distro, or nothing when it cannot be determined.
#
# A WSL2 distro's root filesystem is a SPARSE ext4 VHDX sitting on a Windows
# drive, formatted to the maximum size WSL permits (1 TB on current builds).
# `df` inside the distro reports free space against that formatted size, not
# against the physical space left on C:. So on a Windows machine with 6 GB free,
# a check on $HOME answered something like 900 GB, the 20 GB gate passed, and
# the database failed partway through writing its data with an ENOSPC naming a
# filesystem that appears to have hundreds of gigabytes free. The gate exists
# precisely to prevent that failure, and it was inert on the one platform where
# free space is indirect.
detect_wsl_backing_drive() {
    [ "$(detect_os 2>/dev/null)" = "wsl" ] || return 1
    for _dwb in /mnt/c /mnt/d; do
        [ -d "$_dwb" ] || continue
        # DrvFs only: a directory of that name on the ext4 side is not a
        # Windows drive and would answer the same wrong number again.
        case "$(df -PT "$_dwb" 2>/dev/null | awk 'NR == 2 { print $2 }')" in
            drvfs|9p|virtiofs) printf '%s\n' "$_dwb"; return 0 ;;
        esac
    done
    return 1
}

# detect_free_disk_gb <path> - free GB that actually constrain <path>.
#
# On WSL that is the SMALLER of the distro's own figure and the Windows drive
# behind it; anywhere else it is just the path's filesystem. Reporting the
# smaller is the whole point: it is the one that will stop the install.
detect_free_disk_gb() {
    _dfg_here="$(_detect_free_disk_gb_raw "${1:-$HOME}")"
    _dfg_drive="$(detect_wsl_backing_drive 2>/dev/null || true)"
    [ -n "$_dfg_drive" ] || { echo "$_dfg_here"; return 0; }
    # A path already ON the Windows drive is measured correctly by df; only the
    # distro's own virtual disk needs the cross-check.
    case "${1:-$HOME}" in
        /mnt/*) echo "$_dfg_here"; return 0 ;;
    esac
    _dfg_backing="$(_detect_free_disk_gb_raw "$_dfg_drive")"
    [ "$_dfg_backing" -gt 0 ] 2>/dev/null || { echo "$_dfg_here"; return 0; }
    if [ "$_dfg_backing" -lt "$_dfg_here" ]; then
        echo "$_dfg_backing"
    else
        echo "$_dfg_here"
    fi
}

# detect_free_disk_note <path> - one sentence when the number above did NOT
# come from the path's own filesystem, or nothing when it did.
#
# A separate function rather than a variable the caller reads: every caller
# invokes detect_free_disk_gb in a command substitution, so anything it
# exported would die with that subshell. Without this the reader sees a refusal
# quoting a figure that `df` inside their distro flatly contradicts.
detect_free_disk_note() {
    _dfn_drive="$(detect_wsl_backing_drive 2>/dev/null || true)"
    [ -n "$_dfn_drive" ] || return 1
    case "${1:-$HOME}" in
        /mnt/*) return 1 ;;
    esac
    _dfn_here="$(_detect_free_disk_gb_raw "${1:-$HOME}")"
    _dfn_backing="$(_detect_free_disk_gb_raw "$_dfn_drive")"
    [ "$_dfn_backing" -gt 0 ] 2>/dev/null || return 1
    [ "$_dfn_backing" -lt "$_dfn_here" ] || return 1
    printf "this distro's virtual disk reports %s GB free, but it is a sparse file on %s, which has %s GB - that is the real limit\n" \
        "$_dfn_here" "$_dfn_drive" "$_dfn_backing"
}



# _detect_engine_probe — run an engine command under the kit's bounded runner
# when it exists. `podman info` can block while a machine is still coming up, so
# a version lookup must not sit there in silence. detect.sh is also sourced on
# its own by the installer's preflight, before common.sh and the bounded runner
# exist; there the plain call is correct, since preflight is allowed to wait for
# the engine it is specifically reporting on.
_detect_engine_probe() {
    if command -v exakit_run_bounded >/dev/null 2>&1; then
        exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-8}" "$@"
    else
        "$@"
    fi
}

# detect_podman — "podman" when a usable Podman is here, "none" otherwise.
#
# Since Exasol Personal 2.4 the launcher deploys on Docker (Engine 29+) or
# Podman, and exapump's glibc shim borrows whichever is there; this answers
# for Podman only (detect_docker for Docker). Bounded, because `podman info` can
# block while a machine is still coming up, and a probe that hangs turns a
# status command into a stall.
detect_podman() {
    if command -v podman >/dev/null 2>&1 && _detect_engine_probe podman info >/dev/null 2>&1; then
        echo "podman"
        return 0
    fi
    echo "none"
}

# detect_docker — "docker" when a Docker the Exasol launcher can deploy on is
# here: the daemon answers, runs Linux containers, and is Docker Engine 29 or
# newer (the launcher's floor, from Exasol Personal 2.4). "none" otherwise - a
# Docker that is installed and stopped is "none" too, since nothing can deploy
# on it as it stands. One bounded probe answers all three questions. The
# runtime module asks the same questions in personal_docker_usable, where it
# also needs the reason; this one exists for preflight, which runs before that
# module is sourced.
detect_docker() {
    if detect_docker_reason; then echo "docker"; return 0; fi
    echo "none"
}

# detect_docker_is_podman [probe output] - 0 when the `docker` on PATH is
# Podman's Docker emulation (Fedora/RHEL's podman-docker), so there is no
# Docker here at all. NOT BY ITS BANNER ALONE: /etc/containers/nodocker, which
# the banner itself tells people to create, silences it, and the box then read
# as "Docker is installed but not running" - a prompt to start a Docker that
# does not exist, and about 30 s of re-probes. Podman answering `docker info`'s
# template (no OSType field), a docker that resolves to podman, and a
# `docker --version` naming podman all say the same thing. Only asked once
# `docker info` has failed, so a working Docker costs nothing extra. Twin of
# _personal_docker_is_podman in runtime-personal.sh.
detect_docker_is_podman() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        *"emulate docker cli using podman"*|*"can't evaluate field ostype"*) return 0 ;;
    esac
    _ddp_path="$(command -v docker 2>/dev/null || true)"
    [ -n "$_ddp_path" ] || return 1
    _ddp_real="$(readlink -f "$_ddp_path" 2>/dev/null || true)"
    case "${_ddp_real##*/}" in podman|podman-remote*) return 0 ;; esac
    case "$(_detect_engine_probe docker --version 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
        *podman*) return 0 ;;
    esac
    return 1
}

# detect_launcher_takes_engine - 0 when the Exasol launcher that will deploy
# can be told the engine (`install local --help` names --container-engine).
# The installer's launcher step decides which launcher that is: an `exasol` on
# PATH whose `install` has the `local` preset is KEPT (and the kit's managed
# EXAKIT_BIN_DIR/exasol, when there, still wins, as in personal_cli); any
# other case ends with the kit's own download, which can be told. The bare
# `install --help` is still asked, but only for the `local` preset itself -
# a preset's variables, the engine among them, are listed only under
# `install local --help`, so that is the one bounded question asked of the
# launcher that will deploy. Twin of personal_launcher_takes_engine, for the
# preflight, which runs before the runtime module is sourced.
detect_launcher_takes_engine() {
    [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] || return 0
    command -v exasol >/dev/null 2>&1 || return 0
    _dlt_tok='([[:space:]]|,|$)'
    _dlt_lead='^[[:space:]]*(-[-a-zA-Z0-9]+,[[:space:]]*)?'
    _dlt_cli="$(command -v exasol)"
    _dlt_help="$(_detect_engine_probe "$_dlt_cli" install --help 2>&1 || true)"
    # No `local` preset: the installer downloads its own launcher, which can.
    printf '%s\n' "$_dlt_help" | grep -E "${_dlt_lead}local${_dlt_tok}" >/dev/null || return 0
    if [ -n "${EXAKIT_BIN_DIR:-}" ] && [ -x "$EXAKIT_BIN_DIR/exasol" ] && \
       [ "$EXAKIT_BIN_DIR/exasol" != "$_dlt_cli" ]; then
        _dlt_cli="$EXAKIT_BIN_DIR/exasol"
    fi
    # The engine is a variable of the `local` preset: only `install local
    # --help` lists it. Twin of personal_launcher_takes_engine.
    _dlt_help="$(_detect_engine_probe "$_dlt_cli" install local --help 2>&1 || true)"
    printf '%s\n' "$_dlt_help" | grep -E "${_dlt_lead}--container-engine${_dlt_tok}" >/dev/null
}

# detect_docker_reason - 0 when Docker is usable (as detect_docker). Otherwise
# 1 with the reason in _dd_said and its kind in _dd_kind: missing (no docker,
# or Podman's docker emulation), denied, down, type, version. The same reasons,
# in the same words, as personal_docker_usable - which the deploy step prints
# a minute later, so the preflight must not say something else.
detect_docker_reason() {
    _dd_said=""
    _dd_kind=""
    if ! command -v docker >/dev/null 2>&1; then
        _dd_said="Docker is not on PATH"; _dd_kind="missing"; return 1
    fi
    _dd_errf="$(mktemp "${TMPDIR:-/tmp}/exakit-docker.XXXXXX" 2>/dev/null || true)"
    [ -n "$_dd_errf" ] || _dd_errf=/dev/null
    _dd_info="$(_detect_engine_probe docker info --format '{{.OSType}} {{.ServerVersion}}' 2>"$_dd_errf" | tr -d '\r' | head -1)"
    _dd_err=""
    if [ "$_dd_errf" != /dev/null ]; then
        _dd_err="$(cat "$_dd_errf" 2>/dev/null || true)"
        rm -f "$_dd_errf"
    fi
    _dd_type="${_dd_info%% *}"
    _dd_ver="${_dd_info#* }"
    if [ -z "$_dd_type" ] || [ "$_dd_type" = "$_dd_info" ]; then
        if detect_docker_is_podman "$_dd_err $_dd_info"; then
            _dd_said="'docker' here is Podman's Docker emulation"; _dd_kind="missing"; return 1
        fi
        case "$(printf '%s %s' "$_dd_err" "$_dd_info" | tr '[:upper:]' '[:lower:]')" in
            *"permission denied"*)
                _dd_said="Docker is running but your user cannot use it (permission denied on its socket)"; _dd_kind="denied" ;;
            *"could not be found in this wsl"*)
                _dd_said="Docker Desktop is not running (its WSL integration answered, the daemon did not)"; _dd_kind="down" ;;
            *)
                _dd_said="Docker is installed but not running ('docker info' did not answer)"; _dd_kind="down" ;;
        esac
        return 1
    fi
    if [ "$_dd_type" != "linux" ]; then
        _dd_said="Docker runs $_dd_type containers here, and Exasol Personal needs Linux containers"; _dd_kind="type"; return 1
    fi
    _dd_major="${_dd_ver%%.*}"
    case "$_dd_major" in
        ''|*[!0-9]*) _dd_said="Docker Engine version '$_dd_ver' could not be read"; _dd_kind="version"; return 1 ;;
    esac
    if [ "$_dd_major" -lt 29 ]; then
        _dd_said="Docker Engine $_dd_ver is older than 29, the oldest Exasol Personal 2.4 runs on"; _dd_kind="version"; return 1
    fi
    return 0
}

# _detect_podman_conf_files — the containers.conf files Podman reads, one per
# line, in Podman's order (a later file's setting wins): the vendor file, the
# admin file, the admin drop-ins (sorted), the user's file, the user's
# drop-ins (sorted). Only files that exist and can be read are listed; a
# missing one is never an error. ⇄ twin: the file list
# Test-PersonalPodmanMachineIptables reads inside the Podman machine.
_detect_podman_conf_files() {
    _dpcf_user="${XDG_CONFIG_HOME:-$HOME/.config}/containers"
    for _dpcf_f in /usr/share/containers/containers.conf \
                   /etc/containers/containers.conf \
                   /etc/containers/containers.conf.d/*.conf \
                   "$_dpcf_user/containers.conf" \
                   "$_dpcf_user/containers.conf.d/"*.conf; do
        [ -f "$_dpcf_f" ] && [ -r "$_dpcf_f" ] && printf '%s\n' "$_dpcf_f"
    done
    return 0
}

# detect_podman_firewall_driver — the firewall_driver Podman will use, as its
# configuration sets it ("iptables", "nftables"), or nothing when no file sets
# it. THE SAME RULE AS PODMAN, not a grep: only the key inside the [network]
# table counts (a firewall_driver line under [engine] is not read by Podman),
# comments are ignored, a TOML basic ("...") or literal ('...') string is
# accepted, and the LAST setting across the files of _detect_podman_conf_files
# wins - a user file on nftables overrides an admin file on iptables. A value
# that is not a quoted string is not one Podman reads either, so it is
# answered as it stands and never matches "iptables". Each file starts with no
# table. ⇄ twin: the same rule in Test-PersonalPodmanMachineIptables.
detect_podman_firewall_driver() {
    _dpfd_files="$(_detect_podman_conf_files)"
    [ -n "$_dpfd_files" ] || return 0
    printf '%s\n' "$_dpfd_files" | {
        set --
        while IFS= read -r _dpfd_f; do
            [ -n "$_dpfd_f" ] && set -- "$@" "$_dpfd_f"
        done
        [ "$#" -gt 0 ] || exit 0
        awk -v q="'" '
            FNR == 1 { table = "" }
            {
                line = $0
                sub(/\r$/, "", line)
                sub(/#.*/, "", line)
                if (line ~ /^[ \t]*\[/) {
                    head = line
                    gsub(/[ \t]/, "", head)
                    table = (head == "[network]") ? "network" : "other"
                    next
                }
                if (table != "network") next
                if (line !~ /^[ \t]*firewall_driver[ \t]*=/) next
                sub(/^[ \t]*firewall_driver[ \t]*=[ \t]*/, "", line)
                sub(/[ \t]+$/, "", line)
                first = substr(line, 1, 1)
                if (length(line) >= 2 && (first == "\"" || first == q) && substr(line, length(line), 1) == first) {
                    value = substr(line, 2, length(line) - 2)
                } else {
                    value = "unquoted:" line
                }
            }
            END { if (value != "") print value }
        ' "$@" 2>/dev/null
    }
    return 0
}

# detect_podman_iptables_driver — true when Podman's own configuration routes
# its firewall through iptables rather than nftables, AND iptables is there to
# do it. That is the documented way to run Exasol Personal 2.4 on a WSL kernel
# without nftables (Podman's netavark fails applying its ruleset there), and a
# machine that has done it must not be told to update WSL.
#
# EVIDENCE THAT HOLDS, because this exemption also lets a REPLACE through -
# the path that destroys the deployment before its fresh deploy runs. A line
# in the wrong table, an admin setting the user's file overrides, or the
# setting without the iptables package all passed once, and on WSL 2.6 the
# rebuild then failed after the data was gone. So the setting is read as
# Podman reads it (detect_podman_firewall_driver) and the binary must be on
# PATH, as the kit's own hint says.
detect_podman_iptables_driver() {
    command -v iptables >/dev/null 2>&1 || return 1
    [ "$(detect_podman_firewall_driver)" = "iptables" ]
}

# _detect_personal_deployment_present — true when an Exasol Personal deployment
# already exists in the launcher's deployment directory (its deployment.json or
# state file is there). A file check, not personal_deployment_exists: the
# preflight runs before the runtime module is sourced and must not start the
# launcher. Same directory default as runtime-personal.sh.
_detect_personal_deployment_present() {
    _dpdp_dir="${EXAKIT_PERSONAL_DEPLOY_DIR:-$HOME/.exasol/personal/deployments/default}"
    [ -f "$_dpdp_dir/deployment.json" ] || [ -f "$_dpdp_dir/.exasolLauncherState.json" ]
}

# detect_podman_backend_not_netavark — true when Podman is on PATH and answers
# a network backend other than netavark (`cni`). The WSL nftables failure is
# netavark's own, so such a Podman cannot hit it. No Podman, a Podman that
# does not answer (a template error, a hang) or one that answers netavark is
# false: no answer is not an exemption. ONE PREDICATE for the deploy gate
# (personal_wsl_podman_network_ok) and the preflight line that previews it,
# so the two cannot disagree about the same machine.
detect_podman_backend_not_netavark() {
    command -v podman >/dev/null 2>&1 || return 1
    _dpbn_backend="$(_detect_engine_probe podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null | head -1 | tr -d '\r ')" || true
    [ -n "$_dpbn_backend" ] && [ "$_dpbn_backend" != "netavark" ]
}

# detect_wsl_release — the WSL release ("2.6.1.0") from `wsl.exe --version`,
# run through the distro's interop. Exit 1, printing nothing, whenever no
# release could be READ: not WSL, no wsl.exe, a wsl.exe that cannot run
# (interop off: "Exec format error"), one that exits non-zero or times out,
# and one that answers without a dotted release - the inbox WSL that predates
# the Store release has no --version and prints its usage text. The caller
# must read every one of those as "unknown", never as a version: a probe that
# failed is not evidence of an old WSL.
# wsl.exe writes UTF-16LE even through a pipe. It is decoded, not stripped:
# with only the NULs dropped, a localized label's high bytes survive as ASCII
# digits (Katakana is 0x30xx, Cyrillic а..й is 0x043x), so a Japanese label
# read as "WSL 0" and a Russian one as "5". The release is taken only as a
# number with at least two dots, which no stray byte can form either.
detect_wsl_release() {
    [ "$(detect_os)" = "wsl" ] || return 1
    _dwr_exe="$(command -v wsl.exe 2>/dev/null || true)"
    if [ -z "$_dwr_exe" ] && [ -x /mnt/c/Windows/System32/wsl.exe ]; then
        _dwr_exe=/mnt/c/Windows/System32/wsl.exe
    fi
    [ -n "$_dwr_exe" ] || return 1
    # A FILE, NOT A PIPE: the probe's own exit status is the first verdict
    # (bash 3.2 has no pipefail to keep it), and a command substitution would
    # drop the NUL bytes the decoder needs to recognise UTF-16.
    _dwr_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-wsl.XXXXXX" 2>/dev/null)" || return 1
    if ! _detect_engine_probe "$_dwr_exe" --version > "$_dwr_tmp" 2>/dev/null; then
        rm -f "$_dwr_tmp"
        return 1
    fi
    # UTF-16 only when NULs are there: WSL_UTF8=1 makes wsl.exe write UTF-8,
    # which a UTF-16 decode would garble. LC_ALL=C throughout: in a UTF-8
    # locale tr, sed and grep refuse a byte order mark as an illegal sequence.
    if [ "$(LC_ALL=C tr -d '\000' < "$_dwr_tmp" | wc -c)" -ne "$(wc -c < "$_dwr_tmp")" ] && \
       command -v iconv >/dev/null 2>&1; then
        _dwr_line="$(iconv -f UTF-16LE -t UTF-8 < "$_dwr_tmp" 2>/dev/null | \
            LC_ALL=C sed "1s/^$(printf '\357\273\277')//" | LC_ALL=C tr -d '\r' | head -1)"
    else
        _dwr_line="$(LC_ALL=C tr -d '\000\r' < "$_dwr_tmp" | head -1)"
    fi
    rm -f "$_dwr_tmp"
    _dwr_rel="$(printf '%s\n' "$_dwr_line" | \
        LC_ALL=C grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)*' | head -1)"
    [ -n "$_dwr_rel" ] || return 1
    printf '%s\n' "$_dwr_rel"
}


# port_listener_pids <port> — the pids of whatever is LISTENING on the port,
# newest tool first, empty when nothing can tell. The one place in the kit that
# answers "who has this port?", so a machine without lsof degrades the same way
# everywhere instead of once per caller.
#
# lsof is on every macOS and on no minimal Linux: a Fedora @core or Ubuntu
# Server image ships iproute2 (`ss`) and nothing else, so an lsof-only probe was
# silently unavailable on exactly the hosts most likely to be running something
# else on a port. ss first on Linux, then lsof, then net-tools' netstat, which is
# still what some older images carry.
port_listener_pids() {
    _plp_port="$1"
    _plp_out=""
    if command -v ss >/dev/null 2>&1; then
        # "LISTEN 0 4096 127.0.0.1:5100 0.0.0.0:* users:(("python3",pid=42,fd=6))"
        # -H is not in older iproute2, so match the address column instead of
        # trusting a header to be absent.
        _plp_out="$(ss -ltnp 2>/dev/null \
            | awk -v p=":$_plp_port" '$4 ~ p"$" { print }' \
            | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
    fi
    if [ -z "$_plp_out" ] && command -v lsof >/dev/null 2>&1; then
        _plp_out="$(lsof -nP -iTCP:"$_plp_port" -sTCP:LISTEN -t 2>/dev/null)"
    fi
    if [ -z "$_plp_out" ] && command -v netstat >/dev/null 2>&1; then
        # net-tools prints "pid/name" in the last column of a LISTEN row.
        _plp_out="$(netstat -ltnp 2>/dev/null \
            | awk -v p=":$_plp_port" '$4 ~ p"$" { print $NF }' \
            | sed -n 's|^\([0-9][0-9]*\)/.*|\1|p')"
    fi
    [ -n "$_plp_out" ] || return 1
    printf '%s\n' "$_plp_out" | sort -u
    return 0
}

# port_holder_desc <port> — "pid N (name)" for whatever is listening, or empty.
#
# "Stop it or set EXAKIT_DB_PORT" is unactionable when "it" is never named, and
# the holder is often not what the user expects: on a Windows machine with WSL,
# a failed WSL install leaves wslrelay holding the port after its container is
# long gone. dash-server has named its port's holder this way for a while
# (_dash_server_port_foreign_desc); the database port deserves the same.
#
# Inside a WSL distro this can still come back empty while the port really is
# taken: Windows and WSL share localhost, and no tool in the distro can see a
# Windows process. Callers say so rather than leaving an unexplained blank.
port_holder_desc() {
    _phd_port="$1"
    _phd_pid="$(port_listener_pids "$_phd_port" 2>/dev/null | head -1)"
    [ -n "$_phd_pid" ] || return 1
    _phd_name="$(ps -o comm= -p "$_phd_pid" 2>/dev/null | sed 's|.*/||' | tr -d ' ')"
    [ -n "$_phd_name" ] || _phd_name="unknown"
    printf 'pid %s (%s)' "$_phd_pid" "$_phd_name"
    return 0
}

# port_in_use <port> — succeeds when something already listens on the port.
#
# /dev/tcp is a bash/ksh feature, not POSIX: under dash or BusyBox ash the
# redirection simply fails and the function answered "the port is free" — a
# fail-OPEN answer in a file whose every other probe fails closed. Guard it on
# $BASH_VERSION and give the POSIX shells a real probe instead.
port_in_use() {
    _piu_port="$1"
    if [ -n "${BASH_VERSION:-}" ]; then
        (exec 3<>"/dev/tcp/127.0.0.1/$_piu_port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$_piu_port" '$4 ~ p"$" { found = 1 } END { exit !found }' && return 0
        return 1
    fi
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$_piu_port" >/dev/null 2>&1 && return 0
        return 1
    fi
    port_listener_pids "$_piu_port" >/dev/null 2>&1 && return 0
    return 1
}

# detect_rootless_podman_gap — one sentence naming a rootless-Podman
# precondition this machine does not meet, with its remedy; empty (and non-zero)
# when the machine looks fine. Cheap: two greps and a file test, no engine call.
#
# The docs ask for Podman and stop there, but rootless Podman needs two more
# things and says so only through an engine error the kit does not translate:
#   - subordinate id ranges for this user (/etc/subuid, /etc/subgid). Without
#     them `podman info` itself fails with "no subuid ranges found for user".
#   - cgroups v2. The container is started with --pids-limit and --shm-size,
#     and rootless Podman refuses resource limits on a cgroups-v1 host.
# Neither applies to root, or to macOS (where Podman runs in its own VM).
# detect_rootless_podman_gap_kind — the SAME finding as the sentence below, as
# one word a caller can branch on: subid | uidmap | cgroups | (empty).
#
# Two functions rather than one because the two callers want different things.
# The preflight wants a sentence to show a reader. The installer wants to know
# whether it can fix the thing itself, and only two of the three are fixable at
# all: a missing sub-id range and a missing uidmap package are both one command,
# while cgroups v2 needs a reboot or a boot flag and no process can grant it.
detect_rootless_podman_gap_kind() {
    [ "$(detect_os)" != "macos" ] || return 1
    [ "$(id -u 2>/dev/null || echo 0)" != "0" ] || return 1
    _drpk_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
    [ -n "$_drpk_user" ] || return 1
    for _drpk_file in /etc/subuid /etc/subgid; do
        [ -r "$_drpk_file" ] || continue
        if ! grep -q "^${_drpk_user}:" "$_drpk_file" 2>/dev/null; then
            printf 'subid\n'
            return 0
        fi
    done
    # newuidmap is the setuid helper that USES those ranges. Present ranges with
    # no helper fails just as hard, and later, inside a container start.
    if ! command -v newuidmap >/dev/null 2>&1; then
        printf 'uidmap\n'
        return 0
    fi
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        printf 'cgroups\n'
        return 0
    fi
    return 1
}

detect_rootless_podman_gap() {
    [ "$(detect_os)" != "macos" ] || return 1
    [ "$(id -u 2>/dev/null || echo 0)" != "0" ] || return 1
    _drp_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
    [ -n "$_drp_user" ] || return 1
    for _drp_file in /etc/subuid /etc/subgid; do
        # An unreadable or absent file is not evidence of a gap — some
        # distributions manage the ranges elsewhere. Only a readable file that
        # does not list this user is.
        [ -r "$_drp_file" ] || continue
        if ! grep -q "^${_drp_user}:" "$_drp_file" 2>/dev/null; then
            printf 'no user-namespace range for %s in %s — add one with: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 %s && podman system migrate' \
                "$_drp_user" "$_drp_file" "$_drp_user"
            return 0
        fi
    done
    # newuidmap is the setuid helper that USES the subuid ranges. Present ranges
    # with no helper is the shape `--no-install-recommends podman` leaves on
    # Debian and Ubuntu, and it was the one gap_kind could name and this could
    # not - so the caller got an empty reason and preflight said all-clear.
    if ! command -v newuidmap >/dev/null 2>&1; then
        printf 'the setuid helper newuidmap is missing, so rootless Podman cannot map your subuid range — install it with your package manager (Debian/Ubuntu: sudo apt-get install uidmap; Fedora/RHEL: sudo dnf install shadow-utils; Arch: sudo pacman -S shadow; Alpine: sudo apk add shadow-uidmap)'
        return 0
    fi
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        if [ "$(detect_os)" = "wsl" ]; then
            # There is no GRUB in WSL and the kernel comes from Windows, so the
            # boot-flag remedy below is an instruction nobody here can follow.
            # The equivalent knob is a Windows-side file.
            printf 'cgroups v2 is not active, so rootless Podman cannot apply the resource limits the kit sets — on the WINDOWS side add "[wsl2]" and "kernelCommandLine = cgroup_no_v1=all" to %%USERPROFILE%%\.wslconfig, then run: wsl --shutdown'
            return 0
        fi
        printf 'cgroups v2 is not active, so rootless Podman cannot apply the resource limits the kit sets — boot with systemd.unified_cgroup_hierarchy=1'
        return 0
    fi
    return 1
}


# preflight_report — check every requirement for this machine and print a
# pass/fail line for each, with the remedy inline. Returns non-zero when a
# hard requirement is missing. Installs nothing; safe to run any time.
preflight_report() {
    _failures=0
    _pf_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
    _pf_bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; _failures=$((_failures + 1)); }
    _pf_note() { printf '  \033[1;33m·\033[0m %s\n' "$*"; }

    _os="$(detect_os)"
    _arch="$(detect_arch)"

    printf 'Preflight check\n'

    # platform
    if [ "$_os" = "unsupported" ]; then
        _pf_bad "Operating system: $(uname -s) is not supported (macOS, Linux, WSL, or Windows via install.ps1)"
    else
        _pf_ok "Operating system: $_os"
    fi
    if detect_macos_translated; then
        _pf_note "This shell is running under Rosetta 2, so it reports itself as Intel. The kit has looked past that and will install the native arm64 build."
    fi
    if [ "$_arch" = "unsupported" ]; then
        _pf_bad "CPU architecture: $(uname -m) is not supported (arm64 or x86_64 required)"
    else
        _pf_ok "CPU architecture: $_arch"
    fi
    # A kit home on a Windows drive cannot hold a protected secret: DrvFs is
    # mounted without Linux permissions, so the chmod 600 on the database
    # passwords is accepted and discarded. Warned BEFORE the install writes one.
    _pf_home="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
    if detect_wsl_drvfs_path "$_pf_home" 2>/dev/null; then
        _pf_bad "Kit home $_pf_home is on a Windows drive: WSL mounts those without Linux file permissions, so the database passwords stored there cannot be protected (any Windows user can read them, and OneDrive syncs them) — set EXAKIT_HOME to a path on the Linux filesystem, e.g. EXAKIT_HOME=\$HOME/.exasol-starter-kit"
    fi

    # memory and disk, against the target runtime for this OS
    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "$_os" = "macos" ]; then
        if [ "$_ram" -ge 8 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Personal needs 8+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Personal needs at least 8 GB; this machine cannot run the kit's macOS path"; fi
        if [ "$_disk" -ge 20 ]; then _pf_ok "Free disk: ${_disk} GB (20+ recommended)"
        else _pf_bad "Free disk: ${_disk} GB — free up space (20 GB recommended for the local database)"; fi
    else
        if [ "$_ram" -ge 8 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Personal needs 8+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Personal needs at least 8 GB"; fi
        if [ "$_disk" -ge 20 ]; then _pf_ok "Free disk at $HOME: ${_disk} GB (20+ recommended)"
        else _pf_bad "Free disk at $HOME: ${_disk} GB — free up space (20 GB recommended for the local database)"; fi
        # Where that number came from, when it did NOT come from this
        # filesystem. Without it the reader is refused on a figure `df` inside
        # their own distro flatly contradicts.
        _pf_disk_note="$(detect_free_disk_note "$HOME" 2>/dev/null || true)"
        [ -n "$_pf_disk_note" ] && _pf_note "Free disk: $_pf_disk_note"
    fi

    # base tools. bash is one of them: install.sh is POSIX sh, but every setup
    # script and library it hands off to is bash, so a bash-less distro fails at
    # the handoff with a bare "exec: bash: not found".
    for _tool in curl tar bash; do
        if command -v "$_tool" >/dev/null 2>&1; then _pf_ok "$_tool available"
        else _pf_bad "$_tool missing — install it with your package manager"; fi
    done
    # The macOS Command Line Tools placeholder is ruled out WITHOUT running it:
    # running /usr/bin/python3 on a Mac without the tools pops the "install
    # developer tools" dialog, and it is not an interpreter - reporting it as
    # "older than 3.11" named a version problem that does not exist. Preflight
    # sources this file alone, so the check is spelled out here rather than
    # shared with common.sh (_exakit_python3_is_xcode_stub).
    _pf_py_stub=0
    if [ "$(command -v python3 2>/dev/null)" = /usr/bin/python3 ] && [ -x /usr/bin/xcode-select ] && \
       ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
        _pf_py_stub=1
    fi
    if [ "$_pf_py_stub" = 1 ]; then
        _pf_note "python3 is only the macOS placeholder (no Command Line Tools) — the installer will use its managed Python runtime automatically"
    elif command -v python3 >/dev/null 2>&1; then
        # The kit's tooling needs 3.11+ (tomllib); an older system python is
        # fine — the installer switches to its managed runtime automatically.
        if python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
            _pf_ok "python3 available"
        else
            _pf_note "python3 available but older than 3.11 — the installer will use its managed Python runtime automatically"
        fi
    elif _pf_uv="$(exakit_uv_report 2>/dev/null)" && [ "${_pf_uv%%|*}" = "ok" ]; then
        _pf_ok "uv available — it can provide Python automatically"
    elif [ "${_pf_uv%%|*}" = "below" ]; then
        # Present but below the floor the kit will run (its CA store trusts a
        # compromised root): the installer leaves it alone and installs its own.
        _pf_note "uv is installed but older than the kit's minimum — the installer will install its own pinned uv and use that"
    elif [ "$_os" = "macos" ]; then
        _pf_note "python3 missing — the installer can bootstrap a managed Python runtime automatically"
    else
        _pf_note "python3 missing — the installer can bootstrap a managed Python runtime automatically"
    fi

    # The database is an Exasol Personal deployment, and on Linux the launcher
    # deploys through Docker or Podman; nothing else substitutes. macOS needs
    # nothing installed first. WSL takes the Linux checks: the launcher has no
    # WSL concept on that path, only the Linux one, and a WSL2 distro
    # satisfies it with an engine of its own.
    # WSL 1 HAS NO LINUX KERNEL, so it has no cgroups, no user namespaces, and
    # no container runtime that can work. detect_wsl_version's own comment says
    # "this gates a hard refusal" - and nothing anywhere called it for that.
    # Its one caller discards the value and uses it as a boolean "am I in WSL".
    #
    # Unrefused, a WSL 1 distro is classified `wsl`, routed to setup-linux.sh,
    # and told to install Podman INSIDE the distro. On Debian/Ubuntu `apt-get
    # install podman` succeeds, so this report goes green, and because
    # EXAKIT_INSTALL_PODMAN defaults to on the installer then runs that install
    # with sudo, unprompted. The failure surfaces a layer down as a raw Podman
    # error about cgroups or newuidmap - after a several-minute download and a
    # package install the user never needed. The one thing that would have said
    # so in a sentence, at the front, was written and never wired up.
    if [ "$_os" = "wsl" ] && [ "$(detect_wsl_version 2>/dev/null)" = "1" ]; then
        _pf_bad "WSL 1: Exasol Personal needs a real Linux kernel to run containers, and WSL 1 does not have one (it translates syscalls to the NT kernel). Convert this distro from PowerShell: wsl --set-version $(cat /etc/hostname 2>/dev/null || echo '<distro>') 2   then re-run the installer."
    elif [ "$_os" = "linux" ] || [ "$_os" = "wsl" ]; then
        # From Exasol Personal 2.4 a NEW deployment runs on Docker when the kit
        # finds one it can use, else on Podman - the same order the deploy step
        # takes (personal_resolve_engine). EXAKIT_CONTAINER_ENGINE=podman is
        # honoured here too, so the report describes the install that will run.
        #
        # THE SAME ANSWER AS THE DEPLOY STEP, reasons included. A docker on
        # PATH that did not count used to vanish from the report ("none is on
        # PATH"), EXAKIT_CONTAINER_ENGINE=docker with a stopped Docker passed
        # here and stopped the database step a minute later, and a bogus value
        # passed here and ended the run there.
        _pf_named="${EXAKIT_CONTAINER_ENGINE:-}"
        _pf_engine=""
        _pf_docker_why=""
        case "$_pf_named" in
            ''|docker|podman) : ;;
            *) _pf_bad "EXAKIT_CONTAINER_ENGINE must be docker or podman, not '$_pf_named' - the database step stops on it" ;;
        esac
        _pf_docker_kind=""
        if [ "${EXAKIT_CONTAINER_ENGINE:-}" != "podman" ] && [ "$(detect_docker 2>/dev/null)" = "docker" ]; then
            # NOT GREEN FOR A LAUNCHER THAT CANNOT BE TOLD. A kept launcher
            # from before --container-engine deploys on Podman whatever the
            # kit decides, and the deploy step says so; the preflight used to
            # promise Docker on exactly that machine.
            if detect_launcher_takes_engine; then
                _pf_docker_v="$(_detect_engine_probe docker info --format '{{.ServerVersion}}' 2>/dev/null | tr -d '\r' | head -1)"
                _pf_ok "Docker: available (Engine ${_pf_docker_v:-29+}) - a new Exasol Personal deployment runs on it"
                _pf_engine="docker"
            elif [ "$_pf_named" = "docker" ]; then
                _pf_bad "EXAKIT_CONTAINER_ENGINE=docker, but this Exasol launcher cannot be told which engine to use, so the database runs on Podman - the database step stops on it: update the launcher ('exakit update personal'), or drop the variable"
                _pf_engine="refused"
            else
                _pf_docker_why="Docker is usable, but this Exasol launcher cannot be told which engine to use"
            fi
        elif [ "$_pf_named" != "podman" ] && command -v docker >/dev/null 2>&1 && \
             ! detect_docker_reason && [ "$_dd_kind" != "missing" ]; then
            _pf_docker_why="$_dd_said"
            _pf_docker_kind="$_dd_kind"
        fi
        if [ -n "$_pf_engine" ]; then
            :
        elif [ "$_pf_named" = "docker" ]; then
            _pf_bad "EXAKIT_CONTAINER_ENGINE=docker, but ${_pf_docker_why:-Docker is not usable here} - the database step stops on it: fix Docker, or drop the variable to let the kit use Podman"
        elif command -v podman >/dev/null 2>&1; then
            [ -n "$_pf_docker_why" ] && _pf_note "$_pf_docker_why - a new Exasol Personal deployment will run on Podman"
            # THE REMEDY GOES HERE, BEFORE ANYTHING EXISTS. Once the database
            # is made on Podman it stays there: joining the group and
            # re-running does not move it (that takes an uninstall).
            [ "$_pf_docker_kind" = "denied" ] && \
                _pf_note "To use Docker instead, add your user to the docker group before installing (this grants root-level access; log out and back in), then re-run"
            _pf_ok "Podman: available (the Exasol Personal deployment runs through it)"
            _pf_engine="podman"
            # NOT JUDGED HERE: whether rootless Podman is complete (a subuid
            # range, newuidmap, cgroups v2). This gate used to refuse the
            # install on such a gap, which sent people to fix by hand what the
            # next step offers to fix for them. The deploy step heals what it
            # can and warns about the rest (personal_heal_rootless_podman), and
            # the launcher says if what is left matters.
        elif [ "$_pf_named" = "podman" ]; then
            # NAMED, NOT ABSENT. "None is on PATH" was wrong on a box with a
            # working Docker, and offered Docker while the variable bars it.
            # The database step installs Podman where it can.
            if [ "${EXAKIT_INSTALL_PODMAN:-1}" = "0" ]; then
                _pf_bad "EXAKIT_CONTAINER_ENGINE=podman, and Podman is not installed - EXAKIT_INSTALL_PODMAN=0 stops the installer installing it: install Podman yourself (e.g. 'sudo apt-get install -y podman uidmap' or 'sudo dnf install -y podman'), then re-run"
            else
                _pf_note "EXAKIT_CONTAINER_ENGINE=podman, and Podman is not installed yet - the database step installs it where this distro's package manager can (or install it yourself: e.g. 'sudo apt-get install -y podman uidmap' or 'sudo dnf install -y podman')"
                _pf_engine="podman"
            fi
        elif [ -n "$_pf_docker_why" ]; then
            # Docker IS on PATH: say why it did not count, not "none is on PATH".
            if [ "$_os" = "wsl" ]; then
                _pf_bad "No usable container engine in this distro: $_pf_docker_why, and Podman is not installed - fix Docker (Docker Desktop with its WSL integration for this distro, Engine 29 or newer), or install Podman here ('sudo apt-get install -y podman uidmap'); Podman on the Windows side does not count"
            else
                _pf_bad "No usable container engine: $_pf_docker_why, and Podman is not installed - fix Docker (Engine 29 or newer), or install Podman with your package manager (e.g. 'sudo apt-get install -y podman' or 'sudo dnf install -y podman')"
            fi
        elif [ "$_os" = "wsl" ]; then
            # Named for the distro, not for "Linux": the engine that counts is
            # the one on PATH inside WSL. Docker Desktop reaches it through its
            # WSL integration; a Podman Desktop on the Windows side does not.
            _pf_bad "A container engine is required and none is on PATH inside this distro - install Podman here (Debian/Ubuntu: 'sudo apt-get install -y podman uidmap'), or enable Docker Desktop's WSL integration for it (Docker Engine 29 or newer); Podman on the Windows side does not count"
        else
            _pf_bad "A container engine is required and none is on PATH - install Podman with your package manager (e.g. 'sudo apt-get install -y podman' or 'sudo dnf install -y podman'), or Docker Engine 29 or newer"
        fi
        # THE WSL GATE, PREVIEWED. A fresh Podman deployment on a WSL kernel
        # without nftables is refused by the deploy step (Podman cannot build
        # the 2.4 network there); the preflight said "all checks passed" on
        # exactly that machine. A release that cannot be read is unknown,
        # never old (detect_wsl_release), so it is a note, not a failure.
        # THE GATE'S OWN EXEMPTIONS, NOT A SUBSET: the iptables driver and a
        # Podman on another network backend pass the deploy, so they pass
        # here too - a preview that fails a machine the deploy accepts stops
        # an agent for nothing.
        if [ "$_os" = "wsl" ] && [ "$_pf_engine" = "podman" ] && \
           ! detect_podman_iptables_driver && ! detect_podman_backend_not_netavark; then
            if _pf_wsl_rel="$(detect_wsl_release 2>/dev/null)" && [ -n "$_pf_wsl_rel" ]; then
                _pf_wsl_major="${_pf_wsl_rel%%.*}"
                _pf_wsl_minor="${_pf_wsl_rel#*.}"
                _pf_wsl_minor="${_pf_wsl_minor%%.*}"
                [ "$_pf_wsl_rel" = "$_pf_wsl_major" ] && _pf_wsl_minor=0
                case "${_pf_wsl_major}${_pf_wsl_minor}" in ''|*[!0-9]*) _pf_wsl_major=0; _pf_wsl_minor=0 ;; esac
                if [ "$_pf_wsl_major" -lt 2 ] || { [ "$_pf_wsl_major" -eq 2 ] && [ "$_pf_wsl_minor" -lt 7 ]; }; then
                    # AN EXISTING DEPLOYMENT IS NOT REFUSED. The deploy step
                    # gates only a fresh Podman deployment, and the launcher
                    # update is not gated at all (it changes no data; the
                    # start after it names the fix from netavark's own error).
                    # Failing the preview there stopped an agent before a
                    # re-run the deploy step accepts, so it is a note.
                    if _detect_personal_deployment_present; then
                        _pf_note "WSL $_pf_wsl_rel: the existing Podman deployment is kept, but once its launcher is Exasol Personal 2.4 it cannot start on this WSL kernel (no nftables) - in PowerShell run 'wsl --update' then 'wsl --shutdown', or set firewall_driver = \"iptables\" under [network] in ~/.config/containers/containers.conf (the iptables package must be installed)"
                    else
                        _pf_bad "WSL $_pf_wsl_rel: Podman on this WSL kernel cannot create the network Exasol Personal 2.4 needs (no nftables) - in PowerShell run 'wsl --update' then 'wsl --shutdown', or set firewall_driver = \"iptables\" under [network] in ~/.config/containers/containers.conf (the iptables package must be installed)"
                    fi
                fi
            else
                _pf_note "The WSL release could not be read from this distro - Exasol Personal 2.4 on Podman needs WSL 2.7 or newer; check with 'wsl --version' in PowerShell"
            fi
        fi
    fi

    # port
    #
    # PROBE THE PORT THE INSTALL WILL ACTUALLY BIND. EXAKIT_DB_PORT only moves
    # the CONTAINER deployments; the macOS deployment always binds 8563. The
    # preflight honoured the variable everywhere, so on a Mac with
    # EXAKIT_DB_PORT=8564 it reported "Port 8564 is free" — a green tick for a
    # port the deploy never touches — and never looked at 8563 at all. The
    # preflight's whole job is to answer "will this work here", so it asks
    # about the right port and drops the knob from the remedy where it does
    # nothing.
    if [ "$(detect_os)" = "macos" ]; then
        _pf_port=8563
    else
        _pf_port="${EXAKIT_DB_PORT:-8563}"
    fi
    if port_in_use "$_pf_port"; then
        if [ "$(detect_os)" = "macos" ]; then
            _pf_note "Port $_pf_port is in use — fine if that is an existing local Exasol (it is adopted); otherwise stop the other application (the macOS deployment cannot use a different port)"
        else
            _pf_note "Port $_pf_port is in use — fine if that is an existing local Exasol; otherwise stop the other application or set EXAKIT_DB_PORT"
        fi
    else
        _pf_ok "Port $_pf_port is free"
    fi

    # network reachability (downloads come from these). Any HTTP response
    # counts as reachable — only connection/DNS/TLS failures matter here.
    _pf_reachable() {
        curl -sI --connect-timeout 5 -o /dev/null "https://$1" 2>/dev/null
    }
    for _endpoint in github.com objects.githubusercontent.com; do
        if _pf_reachable "$_endpoint"; then
            _pf_ok "Network: $_endpoint reachable"
        else
            _pf_bad "Network: cannot reach $_endpoint — check connectivity/proxy (set HTTPS_PROXY if needed)"
        fi
    done
    if _pf_reachable "pypi.org"; then
        _pf_ok "Network: pypi.org reachable (MCP server package)"
    else
        _pf_bad "Network: cannot reach pypi.org — the MCP server package cannot be downloaded"
    fi

    printf '\n'
    if [ "$_failures" -eq 0 ]; then
        printf 'All checks passed — this machine can run the starter kit.\n'
    else
        printf '%s requirement(s) missing — fix the items marked ✗ above and re-run.\n' "$_failures"
    fi
    return "$_failures"
}
