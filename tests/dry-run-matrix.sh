#!/usr/bin/env bash
# dry-run-matrix.sh — exercises the detection and routing logic against
# simulated environments (stubbed uname / container CLIs). No installs.
#
#   bash tests/dry-run-matrix.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# A failure note that was ALREADY in the developer's kit home before this suite
# started is not pollution this suite caused - any real command of theirs that
# failed leaves one. Remember what was there, so the check at the end can tell
# "the suite wrote this" from "it was already here" instead of reporting a false
# alarm and training people to ignore it.
_PRE_NOTE=""
[ -e "$HOME/.exasol-starter-kit/.last-failure" ] && \
    _PRE_NOTE="$(cat "$HOME/.exasol-starter-kit/.last-failure" 2>/dev/null)"
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
# No podman on PATH at all -> none
empty="$(mktemp -d)"
for tool in bash sh grep awk cat uname command; do
    _p="$(command -v $tool)" && ln -s "$_p" "$empty/$tool" 2>/dev/null
done
got="$(PATH="$empty" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_podman")"
check "podman(absent)" "none" "$got"

# podman present but not answering -> none, so the refusal names installing or
# starting it rather than claiming an engine that cannot be driven. The stub dir
# is prepended to the real PATH, so a healthy real podman would otherwise leak
# in and answer for the state under test.
stub="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$stub/podman" && chmod +x "$stub/podman"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_podman")"
check "podman(not answering)" "none" "$got"

# podman present and healthy -> podman
printf '#!/bin/sh\nexit 0\n' > "$stub/podman" && chmod +x "$stub/podman"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_podman")"
check "podman(healthy)" "podman" "$got"
rm -rf "$stub" "$empty"

echo "install.sh dispatch:"
# Dry-run against a local tarball server is overkill; verify the routing
# table statically instead: every platform maps to the right setup script.
grep -q 'setup_script="setup/setup-macos.sh"' "$ROOT/install.sh" && \
    check "dispatch(macos)" "setup-macos.sh" "setup-macos.sh" || \
    check "dispatch(macos)" "setup-macos.sh" "missing"
grep -q 'setup_script="setup/setup-linux.sh"' "$ROOT/install.sh" && \
    check "dispatch(linux/wsl)" "setup-linux.sh" "setup-linux.sh" || \
    check "dispatch(linux/wsl)" "setup-linux.sh" "missing"

echo "the support matrix is stated, never silently rerouted:"
# Exasol Personal is the only runtime this kit installs. A platform it does not
# support must be refused BY NAME, before anything is downloaded - a silent
# reroute onto something else is exactly what this replaced.
#
# WSL IS NOT SUCH A PLATFORM. It is Linux to the launcher, so install.sh sends
# it to the Linux setup rather than turning it away, and the prerequisite that
# differs - a podman inside the distro, not on the Windows side - is checked
# there. What must not come back is the refusal.
grep -q 'it does not support WSL' "$ROOT/install.sh" && \
    check "install.sh no longer turns WSL away" absent present || \
    check "install.sh no longer turns WSL away" absent absent
check "install.sh sends WSL to the Linux setup" "setup/setup-linux.sh" \
    "$(sed -n '/^        Linux)/,/^            ;;/p' "$ROOT/install.sh" | sed -n 's/.*setup_script="\([^"]*\)".*/\1/p')"
grep -q 'it does not support Windows arm64' "$ROOT/install.ps1" && \
    check "install.ps1 exits gracefully on arm64, naming the support matrix" present present || \
    check "install.ps1 exits gracefully on arm64, naming the support matrix" present MISSING
# THE WINDOWS INSTALLER MUST NOT CLOSE THE USER'S TERMINAL. Its documented entry
# point is `irm ... | iex`, which runs the body in the CALLER'S session - so a
# top-level `exit` terminates the PowerShell host, window and all. That took the
# preflight report off the screen before it could be read, and took every
# failure message with it (the trap printed the cause, then exit closed the
# window over it). Every stop is now a return, with exit reserved for a real
# file invocation, and $LASTEXITCODE still carries the code.
_pse="$(grep -cE '^\s*(exit [0-9$]|exit \()' "$ROOT/install.ps1" || true)"
check "install.ps1 has no unguarded top-level exit" "0" "$_pse"
grep -q 'ExakitRanAsFile = \[bool\]$PSCommandPath' "$ROOT/install.ps1" && \
    check "...it knows whether it was run as a file" present present || \
    check "...it knows whether it was run as a file" present MISSING
# One per stop that can happen while the body runs in the caller's session: the
# preflight refusal, the download failure, the installer/kit mismatch, and the
# setup script's own code. Raise this when a stop is added; never lower it by
# dropping the assignment.
check "...and every stop still reports a code" "4" \
    "$(grep -c 'global:LASTEXITCODE' "$ROOT/install.ps1")"
grep -q 'Exasol Personal (local deployment via Podman)' "$ROOT/install.sh" && \
    check "install.sh routes personal-on-linux and names the plan" present present || \
    check "install.sh routes personal-on-linux and names the plan" present MISSING
# The setup script sources the one runtime module there is - no dispatch, and
# nothing else to source.
grep -q 'runtime-personal.sh' "$ROOT/setup/setup-linux.sh" && \
    ! grep -q 'runtime-nano' "$ROOT/setup/setup-linux.sh" && \
    check "setup-linux.sh sources the Personal runtime, and only it" present present || \
    check "setup-linux.sh sources the Personal runtime, and only it" present MISSING
# The preflight answers the question the runtime actually asks: it checks Podman
# by name, because no other engine substitutes for it.
_pfr() { # _pfr <with-podman:0|1> -> the engine line of the preflight
    _pfr_bin="$(mktemp -d)/pf-bin"; mkdir -p "$_pfr_bin"
    [ "$1" = 1 ] && { printf '#!/bin/sh\nexit 0\n' > "$_pfr_bin/podman"; chmod +x "$_pfr_bin/podman"; }
    PATH="$_pfr_bin:/usr/bin:/bin" bash -c '
        . "$0/setup/lib/detect.sh"
        detect_os() { echo linux; }; detect_arch() { echo x86_64; }
        detect_ram_gb() { echo 16; }; detect_free_disk_gb() { echo 100; }
        detect_wsl_version() { echo 2; }; detect_wsl_drvfs_path() { return 1; }
        preflight_report' "$ROOT" 2>/dev/null | grep -ci "podman"
}
# Counted as "at least once", not "exactly once": the refusal names the engine
# and then names the package-manager command that installs it, and pinning the
# count made the guard fail on a better message.
check "preflight(personal) asks about podman" "yes" "$([ "$(_pfr 1)" -ge 1 ] && echo yes || echo no)"
check "preflight(personal, no podman) fails on podman by name" "yes" "$([ "$(_pfr 0)" -ge 1 ] && echo yes || echo no)"
grep -q 'Exasol Personal (local deployment via Podman)' "$ROOT/install.ps1" && \
    check "install.ps1 names the personal plan" present present || \
    check "install.ps1 names the personal plan" present MISSING
# NO RUNTIME DISPATCH ANYWHERE. There is one runtime, so an installer or setup
# script that still branches on a runtime name is carrying a road to somewhere
# that no longer exists.
# COMMENTS ARE NOT DISPATCH. The grep read whole files, so a comment that
# merely NAMES the old runtime's files - saying they are the leftovers an
# install over another kit has to clear - counted as a road to it. Strip the
# comments and the check tests what runs, which is what it always meant to.
_rd=0
for _f in install.sh install.ps1 setup/setup-macos.sh setup/setup-linux.sh setup/setup-windows.ps1; do
    sed -e 's/[[:space:]]*#.*$//' "$ROOT/$_f" \
        | grep -qiE 'nano|EXAKIT_RUNTIME=|RuntimeChoice' && _rd=$((_rd + 1))
done
check "no installer or setup script dispatches on a runtime name" "0" "$_rd"

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
# Sandboxed kit home: on a machine whose REAL install carries a marketplace
# add-on, the installed-addons probe would otherwise read the real manifest
# and legitimately append it to the targets — the fixture wants a clean box.
update_targets="$(bash -c "EXAKIT_HOME=\$(mktemp -d); EXAKIT_BIN_DIR=\"\$EXAKIT_HOME/bin\"; . '$ROOT/setup/lib/common.sh'; exakit_update_targets all" | tr '\n' ' ')"
check "update_targets(all)" "exakit runtime exapump mcp pyexasol skills " "$update_targets"
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
# One row per target, every one of them behind: each must name the version that
# is waiting for it. The rows used to carry an `exakit update <component>`
# command apiece; the merged `exakit version` promotes one command for the whole
# screen instead, so what is counted here is the rows that report an update, not
# the commands they used to print. EXAKIT_VERSION_POLICY is pinned so the harness
# cannot reach the network, and the available versions come from the stub below.
_stub_bin="$(mktemp -d)"
printf '#!/bin/sh\necho "exapump 0.11.2"\n' > "$_stub_bin/exapump"
printf '#!/bin/sh\necho 2.2.2\n' > "$_stub_bin/python"
chmod +x "$_stub_bin/exapump" "$_stub_bin/python"
update_action="$(bash -c "
EXAKIT_VERSION_POLICY=pinned
EXAKIT_HOME=\$(mktemp -d); EXAKIT_BIN_DIR=\"\$EXAKIT_HOME/bin\"
. '$ROOT/setup/lib/common.sh'
# The mcp row probes the REAL AI client configs for their pinned server
# version; on a machine with a live install that pin (e.g. 2.0.0) outruns the
# stub's advertised 1.11.0 and the row flips to 'yours is newer'. The record
# below is the fixture — keep the probe out of the sandbox.
exakit_installed_mcp_version() { return 1; }
manifest_get() {
  case \"\$1\" in
    runtime.type) printf '%s\n' personal ;;
    runtime.version) printf '%s\n' 2.2.0 ;;
    components.exapump.version) printf '%s\n' 0.11.2 ;;
    components.exapump.path) printf '%s\n' '$_stub_bin/exapump' ;;
    components.pyexasol.python) printf '%s\n' '$_stub_bin/python' ;;
    components.mcp_server.version) printf '%s\n' 1.10.1 ;;
    components.pyexasol.version) printf '%s\n' 2.2.2 ;;
    kit.version) printf '%s\n' 0.2.0 ;;
    kit.source) printf '%s\n' example/starter@0.2.0 ;;
    *) return 1 ;;
  esac
}
# The MCP version is read LIVE, so without this the fixture reads whatever MCP this
# machine happens to have installed. The day a real install went past the advertised
# 1.11.0, that turned the mcp row into an installed-is-newer row with an action of
# \"none\" and quietly cost this check one of its five waiting updates.
exakit_installed_mcp_version() { printf '%s\n' 1.10.1 ; }
exakit_component_available() {
  case \"\$1\" in
    personal) printf '%s\n' 2.3.0 ;;
    exapump) printf '%s\n' 0.12.0 ;;
    mcp) printf '%s\n' 1.11.0 ;;
    pyexasol) printf '%s\n' 2.3.0 ;;
    exakit) printf '%s\n' 0.3.0 ;;
  esac
}
exakit_print_version_table
" | grep -c '^  |.* available *|')"
check "version_table(rows_waiting)" "5" "$update_action"

