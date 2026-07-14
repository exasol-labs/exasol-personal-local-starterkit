#!/usr/bin/env bash
# dry-run-matrix.sh — exercises the detection and routing logic against
# simulated environments (stubbed uname / container CLIs). No installs.
#
#   bash tests/dry-run-matrix.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# make_stub_env <uname-s> <uname-m> — builds a PATH dir with a stubbed uname.
make_stub_env() {
    _dir="$(mktemp -d)"
    cat > "$_dir/uname" <<EOF
#!/bin/sh
case "\${1:-}" in
    -s) echo "$1" ;;
    -m) echo "$2" ;;
    *)  echo "$1" ;;
esac
EOF
    chmod +x "$_dir/uname"
    echo "$_dir"
}

echo "detect_os / detect_arch matrix:"
for spec in "Darwin arm64 macos arm64" \
            "Darwin x86_64 macos x86_64" \
            "Linux x86_64 linux x86_64" \
            "Linux aarch64 linux arm64" \
            "FreeBSD amd64 unsupported x86_64"; do
    set -- $spec
    stub="$(make_stub_env "$1" "$2")"
    got_os="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_os")"
    got_arch="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_arch")"
    # WSL looks like Linux to uname; the /proc/version branch cannot be
    # simulated on macOS and is covered by a run on real WSL.
    [ "$1" = "Linux" ] && [ "$got_os" = "wsl" ] && got_os="linux"
    check "os($1)" "$3" "$got_os"
    check "arch($2)" "$4" "$got_arch"
    rm -rf "$stub"
done

echo "container runtime detection:"
# No docker/podman on PATH at all -> none
empty="$(mktemp -d)"
for tool in bash sh grep awk cat uname command; do
    _p="$(command -v $tool)" && ln -s "$_p" "$empty/$tool" 2>/dev/null
done
got="$(PATH="$empty" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime")"
check "runtime(no CLIs)" "none" "$got"
got="$(PATH="$empty" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime_detail")"
check "runtime_detail(no CLIs)" "none" "$got"

# docker present but daemon down -> docker-stopped, and not selected.
# A FAILING podman stub is created alongside: the stub dir is prepended to
# the real PATH, so on a machine with a healthy real podman the fallback
# would otherwise leak in and detection would (correctly, but off-test)
# return podman instead of the docker-* state under test.
stub="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$stub/docker" && chmod +x "$stub/docker"
printf '#!/bin/sh\nexit 1\n' > "$stub/podman" && chmod +x "$stub/podman"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime_detail")"
check "runtime_detail(docker down)" "docker-stopped" "$got"

# docker daemon UP but the user lacks socket permission (not in the docker
# group) -> docker-permission, so the error names the real remedy (usermod)
# instead of telling the user to start a daemon that is already running.
printf '#!/bin/sh\necho "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2\nexit 1\n' > "$stub/docker" && chmod +x "$stub/docker"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime_detail")"
check "runtime_detail(docker permission)" "docker-permission" "$got"

# docker present and healthy -> docker
printf '#!/bin/sh\nexit 0\n' > "$stub/docker" && chmod +x "$stub/docker"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime")"
check "runtime(docker up)" "docker" "$got"

# podman only -> podman. The docker stub must FAIL rather than be removed:
# the stub dir is prepended to the real PATH, so on a machine with a healthy
# Docker the real binary would leak in and detection would return docker.
printf '#!/bin/sh\nexit 1\n' > "$stub/docker" && chmod +x "$stub/docker"
printf '#!/bin/sh\nexit 0\n' > "$stub/podman" && chmod +x "$stub/podman"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime")"
check "runtime(podman only)" "podman" "$got"
rm -rf "$stub" "$empty"

echo "install.sh dispatch:"
# Dry-run against a local tarball server is overkill; verify the routing
# table statically instead: every platform maps to the right setup script.
grep -q 'setup_script="setup/setup-macos.sh"' "$ROOT/install.sh" && \
    check "dispatch(macos)" "setup-macos.sh" "setup-macos.sh" || \
    check "dispatch(macos)" "setup-macos.sh" "missing"
grep -q 'setup_script="setup/setup-wsl.sh"' "$ROOT/install.sh" && \
    check "dispatch(linux/wsl)" "setup-wsl.sh" "setup-wsl.sh" || \
    check "dispatch(linux/wsl)" "setup-wsl.sh" "missing"

echo "mcp credential fallback:"
_mcp_test_dir="$(mktemp -d)"
EXAKIT_CREDS_DIR="$_mcp_test_dir/credentials"
mkdir -p "$_mcp_test_dir/credentials"
printf 'readonly-secret\n' > "$_mcp_test_dir/credentials/mcp_readonly_password"
manifest_get() {
    case "$1" in
        components.mcp_server.connection.user)
            return 1
            ;;
        components.mcp_server.connection.password_file)
            return 1
            ;;
        components.mcp_server.user)
            printf '%s\n' "legacy-marker"
            ;;
        runtime.user)
            printf '%s\n' "sys"
            ;;
        runtime.password_file)
            printf '%s\n' "$_mcp_test_dir/credentials/db_password"
            ;;
        *)
            return 1
            ;;
    esac
}
. "$ROOT/setup/lib/mcp.sh"
_mcp_user="$(mcp_credentials | awk -F '\t' '{print $1}')"
check "mcp_credentials(legacy fallback)" "mcp_readonly" "$_mcp_user"
rm -rf "$_mcp_test_dir"

