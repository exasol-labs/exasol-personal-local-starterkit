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
    check "powershell(version_policy_fallback)" "2026.2.0-nano.2 0.13.0 1.10.1" "$ps_versions"
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

echo "step re-verification before skipping:"
# A manifest saying steps_completed: ["launcher"] with no launcher on disk made
# every re-run skip step 1 and then fail step 2 (which needs the launcher), for
# ever: the one step that could repair the install was the one being skipped.
# begin_step now skips only when the tick AND the disk agree, and an artifact it
# cannot prove is gone ("unknown") must never override the tick — re-running the
# runtime step on a guess would stop a working database.
#
# _sv_state <home> <step> <extra-shell> — step_artifact_state's verdict.
# _sv_step  <home> <step> <extra-shell> — what begin_step decides:
#   "skip"  begin_step returned 1 (caller skips the step)
#   "rerun" begin_step returned 0 and said why (recorded done, artifact gone)
#   "run"   begin_step returned 0 with no re-run notice (never recorded done)
_sv_state() {
    bash -c "
set -u
EXAKIT_HOME='$1'
EXAKIT_BIN_DIR='$1/bin'
. '$ROOT/setup/lib/common.sh'
$3
step_artifact_state '$2'
" 2>/dev/null
}
_sv_step() {
    bash -c "
set -u
EXAKIT_HOME='$1'
EXAKIT_BIN_DIR='$1/bin'
. '$ROOT/setup/lib/common.sh'
$3
if begin_step '$2' 'Step 1/1  probe' > '$1/begin.out' 2>&1; then
    if grep -q 'what it installed is missing' '$1/begin.out'; then
        printf rerun
    else
        printf run
    fi
else
    printf skip
fi
"
}
# The launcher cases must not see a launcher this machine happens to have on
# PATH: personal_cli() would resolve it, so step_artifact_state counts it as
# present (and is right to). Drop any PATH entry holding one — python3, which
# step_done needs, stays reachable.
_sv_path_without_exasol() {
    _svp=""
    _svp_ifs="$IFS"
    IFS=:
    for _svp_dir in $PATH; do
        [ -x "$_svp_dir/exasol" ] && continue
        _svp="${_svp:+$_svp:}$_svp_dir"
    done
    IFS="$_svp_ifs"
    printf '%s\n' "$_svp"
}
_SV_CLEAN_PATH="$(_sv_path_without_exasol)"

# launcher, recorded done, binary gone -> the bug: must re-run, not skip.
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["launcher"], "components": {}}\n' > "$_sv_home/manifest.json"
_sv_launcher_setup="PATH='$_SV_CLEAN_PATH'; . '$ROOT/setup/lib/detect.sh'; . '$ROOT/setup/lib/runtime-personal.sh'"
check "step_state(launcher missing)" "missing" \
    "$(_sv_state "$_sv_home" launcher "$_sv_launcher_setup")"
check "begin_step(launcher missing)" "rerun" \
    "$(_sv_step "$_sv_home" launcher "$_sv_launcher_setup")"
# ...and with the binary back, the completed step must still be skipped.
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/bin/exasol"
chmod +x "$_sv_home/bin/exasol"
check "step_state(launcher present)" "present" \
    "$(_sv_state "$_sv_home" launcher "$_sv_launcher_setup")"
check "begin_step(launcher present)" "skip" \
    "$(_sv_step "$_sv_home" launcher "$_sv_launcher_setup")"
rm -rf "$_sv_home"

# exakit_helper: the same shape, on the artifact the helper step installs.
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["exakit_helper"], "components": {}}\n' > "$_sv_home/manifest.json"
check "step_state(exakit_helper missing)" "missing" "$(_sv_state "$_sv_home" exakit_helper "")"
check "begin_step(exakit_helper missing)" "rerun" "$(_sv_step "$_sv_home" exakit_helper "")"
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/bin/exakit"
chmod +x "$_sv_home/bin/exakit"
check "step_state(exakit_helper present)" "present" "$(_sv_state "$_sv_home" exakit_helper "")"
check "begin_step(exakit_helper present)" "skip" "$(_sv_step "$_sv_home" exakit_helper "")"
rm -rf "$_sv_home"

# runtime is the "unknown" case that matters most: no file test can prove a
# database deployment is gone, so a completed runtime step is ALWAYS skipped.
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["runtime", "mcp", "pyexasol"], "components": {}}\n' > "$_sv_home/manifest.json"
for _sv_unknown in runtime mcp pyexasol; do
    check "step_state($_sv_unknown)" "unknown" "$(_sv_state "$_sv_home" "$_sv_unknown" "")"
    check "begin_step($_sv_unknown recorded)" "skip" "$(_sv_step "$_sv_home" "$_sv_unknown" "")"
done
# A step that was never recorded runs, with no re-run notice.
check "begin_step(launcher not recorded)" "run" "$(_sv_step "$_sv_home" launcher "$_sv_launcher_setup")"
rm -rf "$_sv_home"

# exapump is judged by the path the install recorded. No recorded path is
# "unknown" (an older install, or a soft failure) — never "missing".
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["exapump"], "components": {}}\n' > "$_sv_home/manifest.json"
check "step_state(exapump unrecorded)" "unknown" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump unrecorded)" "skip" "$(_sv_step "$_sv_home" exapump "")"
printf '{"steps_completed": ["exapump"], "components": {"exapump": {"path": "%s"}}}\n' \
    "$_sv_home/bin/exapump" > "$_sv_home/manifest.json"
check "step_state(exapump missing)" "missing" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump missing)" "rerun" "$(_sv_step "$_sv_home" exapump "")"
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/bin/exapump"
chmod +x "$_sv_home/bin/exapump"
check "step_state(exapump present)" "present" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump present)" "skip" "$(_sv_step "$_sv_home" exapump "")"
rm -rf "$_sv_home"

# The check must cost nothing on every install: file tests only. Anything that
# could wake a container engine, or reach the network, belongs nowhere near it.
_sv_body="$(awk '/^step_artifact_state\(\) \{/ { inside = 1 } inside { print } inside && /^}/ { exit }' \
    "$ROOT/setup/lib/common.sh")"
if printf '%s\n' "$_sv_body" | grep -q 'launcher)' && \
   ! printf '%s\n' "$_sv_body" | grep -Eq 'docker|podman|curl|fetch |nano_status|personal_status|exasol info'; then
    check "step_state(file_tests_only)" "yes" "yes"
else
    check "step_state(file_tests_only)" "yes" "no"
fi

# Both sides carry the same two halves: the artifact table and a begin_step that
# only lets a proven "missing" override the manifest tick.
if grep -q 'step_artifact_state' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Get-ExakitStepArtifactState' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'what it installed is missing' "$ROOT/setup/lib/common.sh" && \
   grep -q 'what it installed is missing' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "step_state(ps_parity)" "yes" "yes"
else
    check "step_state(ps_parity)" "yes" "no"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