# The runtime is the only heavy target, and a routine `exakit update` must
# announce it instead of stopping the database on its own.
update_plan="$(bash -c "
EXAKIT_VERSION_POLICY=pinned
. '$ROOT/setup/lib/common.sh'
manifest_get() {
  case \"\$1\" in
    runtime.type) printf '%s\n' personal ;;
    runtime.version) printf '%s\n' 2.2.0 ;;
    components.exapump.version) printf '%s\n' 0.11.2 ;;
    kit.version) printf '%s\n' 0.2.0 ;;
    *) return 1 ;;
  esac
}
exakit_component_available() {
  case \"\$1\" in
    personal) printf '%s\n' 2.3.0 ;;
    exapump) printf '%s\n' 0.11.2 ;;
    *) return 1 ;;
  esac
}
exakit_init_logging() { :; }
exakit_update_component() { printf 'APPLIED %s\n' \"\$1\"; }
exakit_update all
" 2>&1)"
if printf '%s' "$update_plan" | grep -q 'needs the database stopped' && \
   ! printf '%s' "$update_plan" | grep -q 'APPLIED runtime'; then
    check "update_all(defers_heavy)" "yes" "yes"
else
    check "update_all(defers_heavy)" "yes" "no"
fi

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
exakit_component_available() { printf '%s\n' 3.0.0; }
personal_update --plan
" 2>&1 | grep -c 'migration/redeployment guidance')"
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
# A DEPLOYMENT OF OURS, which is what this check is about: reuse is now refused
# for a database on the port that the launcher does not own, because Windows and
# WSL share one network stack and the other side's database answers here too.
# The stub directory stands in for the deployment directory the probe reads.
EXAKIT_PERSONAL_DEPLOY_DIR=\"\$_stub_dir\"
# The liveness signal is a completed TLS handshake, not an open port: under
# rootless Podman the port belongs to pasta from the moment the container
# starts. This sandbox has no database to hand, so the handshake is stubbed
# and what is measured stays what this check is about - the guard's decision.
# tests/personal-readiness.sh pins the handshake itself against real servers.
personal_tls_answers() { return 0; }
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
  esac
}
printf '%s %s ' \"\$(exakit_latest_github_release_version owner/repo)\" \"\$(exakit_latest_pypi_version pkg)\"
if exakit_version_newer 3.0.0 2.9.9; then printf yes; else printf no; fi
")"
check "lookup_fallback(no-python)" "9.8.7 6.5.4 yes" "$fallback_versions"

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

# mcp-doctor is what people run when an AI client looks wrong, so it names the one
# command that fixes it. Only doctor: status/validate/repair are not that question.
if grep -q 'doctor) info "Connect or re-connect AI clients any time with:  exakit mcp-setup"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Connect or re-connect AI clients any time with:  exakit mcp-setup' "$ROOT/setup/lib/mcp.ps1"; then
    check "mcp_doctor(names_the_remedy)" "yes" "yes"
else
    check "mcp_doctor(names_the_remedy)" "yes" "no"
fi

echo "install time is shown in the machine's own timezone:"
# The manifest keeps UTC ISO 8601; only the display is localised. TZ is pinned per
# case so the expectation is deterministic on any machine that runs this suite.
for tz_spec in "UTC|2026-07-30T05:50:21Z|July 30, 2026 at 5:50 AM" \
               "Asia/Kolkata|2026-05-03T12:00:00Z|May 3, 2026 at 5:30 PM" \
               "America/New_York|2026-05-03T12:00:00Z|May 3, 2026 at 8:00 AM" \
               "UTC|2026-07-30T00:30:00Z|July 30, 2026 at 12:30 AM" \
               "UTC|2026-07-30T12:05:00Z|July 30, 2026 at 12:05 PM"; do
    tz_name="${tz_spec%%|*}"
    tz_rest="${tz_spec#*|}"
    tz_input="${tz_rest%%|*}"
    tz_want="${tz_rest#*|}"
    tz_got="$(TZ="$tz_name" bash -c ". '$ROOT/setup/lib/common.sh'; exakit_format_local_time '$tz_input'")"
    check "local_time($tz_name)" "$tz_want" "$tz_got"
done
# A timestamp nobody can parse is still better shown than swallowed.
tz_passthrough="$(bash -c ". '$ROOT/setup/lib/common.sh'; exakit_format_local_time 'not-a-date'")"
check "local_time(unparseable passes through)" "not-a-date" "$tz_passthrough"
if grep -q 'exakit_format_local_time "$(manifest_get installed_at' "$ROOT/setup/exakit" && \
   grep -q 'Format-ExakitLocalTime (Get-ExakitManifestValue' "$ROOT/setup/exakit.ps1"; then
    check "local_time(wired on both platforms)" "yes" "yes"
else
    check "local_time(wired on both platforms)" "yes" "no"
fi

echo "self-update staging guard:"
if grep -q 'exakit-kit-stage' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Downloaded starter kit is incomplete' "$ROOT/setup/lib/common.sh" && \
   grep -q 'existing kit copy was left untouched' "$ROOT/setup/lib/common.sh"; then
    check "self_update(staged_validation)" "yes" "yes"
else
    check "self_update(staged_validation)" "yes" "no"
fi
# A successful self-update must record the version that actually landed, not just
# where it came from: exakit_component_current reads kit.version first, so without
# this write the kit reports its old version forever and re-downloads every time.
if grep -q 'manifest_set kit.version "\$_staged_version"' "$ROOT/setup/lib/common.sh"; then
    check "self_update(records_kit_version)" "yes" "yes"
else
    check "self_update(records_kit_version)" "yes" "no"
fi
# main is the primary source (kit scripts live there; a tag exists only where a
# release was cut), and versions.json is on the required list — without it the new
# copy has no offline version tier and cannot say what version it is.
if grep -q 'archive/refs/heads/main.tar.gz' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit-common.ps1 versions.json' "$ROOT/setup/lib/common.sh"; then
    check "self_update(main_and_manifest)" "yes" "yes"
else
    check "self_update(main_and_manifest)" "yes" "no"
fi
# Windows is no longer warn-only: the same flow exists there, including the
# deferred swap for the files this very script runs from.
if grep -q 'function Update-ExakitSelf' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'archive/refs/heads/main.zip' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q '"versions.json"' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Complete-ExakitSelfUpdateDeferred' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Update-ExakitSelf -Advertised' "$ROOT/setup/exakit.ps1"; then
    check "self_update(windows_path)" "yes" "yes"
else
    check "self_update(windows_path)" "yes" "no"
fi

echo "Windows parity guards:"
if command -v pwsh >/dev/null 2>&1; then
    ps_parse="$(pwsh -NoProfile -Command '
      $files = @("setup/lib/exakit-common.ps1","setup/lib/runtime-personal.ps1","setup/lib/mcp.ps1","setup/lib/dash-server.ps1","setup/lib/dbt-exasol.ps1","setup/lib/exasol-vscode.ps1","setup/lib/json-tables.ps1","setup/setup-windows.ps1","setup/exakit.ps1")
      foreach ($f in $files) {
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $f), [ref]$errors)
        if ($errors) { Write-Output "no"; exit 0 }
      }
      Write-Output "yes"
    ' | tr -d '\r')"
    check "powershell(parse)" "yes" "$ps_parse"

    # Default (manifest) policy: the Windows path must resolve to exactly what
    # versions.json advertises. Expectations are read from that file, so a
    # Component bump never means editing this guard. A non-HTTPS endpoint keeps
    # the check offline — it is refused before any connection is attempted — and
    # the kit copy under the temporary home is the document being read.
    _ps_tmp="$(mktemp -d)"
    mkdir -p "$_ps_tmp/home/kit/mcp"
    cp "$ROOT/versions.json" "$_ps_tmp/home/kit/versions.json"
    _read_advertised() { bash -c ". '$ROOT/setup/lib/common.sh'; exakit_versions_value '$1' '$ROOT/versions.json'"; }
    exp_versions="baked $(_read_advertised components.personal.version) $(_read_advertised components.exapump.version) $(_read_advertised components.mcp.version)"
    ps_versions="$(EXAKIT_HOME="$_ps_tmp/home" EXAKIT_BIN_DIR="$_ps_tmp/bin" \
      EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" pwsh -NoProfile -Command '
      . ./setup/lib/exakit-common.ps1
      . ./setup/lib/runtime-personal.ps1
      $env:EXAKIT_PERSONAL_VERSION = ""
      Initialize-ExakitManifest
      Resolve-ExakitInstallVersions
      Write-Output "$($script:VersionsSourceUsed) $env:EXAKIT_PERSONAL_VERSION $script:ExapumpVersion $script:McpVersion"
    ' | tail -1 | tr -d '\r')"
    check "powershell(manifest_policy)" "$exp_versions" "$ps_versions"

    # Any other policy value is the offline branch: the compiled-in constants,
    # compared against the *Fallback variables themselves so this guard has no
    # literals to fall out of date either.
    ps_pinned="$(EXAKIT_HOME="$_ps_tmp/home2" EXAKIT_BIN_DIR="$_ps_tmp/bin2" EXAKIT_VERSION_POLICY=pinned pwsh -NoProfile -Command '
      . ./setup/lib/exakit-common.ps1
      . ./setup/lib/runtime-personal.ps1
      $env:EXAKIT_PERSONAL_VERSION = ""
      Initialize-ExakitManifest
      Resolve-ExakitInstallVersions
      $matchesFallbacks = ($env:EXAKIT_PERSONAL_VERSION -eq $script:PersonalVersionFallback) -and
        ($script:ExapumpVersion -eq $script:ExapumpVersionFallback) -and
        ($script:McpVersion -eq $script:McpVersionFallback) -and
        ($script:PyexasolVersion -eq $script:PyexasolVersionFallback)
      Write-Output "$($script:VersionsSourceUsed) $matchesFallbacks"
    ' | tail -1 | tr -d '\r')"
    rm -rf "$_ps_tmp"
    check "powershell(version_policy_fallback)" "fallback True" "$ps_pinned"