echo "update command routing:"
update_targets="$(bash -c ". '$ROOT/setup/lib/common.sh'; exakit_update_targets all" | tr '\n' ' ')"
check "update_targets(all)" "exakit runtime exapump mcp " "$update_targets"
personal_target="$(bash -c ". '$ROOT/setup/lib/common.sh'; exakit_update_targets personal" | tr '\n' ' ')"
check "update_targets(personal)" "personal " "$personal_target"
if grep -q 'mcp.sh' "$ROOT/setup/exakit"; then
    check "exakit_sources(mcp)" "yes" "yes"
else
    check "exakit_sources(mcp)" "yes" "no"
fi
if grep -q 'cmd_update "$@"' "$ROOT/setup/exakit" && \
   grep -q 'exakit_update_component "$_component" "$@"' "$ROOT/setup/lib/common.sh"; then
    check "update_options(forwarded)" "yes" "yes"
else
    check "update_options(forwarded)" "yes" "no"
fi
if bash -c ". '$ROOT/setup/lib/common.sh'; exakit_version_newer 3.0.0 2.0.0"; then
    check "version_newer(3>2)" "yes" "yes"
else
    check "version_newer(3>2)" "yes" "no"
fi
update_action="$(bash -c "
. '$ROOT/setup/lib/common.sh'
manifest_get() {
  case \"\$1\" in
    runtime.type) printf '%s\n' nano ;;
    runtime.image) printf '%s\n' docker.io/exasol/nano:2026.2.0-nano.2 ;;
    components.exapump.version) printf '%s\n' 0.11.2 ;;
    components.mcp_server.version) printf '%s\n' 1.10.1 ;;
    kit.source) printf '%s\n' example/starter@1.0.0 ;;
    *) return 1 ;;
  esac
}
exakit_component_latest() {
  case \"\$1\" in
    nano) printf '%s\n' 2026.3.0-nano.1 ;;
    exapump) printf '%s\n' 0.12.0 ;;
    mcp) printf '%s\n' 1.11.0 ;;
    exakit) printf '%s\n' 1.1.0 ;;
  esac
}
exakit_print_update_check all
" | grep -c 'exakit update')"
check "update_check(commands)" "5" "$update_action"

personal_major_plan="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
manifest_get() {
  case \"\$1\" in
    runtime.version) printf '%s\n' 2.0.0 ;;
    *) return 1 ;;
  esac
}
exakit_component_latest() { printf '%s\n' 3.0.0; }
personal_update --plan
" 2>&1 | grep -c 'exakit update personal --backup')"
check "personal_major(plan)" "1" "$personal_major_plan"

personal_reuse_guard="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_PERSONAL_PORT=8563
_stub_dir=\"\$(mktemp -d)\"
printf '#!/bin/sh\n[ \"\$1\" = info ] && exit 0\nexit 1\n' > \"\$_stub_dir/exasol\"
chmod +x \"\$_stub_dir/exasol\"
personal_cli() { printf '%s\n' \"\$_stub_dir/exasol\"; }
port_in_use() { return 1; }
if personal_deployment_running; then printf reuse; else printf deploy; fi
rm -rf \"\$_stub_dir\"
")"
check "personal_reuse_guard(no-port)" "deploy" "$personal_reuse_guard"

personal_reuse_when_port_open="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_PERSONAL_PORT=8563
_stub_dir=\"\$(mktemp -d)\"
printf '#!/bin/sh\n[ \"\$1\" = info ] && exit 0\nexit 1\n' > \"\$_stub_dir/exasol\"
chmod +x \"\$_stub_dir/exasol\"
personal_cli() { printf '%s\n' \"\$_stub_dir/exasol\"; }
port_in_use() { return 0; }
if personal_deployment_running; then printf reuse; else printf deploy; fi
rm -rf \"\$_stub_dir\"
")"
check "personal_reuse_guard(open-port)" "reuse" "$personal_reuse_when_port_open"

_personal_backup_dir="$(mktemp -d)"
mkdir -p "$_personal_backup_dir/deploy"
printf 'deployment state\n' > "$_personal_backup_dir/deploy/marker.txt"
personal_backup_count="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_HOME='$_personal_backup_dir/home'
EXAKIT_PERSONAL_DEPLOY_DIR='$_personal_backup_dir/deploy'
EXAKIT_LOG_FILE='$_personal_backup_dir/backup.log'
manifest_set() { :; }
personal_status() { printf '%s\n' stopped; }
personal_upgrade_backup 2.0.0 3.0.0 >/dev/null
find \"\$EXAKIT_HOME/backups\" -name 'personal-upgrade-*.tar.gz' | wc -l | tr -d ' '
")"
check "personal_major(backup)" "1" "$personal_backup_count"
rm -rf "$_personal_backup_dir"

echo "version lookup fallbacks without Python/uv:"
fallback_versions="$(bash -c "
. '$ROOT/setup/lib/common.sh'
EXAKIT_DISABLE_SYSTEM_PYTHON=1
exakit_ensure_uv() { return 1; }
curl() {
  case \"\$*\" in
    *api.github.com*) printf '%s\n' '{\"tag_name\":\"v9.8.7\"}' ;;
    *pypi.org*) printf '%s\n' '{\"info\":{\"version\":\"6.5.4\"}}' ;;
    *hub.docker.com*) printf '%s\n' '{\"results\":[{\"name\":\"2026.4.0-nano.1\"},{\"name\":\"latest\"}]}' ;;
  esac
}
printf '%s %s %s ' \"\$(exakit_latest_github_release_version owner/repo)\" \"\$(exakit_latest_pypi_version pkg)\" \"\$(exakit_latest_docker_tag exasol/nano)\"
if exakit_version_newer 3.0.0 2.9.9; then printf yes; else printf no; fi
")"
check "lookup_fallback(no-python)" "9.8.7 6.5.4 2026.4.0-nano.1 yes" "$fallback_versions"

