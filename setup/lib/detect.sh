#!/usr/bin/env bash
# detect.sh — environment detection for the Exasol Personal Local Starter Kit.
#
# Sourced by install.sh and setup-*.sh. Pure read-only checks, no side effects.
# Compatible with bash 3.2 and POSIX sh.

# detect_os — prints: macos | linux | wsl | unsupported
detect_os() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
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

# detect_arch — prints: arm64 | x86_64 | unsupported
detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        *)             echo "unsupported" ;;
    esac
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
# before ~5.16 ignore arm64.nosve, hence the HWE kernel step.
detect_sve_remedy_hint() {
    info "This guest advertises SVE support its host CPU cannot execute (common with VirtualBox on Apple Silicon)."
    info "Permanent fix: install a kernel that honors arm64.nosve and disable SVE at boot:"
    info "  sudo apt-get install -y linux-generic-hwe-\$(lsb_release -rs 2>/dev/null || echo 22.04)"
    info "  add 'arm64.nosve arm64.nosme' to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
    info "  sudo update-grub && sudo reboot"
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
        _dr_ram="$(awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null)"
    fi
    case "$_dr_ram" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dr_ram" ;;
    esac
}

# detect_free_disk_gb <path> — free space in whole GB. Same fail-closed
# contract as detect_ram_gb: always a non-negative integer, 0 if unknown.
detect_free_disk_gb() {
    _dd="$(df -Pk "${1:-$HOME}" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"
    case "$_dd" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dd" ;;
    esac
}

# detect_container_runtime — prints the first usable runtime:
#   docker | podman | none
# "Usable" means the CLI exists and the daemon/socket answers.
detect_container_runtime() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
        return
    fi
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
        return
    fi
    echo "none"
}

# detect_container_runtime_detail — richer status for error messages:
#   docker | podman | docker-permission | docker-stopped | podman-stopped | none
detect_container_runtime_detail() {
    _usable="$(detect_container_runtime)"
    if [ "$_usable" != "none" ]; then
        echo "$_usable"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        # Distinguish "the daemon is down" from "the daemon is UP but this
        # user may not talk to it" (typically: not in the docker group, so
        # /var/run/docker.sock refuses with permission denied). The remedies
        # are completely different — telling that user to start a daemon
        # that is already running sends them in circles.
        if docker info 2>&1 | grep -qi 'permission denied'; then
            echo "docker-permission"
            return
        fi
        echo "docker-stopped"
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        echo "podman-stopped"
        return
    fi
    echo "none"
}

# port_in_use <port> — succeeds when something already listens on the port.
port_in_use() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

# wsl_docker_desktop_on_windows — inside WSL, use Windows interop to detect
# the classic half-configured state: Docker Desktop IS running on the
# Windows side (docker.exe answers) while this distro cannot reach it,
# i.e. WSL integration is not enabled for this distro.
wsl_docker_desktop_on_windows() {
    [ "$(detect_os)" = "wsl" ] || return 1
    command -v docker.exe >/dev/null 2>&1 || return 1
    docker.exe info >/dev/null 2>&1
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
    if [ "$_arch" = "unsupported" ]; then
        _pf_bad "CPU architecture: $(uname -m) is not supported (arm64 or x86_64 required)"
    else
        _pf_ok "CPU architecture: $_arch"
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
        if [ "$_ram" -ge 4 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Nano needs 4+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Nano needs at least 4 GB"; fi
        if [ "$_disk" -ge 10 ]; then _pf_ok "Free disk: ${_disk} GB (10+ recommended)"
        else _pf_bad "Free disk: ${_disk} GB — free up space (10 GB recommended for the database image and data)"; fi
    fi

    # base tools
    for _tool in curl tar; do
        if command -v "$_tool" >/dev/null 2>&1; then _pf_ok "$_tool available"
        else _pf_bad "$_tool missing — install it with your package manager"; fi
    done
    if command -v python3 >/dev/null 2>&1; then
        # The kit's tooling needs 3.11+ (tomllib); an older system python is
        # fine — the installer switches to its managed runtime automatically.
        if python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
            _pf_ok "python3 available"
        else
            _pf_note "python3 available but older than 3.11 — the installer will use its managed Python runtime automatically"
        fi
    elif command -v uv >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/uv" ]; then
        _pf_ok "uv available — it can provide Python automatically"
    elif [ "$_os" = "macos" ]; then
        _pf_note "python3 missing — the installer can bootstrap a managed Python runtime automatically"
    else
        _pf_note "python3 missing — the installer can bootstrap a managed Python runtime automatically"
    fi

    # container runtime (only the Nano platforms need one)
    if [ "$_os" != "macos" ]; then
        case "$(detect_container_runtime_detail)" in
            docker)         _pf_ok "Container runtime: docker (running)" ;;
            podman)         _pf_ok "Container runtime: podman (running)" ;;
            docker-stopped)
                if command -v podman >/dev/null 2>&1; then
                    _pf_podman="Podman (the fallback) is installed but not running either"
                else
                    _pf_podman="Podman (the fallback) is not installed"
                fi
                if wsl_docker_desktop_on_windows; then
                    _pf_bad "Docker is unreachable: Docker Desktop runs on Windows but is not connected to this WSL distro (Docker Desktop > Settings > Resources > WSL integration > enable this distro, Apply & restart); $_pf_podman"
                else
                    _pf_bad "Docker is installed but unreachable (daemon not responding) — start Docker (e.g. Docker Desktop); $_pf_podman"
                fi ;;
            docker-permission) _pf_bad "Docker is running but this user may not use it (permission denied on the Docker socket) — add yourself to the docker group: sudo usermod -aG docker \$USER, then log out and back in" ;;
            podman-stopped) _pf_bad "Podman is installed but not running (Docker not found) — try: podman machine start, or install Docker" ;;
            none)           _pf_bad "No container runtime — install Docker (docs.docker.com/get-docker) or Podman (podman.io)" ;;
        esac
    fi

    # leftover root-owned credentials (a root Docker daemon creates missing
    # bind-mount paths as root-owned directories; an interrupted install can
    # leave them behind — the installer repairs this automatically)
    _pf_creds="${EXAKIT_CREDS_DIR:-$HOME/.exasol-starter-kit/credentials}"
    if [ -d "$_pf_creds/nano_sys_password" ] || { [ -d "$_pf_creds" ] && [ ! -w "$_pf_creds" ]; }; then
        _pf_note "Root-owned leftovers from an interrupted install in $_pf_creds — the installer repairs this automatically via the container engine"
    fi

    # port
    if port_in_use "${EXAKIT_DB_PORT:-8563}"; then
        _pf_note "Port ${EXAKIT_DB_PORT:-8563} is in use — fine if that is an existing local Exasol; otherwise stop the other application or set EXAKIT_DB_PORT"
    else
        _pf_ok "Port ${EXAKIT_DB_PORT:-8563} is free"
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
    if [ "$_os" != "macos" ]; then
        if _pf_reachable "registry-1.docker.io/v2/"; then
            _pf_ok "Network: Docker Hub reachable"
        else
            _pf_bad "Network: cannot reach Docker Hub — the Nano image cannot be pulled from this network"
        fi
    fi
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