else
    check "powershell(parse)" "skipped" "skipped"
    check "powershell(manifest_policy)" "skipped" "skipped"
    check "powershell(version_policy_fallback)" "skipped" "skipped"
fi
# The live-lookup helpers stay in the library: `latest` policy is still supported.
if grep -q 'Resolve-ExakitInstallVersions' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Get-ExakitLatestGithubRelease' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitLatestPypiVersion' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "windows_install(latest_resolution)" "yes" "yes"
else
    check "windows_install(latest_resolution)" "yes" "no"
fi
if grep -q 'Update-ExakitVersionsCache' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitVersionsValue' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Update-ExakitSelf' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Set-ExakitCmdShim' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Get-ExakitKitVersionAt' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Get-ExapumpExpectedSha256' "$ROOT/setup/lib/exapump.ps1"; then
    check "windows_install(manifest_wiring)" "yes" "yes"
else
    check "windows_install(manifest_wiring)" "yes" "no"
fi
# Soft-failing components, both sides. A component that dies must not take the run
# down with it: the exakit command is installed last, and without it a user whose
# exapump download broke has no way to repair anything.
if grep -q 'exakit_soft_step exapump' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_soft_step mcp' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_soft_step pyexasol' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_print_soft_failures' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Invoke-ExakitSoftStep -Component "exapump"' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Invoke-ExakitSoftStep -Component "mcp"' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Invoke-ExakitSoftStep -Component "pyexasol"' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Write-ExakitSoftFailures' "$ROOT/setup/setup-windows.ps1"; then
    check "install(components_soft_fail)" "yes" "yes"
else
    check "install(components_soft_fail)" "yes" "no"
fi
echo "runtime self-heal (exakit_ensure_runtime_running):"
# The four states, against stubbed runtime helpers: running is left alone,
# stopped is started and health-checked, missing is deployed only when the
# caller allows it and refused with the remedy otherwise.
heal_case() { # heal_case <running> <exists> <deploy-arg> — echoes the calls made
    bash -c '
        EXAKIT_HOME="$(mktemp -d)"; EXAKIT_BIN_DIR="$EXAKIT_HOME/bin"
        . "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1
        manifest_get() { [ "$1" = runtime.type ] && echo personal; }
        personal_deployment_running() { return '"$1"'; }
        personal_deployment_exists()  { return '"$2"'; }
        personal_start()       { printf "start "; }
        # The self-heal asks for the REPAIRING wait now: a start the launcher
        # accepted without acting on is finished by its own deploy, and this is
        # the function that does that. personal_wait_ready is still stubbed,
        # and still not what this path calls - which is the point.
        personal_wait_ready()  { printf "plain-wait "; }
        personal_wait_ready_or_deploy() { printf "wait "; }
        personal_repair_command() { printf "exakit repair-runtime"; }
        personal_deploy_local(){ printf "deploy "; }
        info() { :; }; die() { printf "die"; exit 1; }
        exakit_ensure_runtime_running '"$3"'
        rm -rf "$EXAKIT_HOME"
    ' 2>/dev/null
}
check "self_heal(running -> untouched)"        ""            "$(heal_case 0 0 "")"
check "self_heal(stopped -> start + repairing wait)" "start wait " "$(heal_case 1 0 "")"
check "self_heal(missing + deploy -> deploys)" "deploy "     "$(heal_case 1 1 deploy)"
check "self_heal(missing, no deploy -> dies)"  "die"         "$(heal_case 1 1 "")"
# ...and the commands that speak SQL actually use it, on both sides.
if grep -q 'exakit_ensure_runtime_running$' "$ROOT/setup/lib/common.sh" >/dev/null 2>&1 || \
   grep -q 'exakit_ensure_runtime_running' <(awk '/^exakit_mcp_setup\(\)/,/^}/' "$ROOT/setup/lib/common.sh") && \
   grep -q 'exakit_ensure_runtime_running deploy' "$ROOT/setup/exakit" && \
   grep -q 'Confirm-ExakitRuntimeRunning' "$ROOT/setup/lib/mcp.ps1" && \
   grep -q 'Confirm-ExakitRuntimeRunning -Deploy' "$ROOT/setup/exakit.ps1"; then
    check "self_heal(wired_into_sql_commands)" "yes" "yes"
else
    check "self_heal(wired_into_sql_commands)" "yes" "no"
fi

# A re-run over an existing install must START a stopped database, not skip
# the step: everything after it talks SQL, and skipping used to surface as
# "Connection refused" in the MCP user creation. All three installers, same
# behaviour.
if grep -q 'personal_deployment_running' "$ROOT/setup/setup-macos.sh" && \
   grep -q 'personal_start' "$ROOT/setup/setup-macos.sh" && \
   grep -q 'personal_wait_ready' "$ROOT/setup/setup-macos.sh" && \
   grep -q '! personal_deployment_running' "$ROOT/setup/setup-linux.sh" && \
   grep -q '(Test-PersonalDeploymentRunning)' "$ROOT/setup/setup-windows.ps1"; then
    check "install(rerun_starts_stopped_runtime)" "yes" "yes"
else
    check "install(rerun_starts_stopped_runtime)" "yes" "no"
fi
# ...and setup-linux.sh carries the same resume shape the macOS script does: redeploy what is gone (disarming the registered destroy by
# hand), start what is merely stopped.
if grep -q 'personal_deployment_exists' "$ROOT/setup/setup-linux.sh" && \
   grep -q 'personal_deployment_running' "$ROOT/setup/setup-linux.sh" && \
   grep -q 'personal_wait_ready' "$ROOT/setup/setup-linux.sh" && \
   grep -q 'rollback_clear' "$ROOT/setup/setup-linux.sh"; then
    check "install(linux personal resume matches macos)" "yes" "yes"
else
    check "install(linux personal resume matches macos)" "yes" "no"
fi

# The marketplace, both sides. The registry, the installed-only gate on
# `update all`, the command dispatch, and the dash-server module twins must
# exist on each side, or the Windows path silently loses the add-on layer.
if grep -q 'exakit_marketplace_addons()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_marketplace_installed_addons' "$ROOT/setup/lib/common.sh" && \
   grep -q 'dash_server_update' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'dash_server_install' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'marketplace) shift; .*_with_notice cmd_marketplace' "$ROOT/setup/exakit" && \
   grep -q 'function Get-ExakitMarketplaceAddons' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitMarketplaceInstalledAddons' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Update-DashServer' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'function Install-DashServer' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'exasol_vscode_update' "$ROOT/setup/lib/exasol-vscode.sh" && \
   grep -q 'exasol_vscode_install' "$ROOT/setup/lib/exasol-vscode.sh" && \
   grep -q 'function Update-ExasolVscode' "$ROOT/setup/lib/exasol-vscode.ps1" && \
   grep -q 'function Install-ExasolVscode' "$ROOT/setup/lib/exasol-vscode.ps1" && \
   grep -q '"exasol-vscode"' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'json_tables_update' "$ROOT/setup/lib/json-tables.sh" && \
   grep -q 'json_tables_install' "$ROOT/setup/lib/json-tables.sh" && \
   grep -q 'function Update-JsonTables' "$ROOT/setup/lib/json-tables.ps1" && \
   grep -q 'function Install-JsonTables' "$ROOT/setup/lib/json-tables.ps1" && \
   grep -q '"json-tables"' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'dbt_exasol_update' "$ROOT/setup/lib/dbt-exasol.sh" && \
   grep -q 'dbt_exasol_install' "$ROOT/setup/lib/dbt-exasol.sh" && \
   grep -q 'function Update-DbtExasol' "$ROOT/setup/lib/dbt-exasol.ps1" && \
   grep -q 'function Install-DbtExasol' "$ROOT/setup/lib/dbt-exasol.ps1" && \
   grep -q '"dbt-exasol"' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q '"marketplace"  { Invoke-CmdMarketplace' "$ROOT/setup/exakit.ps1"; then
    check "marketplace(twins)" "yes" "yes"
else
    check "marketplace(twins)" "yes" "no"
fi
# The advertised-version resolver an add-on install needs, both sides. On the
# shell side exakit_component_available lives in common.sh, so the setup script
# and the CLI both have it. On the PowerShell side its twin,
# Get-ExakitComponentAvailable, is defined in the CLI (setup/exakit.ps1) and the
# SETUP script never loads the CLI — so an add-on Install-* that called it
# directly died with a CommandNotFoundException the moment the closing
# marketplace offer tried to install one, and every Windows add-on install
# failed while macOS was fine. Get-ExakitAddonAdvertisedVersion is what answers
# in both contexts; the Install-* functions must go through it.
if grep -q 'function Get-ExakitAddonAdvertisedVersion' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitAddonAdvertisedVersion -Id "exasol-vscode"' "$ROOT/setup/lib/exasol-vscode.ps1" && \
   grep -q 'Get-ExakitAddonAdvertisedVersion -Id "dash-server"' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'exakit_component_available' "$ROOT/setup/lib/common.sh"; then
    check "marketplace(addon_version_resolver)" "yes" "yes"
else
    check "marketplace(addon_version_resolver)" "yes" "no"
fi

# JSON Tables on Windows. The add-on used to be gate-only there: upstream
# reaches its engine solely through `subprocess.run(["cargo", "run", ...])`, and
# CreateProcess resolves a bare name by appending .exe only — never PATHEXT — so
# the /bin/sh cargo shim that works on macOS and Linux is invisible on Windows.
# The answer is a COMPILED shim, built by the packaging workflow from this
# repository. Guard every piece of that chain: without any one of them the
# add-on is either hidden again or installs an engine nothing can reach.
if [ -d "$ROOT/setup/shim/json-tables-cargo" ] && \
   grep -q 'name = "cargo"' "$ROOT/setup/shim/json-tables-cargo/Cargo.toml" && \
   grep -q 'fn is_ingest_call' "$ROOT/setup/shim/json-tables-cargo/src/main.rs" && \
   grep -q 'json-tables-cargo/Cargo.toml' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   grep -q 'exakit-json-tables-cargo-windows-x86_64.exe' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   grep -q 'function Get-JsonTablesShimAsset' "$ROOT/setup/lib/json-tables.ps1" && \
   grep -q 'function Write-JsonTablesLauncher' "$ROOT/setup/lib/json-tables.ps1" && \
   grep -q 'function Get-JsonTablesMirrorDigest' "$ROOT/setup/lib/json-tables.ps1" && \
   grep -q 'function Test-JsonTablesAppControl' "$ROOT/setup/lib/json-tables.ps1"; then
    check "json-tables(windows_shim)" "yes" "yes"