echo "managed binary precedence:"
_bin_test_dir="$(mktemp -d)"
mkdir -p "$_bin_test_dir/kit-bin" "$_bin_test_dir/path-bin"
printf '#!/bin/sh\necho kit\n' > "$_bin_test_dir/kit-bin/exapump"
printf '#!/bin/sh\necho path\n' > "$_bin_test_dir/path-bin/exapump"
chmod +x "$_bin_test_dir/kit-bin/exapump" "$_bin_test_dir/path-bin/exapump"
managed_exapump="$(PATH="$_bin_test_dir/path-bin:$PATH" bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/exapump.sh'
EXAKIT_EXAPUMP_BIN='$_bin_test_dir/kit-bin/exapump'
exapump_cli
")"
check "exapump_cli(prefers-managed)" "$_bin_test_dir/kit-bin/exapump" "$managed_exapump"
rm -rf "$_bin_test_dir"

echo "self-update staging guard:"
if grep -q 'exakit-kit-stage' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Downloaded starter kit is incomplete' "$ROOT/setup/lib/common.sh" && \
   grep -q 'existing kit copy was left untouched' "$ROOT/setup/lib/common.sh"; then
    check "self_update(staged_validation)" "yes" "yes"
else
    check "self_update(staged_validation)" "yes" "no"
fi

echo "Windows parity guards:"
if command -v pwsh >/dev/null 2>&1; then
    ps_parse="$(pwsh -NoProfile -Command '
      $files = @("setup/lib/exakit-common.ps1","setup/lib/nano.ps1","setup/lib/mcp.ps1","setup/setup-windows-docker.ps1","setup/exakit.ps1")
      foreach ($f in $files) {
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $f), [ref]$errors)
        if ($errors) { Write-Output "no"; exit 0 }
      }
      Write-Output "yes"
    ' | tr -d '\r')"
    check "powershell(parse)" "yes" "$ps_parse"

    _ps_tmp="$(mktemp -d)"
    ps_versions="$(EXAKIT_HOME="$_ps_tmp/home" EXAKIT_BIN_DIR="$_ps_tmp/bin" EXAKIT_VERSION_POLICY=pinned pwsh -NoProfile -Command '
      . ./setup/lib/exakit-common.ps1
      Initialize-ExakitManifest
      Resolve-ExakitInstallVersions
      Write-Output "$script:NanoTag $script:ExapumpVersion $script:McpVersion"
    ' | tail -1 | tr -d '\r')"
    rm -rf "$_ps_tmp"
    check "powershell(version_policy_fallback)" "2026.2.0-nano.2 0.11.2 1.10.1" "$ps_versions"
else
    check "powershell(parse)" "skipped" "skipped"
    check "powershell(version_policy_fallback)" "skipped" "skipped"
fi
if grep -q 'Resolve-ExakitInstallVersions' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Get-ExakitLatestDockerTag' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitLatestGithubRelease' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitLatestPypiVersion' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "windows_install(latest_resolution)" "yes" "yes"
else
    check "windows_install(latest_resolution)" "yes" "no"
fi
if grep -q 'nano_update_snapshot' "$ROOT/setup/lib/runtime-nano.sh" && \
   grep -q 'nano_restore_previous_container' "$ROOT/setup/lib/runtime-nano.sh" && \
   grep -q 'New-NanoUpdateSnapshot' "$ROOT/setup/lib/nano.ps1" && \
   grep -q 'Restore-PreviousNanoContainer' "$ROOT/setup/lib/nano.ps1"; then
    check "nano_update(recoverability)" "yes" "yes"
else
    check "nano_update(recoverability)" "yes" "no"
fi
if grep -q 'mcp_update_snapshot' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'New-McpUpdateSnapshot' "$ROOT/setup/lib/mcp.ps1" && \
   grep -q 'backups.mcp_update.latest' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'backups.mcp_update.latest' "$ROOT/setup/lib/mcp.ps1"; then
    check "mcp_update(snapshot)" "yes" "yes"
else
    check "mcp_update(snapshot)" "yes" "no"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