else
    check "json-tables(windows_shim)" "yes" "no"
fi
# ...and that the module no longer reports itself unavailable unconditionally,
# which is what the stub did.
if grep -q 'return ((Get-JsonTablesEngineAsset) -ne "")' "$ROOT/setup/lib/json-tables.ps1"; then
    check "json-tables(windows_applicable)" "yes" "yes"
else
    check "json-tables(windows_applicable)" "yes" "no"
fi

# The PowerShell shared layer must be SELF-SUFFICIENT for an install.
#
# setup/exakit.ps1 is the CLI. setup/setup-windows.ps1 is the installer,
# and it dot-sources setup/lib/exakit-common.ps1 plus the component and add-on
# modules — never the CLI. So a function defined only in the CLI is invisible
# during an install, and calling it there dies with CommandNotFoundException.
#
# That asymmetry produced the same bug three times in one week, each time in
# front of a first-time user: every Windows add-on install failing at the
# closing offer, the marketplace table printing "unknown" for every version,
# and a freshly installed service add-on never joining the boot set. The shell
# side cannot have this class of bug — common.sh holds these functions and
# every entry point sources it.
#
# This recomputes the leak set: functions DEFINED in the CLI and REFERENCED by
# a file the installer loads. It must be empty. The fix for a failure here is
# to MOVE the function into exakit-common.ps1, not to wrap the call in another
# `Get-Command ... -ErrorAction SilentlyContinue`.
if command -v python3 >/dev/null 2>&1; then
    _ps_leak="$(python3 - "$ROOT" <<'LEAKEOF'
import io, os, re, sys, glob
root = sys.argv[1]

def defs(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return set(re.findall(r'(?im)^\s*function\s+([A-Za-z][\w-]*)', fh.read()))

cli = os.path.join(root, "setup", "exakit.ps1")
shared = os.path.join(root, "setup", "lib", "exakit-common.ps1")
modules = [p for p in glob.glob(os.path.join(root, "setup", "lib", "*.ps1"))
           if os.path.basename(p) not in ("exakit-common.ps1", "ui.ps1")]

cli_funcs = defs(cli)
elsewhere = defs(shared) | defs(os.path.join(root, "setup", "lib", "ui.ps1"))
for m in modules:
    elsewhere |= defs(m)
cli_only = cli_funcs - elsewhere

loaded = [shared] + modules + [os.path.join(root, "setup", "setup-windows.ps1")]
leaked = set()
for path in loaded:
    if not os.path.exists(path):
        continue
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        text = re.sub(r'(?m)^\s*#.*$', '', fh.read())
    for fn in cli_only:
        if re.search(r'(?<![\w-])' + re.escape(fn) + r'(?![\w-])', text):
            leaked.add(fn)
print(" ".join(sorted(leaked)))
LEAKEOF
)"
    if [ -z "$_ps_leak" ]; then
        check "powershell(no_cli_only_leak)" "yes" "yes"
    else
        check "powershell(no_cli_only_leak)" "yes" "no ($_ps_leak)"
    fi
else
    echo "  SKIP  powershell(no_cli_only_leak) — no python3 on this machine"
fi

# A GENERATED .cmd MUST NOT PUT A BRACKETED if-BLOCK AROUND TEXT IT DOES NOT
# CONTROL.
#
# cmd parses `if ( ... )` by scanning for the closing paren and does not care
# that the one it finds sits inside an echo. The dash-server launcher printed
# "already running: http://127.0.0.1:5100 (MCP: /mcp)" inside such a block, so
# the ")" in "(MCP: /mcp)" closed it early: the first echo was swallowed and the
# two lines meant to be conditional - the State line and `exit /b 0` - ran
# UNCONDITIONALLY. The launcher exited 0 every time WITHOUT STARTING THE SERVER,
# on a fresh install and on `exakit start` alike, leaving a log with exactly one
# line in it that read as if all was well.
#
# The shape is the fix: `goto` has no body to terminate, so no punctuation in
# any of those lines can break the control flow again. Escaping the parens would
# have fixed that one message and left the trap set for the next edit.
#
# Guarded by shape, not by message: any bracketed `if ... (` in the launcher
# generator is the hazard, whatever it happens to print today.
if grep -q 'if errorlevel 1 goto exakit_dash_start' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q ':exakit_dash_start' "$ROOT/setup/lib/dash-server.ps1" && \
   ! grep -qE '"if (not )?errorlevel [0-9]+ \("' "$ROOT/setup/lib/dash-server.ps1"; then
    check "dash-server(launcher_no_bracket_block)" "yes" "yes"
else
    check "dash-server(launcher_no_bracket_block)" "yes" "no"
fi

# Port ownership, both sides: a foreign listener must never read as a running
# dash-server, and the install must settle on a port before baking one in.
if grep -q '_dash_server_port_is_ours()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q '_dash_server_port_foreign_desc()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q '_dash_server_settle_port()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'function Test-DashServerPortIsOurs' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'function Get-DashServerPortForeignDescription' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'function Confirm-DashServerPort' "$ROOT/setup/lib/dash-server.ps1"; then
    check "dash-server(port_ownership_twins)" "yes" "yes"
else
    check "dash-server(port_ownership_twins)" "yes" "no"
fi

# Log viewing, both sides: the registry-driven target list, the overview, the
# tail/follow path, and the add-on hook that folds a new one in.
if grep -q 'exakit_log_targets()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_logs_overview()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_logs_show()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'dash_server_log_path()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'function Get-ExakitLogTargets' "$ROOT/setup/exakit.ps1" && \
   grep -q 'function Show-ExakitLogsOverview' "$ROOT/setup/exakit.ps1" && \
   grep -q 'function Show-ExakitLog' "$ROOT/setup/exakit.ps1" && \
   grep -q 'function Get-DashServerLogPath' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'LogFn' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "logs(viewer_twins)" "yes" "yes"
else
    check "logs(viewer_twins)" "yes" "no"
fi

# Services and autostart, both sides: the registry-driven service set, the
# start/stop/status hooks, the boot registration, and the autostart command.
if grep -q 'exakit_service_ids()' "$ROOT/setup/lib/common.sh" && \
   grep -q '_exakit_autostart_register()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_autostart_enable()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'dash_server_status()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'dash_server_start()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'dash_server_autostart_command()' "$ROOT/setup/lib/dash-server.sh" && \
   grep -q 'autostart) shift; _with_notice cmd_autostart' "$ROOT/setup/exakit" && \
   grep -q 'function Get-ExakitServiceIds' "$ROOT/setup/exakit.ps1" && \
   grep -q 'function Register-ExakitAutostart' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Enable-ExakitAutostart' "$ROOT/setup/exakit.ps1" && \
   grep -q 'function Get-DashServerStatus' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q 'function Start-DashServer' "$ROOT/setup/lib/dash-server.ps1" && \
   grep -q '"autostart"    { Invoke-CmdAutostart' "$ROOT/setup/exakit.ps1"; then
    check "services(autostart_twins)" "yes" "yes"
else
    check "services(autostart_twins)" "yes" "no"
fi
# The install turns it on, and the uninstall takes the boot entries away.
if grep -q 'exakit_autostart_enable' <(awk '/^kit_shared_steps\(\)/,/^}/' "$ROOT/setup/lib/common.sh") && \
   grep -q '_exakit_autostart_unregister' <(awk '/^exakit_uninstall_run\(\)/,/^}/' "$ROOT/setup/lib/common.sh") && \
   grep -q 'Unregister-ExakitAutostart' "$ROOT/setup/exakit.ps1"; then
    check "services(autostart_install_and_sweep)" "yes" "yes"
else
    check "services(autostart_install_and_sweep)" "yes" "no"
fi

# The closing marketplace offer, all three installers: shown after everything
# ran, and its core is shared (common.sh / exakit-common.ps1), not duplicated.
if grep -q 'exakit_marketplace_offer' "$ROOT/setup/setup-macos.sh" && \
   grep -q 'exakit_marketplace_offer' "$ROOT/setup/setup-linux.sh" && \
   grep -q 'Request-ExakitMarketplaceOffer' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'exakit_marketplace_offer()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'function Request-ExakitMarketplaceOffer' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "marketplace(closing_offer)" "yes" "yes"
else
    check "marketplace(closing_offer)" "yes" "no"
fi
# The marketplace must stay OUT of the install steps: no setup script may
# INSTALL the dash-server module (the Windows script dot-sources it and the
# offer runs after everything else, but no step invokes Install-DashServer /
# dash_server_install directly), and no shared step may install it.
if ! grep -qE 'dash_server_install|exasol_vscode_install|json_tables_install' "$ROOT/setup/setup-macos.sh" && \
   ! grep -qE 'dash_server_install|exasol_vscode_install|json_tables_install' "$ROOT/setup/setup-linux.sh" && \
   ! grep -qE 'Install-DashServer|Install-ExasolVscode|Install-JsonTables' "$ROOT/setup/setup-windows.ps1" && \
   ! grep -qE 'dash_server_install|exasol_vscode_install|json_tables_install' <(awk '/^kit_shared_steps\(\)/,/^}/' "$ROOT/setup/lib/common.sh"); then
    check "marketplace(not_in_install_flow)" "yes" "yes"
else
    check "marketplace(not_in_install_flow)" "yes" "no"
fi

# json-tables: the no-Rust chain. The packaging workflow builds the engine and
# the wheel, publishes them as one immutable json-tables-<version> release (a
# fixed rolling tag is exactly the shape that broke: overwritten binaries under
# pinned digests), the module downloads them from the release versions.json
# names and puts a cargo shim in front of the CLI, and versions.json is only
# bumped AFTER a successful publish -- so no installed kit is ever offered a
# version whose artifacts do not exist. Each of those is load-bearing.
if grep -q 'tag_name: ${{ needs.check.outputs.tag }}' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   ! grep -q 'tag_name: mirror-json-tables' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   grep -q 'version=${{ needs.check.outputs.sha }}' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   grep -qE '^  advertise:' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   grep -q 'needs: \[check, publish\]' "$ROOT/.github/workflows/pkg-json-tables.yml" && \
   grep -q 'json_tables_write_shim()' "$ROOT/setup/lib/json-tables.sh" && \
   grep -q 'json_tables_latest()' "$ROOT/setup/lib/json-tables.sh" && \
   grep -q 'json_tables_system_present()' "$ROOT/setup/lib/json-tables.sh" && \
   grep -q 'exakit_data_file_kind()' "$ROOT/setup/lib/exapump.sh" && \
   grep -q 'exakit_load_local_json()' "$ROOT/setup/lib/exapump.sh"; then
    check "json_tables(prebuilt_chain)" "yes" "yes"
else
    check "json_tables(prebuilt_chain)" "yes" "no"
fi

# Agent operability, both sides: the exit-code contract on status
# (0/3/4), --json on status and mcp-doctor, the runtime probe that makes
# mcp-doctor diagnose a stopped database instead of a broken MCP user, the
# allowlist merge skills-install performs, the DB error translator, and the
# datasets surfaced in status. Each is a machine-facing promise an agent
# branches on -- a twin that quietly lost one would strand Windows agents.
if grep -q 'exakit_runtime_is_running()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_loaded_datasets()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_apply_readonly_allowlist()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_explain_db_error()' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exit 3' "$ROOT/setup/exakit" && \
   grep -q 'exit 4' "$ROOT/setup/exakit" && \
   grep -q 'function Get-ExakitLoadedDatasets' "$ROOT/setup/exakit.ps1" && \
   grep -q 'function Set-ExakitReadonlyAllowlist' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'exit 3' "$ROOT/setup/exakit.ps1" && \
   grep -q 'exit 4' "$ROOT/setup/exakit.ps1" && \
   grep -q 'EXAKIT_MCP_RESULT_JSON' "$ROOT/setup/lib/common.sh" && \
   grep -q 'EXAKIT_MCP_RESULT_JSON' "$ROOT/setup/lib/mcp.ps1"; then
    check "agent_operability(twins)" "yes" "yes"
else
    check "agent_operability(twins)" "yes" "no"
fi

# Release notes, both sides: the command, the print after a self-update, and the
# card file travelling into the kit copy (without that last part `exakit whats-new`
# works from a checkout and then dies with it). setup/whats-new.json lives under
# setup/, and only setup/lib is staged, so the copy has to name it explicitly.
if grep -q 'cmd_whats_new' "$ROOT/setup/exakit" && \
   grep -q 'exakit_whats_new_file' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_print_whats_new "$_staged_version"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'setup/whats-new.json" "$EXAKIT_HOME/kit/setup/' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Invoke-CmdWhatsNew' "$ROOT/setup/exakit.ps1" && \
   grep -q 'Get-ExakitWhatsNewFile' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Write-ExakitWhatsNew -Version $stagedVersion' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'whats-new.json' "$ROOT/setup/setup-windows.ps1" && \
   [ -f "$ROOT/setup/whats-new.json" ]; then
    check "whats_new(both_sides)" "yes" "yes"
else
    check "whats_new(both_sides)" "yes" "no"
fi
# The upgrade box, both sides: the record taken before kit.version is overwritten,
# and the box that reads it. Both halves have to exist on both platforms or one of
# them announces an upgrade the other stays silent about.
if grep -q 'exakit_note_kit_upgrade() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_whats_new_versions() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_whats_new_points() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_print_whats_new_box() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_note_kit_upgrade "$KIT_ROOT"' "$ROOT/setup/setup-macos.sh" && \
   grep -q 'exakit_note_kit_upgrade "$KIT_ROOT"' "$ROOT/setup/setup-linux.sh" && \
   grep -q 'function Set-ExakitKitUpgradeNote {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Get-ExakitWhatsNewVersions {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Get-ExakitWhatsNewPoints {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Write-ExakitWhatsNewBox {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Set-ExakitKitUpgradeNote -KitRoot $KitRoot' "$ROOT/setup/setup-windows.ps1"; then
    check "whats_new_box(both_sides)" "yes" "yes"
else
    check "whats_new_box(both_sides)" "yes" "no"
fi
# Placement, on all three platforms: after the connection details, before the
# closing line. Anywhere earlier and the connection panel pushes the box off the
# screen, which is the whole reason it moved out of the step output.
#
# Anchored on "for support", the one phrase the closing line keeps on all three
# platforms. It used to anchor on "Next: exakit status" and that wording is gone
# - an anchor tied to a sentence breaks the moment the sentence is reworded, and
# what this guard actually cares about is only WHERE that line sits.
wn_box_placement() { # wn_box_placement <file> <panel-call> <box-call>
    awk -v panel="$2" -v box="$3" '
        index($0, panel) && panel_at == 0 { panel_at = NR }
        index($0, box)   && box_at == 0   { box_at = NR }
        index($0, "for support") && next_at == 0 { next_at = NR }
        END {
            if (panel_at > 0 && box_at > panel_at && next_at > box_at) print "panel,box,next"
            else printf "panel=%d box=%d next=%d\n", panel_at, box_at, next_at
        }
    ' "$1"
}
check "whats_new_box(order_macos)" "panel,box,next" \
    "$(wn_box_placement "$ROOT/setup/setup-macos.sh" \
        'connection_summary' 'exakit_print_whats_new_box "$KIT_ROOT"')"
check "whats_new_box(order_wsl)" "panel,box,next" \
    "$(wn_box_placement "$ROOT/setup/setup-linux.sh" \
        'connection_summary' 'exakit_print_whats_new_box "$KIT_ROOT"')"
check "whats_new_box(order_windows)" "panel,box,next" \
    "$(wn_box_placement "$ROOT/setup/setup-windows.ps1" \
        'Show-ExakitConnectionSummary' 'Write-ExakitWhatsNewBox -KitRoot')"
# The short help is the only command list most people ever read: a bare `exakit`,
# `exakit help` and any unknown command all print it, while the full reference is
# behind `--all`. Staying current has to be visible there, or the update path
# exists and nobody finds it. The bash half is run for real; the PowerShell half
# is a mirrored string array, so it is read.
short_help="$(EXAKIT_NO_UPDATE_NOTICE=1 bash "$ROOT/setup/exakit" help 2>&1 || true)"
ps_help_lines=0
# _ui_visible_len measures what the user SEES, and ui_panel_end uses it twice:
# once to pick the box width, once to pad each line. It used a BRE alternation
# `\|` to accept either OSC 8 terminator -- a GNU sed extension that BSD sed
# ignores -- so on macOS a hyperlinked line returned its RAW byte length, became
# the widest line, blew the box out to 124 columns and closed its own border
# early. Escapes are built LITERALLY here on purpose: sourcing ui.sh re-derives
# UI_FANCY from `-t 1`, so calling ui_link in a piped test emits plain text and
# would prove nothing at all.
vis_probe="$(
    . "$ROOT/setup/lib/ui.sh" 2>/dev/null
    _v_two="$(printf 'SQL client:   \033]8;;https://dbeaver.io/download/\033\\DBeaver\033]8;;\033\\ or \033]8;;https://www.dbvis.com/download/\033\\DbVisualizer\033]8;;\033\\')"
    _v_bel="$(printf 'x \033]8;;http://a\007L\033]8;;\007 y')"
    _v_sgr="$(printf '\033[1mbold\033[0m plain')"
    printf '%s %s %s %s' "$(_ui_visible_len "SQL client:   DBeaver or DbVisualizer")" \
        "$(_ui_visible_len "$_v_two")" "$(_ui_visible_len "$_v_bel")" "$(_ui_visible_len "$_v_sgr")"
)"
check "visible_len(plain two-link BEL SGR)" "37 37 5 10" "$vis_probe"

# The helper being right is not the same as the BOX being right, so assert the
# rendered rows: every row of a panel containing a hyperlink must be equal width.
panel_widths="$(
    . "$ROOT/setup/lib/ui.sh" 2>/dev/null
    UI_FANCY=1
    _p_link="$(printf 'SQL client:   \033]8;;https://dbeaver.io/download/\033\\DBeaver\033]8;;\033\\ or \033]8;;https://www.dbvis.com/download/\033\\DbVisualizer\033]8;;\033\\')"
    ui_panel_begin "Connection details"
    ui_panel_line "Logs:         ~/.exasol-starter-kit/logs"
    ui_panel_line "$_p_link"
    ui_panel_line "More info:    exakit guide"
    ui_panel_end
)"
# strip every escape, then count distinct rendered row lengths: 1 means aligned
distinct="$(printf '%s\n' "$panel_widths" | LC_ALL=C sed \
    -e 's/'"$(printf '\033')"'\[[0-9;]*m//g' \
    -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\007')"'//g' \
    -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\033')"'\\//g' \
    | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')"
check "panel(hyperlinked rows all one width)" "1" "$distinct"

# The update path has to reach the user from the help screen. Both CLIs now
# render that screen from setup/help/exakit.json, so "both sides" is a property
# of the document plus each side reading it - not of two hardcoded lists that
# could drift. Assert all three: the document declares the group, the bash
# screen shows it, and the PowerShell CLI renders from the same documents.
_upd_group="$(python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
groups = [g for g in doc['groups'] if g['title'] == 'Keeping up to date']
print(' '.join(groups[0]['commands']) if groups else '')" 2>/dev/null || true)"
# update-check is absent because the command is: it was merged into `exakit
# version`, so the group is version + update and the count below is one lower
# than it once was.
for _hl in version update; do
    printf '%s' "$_upd_group" | grep -qw "$_hl" && ps_help_lines=$((ps_help_lines + 1))
done
grep -q 'Show-ExakitHelpOverview' "$ROOT/setup/exakit.ps1" && ps_help_lines=$((ps_help_lines + 1))
if printf '%s' "$short_help" | grep -q 'Keeping up to date' && \
   printf '%s' "$short_help" | grep -qE '^ +exakit version {2,}' && \
   printf '%s' "$short_help" | grep -qE '^ +exakit update {2,}' && \
   [ "$ps_help_lines" = 3 ]; then
    check "help(update_path_listed_both_sides)" "yes" "yes"
else
    check "help(update_path_listed_both_sides)" "yes" "no"
fi
# `exakit info --json` is the machine-readable surface: the install record, byte for
# byte, and nothing else on stdout. Two things break that - re-serialising it (the
# output would be free to disagree with the file), and anything printing alongside
# it. The update notice is the standing risk there, which is why the json branch
# stays outside `_with_notice` and sets $script:JsonOutput on the PowerShell side.
# Missing record: exit 4 and a MACHINE-READABLE object naming the remedy. An
# empty stdout was the old behaviour and it broke the contract exactly where it
# matters -- a caller piping --json into a parser got "Expecting value: line 1
# column 1" instead of an answer it could branch on.
_ij="$(mktemp -d)"
mkdir -p "$_ij/have" "$_ij/none"
printf '{\n  "kit": {\n    "version": "0.2.0"\n  }\n}\n' > "$_ij/have/manifest.json"
_ij_out="$(EXAKIT_HOME="$_ij/have" bash "$ROOT/setup/exakit" info --json 2>"$_ij/err")"
_ij_alias="$(EXAKIT_HOME="$_ij/have" bash "$ROOT/setup/exakit" info -j 2>/dev/null)"
_ij_none="$(EXAKIT_HOME="$_ij/none" bash "$ROOT/setup/exakit" info --json 2>/dev/null)"; _ij_rc=$?
# The record PLUS the keys every state query carries (installed/status/remedy,
# and remedy_hint when the remedy needs explaining) and the `skills` verdict
# block: strip those and what is left must be the manifest.
if python3 -c 'import json,sys; d=json.loads(sys.argv[2]); r=json.load(open(sys.argv[1])); [d.pop(k, None) for k in ("installed","status","remedy","remedy_hint","skills")]; sys.exit(0 if d == r else 1)' "$_ij/have/manifest.json" "$_ij_out" && \
   [ "$_ij_alias" = "$_ij_out" ] && \
   [ ! -s "$_ij/err" ] && \
   printf '%s' "$_ij_none" | python3 -m json.tool >/dev/null 2>&1 && \
   case "$_ij_none" in *'"remedy"'*) true ;; *) false ;; esac && \
   [ "$_ij_rc" = 4 ] && \
   grep -q 'cmd_info_json' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_info_json' "$ROOT/setup/exakit" && \
   grep -q 'Invoke-CmdInfoJson' "$ROOT/setup/exakit.ps1" && \
   grep -q 'JsonOutput = \$true' "$ROOT/setup/exakit.ps1" && \
   grep -q 'if (-not \$script:JsonOutput -and' "$ROOT/setup/exakit.ps1" && \
   grep -qF 'Get-Content -Raw -Encoding UTF8 -Path $script:ManifestPath' "$ROOT/setup/exakit.ps1"; then
    check "info(json_is_the_record_verbatim)" "yes" "yes"
else
    check "info(json_is_the_record_verbatim)" "yes" "no"
fi
rm -rf "$_ij"
# Bounded probes, both sides. An engine probe does not return while the engine
# is still starting, and a wedged launcher does not return at all, so every
# read-path probe has to be able to give up. The PowerShell half must use
# .Arguments and not .ArgumentList, which exists only on .NET Core and would
# throw on the Windows PowerShell 5.1 these scripts support.
if grep -q 'exakit_run_bounded' "$ROOT/setup/lib/common.sh" && \
   grep -q '_detect_engine_probe podman info' "$ROOT/setup/lib/detect.sh" && \
   grep -q 'Invoke-ExakitBounded' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Invoke-ExakitBounded' "$ROOT/setup/lib/runtime-personal.ps1" && \
   grep -q '\$info\.Arguments = ' "$ROOT/setup/lib/exakit-common.ps1" && \
   ! grep -qE '\$info\.ArgumentList' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "engine_probe(bounded_both_sides)" "yes" "yes"
else
    check "engine_probe(bounded_both_sides)" "yes" "no"
fi
# The notice plan cache, both sides. Keyed on content rather than mtime, because
# bash compares mtimes by the second and an update that rewrote the manifest in the
# same second the plan was written would otherwise look fresh.
if grep -q '_exakit_notice_plan_fresh' "$ROOT/setup/lib/common.sh" && \
   grep -q '_exakit_notice_signature' "$ROOT/setup/lib/common.sh" && \
   grep -q 'cksum "$EXAKIT_MANIFEST"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Test-ExakitNoticePlanFresh' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitNoticeSignature' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-FileHash' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q '_exakit_notice_still_behind' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Get-ExakitNoticeStillBehind' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'rm -f "$EXAKIT_NOTICE_PLAN"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Remove-Item -Force $script:NoticePlanPath' "$ROOT/setup/exakit.ps1"; then
    check "notice(plan_cached_both_sides)" "yes" "yes"
else
    check "notice(plan_cached_both_sides)" "yes" "no"
fi
# Re-run freshness, both sides: the exakit_helper flag says "installed", not
# "current", so a re-run over an older install has to compare what is on disk with
# what this kit would write. bash compares the installed COPY of setup/exakit; the
# Windows shim only points at the kit copy, so there it is the shim's own content.
# The behavioural halves live in tests/versions-manifest.sh.
if grep -q 'cmp -s "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Test-ExakitCmdShimCurrent' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Test-ExakitCmdShimCurrent' "$ROOT/setup/setup-windows.ps1" && \
   grep -q 'Get-ExakitCmdShimContent' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "rerun(refreshes_stale_command)" "yes" "yes"
else
    check "rerun(refreshes_stale_command)" "yes" "no"
fi
# The Kit 2 surface: both wrappers, the update target, and the Windows answer.
# Kit 2 stays off the help screen and off `catalog --json` - but by being marked
# "hidden": true in setup/help/exakit.json, not by being absent from it. A
# command in the dispatcher and in NO document at all is one an agent can only
# find by reading the source (the audit's AGK-10); hidden gives it a page that
# `exakit upgrade-kit2 --help` answers with while keeping it out of discovery.
# Whether Kit 2 is ADVERTISED is a separate switch (the kit2 block in
# versions.json) and is asserted in tests/versions-manifest.sh.
if grep -q 'upgrade-kit2)  cmd_kit2_script' "$ROOT/setup/exakit" && \
   grep -q 'rollback-kit2) cmd_kit2_script' "$ROOT/setup/exakit" && \
   grep -q 'exakit_update_kit2' "$ROOT/setup/lib/common.sh" && \
   grep -q 'manifest_set kit2.version' "$ROOT/upgrade/upgrade-kit2.sh" && \
   python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for name in ("upgrade-kit2", "rollback-kit2"):
    entry = [c for c in doc["commands"] if c["command"] == name]
    assert entry and entry[0].get("hidden") is True, name
' "$ROOT/setup/help/exakit.json" && \
   bash "$ROOT/setup/exakit" catalog --json 2>/dev/null | python3 -c '
# OUT OF DISCOVERY, NOT OUT OF THE DOCUMENT. This used to assert the string was
# absent from catalog --json altogether, which contradicted AGENTS.md ("a
# handful of internal upgrade paths are marked hidden") and meant no row
# carried a hidden key at all. The machine surface discloses them with the
# flag; the SCREENS are what must not advertise them, and that is asserted
# just below.
import json, sys
d = json.load(sys.stdin)
by = {r["invocation"]: r for r in d["commands"]}
for name in ("exakit upgrade-kit2", "exakit rollback-kit2"):
    assert by.get(name, {}).get("hidden") is True, name
' && \
   ! bash "$ROOT/setup/exakit" help --all 2>/dev/null | grep -q 'upgrade-kit2' && \
   ! bash "$ROOT/setup/exakit" help 2>/dev/null | grep -q 'upgrade-kit2' && \
   grep -q 'Write-ExakitKit2NotAvailable' "$ROOT/setup/exakit.ps1"; then
    check "kit2(cli_surface)" "yes" "yes"
else
    check "kit2(cli_surface)" "yes" "no"
fi
# A MAJOR launcher upgrade is a data migration, so it is never taken from a
# y/N: the sh side owns the three-step --plan / --backup / --apply flow, and
# both sides must agree that a major change is the staged route rather than an
# ordinary one.
if grep -q 'personal_upgrade_backup' "$ROOT/setup/lib/runtime-personal.sh" && \
   grep -q '\-\-plan' "$ROOT/setup/lib/runtime-personal.sh" && \
   grep -q 'exakit_runtime_update_is_staged' "$ROOT/setup/lib/common.sh" && \
   grep -q 'function Test-ExakitRuntimeUpdateStaged' "$ROOT/setup/exakit.ps1"; then
    check "personal_update(recoverability)" "yes" "yes"
else
    check "personal_update(recoverability)" "yes" "no"
fi
if grep -q 'mcp_update_snapshot' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'New-McpUpdateSnapshot' "$ROOT/setup/lib/mcp.ps1" && \
   grep -q 'backups.mcp_update.latest' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'backups.mcp_update.latest' "$ROOT/setup/lib/mcp.ps1"; then
    check "mcp_update(snapshot)" "yes" "yes"
else
    check "mcp_update(snapshot)" "yes" "no"
fi
# The MCP update must judge itself by the pin in the AI client configs — what uvx
# will actually launch, and what `exakit version` reports as its Version — and it must be
# the thing that rewrites those configs. A guard that read
# components.mcp_server.version instead answered "already current" for a version no
# client was running. Both sides carry the same two halves.
if grep -q 'exakit_component_current mcp' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'mcp_refresh_client_pins' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'Update-McpClientPins' "$ROOT/setup/lib/mcp.ps1" && \
   grep -q 'Update-McpClientPins' "$ROOT/setup/exakit.ps1" && \
   ! grep -q 'Run exakit mcp-setup to refresh AI client configs' "$ROOT/setup/exakit.ps1"; then
    check "mcp_update(live_pin_guard)" "yes" "yes"
else
    check "mcp_update(live_pin_guard)" "yes" "no"
fi
# Same defect, same fix, for exapump: the guard must ask the binary on disk (what
# `exakit version` reports) rather than components.exapump.version, which is
# only what a previous run wrote down before proving the download. Both sides also
# confirm the move from the binary instead of the record they just wrote.
if grep -q 'exakit_component_current exapump' "$ROOT/setup/lib/exapump.sh" && \
   grep -q 'exapump_confirm_installed_version' "$ROOT/setup/lib/exapump.sh" && \
   grep -q 'Confirm-ExapumpInstalledVersion' "$ROOT/setup/lib/exapump.ps1" && \
   grep -q 'Confirm-ExapumpInstalledVersion' "$ROOT/setup/exakit.ps1"; then
    check "exapump_update(live_probe_guard)" "yes" "yes"
else
    check "exapump_update(live_probe_guard)" "yes" "no"
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

# The PATH fallback — an `exasol` reachable on PATH with no kit-managed binary —
# is the ONLY branch that can turn a needed re-run into a skip, and the cases
# above never reach it: they all run with a PATH scrubbed of every launcher, so
# deleting the branch outright left the suite green. These cases pin it.
#
# Their PATH is built from scratch rather than scrubbed, for two reasons. A stub
# launcher in a directory of our own makes the verdict depend on the test and not
# on what this machine happens to have installed. And scrubbing is a trap here:
# on macOS the kit installs its launcher into ~/.local/bin, which is also where
# uv lives, so dropping every directory that holds an `exasol` can drop uv too —
# and begin_step calls step_done -> run_python, which would then try to bootstrap
# a Python runtime over the network (or die for that unrelated reason) instead of
# testing anything. So: the stub's directory first, then the directory of the
# python3 this machine already resolved, then /usr/bin:/bin for grep and friends.
# EXAKIT_UV_BIN is pinned to a uv resolved from the outer PATH, so even a system
# python3 below the kit's 3.11 floor falls back to a uv already on disk.
_SV_PY_DIR="/usr/bin"
if command -v python3 >/dev/null 2>&1; then
    _SV_PY_DIR="$(dirname "$(command -v python3)")"
fi
_SV_UV_BIN="$(command -v uv 2>/dev/null || true)"

_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin" "$_sv_home/onpath" "$_sv_home/nolauncher"
printf '{"steps_completed": ["launcher"], "components": {}}\n' > "$_sv_home/manifest.json"
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/onpath/exasol"
chmod +x "$_sv_home/onpath/exasol"
_sv_onpath_setup="PATH='$_sv_home/onpath:$_SV_PY_DIR:/usr/bin:/bin'; EXAKIT_UV_BIN='$_SV_UV_BIN'; . '$ROOT/setup/lib/detect.sh'; . '$ROOT/setup/lib/runtime-personal.sh'"
# No kit-managed binary, one on PATH: personal_cli() resolves the PATH one, so
# the step is genuinely satisfied and must be skipped.
check "step_state(launcher on PATH only)" "present" \
    "$(_sv_state "$_sv_home" launcher "$_sv_onpath_setup")"
check "begin_step(launcher on PATH only)" "skip" \
    "$(_sv_step "$_sv_home" launcher "$_sv_onpath_setup")"
# Same home, same manifest, PATH without the stub: the verdict flips. This is
# what proves the case above is the fallback branch answering and not something
# else — no python3 is needed for a state-only check, so this PATH can be
# minimal and fully deterministic.
check "step_state(launcher off PATH)" "missing" \
    "$(_sv_state "$_sv_home" launcher "PATH='$_sv_home/nolauncher:/usr/bin:/bin'; . '$ROOT/setup/lib/detect.sh'; . '$ROOT/setup/lib/runtime-personal.sh'")"
# The fallback holds the launcher it finds to the same bar as the managed one: a
# 0-byte stub on PATH satisfies `command -v` and nothing else.
: > "$_sv_home/onpath/exasol"
chmod 755 "$_sv_home/onpath/exasol"
check "step_state(PATH launcher truncated)" "missing" \
    "$(_sv_state "$_sv_home" launcher "$_sv_onpath_setup")"
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/onpath/exasol"
chmod +x "$_sv_home/onpath/exasol"

# A 0-byte launcher with mode 755 is not a launcher. `[ -x ]` is true of it, so
# an existence-only check answered "present", begin_step skipped step 1, and
# step 2 got an unrunnable launcher — the same dead end as the missing binary,
# from a neighbouring cause (an interrupted install, or a full disk). It must be
# executable AND non-empty. Note the PATH here HAS a working launcher: it cannot
# excuse the truncated managed binary, because personal_cli() prefers that one.
: > "$_sv_home/bin/exasol"
chmod 755 "$_sv_home/bin/exasol"
if [ -x "$_sv_home/bin/exasol" ] && [ ! -s "$_sv_home/bin/exasol" ]; then
    check "step_state(0-byte is executable)" "yes" "yes"
else
    check "step_state(0-byte is executable)" "yes" "no"
fi
check "step_state(launcher truncated)" "missing" \
    "$(_sv_state "$_sv_home" launcher "$_sv_onpath_setup")"
check "begin_step(launcher truncated)" "rerun" \
    "$(_sv_step "$_sv_home" launcher "$_sv_onpath_setup")"
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
# A truncated helper is as unrunnable as an absent one (the sibling bug in this
# family was literally a 0-byte config file).
: > "$_sv_home/bin/exakit"
chmod 755 "$_sv_home/bin/exakit"
check "step_state(exakit_helper truncated)" "missing" "$(_sv_state "$_sv_home" exakit_helper "")"
check "begin_step(exakit_helper truncated)" "rerun" "$(_sv_step "$_sv_home" exakit_helper "")"
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
# A recorded path that is now a 0-byte executable is a failed download, not an
# install: the step must run again.
: > "$_sv_home/bin/exapump"
chmod 755 "$_sv_home/bin/exapump"
check "step_state(exapump truncated)" "missing" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump truncated)" "rerun" "$(_sv_step "$_sv_home" exapump "")"
rm -rf "$_sv_home"

# The check must cost nothing on every install: file tests only. Anything that
# could wake a container engine, or reach the network, belongs nowhere near it.
# Its PATH-lookup helper is held to the same bar, so both bodies are examined.
_sv_fn_body() { # _sv_fn_body <function-name>
    awk -v fn="$1() {" 'index($0, fn) == 1 { inside = 1 } inside { print } inside && /^}/ { exit }' \
        "$ROOT/setup/lib/common.sh"
}
_sv_body="$(_sv_fn_body step_artifact_state)
$(_sv_fn_body _sas_launcher_on_path)"
if printf '%s\n' "$_sv_body" | grep -q 'launcher)' && \
   printf '%s\n' "$_sv_body" | grep -q '_sas_cli' && \
   ! printf '%s\n' "$_sv_body" | grep -Eq 'docker|podman|curl|fetch |nano_status|personal_status|exasol info'; then
    check "step_state(file_tests_only)" "yes" "yes"
else
    check "step_state(file_tests_only)" "yes" "no"
fi

# Both sides carry the same two halves: the artifact table and a begin_step that
# only lets a proven "missing" override the manifest tick. Both also refuse a
# 0-byte artifact — `-s` in the shell, a length test on Windows, where Test-Path
# alone was the same existence-only check. (pwsh is not installed here, so the
# Windows half is pinned by inspection: it cannot be executed.)
if grep -q 'step_artifact_state' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Get-ExakitStepArtifactState' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'what it installed is missing' "$ROOT/setup/lib/common.sh" && \
   grep -q 'what it installed is missing' "$ROOT/setup/lib/exakit-common.ps1" && \
   printf '%s\n' "$_sv_body" | grep -q -- '-s "\$EXAKIT_PERSONAL_BIN"' && \
   [ "$(grep -c 'Length -gt 0' "$ROOT/setup/lib/exakit-common.ps1")" -ge 2 ]; then
    check "step_state(ps_parity)" "yes" "yes"
else
    check "step_state(ps_parity)" "yes" "no"
fi

echo "installer never downgrades the Personal launcher:"
# The installer calls personal_install_launcher directly: `exakit update`'s
# downgrade refusal is not on this path, and this function used to hold no
# version opinion at all. It installed whatever versions.json advertised, so a
# lowered advertised set (how a faulty release gets withdrawn) overwrote a newer
# launcher with an older one and left the deployment undriveable.
#
# Each case runs the real function with a fake deployment directory and a fetch
# stub that ANNOUNCES the download and stops the shell. "FETCHED" in the output
# therefore means the ordinary install path was reached; its absence means the
# guard fired before a single byte was downloaded.
_pld_run() { # _pld_run <advertised> [deployed-version]
    _pld_dir="$(mktemp -d)"
    if [ -n "${2:-}" ]; then
        mkdir -p "$_pld_dir/deploy"
        printf '%s' "$2" > "$_pld_dir/deploy/.exasolLauncher.version"
    fi
    # EXAKIT_HOME must be exported BEFORE common.sh is sourced: the guard under
    # test ends in `die`, die records a failure note, and the note goes to
    # $EXAKIT_HOME/.last-failure. Without this the suite wrote "Refusing to
    # install launcher 2.0.0 over a newer 2.1.0 deployment" into the developer's
    # REAL installation -- a bogus record that outlives the test run and, now
    # that `exakit status --json` surfaces last_failure, actively misleads an
    # agent about a machine that is perfectly healthy.
    PATH="$_SV_CLEAN_PATH" EXAKIT_HOME="$_pld_dir/home" bash -c "
mkdir -p '$_pld_dir/home'
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_PERSONAL_VERSION='$1'
EXAKIT_PERSONAL_DEPLOY_DIR='$_pld_dir/deploy'
EXAKIT_BIN_DIR='$_pld_dir/bin'
EXAKIT_PERSONAL_BIN='$_pld_dir/bin/exasol'
EXAKIT_LOG_FILE='$_pld_dir/install.log'
fetch() { printf 'FETCHED %s\n' \"\$1\"; exit 0; }
personal_asset_name() { printf 'exasol-personal_macOS_arm64.tar.gz\n'; }
personal_install_launcher 2>&1
" 2>&1
    rm -rf "$_pld_dir"
}

# 1. Deployment NEWER than the advertised launcher -> refuse, install nothing.
pld_newer="$(_pld_run 2.0.0 2.1.0)"
case "$pld_newer" in
    *FETCHED*) check "installer_downgrade(nothing installed)" "yes" "no" ;;
    *) check "installer_downgrade(nothing installed)" "yes" "yes" ;;
esac
# The message has to be usable on its own: both versions, the direction, and the
# override that resolves it. Each needle names a version INSIDE the guard's own
# wording -- a bare "2.0.0" would also match the download URL the fetch stub
# echoes, and would stay green with the guard removed.
for _pld_want in "deployment on this machine is version 2.1.0" \
                 "newer than the launcher version this kit advertises (2.0.0)" \
                 "EXAKIT_PERSONAL_VERSION=2.1.0" \
                 "Refusing to install launcher 2.0.0 over a newer 2.1.0 deployment"; do
    case "$pld_newer" in
        *"$_pld_want"*) check "installer_downgrade(says '$_pld_want')" "yes" "yes" ;;
        *) check "installer_downgrade(says '$_pld_want')" "yes" "no" ;;
    esac
done
# ...and it is the kit talking, not the launcher's help. The observed failure
# printed a wall of launcher usage text before "Setup failed during step".
case "$pld_newer" in
    *Usage:*|*USAGE:*) check "installer_downgrade(no launcher usage dump)" "yes" "no" ;;
    *) check "installer_downgrade(no launcher usage dump)" "yes" "yes" ;;
esac

# 2. Deployment OLDER than the advertised launcher -> a genuine upgrade, which
#    must be entirely unaffected.
case "$(_pld_run 2.1.0 2.0.0)" in
    *FETCHED*) check "installer_downgrade(upgrade unaffected)" "yes" "yes" ;;
    *) check "installer_downgrade(upgrade unaffected)" "yes" "no" ;;
esac

# 3. No deployment at all -> a fresh install, unaffected.
case "$(_pld_run 2.0.0)" in
    *FETCHED*) check "installer_downgrade(fresh unaffected)" "yes" "yes" ;;
    *) check "installer_downgrade(fresh unaffected)" "yes" "no" ;;
esac

# 4. Deployment EQUAL to the advertised launcher -> a re-install, unaffected.
case "$(_pld_run 2.0.0 2.0.0)" in
    *FETCHED*) check "installer_downgrade(reinstall unaffected)" "yes" "yes" ;;
    *) check "installer_downgrade(reinstall unaffected)" "yes" "no" ;;
esac

# The version is read from deployment state, never by running a launcher: the
# decision comes before any binary is installed, and the launcher that could
# answer is the one about to be overwritten. Both state files must be honoured,
# and unreadable state must read as "unknown" so it cannot wrongly block.
_pld_reads="$(_pld_dir="$(mktemp -d)"
    mkdir -p "$_pld_dir/deploy"
    bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_PERSONAL_DEPLOY_DIR='$_pld_dir/deploy'
printf 'v2.4.0\n' > \"\$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncher.version\"
printf 'bare=[%s]\n' \"\$(personal_deployed_version || true)\"
: > \"\$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncher.version\"
printf '{\"deploymentId\":\"x\",\"deploymentVersion\":\"2.5.0\"}' > \"\$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json\"
printf 'json=[%s]\n' \"\$(personal_deployed_version || true)\"
printf 'not a version' > \"\$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncher.version\"
rm -f \"\$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json\"
printf 'junk=[%s]\n' \"\$(personal_deployed_version || true)\"
"
    rm -rf "$_pld_dir")"
_pld_said() { # _pld_said <needle> -> yes|no  (case inside $() upsets bash 3.2)
    case "$_pld_reads" in
        *"$1"*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}
check "installer_downgrade(reads bare version file)" "yes" "$(_pld_said 'bare=[2.4.0]')"
check "installer_downgrade(reads state json)" "yes" "$(_pld_said 'json=[2.5.0]')"
check "installer_downgrade(junk reads as unknown)" "yes" "$(_pld_said 'junk=[]')"

# The comparison behind the refusal. It blocks an install, so it must answer
# "deployed is higher" only when that is provable, and never in both directions:
# a same-major upgrade misread as a regression would block a legitimate install.
_pld_rank="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
# No Python: this decision must not depend on one being available, and the shared
# exakit_version_newer helper deliberately answers 'yes' both ways without it.
EXAKIT_DISABLE_SYSTEM_PYTHON=1
exakit_ensure_uv() { return 1; }
for _pair in 2.1.0:2.0.0 2.0.0:2.1.0 2.0.0:2.0.0 3.0.0:2.9.9 2.9.9:3.0.0 \\
             2.10.0:2.9.0 2.9.0:2.10.0 2.0.1:2.0.0 2.1:2 2:2.1 \\
             2.1.0-rc1:2.1.0 abc:2.0.0; do
    _a=\"\${_pair%%:*}\"; _b=\"\${_pair#*:}\"
    if personal_deployment_outranks \"\$_a\" \"\$_b\"; then printf '%s>yes ' \"\$_pair\"
    else printf '%s>no ' \"\$_pair\"; fi
done")"
check "installer_downgrade(version ranking, no python)" \
    "2.1.0:2.0.0>yes 2.0.0:2.1.0>no 2.0.0:2.0.0>no 3.0.0:2.9.9>yes 2.9.9:3.0.0>no 2.10.0:2.9.0>yes 2.9.0:2.10.0>no 2.0.1:2.0.0>yes 2.1:2>yes 2:2.1>no 2.1.0-rc1:2.1.0>no abc:2.0.0>no " \
    "$_pld_rank"

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
# ---------------------------------------------------------------------------
# Naming the process that holds a port, on a machine WITHOUT lsof.
# ---------------------------------------------------------------------------
# THE BUG: port_holder_desc bailed out unless lsof was installed. lsof is on
# every macOS and on no minimal Linux (Fedora @core, Ubuntu Server), so on
# exactly the hosts most likely to be running something else on 8563 the
# remedy degraded back to the unactionable "stop it" the naming was added to
# replace. ss (iproute2) is there instead, and net-tools' netstat on older
# images.
echo "port holder identification without lsof:"
phd_stub="$(mktemp -d)"
cat > "$phd_stub/ss" <<'EOF'
#!/bin/sh
echo 'State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process'
echo 'LISTEN 0      4096   127.0.0.1:8563      0.0.0.0:*         users:(("some-server",pid=4242,fd=6))'
EOF
chmod +x "$phd_stub/ss"
# lsof is not merely absent, it FAILS: the stub dir is prepended to the real
# PATH, so a developer machine's real lsof would otherwise answer for it.
printf '#!/bin/sh\nexit 1\n' > "$phd_stub/lsof" && chmod +x "$phd_stub/lsof"
got="$(PATH="$phd_stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; port_holder_desc 8563")"
case "$got" in "pid 4242 ("*) got_r="named" ;; *) got_r="${got:-<nothing>}" ;; esac
check "port_holder_desc(ss, no lsof)" "named" "$got_r"

# net-tools only: ss present but silent, lsof failing.
printf '#!/bin/sh\nexit 0\n' > "$phd_stub/ss" && chmod +x "$phd_stub/ss"
cat > "$phd_stub/netstat" <<'EOF'
#!/bin/sh
echo 'Active Internet connections (only servers)'
echo 'tcp        0      0 127.0.0.1:8563          0.0.0.0:*               LISTEN      4243/some-server'
EOF
chmod +x "$phd_stub/netstat"
got="$(PATH="$phd_stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; port_holder_desc 8563")"
case "$got" in "pid 4243 ("*) got_r="named" ;; *) got_r="${got:-<nothing>}" ;; esac
check "port_holder_desc(netstat only)" "named" "$got_r"

# Nothing can tell: the function must fail cleanly rather than invent a holder.
printf '#!/bin/sh\nexit 0\n' > "$phd_stub/netstat" && chmod +x "$phd_stub/netstat"
got="$(PATH="$phd_stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; port_holder_desc 8563 || echo UNKNOWN")"
check "port_holder_desc(nothing available)" "UNKNOWN" "$got"
rm -rf "$phd_stub"

echo
# ---------------------------------------------------------------------------
# install.sh refuses a bash-less machine BEFORE it downloads anything.
# ---------------------------------------------------------------------------
# THE BUG: install.sh is POSIX sh but every script it hands off to is bash. With
# no `command -v bash` check it downloaded and unpacked the whole kit and then
# died at `exec bash` with the shell's own "exec: bash: not found" — past fail(),
# so not even the .last-failure note an agent reads in the next session existed.
echo "install.sh requires bash:"
bash_stub="$(mktemp -d)"
bash_home="$(mktemp -d)"
for _tool in sh id curl tar mkdir date cat uname grep sed; do
    _p="$(command -v "$_tool")" && ln -s "$_p" "$bash_stub/$_tool" 2>/dev/null
done
_iout="$(PATH="$bash_stub" HOME="$bash_home" EXAKIT_HOME="$bash_home/kit-home" \
    "$bash_stub/sh" "$ROOT/install.sh" 2>&1)"
_icode=$?
case "$_iout" in *"bash is required"*) _ir="refused" ;; *) _ir="$(printf '%s' "$_iout" | head -n 1)" ;; esac
check "install.sh(no bash on PATH)" "refused" "$_ir"
check "install.sh(no bash) exit code" "1" "$_icode"
# ...and it refused before fetching: nothing was written into the kit dir.
check "install.sh(no bash) downloaded nothing" "no" \
    "$([ -d "$bash_home/kit-home/kit" ] && echo yes || echo no)"
# The failure IS recorded, which is the whole point of failing through fail().
check "install.sh(no bash) left a note" "yes" \
    "$([ -s "$bash_home/kit-home/.last-failure" ] && echo yes || echo no)"
rm -rf "$bash_stub" "$bash_home"

echo

echo

# ---------------------------------------------------------------------------
# No test may write into a real installation.
# ---------------------------------------------------------------------------
# This suite sources common.sh repeatedly, and common.sh derives EXAKIT_HOME
# from the environment -- defaulting to the developer's live ~/.exasol-starter-kit.
# Any helper that forgets to isolate it silently mutates a real install: the
# downgrade-guard case used to leave a bogus .last-failure behind, which took an
# agent-operability audit to notice. Assert the live home is untouched.
_real_home="${HOME}/.exasol-starter-kit"
_now_note=""
[ -e "$_real_home/.last-failure" ] && _now_note="$(cat "$_real_home/.last-failure" 2>/dev/null)"
if [ -n "$_now_note" ] && [ "$_now_note" != "$_PRE_NOTE" ]; then
    check "the suite left no failure note in the real kit home" "clean" \
        "POLLUTED: $(printf '%s' "$_now_note" | head -n 1)"
elif [ -n "$_now_note" ]; then
    # Unchanged from before the run: the developer's own, not ours.
    check "the suite left no failure note in the real kit home" "clean" "clean"
else
    check "the suite left no failure note in the real kit home" "clean" "clean"
fi

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
