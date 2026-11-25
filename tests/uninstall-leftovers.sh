#!/usr/bin/env bash
# uninstall-leftovers.sh - a full uninstall must never report success while the
# database deployment is still on the machine.
#
#   bash tests/uninstall-leftovers.sh
#
# THE BUG: `exakit uninstall --yes` printed "Database removed" and "Uninstall
# complete" and exited 0 whatever the launcher's destroy did. personal_teardown
# returned the status of its last line (a manifest write), so a destroy that
# failed - or exited 0 and left the deployment directory behind, or was never
# run because `exasol info` failed on a deployment in launcher state
# "deployment_failed" - still read as success, and the caller's
# `|| warn` never fired. The kit home and the launcher were then deleted, so
# nothing on the machine knew the database was still there.
#
# What is pinned:
#   personal_teardown  - destroy exits 0 but the directory remains: non-zero,
#                        the directory named, the remedy is `rm -rf <dir>`
#                      - destroy fails: non-zero
#                      - `exasol info` fails but the directory exists: destroy
#                        is still attempted
#                      - the kit's runner still listens on the port: named,
#                        and the remedy kills it first
#                      - destroy works and the directory is gone: 0, nothing
#                        reported
#                      - the folder is gone and a container is not: found by
#                        the id recorded at install
#                      - the deployment moved to another launcher folder: that
#                        folder named (by its id) and never removed
#   exakit_uninstall_run - a teardown that leaves the deployment: no "Database
#                        removed" line, the leftover and the remedy printed,
#                        non-zero; a clean teardown: unchanged
#   cmd_uninstall --yes - a run that left the database: no "Uninstall
#                        complete", exit 1; a clean run: success, exit 0;
#                        --dry-run unchanged (exit 0, nothing run for real)
#
# Everything runs against a sandboxed HOME with a stub launcher and a stubbed
# lsof; no real launcher, port, container, kit home or uninstall is touched.

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

# The sandbox HOME is the only home anything below can see. Guard: refuse to
# run at all if it somehow resolved to the real one.
SBHOME="$TMP/home"
mkdir -p "$SBHOME"
case "$SBHOME" in "$HOME"|"$HOME/") echo "refusing: sandbox HOME is the real HOME"; exit 1 ;; esac
# The kit's own deployment, starter-kit-local, where a launcher before 2.5.0 keeps it.
DEPLOY="$SBHOME/.exasol/personal/deployments/starter-kit-local"

# --- stub launcher --------------------------------------------------------
# STUB_INFO_RC: exit code of `exasol info` (1 = the launcher refuses it, as in
# "deployment_failed"). STUB_DESTROY_RC: exit code of `destroy`.
# STUB_DESTROY_REMOVES=1: destroy really deletes the deployment directory.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/exasol" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1" in
    info)    exit "${STUB_INFO_RC:-0}" ;;
    destroy)
        # The folder it is told (--deployment-dir), else the kit's.
        _d="$STUB_DEPLOY"; _p=""
        for _a in "$@"; do [ "$_p" = --deployment-dir ] && _d="$_a"; _p="$_a"; done
        [ "${STUB_DESTROY_REMOVES:-0}" = 1 ] && rm -rf "$_d"
        exit "${STUB_DESTROY_RC:-0}" ;;
esac
exit 0
STUB
# docker / podman: `ps -a` lists STUB_DOCKER_PS / STUB_PODMAN_PS. On PATH ahead
# of any real engine, so no real container is ever listed or touched.
printf '#!/usr/bin/env bash\n[ -n "${STUB_DOCKER_FAIL:-}" ] && { echo "$STUB_DOCKER_FAIL" >&2; exit 1; }\n[ "$1" = ps ] && printf "%%s\\n" "${STUB_DOCKER_PS:-}"\nexit 0\n' > "$TMP/bin/docker"
printf '#!/usr/bin/env bash\n[ -n "${STUB_PODMAN_FAIL:-}" ] && { echo "$STUB_PODMAN_FAIL" >&2; exit 1; }\n[ "$1" = ps ] && printf "%%s\\n" "${STUB_PODMAN_PS:-}"\nexit 0\n' > "$TMP/bin/podman"
chmod +x "$TMP/bin/exasol" "$TMP/bin/docker" "$TMP/bin/podman"

# --- personal_teardown, the real function ---------------------------------
cat > "$TMP/teardown.sh" <<HARNESS
set -u
HOME="$SBHOME"; export HOME
export STUB_CALLS="$TMP/calls" STUB_DEPLOY="\${STUB_KIT_DIR:-$DEPLOY}"
export PATH="$TMP/bin:\$PATH"
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }
warn(){ printf 'WARN %s\n' "\$*"; }; error(){ printf 'ERROR %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
# runtime.engine is STUB_ENGINE (nothing recorded by default), and
# runtime.deployment_id STUB_DEP_ID (the id the kit recorded at install).
manifest_get(){ [ "\$1" = runtime.engine ] && printf '%s' "\${STUB_ENGINE:-}"; [ "\$1" = runtime.deployment_id ] && printf '%s' "\${STUB_DEP_ID:-}"; return 0; }
manifest_set(){ printf 'MANIFEST %s=%s\n' "\$1" "\$2"; }
manifest_del(){ :; }
detect_os(){ printf '%s' "\${STUB_OS:-macos}"; }
exakit_run_bounded(){ shift; "\$@"; }
run_logged(){ "\$@" >/dev/null 2>&1; }
port_in_use(){ return 1; }
EXAKIT_BIN_DIR="$TMP/bin"
# STUB_KIT_DIR: a folder the user chose for the kit, in place of the default.
EXAKIT_PERSONAL_DEPLOY_DIR="\${STUB_KIT_DIR:-$DEPLOY}"
source "$ROOT/setup/lib/runtime-personal.sh"
# The kit's own launcher (the kit runs only its own, personal_cli) is the stub.
EXAKIT_PERSONAL_KIT_BIN="$TMP/bin/exasol"; EXAKIT_PERSONAL_BIN="$TMP/bin/exasol"
# The port is answered by a stub, never by the real lsof: this machine may run
# a real database on 8563. STUB_LISTENER is the pid "listening" (if any), and
# STUB_RUNNER=1 makes it the kit's own runner.
lsof(){ [ -n "\${STUB_LISTENER:-}" ] && printf '%s\n' "\$STUB_LISTENER"; return 0; }
_personal_is_runner_process(){ [ "\${STUB_RUNNER:-0}" = 1 ] && [ "\$1" = "\${STUB_LISTENER:-}" ]; }
personal_reap_orphan_daemon(){ return 0; }
personal_teardown --data
rc=\$?
printf 'RC=%s\n' "\$rc"
printf 'LEFT=%s\n' "\${EXAKIT_TEARDOWN_LEFTOVERS:-}" | tr '\n' ';'; printf '\n'
printf 'REMEDY=%s\n' "\${EXAKIT_TEARDOWN_REMEDY:-}"
printf 'WARNINGS=%s\n' "\${EXAKIT_TEARDOWN_WARNINGS:-}"
HARNESS

teardown() { # env... -> output of the harness
    rm -f "$TMP/calls"
    env "$@" bash "$TMP/teardown.sh" 2>&1
}
seed_deploy() { rm -rf "$DEPLOY"; mkdir -p "$DEPLOY"; printf '{"deploymentId": "exa-test1"}\n' > "$DEPLOY/deployment.json"; }

echo "personal_teardown verifies the end state:"

# (a) destroy exits 0, the directory is still there.
seed_deploy
out="$(teardown STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=0)"
lacks    "a: destroy 0 + dir left is not success" "RC=0" "$out"
contains "a: the leftover directory is named" "$DEPLOY" "$out"
contains "a: the remedy removes it" "rm -rf '$DEPLOY'" "$out"
lacks    "a: the record does not say removed" "MANIFEST runtime.status=removed" "$out"

# (b) destroy fails.
seed_deploy
out="$(teardown STUB_DESTROY_RC=1 STUB_DESTROY_REMOVES=0)"
lacks    "b: a failed destroy is not success" "RC=0" "$out"
contains "b: the leftover directory is named" "$DEPLOY" "$out"

# (d) the launcher refuses `info` (deployment_failed): destroy still attempted.
seed_deploy
out="$(teardown STUB_INFO_RC=1 STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1)"
contains "d: destroy is attempted when info fails" "destroy --remove --auto-approve" "$(cat "$TMP/calls" 2>/dev/null)"
contains "d: and then it is a success" "RC=0" "$out"
check    "d: the directory is gone" "no" "$([ -e "$DEPLOY" ] && echo yes || echo no)"

# (e) the directory went, the kit's runner still holds the port.
seed_deploy
out="$(teardown STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_LISTENER=424242 STUB_RUNNER=1)"
lacks    "e: a live runner is not success" "RC=0" "$out"
contains "e: the runner pid is named" "424242" "$out"
contains "e: the remedy kills it" "kill 424242" "$out"

# (e2) a FOREIGN listener on the port is not the kit's leftover.
seed_deploy
out="$(teardown STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_LISTENER=434343 STUB_RUNNER=0)"
contains "e2: a foreign listener does not fail the teardown" "RC=0" "$out"

# (c) destroy works and the directory is gone.
seed_deploy
out="$(teardown STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1)"
contains "c: a clean destroy is success" "RC=0" "$out"
contains "c: the record says removed" "MANIFEST runtime.status=removed" "$out"
contains "c: nothing is left over" "LEFT=;" "$out"

# (g) Linux: the directory went, a container carrying the id did not.
seed_deploy
out="$(teardown STUB_OS=linux STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_DOCKER_PS="$(printf 'exa-test1-db-1\nsomebody-else\nexa-test10')")"
lacks    "g: a container left behind is not success" "RC=0" "$out"
contains "g: the container is named" "docker container exa-test1-db-1" "$out"
contains "g: the remedy removes it" "docker rm -f exa-test1-db-1" "$out"
lacks    "g: an unrelated container is not touched" "somebody-else" "$out"
lacks    "g: nor one whose name merely starts with the id" "exa-test10" "$out"

# (g2) Linux: the engine refuses (not in the docker group): a warning with
# the command to check by hand, never a leftover, and the run still succeeds.
seed_deploy
out="$(teardown STUB_OS=linux STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_DOCKER_FAIL="permission denied while trying to connect to the Docker daemon socket")"
contains "g2: an engine that refuses is not a leftover" "RC=0" "$out"
contains "g2: nothing is counted left over" "LEFT=;" "$out"
contains "g2: but it is a warning with the check command" "WARNINGS=Could not confirm the database container is gone (docker said: permission denied while trying to connect to the Docker daemon socket). Check: docker ps -a (or sudo docker ps -a)" "$out"
out="$(teardown STUB_OS=linux STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1)"
contains "g2: an engine that answers gives no warning" "WARNINGS=" "$out"
lacks    "g2: none at all" "Could not ask" "$out"

# (g3) a Docker deployment, and a podman that refuses (W1-02): only the
# recorded engine is asked, so no warning names podman. With podman recorded,
# or nothing recorded, its refusal is still said.
seed_deploy
out="$(teardown STUB_OS=linux STUB_ENGINE=docker STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_PODMAN_FAIL="cannot connect to Podman")"
contains "g3: a refusing engine the deployment never ran on is not a failure" "RC=0" "$out"
lacks    "g3: and gives no warning" "podman" "$(printf '%s\n' "$out" | grep '^WARNINGS=')"
seed_deploy
out="$(teardown STUB_OS=linux STUB_ENGINE=podman STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_PODMAN_FAIL="cannot connect to Podman")"
contains "g3: the recorded engine's refusal is still a warning" "WARNINGS=Could not confirm the database container is gone (podman said: cannot connect to Podman)" "$out"
seed_deploy
out="$(teardown STUB_OS=linux STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1 STUB_PODMAN_FAIL="cannot connect to Podman")"
contains "g3: nothing recorded: both are asked, as before" "podman said: cannot connect to Podman" "$out"

# (k) the folder is already gone, the container is not (scenario X, X3: the
# uninstall said "Database removed" over a deployment still there). The id
# the kit recorded at install names the container, so it is checked anyway.
rm -rf "$DEPLOY"
out="$(teardown STUB_OS=linux STUB_DEP_ID=exa-test1 STUB_DOCKER_PS="$(printf 'exa-test1-db-1\nsomebody-else')")"
lacks    "k: folder gone, container left: not success" "RC=0" "$out"
contains "k: the container is named by the recorded id" "docker container exa-test1-db-1" "$out"
contains "k: the remedy removes it" "docker rm -f exa-test1-db-1" "$out"
lacks    "k: the record does not say removed" "MANIFEST runtime.status=removed" "$out"
out="$(teardown STUB_OS=linux STUB_DOCKER_PS="$(printf 'exa-test1-db-1\nsomebody-else')")"
contains "k: with no id recorded, as before (nothing to match a container by)" "RC=0" "$out"

# (l) the launcher moved the deployment out of the kit's legacy folder
# (launcher 2.5: ~/.exasol/launcher/deployments/starter-kit-local). The kit follows the
# move (personal_deploy_dir_refresh), so the teardown acts on the moved folder
# and removes it. A folder there with another name and id is the user's: not
# named, not touched.
MOVED="$SBHOME/.exasol/launcher/deployments/starter-kit-local"
USERS="$SBHOME/.exasol/launcher/deployments/mine"
rm -rf "$DEPLOY" "$SBHOME/.exasol/launcher"
mkdir -p "$MOVED" "$USERS"
printf '{"deploymentId": "exa-test1"}\n' > "$MOVED/deployment.json"
printf '{"deploymentId": "exa-users"}\n' > "$USERS/deployment.json"
out="$(teardown STUB_DEP_ID=exa-test1 STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1)"
contains "l: the moved default folder is followed, and removed" "destroy --remove --auto-approve --deployment-dir $MOVED" "$(cat "$TMP/calls" 2>/dev/null)"
contains "l: ...and that is success" "RC=0" "$out"
check    "l: ...the moved folder is gone" "gone" "$([ -d "$MOVED" ] && echo left || echo gone)"
lacks    "l: the user's own deployment is not named" "$USERS" "$out"
check    "l: ...nor touched" "yes" "$([ -d "$USERS" ] && echo yes)"
lacks    "l: ...nor destroyed" "--deployment-dir $USERS" "$(cat "$TMP/calls" 2>/dev/null)"
rm -rf "$SBHOME/.exasol/launcher"
# (l2) a folder the user chose for the kit (not the launcher's default, so not
# followed) that the launcher moved: a folder in the launcher's deployment
# folders whose state names the kit's deployment id is that deployment, named
# with its remedy and never removed by the kit. Another id is the user's: not
# named, not touched.
KITD="$SBHOME/.exasol/personal/deployments/kit"
MOVED="$SBHOME/.exasol/launcher/deployments/kit"
rm -rf "$KITD" "$SBHOME/.exasol/launcher"
mkdir -p "$MOVED" "$USERS"
printf '{"deploymentId": "exa-test1"}\n' > "$MOVED/deployment.json"
printf '{"deploymentId": "exa-users"}\n' > "$USERS/deployment.json"
out="$(teardown STUB_KIT_DIR="$KITD" STUB_DEP_ID=exa-test1)"
lacks    "l2: the moved deployment is not success" "RC=0" "$out"
contains "l2: its folder is named" "the deployment directory $MOVED (the database and ALL its data)" "$out"
contains "l2: with the command that removes it" "rm -rf '$MOVED'" "$out"
lacks    "l2: the user's own deployment is not named" "$USERS" "$out"
check    "l2: the kit removed neither folder" "yes yes" "$([ -d "$MOVED" ] && echo yes) $([ -d "$USERS" ] && echo yes)"
lacks    "l2: and ran no destroy on them" "destroy" "$(cat "$TMP/calls" 2>/dev/null)"
# The same with the folder still where the kit put it: found by the id read
# from it, the moved twin is named once beside it.
mkdir -p "$KITD"; printf '{"deploymentId": "exa-test1"}\n' > "$KITD/deployment.json"
out="$(teardown STUB_KIT_DIR="$KITD" STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1)"
contains "l2: a twin beside a removed folder is still named" "the deployment directory $MOVED" "$out"
rm -f "$MOVED/deployment.json"
out="$(teardown STUB_KIT_DIR="$KITD" STUB_DEP_ID=exa-test1)"
contains "l2: a folder that names no id is not counted" "RC=0" "$out"
rm -rf "$SBHOME/.exasol/launcher" "$KITD"

echo "the deployment id is recorded at install, on both sides:"
contains "personal_record_manifest records runtime.deployment_id" 'manifest_set runtime.deployment_id "$_prm_id"' "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
contains "Write-PersonalManifest records it too" 'Set-ExakitManifestValue "runtime.deployment_id" $recordedId' "$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
contains "a Remove-Personal that throws is still checked" 'try { Find-PersonalTeardownLeftovers -Id ("" + (Get-ExakitManifestValue "runtime.deployment_id")) } catch { }' "$(cat "$ROOT/setup/exakit.ps1")"

# (f) nothing was ever deployed: success, nothing destroyed.
rm -rf "$DEPLOY"
out="$(teardown)"
contains "f: no deployment is success" "RC=0" "$out"
lacks    "f: and destroy is not called" "destroy" "$(cat "$TMP/calls" 2>/dev/null)"

# --- exakit_uninstall_run: the record line and the status ----------------
echo
echo "exakit_uninstall_run does not claim a removal that did not happen:"
# The harness's system tools: every command in /usr/bin and /bin EXCEPT the
# container engines, linked into one directory that replaces both on PATH. A
# real /usr/bin/docker (ubuntu-latest has one) is then unreachable from any
# case, so a stub-less case answers "no engine" instead of running a real rmi.
mkdir -p "$TMP/sysbin"
for _sd in /usr/bin /bin; do
    for _sf in "$_sd"/*; do
        _sn="${_sf##*/}"
        case "$_sn" in docker*|podman*|nerdctl*) continue ;; esac
        [ -e "$TMP/sysbin/$_sn" ] || ln -s "$_sf" "$TMP/sysbin/$_sn" 2>/dev/null || true
    done
done
cat > "$TMP/run.sh" <<HARNESS
set -u
HOME="$SBHOME"; export HOME
EXAKIT_HOME="$SBHOME/.exasol-starter-kit"; EXAKIT_BIN_DIR="$SBHOME/.local/bin"
EXAKIT_EXAPUMP_CONFIG_DIR="$SBHOME/.exapump"
EXAKIT_PERSONAL_DEPLOY_DIR="\${STUB_DEPLOY_DIR:-$DEPLOY}"
export EXAKIT_HOME EXAKIT_BIN_DIR EXAKIT_EXAPUMP_CONFIG_DIR
# STUB_QUIET=1: info() is quiet inside the run's quiet bracket, as on screen;
# info_step and ok_step still print (W1-03).
info(){ [ "\${STUB_QUIET:-0}" = 1 ] && [ "\${EXAKIT_QUIET_DETAIL:-0}" = 1 ] && return 0; printf 'INFO %s\n' "\$*"; }
warn(){ printf 'WARN %s\n' "\$*"; }
ok(){ printf 'OK %s\n' "\$*"; }; ok_step(){ printf 'OK %s\n' "\$*"; }
info_step(){ printf 'INFO %s\n' "\$*"; }; error(){ printf 'ERROR %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
ui_spin_begin(){ :; }; ui_spin_end(){ :; }; ui_tilde(){ printf '%s' "\$1"; }
_exakit_log_file(){ :; }
# Boot-entry dirs in the sandbox, the prefix read from common.sh itself, and
# the supervisors stubbed: nothing reaches the real launchd or systemd.
EXAKIT_LAUNCHAGENT_DIR="$SBHOME/Library/LaunchAgents"
EXAKIT_SYSTEMD_USER_DIR="$SBHOME/.config/systemd/user"
$(grep '^EXAKIT_AUTOSTART_PREFIX=' "$ROOT/setup/lib/common.sh")
launchctl(){ printf 'LAUNCHCTL %s\n' "\$*" >> "$TMP/supervisor"; }
systemctl(){ printf 'SYSTEMCTL %s\n' "\$*" >> "$TMP/supervisor"; }
# The engines: only the stubs in STUB_ENG_DIR are on PATH (sysbin holds no
# docker or podman), and the bounded runner just runs them.
PATH="\${STUB_ENG_DIR:-$TMP/eng}:$TMP/sysbin"; export PATH
detect_os(){ printf '%s' "\${STUB_OS:-macos}"; }
# STUB_UNAME: the kernel name the launcher-cache lookup reads (Linux there:
# the cache under XDG_CACHE_HOME), whatever this machine is.
if [ -n "\${STUB_UNAME:-}" ]; then uname(){ printf '%s\n' "\$STUB_UNAME"; }; fi
exakit_run_bounded(){ shift; "\$@"; }
$(grep '^EXAKIT_KIT_IMAGE_REPOS=' "$ROOT/setup/lib/common.sh")
manifest_get(){ case "\$1" in runtime.type) [ "\${STUB_NO_TYPE:-0}" = 1 ] || echo personal ;; runtime.engine) echo "\${STUB_ENGINE:-docker}" ;; *) echo "" ;; esac; }
exakit_repo_root(){ return 1; }
exakit_marketplace_addons(){ :; }
# Component ownership: everything here is the kit's own.
exakit_component_is_managed(){ return 0; }
exakit_preserved_component_paths(){ :; }
exakit_preserve_component(){ info "Keeping \$1"; }
personal_teardown(){
    EXAKIT_TEARDOWN_WARNINGS="\${STUB_TW:-}"
    if [ "\${STUB_TD_RC:-0}" = 0 ]; then rm -rf "\$EXAKIT_PERSONAL_DEPLOY_DIR"; EXAKIT_TEARDOWN_LEFTOVERS=""; EXAKIT_TEARDOWN_REMEDY=""; return 0; fi
    EXAKIT_TEARDOWN_LEFTOVERS="the deployment directory $DEPLOY"
    EXAKIT_TEARDOWN_REMEDY="rm -rf '$DEPLOY'"
    return 1
}
for _fn in personal_deploy_dir_refresh personal_launcher_cache_dir personal_other_deployments personal_prunable_state_dirs; do
    eval "\$(awk -v n="\$_fn" '\$0 ~ ("^" n "\\\\(\\\\)") {f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/runtime-personal.sh")"
done
eval "\$(awk '/^detect_personal_private_mode\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/detect.sh")"
eval "\$(awk '/^detect_personal_deploy_roots\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/detect.sh")"
eval "\$(awk '/^detect_personal_deploy_resolve\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/detect.sh")"
eval "\$(awk '/^detect_personal_deployment_id\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/detect.sh")"
eval "\$(awk '/^_exakit_remove_installed_skills\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
for _fn in _exakit_uninstall_leftover_report _exakit_uninstall_recorded_db_port _exakit_uninstall_teardown_warnings _exakit_uninstall_component _exakit_uninstall_orphan_autostart _exakit_kit_image_label _exakit_uninstall_kit_image_ids _exakit_uninstall_kit_images exakit_uninstall_run; do
    eval "\$(awk -v n="\$_fn" '\$0 ~ ("^" n "\\\\(\\\\)") {f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
done
# STUB_ADDON=1: two add-ons to remove. semantic-views fails the way the
# module does (its reason on stderr, "<id>: <reason>", exit 1) when
# STUB_ADDON_FAIL=1; json-tables succeeds with a note on stderr (W1-01).
if [ "\${STUB_ADDON:-0}" = 1 ]; then
    exakit_marketplace_installed_addons(){ printf 'semantic-views\njson-tables\n'; }
    exakit_marketplace_removable_addons(){ printf 'semantic-views\njson-tables\n'; }
    _exakit_skills_decide_kits(){ :; }
    _exakit_addon_fn(){ printf '%s_%s\n' "\$(printf '%s' "\$1" | tr - _)" "\$2"; }
    semantic_views_uninstall(){
        [ "\${STUB_ADDON_FAIL:-0}" = 1 ] || return 0
        echo "semantic-views: 1 semantic model(s) are defined in the database: they are your work, so nothing was removed" >&2
        return 1
    }
    json_tables_uninstall(){ echo "json-tables: a note on stderr" >&2; return 0; }
fi
mkdir -p "\$EXAKIT_HOME" && : > "\$EXAKIT_HOME/manifest.json"
exakit_unmark_step(){ :; }
# STUB_MCP_REC=1: record the port the MCP-process stop is handed, stop nothing.
if [ "\${STUB_MCP_REC:-0}" = 1 ]; then
    _exakit_uninstall_mcp_processes(){ printf 'MCPSTOP dry=%s port=[%s]\n' "\$1" "\$2"; }
fi
if [ -n "\${STUB_COMPONENT:-}" ]; then
    _exakit_uninstall_component "\$STUB_COMPONENT" "\${STUB_DRY:-0}"
else
    exakit_uninstall_run "\${STUB_DRY:-0}"
fi
printf 'RC=%s\n' "\$?"
HARNESS

out="$(STUB_TD_RC=1 bash "$TMP/run.sh" 2>&1)"
lacks    "a teardown that left the deployment: no 'Database removed'" "Database removed" "$out"
lacks    "and the run does not answer 0" "RC=0" "$out"
contains "the leftover is printed" "$DEPLOY" "$out"
contains "with the one command that removes it" "rm -rf '$DEPLOY'" "$out"
out="$(STUB_TD_RC=0 bash "$TMP/run.sh" 2>&1)"
contains "a clean teardown still says 'Database removed'" "Database removed" "$out"
contains "and answers 0" "RC=0" "$out"
out="$(STUB_TD_RC=0 STUB_TW="could not check docker for the deployment's container (exit 1); check with: docker ps -a --filter name=exa-test1" bash "$TMP/run.sh" 2>&1)"
contains "a container check that could not run is warned under the record line" "WARN could not check docker for the deployment's container (exit 1)" "$out"
contains "and alone still answers 0" "RC=0" "$out"
# The database-only removal (exakit uninstall, pick "database") says the same.
seed_deploy
out="$(STUB_COMPONENT=database STUB_TD_RC=0 STUB_TW="could not check docker for the deployment's container (exit 1); check with: docker ps -a --filter name=exa-test1" bash "$TMP/run.sh" 2>&1)"
contains "database only: the unrun container check is warned" "WARN could not check docker for the deployment's container (exit 1)" "$out"
contains "database only: and alone still answers 0" "RC=0" "$out"
seed_deploy
out="$(STUB_COMPONENT=database STUB_TD_RC=1 STUB_TW="could not check podman for the deployment's container (exit 1); check with: podman ps -a --filter name=exa-test1" bash "$TMP/run.sh" 2>&1)"
contains "database only, deployment left: the warning is said too" "WARN could not check podman" "$out"
contains "database only, deployment left: answers 1" "RC=1" "$out"
out="$(STUB_COMPONENT=database STUB_TD_RC=0 bash "$TMP/run.sh" 2>&1)"
lacks    "database only, no warnings: no WARN line" "WARN could not check" "$out"
# No runtime in the manifest (an interrupted install) and the deployment on
# disk: nothing removes it, so the run must not answer 0 either.
seed_deploy
out="$(STUB_NO_TYPE=1 bash "$TMP/run.sh" 2>&1)"
lacks    "no runtime recorded + deployment on disk: not 0" "RC=0" "$out"
contains "and the directory is named with its remedy" "rm -rf '$DEPLOY'" "$out"
rm -rf "$DEPLOY"
out="$(STUB_NO_TYPE=1 bash "$TMP/run.sh" 2>&1)"
contains "no runtime recorded + nothing on disk: still 0" "RC=0" "$out"

# The add-on's own reason goes on the warning: the logs leave with the kit
# home in the same run (W1-01).
out="$(STUB_ADDON=1 STUB_ADDON_FAIL=1 STUB_TD_RC=0 bash "$TMP/run.sh" 2>&1)"
contains "an add-on that fails: the warning carries its reason" "WARN Removing the semantic-views add-on reported issues (continuing uninstall): 1 semantic model(s) are defined in the database" "$out"
lacks    "...without the id said twice" "(continuing uninstall): semantic-views:" "$out"
contains "...and the run goes on past it" "Add-ons removed: json-tables" "$out"
contains "...to the database" "Database removed" "$out"
out="$(STUB_ADDON=1 STUB_TD_RC=0 bash "$TMP/run.sh" 2>&1)"
lacks    "add-ons that are removed: no warning" "reported issues" "$out"
contains "...both named" "Add-ons removed: semantic-views, json-tables" "$out"
contains "...and what one wrote to stderr still reaches it" "json-tables: a note on stderr" "$out"

# --- the launcher's download cache and its empty state folders -----------
echo
echo "exakit_uninstall_run removes the launcher cache and the empty state folders:"
CACHE="$SBHOME/Library/Caches/.exasol"
[ "$(uname -s)" = Darwin ] || CACHE="$SBHOME/.cache/.exasol"
seed_cache() { rm -rf "$CACHE"; mkdir -p "$CACHE/personal/runtime-artifacts/artifacts/exasol-nano-image"; head -c 2097152 /dev/zero > "$CACHE/personal/runtime-artifacts/artifacts/exasol-nano-image/img"; }
gone() { [ -e "$1" ] && echo kept || echo gone; }
# (h1) dry run: the cache (with its size) and every folder that goes are listed,
# and nothing is removed.
rm -rf "$SBHOME/.exasol"; seed_deploy; seed_cache
out="$(STUB_DRY=1 env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
contains "h1: dry run lists the launcher cache" "will remove: Exasol launcher download cache $CACHE (" "$out"
contains "h1: dry run lists the deployments folder" "will remove: empty launcher folder $SBHOME/.exasol/personal/deployments" "$out"
contains "h1: dry run lists ~/.exasol" "will remove: empty launcher folder $SBHOME/.exasol" "$out"
check    "h1: dry run keeps the cache" "kept" "$(gone "$CACHE")"
check    "h1: dry run keeps the deployment" "kept" "$(gone "$DEPLOY")"
# (h2) the real run removes the cache and the folders it listed.
out="$(env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
contains "h2: the cache removal is recorded" "Launcher download cache removed: $CACHE" "$out"
check    "h2: the cache is gone" "gone" "$(gone "$CACHE")"
check    "h2: its parent cache folder stays" "kept" "$(gone "$(dirname "$CACHE")")"
check    "h2: ~/.exasol is gone" "gone" "$(gone "$SBHOME/.exasol")"
contains "h2: and the run answers 0" "RC=0" "$out"
# (h3) another deployment beside the kit's: cache and folders stay.
rm -rf "$SBHOME/.exasol"; seed_deploy; seed_cache
mkdir -p "$SBHOME/.exasol/personal/deployments/other"
out="$(STUB_DRY=1 env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
lacks    "h3: dry run does not list the shared cache" "launcher download cache" "$out"
lacks    "h3: nor any launcher folder" "empty launcher folder" "$out"
out="$(env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h3: the cache stays" "kept" "$(gone "$CACHE")"
check    "h3: the sibling deployment stays" "kept" "$(gone "$SBHOME/.exasol/personal/deployments/other")"
# (h3b) the kit's deployment lives elsewhere (EXAKIT_PERSONAL_DEPLOY_DIR set)
# and another one sits in the launcher's default folder: the cache stays.
rm -rf "$SBHOME/.exasol"; seed_cache
CUSTOM="$SBHOME/custom/deployments/kit"; mkdir -p "$CUSTOM"
mkdir -p "$SBHOME/.exasol/personal/deployments/other"
out="$(STUB_DEPLOY_DIR="$CUSTOM" env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h3b: a deployment in the default folder keeps the shared cache" "kept" "$(gone "$CACHE")"
check    "h3b: and that deployment stays" "kept" "$(gone "$SBHOME/.exasol/personal/deployments/other")"
# (h3c) the same with the default folder empty: the cache goes.
rm -rf "$SBHOME/.exasol"; seed_cache; mkdir -p "$CUSTOM"
out="$(STUB_DEPLOY_DIR="$CUSTOM" env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h3c: no other deployment anywhere: the cache goes" "gone" "$(gone "$CACHE")"
rm -rf "$SBHOME/custom"
# (h3e) 2.5.0's cache, <cache root>/exasol/launcher/resources: its two
# parents are left empty by the cache's removal and go too, while the cache
# root stays; a parent with something else in it stays (U-01).
CACHE25="$(dirname "$CACHE")/exasol/launcher/resources"
seed_cache25() { rm -rf "$CACHE" "$(dirname "$CACHE")/exasol"; mkdir -p "$CACHE25/personal"; head -c 1024 /dev/zero > "$CACHE25/personal/img"; }
rm -rf "$SBHOME/.exasol"; seed_deploy; seed_cache25
out="$(env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h3e: the 2.5.0 cache, exasol/launcher and exasol are gone, the cache root stays" "gone|gone|gone|kept" \
    "$(gone "$CACHE25")|$(gone "$(dirname "$CACHE25")")|$(gone "$(dirname "$(dirname "$CACHE25")")")|$(gone "$(dirname "$CACHE")")"
rm -rf "$SBHOME/.exasol"; seed_deploy; seed_cache25; : > "$(dirname "$CACHE")/exasol/someone-elses"
out="$(env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h3e: a parent with something else in it stays" "gone|gone|kept" \
    "$(gone "$CACHE25")|$(gone "$(dirname "$CACHE25")")|$(gone "$(dirname "$(dirname "$CACHE25")")")"
rm -rf "$(dirname "$CACHE")/exasol"
# (h3d) the launcher cache is a symlink: it is kept, never followed.
rm -rf "$SBHOME/.exasol"; seed_deploy; rm -rf "$CACHE"
mkdir -p "$TMP/cache-target/personal" "$(dirname "$CACHE")"; : > "$TMP/cache-target/personal/keep"
ln -s "$TMP/cache-target" "$CACHE"
out="$(env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h3d: a symlinked cache is kept" "kept" "$([ -L "$CACHE" ] && echo kept || echo gone)"
check    "h3d: and what it points at is untouched" "kept" "$(gone "$TMP/cache-target/personal/keep")"
lacks    "h3d: and not reported removed" "Launcher download cache removed" "$out"
rm -f "$CACHE"; rm -rf "$TMP/cache-target"
# (h4) a file beside personal/ keeps ~/.exasol but not the empty folders below.
rm -rf "$SBHOME/.exasol"; seed_deploy; seed_cache; : > "$SBHOME/.exasol/notes"
out="$(env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h4: ~/.exasol/personal is gone" "gone" "$(gone "$SBHOME/.exasol/personal")"
check    "h4: ~/.exasol with a file in it stays" "kept" "$(gone "$SBHOME/.exasol/notes")"
# (h5) a teardown that left the deployment: nothing beside it is touched.
rm -rf "$SBHOME/.exasol"; seed_deploy; seed_cache
out="$(STUB_TD_RC=1 env -u XDG_CACHE_HOME bash "$TMP/run.sh" 2>&1)"
check    "h5: a failed teardown keeps the cache" "kept" "$(gone "$CACHE")"
check    "h5: and the deployments folder" "kept" "$(gone "$SBHOME/.exasol/personal/deployments")"
rm -rf "$SBHOME/.exasol" "$CACHE"
# (h6) MODE P: the kit's launcher in its own home, next to an Exasol Personal
# of the user's, on Linux with the user's XDG_CACHE_HOME set. The launcher's
# cache the uninstall removes is the private home's (the wrapper gives the
# launcher that one), never the user's XDG_CACHE_HOME, which a launcher of
# theirs uses.
PKIT="$SBHOME/.exasol-starter-kit/personal"
PDEPLOY="$PKIT/home/.exasol/launcher/deployments/starter-kit-local"
PCACHE="$PKIT/home/.cache/exasol/launcher/resources"
UCACHE="$SBHOME/.cache-user/exasol/launcher/resources"
seed_modep() {
    rm -rf "$SBHOME/.cache-user" "$PKIT"
    mkdir -p "$PKIT/bin" "$PKIT/libexec" "$PDEPLOY" "$PCACHE" "$UCACHE"
    printf '#!/bin/sh\nexit 0\n' > "$PKIT/bin/exasol"; chmod +x "$PKIT/bin/exasol"
    cp "$PKIT/bin/exasol" "$PKIT/libexec/exasol"     # mode P: the binary behind the wrapper
    printf '{"deploymentId": "exa-p1"}\n' > "$PDEPLOY/deployment.json"
    : > "$PCACHE/kits"; : > "$UCACHE/theirs"
}
seed_modep
out="$(STUB_DRY=1 STUB_UNAME=Linux STUB_DEPLOY_DIR="$PDEPLOY" XDG_CACHE_HOME="$SBHOME/.cache-user" bash "$TMP/run.sh" 2>&1)"
contains "h6: dry run lists the private home's cache" "will remove: Exasol launcher download cache $PCACHE" "$out"
lacks    "h6: dry run never names the user's cache" "$SBHOME/.cache-user" "$out"
seed_modep
out="$(STUB_UNAME=Linux STUB_DEPLOY_DIR="$PDEPLOY" XDG_CACHE_HOME="$SBHOME/.cache-user" bash "$TMP/run.sh" 2>&1)"
contains "h6: the private home's cache is removed" "Launcher download cache removed: $PCACHE" "$out"
check    "h6: the user's own cache stays" "kept" "$(gone "$UCACHE/theirs")"
lacks    "h6: and is never named" "$SBHOME/.cache-user" "$out"
rm -rf "$SBHOME/.cache-user" "$PKIT"

# --- orphaned boot entries: swept by the kit prefix, whatever the registry says
echo
echo "exakit_uninstall_run sweeps orphaned kit boot entries:"
LA="$SBHOME/Library/LaunchAgents"; SD="$SBHOME/.config/systemd/user"
seed_entries() {
    rm -rf "$LA" "$SD" "$TMP/supervisor"; mkdir -p "$LA" "$SD"
    : > "$LA/com.exasol.exakit.dash-server.plist"
    : > "$SD/com.exasol.exakit.exasol-scheduler.service"
    : > "$LA/com.example.other.plist"
    : > "$LA/com.exasol.exakitfoo.plist"
    : > "$SD/other.service"
}
# (o1) dry run lists the orphans, removes nothing, never names a foreign entry.
seed_entries
out="$(STUB_DRY=1 bash "$TMP/run.sh" 2>&1)"
contains "o1: dry run lists the orphaned LaunchAgent" "will remove: the leftover automatic-start entry for dash-server ($LA/com.exasol.exakit.dash-server.plist)" "$out"
contains "o1: dry run lists the orphaned unit" "will remove: the leftover automatic-start entry for exasol-scheduler" "$out"
lacks    "o1: a foreign LaunchAgent is not listed" "com.example.other" "$out"
lacks    "o1: nor a near-miss prefix" "exakitfoo" "$out"
check    "o1: dry run keeps the orphan" "kept" "$(gone "$LA/com.exasol.exakit.dash-server.plist")"
lacks    "o1: dry run calls no supervisor" "LAUNCHCTL" "$(cat "$TMP/supervisor" 2>/dev/null)"
# (o2) the real run unloads and removes the orphans, leaves foreign ones.
seed_deploy
out="$(bash "$TMP/run.sh" 2>&1)"
check    "o2: the orphaned LaunchAgent is gone" "gone" "$(gone "$LA/com.exasol.exakit.dash-server.plist")"
check    "o2: the orphaned unit is gone" "gone" "$(gone "$SD/com.exasol.exakit.exasol-scheduler.service")"
contains "o2: launchd is told first" "LAUNCHCTL unload $LA/com.exasol.exakit.dash-server.plist" "$(cat "$TMP/supervisor" 2>/dev/null)"
contains "o2: systemd disables and stops it" "SYSTEMCTL --user disable --now com.exasol.exakit.exasol-scheduler.service" "$(cat "$TMP/supervisor" 2>/dev/null)"
contains "o2: the removal is recorded" "dash-server: leftover automatic-start entry removed" "$out"
check    "o2: a foreign LaunchAgent stays" "kept" "$(gone "$LA/com.example.other.plist")"
check    "o2: a near-miss prefix stays" "kept" "$(gone "$LA/com.exasol.exakitfoo.plist")"
check    "o2: a foreign unit stays" "kept" "$(gone "$SD/other.service")"
rm -rf "$LA" "$SD" "$SBHOME/.exasol"

# --- the container images the deployment ran from ------------------------
echo
echo "exakit_uninstall_run removes the kit's container images, and only those:"
# Stub engines: `images` prints STUB_<ENGINE>_IMAGES (repo|tag|id|size rows),
# `rmi` records its arguments and fails for a ref named in STUB_RMI_FAIL.
# What the deployment ran from (audit LNX-01): `ps -a` prints
# STUB_<ENGINE>_CTRS, and `inspect <container>` / `image inspect <ref>` answer
# the id STUB_<ENGINE>_OBJ_IDS maps it to ("name=id" words).
mkdir -p "$TMP/eng" "$TMP/noeng"
for _e in docker podman; do
    _uc="$(printf '%s' "$_e" | tr a-z A-Z)"
    cat > "$TMP/eng/$_e" <<STUB
#!/bin/sh
printf '$_e %s\n' "\$*" >> "$TMP/engcalls"
case "\$1" in
    images) printf '%s\n' "\${STUB_${_uc}_IMAGES:-}"; exit "\${STUB_${_uc}_RC:-0}" ;;
    rmi) case " \${STUB_RMI_FAIL:-} " in *" \$2 "*) echo "conflict: image is being used by running container abc" >&2; exit 1 ;; esac ;;
    ps) printf '%s\n' "\${STUB_${_uc}_CTRS:-}" ;;
    inspect) for _p in \${STUB_${_uc}_OBJ_IDS:-}; do [ "\${_p%%=*}" = "\$4" ] && printf 'sha256:%s\n' "\${_p#*=}"; done ;;
    image) for _p in \${STUB_${_uc}_OBJ_IDS:-}; do [ "\${_p%%=*}" = "\$5" ] && printf 'sha256:%s\n' "\${_p#*=}"; done ;;
esac
exit 0
STUB
    chmod +x "$TMP/eng/$_e"
done
DOCKER_IMGS="$(printf '%s\n' 'exasol/nano|2026.2.0-nano.8|aaa111|812MB' 'exasol/nano|<none>|ggg777|800MB' 'exasol/mcp-server|<none>|bbb222|426MB' 'exasol/script-language-container|standard-EXASOL-all-java-17-release_abc|hhh888|1.01GB' 'exasol/nanoX|1|ccc333|1MB' 'library/postgres|16|ddd444|400MB' 'someone/exasol/nano|1|eee555|1MB')"
PODMAN_IMGS='docker.io/exasol/nano|2026.2.0-nano.8|fff666|812MB'
# The deployment (exa-test1, on Docker) ran from aaa111 (its database
# container), bbb222 (its MCP sidecar) and the Java language container its
# launcher state lists. exasol-db-exa-test10 is ANOTHER deployment on the same
# engine: its image ggg777 is not this kit's.
export STUB_DOCKER_CTRS="$(printf '%s\n' exasol-db-exa-test1 exasol-db-exa-test1-sidecar-mcp exasol-db-exa-test10)"
export STUB_DOCKER_OBJ_IDS="exasol-db-exa-test1=aaa111 exasol-db-exa-test1-sidecar-mcp=bbb222 exasol-db-exa-test10=ggg777 exasol/script-language-container:standard-EXASOL-all-java-17-release_abc=hhh888"
seed_img_deploy() {
    seed_deploy
    printf '{"deploymentId": "exa-test1", "installedSlcs": [{"flavor": "java", "image": "exasol/script-language-container:standard-EXASOL-all-java-17-release_abc", "installed": true}]}\n' > "$DEPLOY/.exasolLauncherState.json"
}
# Every image case runs the code with PATH="<dir>:$TMP/sysbin". Before any of
# them, each engine must resolve inside <dir> or not at all; anything else
# FAILS the suite and the cases do not run, so no real engine is ever called.
engines_sealed() { # engines_sealed <stub dir> <label>
    _ses=0
    for _se in docker podman; do
        _sp="$(PATH="$1:$TMP/sysbin" command -v "$_se" 2>/dev/null || true)"
        case "$_sp" in ''|"$1/"*) : ;; *) _ses=1; FAIL=$((FAIL + 1)); printf '  FAIL %s: %s resolves outside the stub dir (%s)\n' "$2" "$_se" "$_sp" ;; esac
    done
    [ "$_ses" = 0 ] && { PASS=$((PASS + 1)); printf '  ok   %s: no real engine reachable\n' "$2"; }
    return "$_ses"
}
if engines_sealed "$TMP/eng" "image cases"; then
# (i1) dry run: the kit's images listed with engine and size, nothing removed.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DRY=1 STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_PODMAN_IMAGES="$PODMAN_IMGS" bash "$TMP/run.sh" 2>&1)"
contains "i1: dry run lists exasol/nano" "will remove: docker image exasol/nano:2026.2.0-nano.8 (812MB)" "$out"
contains "i1: another deployment's image on the same engine is kept, and said so" "Kept image exasol/nano:<none>: the kit has no record that its database used it, so it may be another installation's. If nothing uses it, remove it with: docker rmi ggg777" "$out"
lacks    "i1: ...never listed for removal" "will remove: docker image exasol/nano:<none>" "$out"
contains "i1: dry run lists the MCP server image the sidecar ran from" "will remove: docker image exasol/mcp-server:<none> (426MB)" "$out"
contains "i1: dry run lists the language container a connect installed" "will remove: docker image exasol/script-language-container:standard-EXASOL-all-java-17-release_abc (1.01GB)" "$out"
lacks    "i1: the engine the deployment did not run on is not swept" "podman image" "$out"
lacks    "i1: ...nor asked at all" "podman" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i1: a foreign image is not listed" "postgres" "$out"
lacks    "i1: nor a near-miss repository" "nanoX" "$out"
lacks    "i1: nor one that only ends in exasol/nano" "someone/" "$out"
lacks    "i1: dry run runs no rmi" "rmi" "$(cat "$TMP/engcalls" 2>/dev/null)"
# (m1) a deployment without deployment.json: the MCP-process stop gets no
# port, so nothing on 8563 (another database's MCP server) is stopped.
rm -f "$TMP/engcalls"; rm -rf "$DEPLOY"; mkdir -p "$DEPLOY"
out="$(STUB_OS=linux STUB_MCP_REC=1 bash "$TMP/run.sh" 2>&1)"
contains "m1: no deployment.json: the MCP stop gets an empty port" "MCPSTOP dry=0 port=[]" "$out"
lacks    "m1: never the 8563 default" "port=[8563]" "$out"
# (m2) the recorded port is the one used.
rm -f "$TMP/engcalls"; rm -rf "$DEPLOY"; mkdir -p "$DEPLOY"; printf '{"deploymentId": "exa-test1", "connection": {"dbPort": 18563}}\n' > "$DEPLOY/deployment.json"
out="$(STUB_OS=linux STUB_MCP_REC=1 bash "$TMP/run.sh" 2>&1)"
contains "m2: deployment.json's dbPort is handed on" "MCPSTOP dry=0 port=[18563]" "$out"
# (i2) real run: rmi without -f for each kit image, never for a foreign one.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_PODMAN_IMAGES="$PODMAN_IMGS" bash "$TMP/run.sh" 2>&1)"
calls="$(cat "$TMP/engcalls" 2>/dev/null)"
contains "i2: exasol/nano removed by name" "docker rmi exasol/nano:2026.2.0-nano.8" "$calls"
lacks    "i2: another deployment's image on the same engine is not removed" "docker rmi ggg777" "$calls"
lacks    "i2: the other engine is never swept" "podman" "$calls"
contains "i2: the MCP server image (pulled by digest, <none>) removed by id" "docker rmi bbb222" "$calls"
contains "i2: the language container removed by name" "docker rmi exasol/script-language-container:standard-EXASOL-all-java-17-release_abc" "$calls"
lacks    "i2: never with -f" "rmi -f" "$calls"
lacks    "i2: never --force" "--force" "$calls"
lacks    "i2: a foreign image is untouched" "ddd444" "$calls"
lacks    "i2: by name either" "postgres" "$calls"
lacks    "i2: a near-miss repository is untouched" "ccc333" "$calls"
lacks    "i2: an image ending in exasol/nano is untouched" "eee555" "$calls"
contains "i2: the removal is recorded, one name per repository" "Container images removed (docker): exasol/nano, exasol/mcp-server, script-language-container" "$out"
contains "i2: and the run answers 0" "RC=0" "$out"
# (i2b) podman lists one image as a tag row AND a <none> row: one rmi, no "kept".
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_ENGINE=podman STUB_PODMAN_CTRS=exasol-db-exa-test1 STUB_PODMAN_OBJ_IDS=exasol-db-exa-test1=fff666 STUB_PODMAN_IMAGES="$(printf '%s\n' 'docker.io/exasol/nano|2026.2.0-nano.8|fff666|812MB' 'docker.io/exasol/nano|<none>|fff666|812MB')" bash "$TMP/run.sh" 2>&1)"
check    "i2b: one rmi for one image id" "1" "$(grep -c '^podman rmi' "$TMP/engcalls" 2>/dev/null)"
lacks    "i2b: the duplicate row is not reported kept" "Kept image" "$out"
# (i2b') the same, with the <none> row listed FIRST: tagged rows still go
# first, so the tag is removed by name and the <none> twin is skipped.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_ENGINE=podman STUB_PODMAN_CTRS=exasol-db-exa-test1 STUB_PODMAN_OBJ_IDS=exasol-db-exa-test1=fff666 STUB_PODMAN_IMAGES="$(printf '%s\n' 'docker.io/exasol/nano|<none>|fff666|812MB' 'docker.io/exasol/nano|2026.2.0-nano.8|fff666|812MB')" bash "$TMP/run.sh" 2>&1)"
check    "i2b': <none> listed first: one rmi" "1" "$(grep -c '^podman rmi' "$TMP/engcalls" 2>/dev/null)"
contains "i2b': and it is the tag, by name" "podman rmi docker.io/exasol/nano:2026.2.0-nano.8" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i2b': no rmi by id" "podman rmi fff666" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i2b': nothing reported kept" "Kept image" "$out"
# (i2c) one image with TWO tags: each tag is removed by name, or the image stays.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DOCKER_OBJ_IDS=exasol-db-exa-test1=abc123 STUB_DOCKER_IMAGES="$(printf '%s\n' 'exasol/nano|2026.2.0|abc123|812MB' 'exasol/nano|latest|abc123|812MB')" bash "$TMP/run.sh" 2>&1)"
check    "i2c: both tags of one image are removed" "2" "$(grep -c '^docker rmi exasol/nano:' "$TMP/engcalls" 2>/dev/null)"
contains "i2c: the second tag by its name" "docker rmi exasol/nano:latest" "$(cat "$TMP/engcalls" 2>/dev/null)"
# (i2d) a <none> exasol/nano row whose id also carries a user's tag from
# another repository: podman would delete that tag with an rmi by id. Kept.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_ENGINE=podman STUB_PODMAN_CTRS="$(printf '%s\n' exasol-db-exa-test1 exasol-db-exa-test1-sidecar-mcp)" STUB_PODMAN_OBJ_IDS="exasol-db-exa-test1=aaa999 exasol-db-exa-test1-sidecar-mcp=bbb888" STUB_PODMAN_IMAGES="$(printf '%s\n' 'docker.io/exasol/nano|<none>|aaa999|812MB' 'localhost/myorg/foo|1|aaa999|812MB' 'docker.io/exasol/nano|<none>|bbb888|800MB')" bash "$TMP/run.sh" 2>&1)"
lacks    "i2d: no rmi by id for an image a user's tag shares" "podman rmi aaa999" "$(cat "$TMP/engcalls" 2>/dev/null)"
contains "i2d: it is reported kept" "Kept image exasol/nano:<none> (id aaa999): it also carries another repository's tag." "$out"
contains "i2d: a <none> row with no other name still goes" "podman rmi bbb888" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i2d: the user's tag is never named" "myorg" "$(grep rmi "$TMP/engcalls" 2>/dev/null)"
# (i2f) no container query decides an image's fate: a dry run, where the
# deployment's own container still exists, lists the image as "will remove",
# and an image a container does use is kept by the engine's refusal (i3).
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DRY=1 STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
contains "i2f: dry run lists the image as will remove" "will remove: docker image exasol/nano:2026.2.0-nano.8" "$out"
lacks    "i2f: no engine is asked which containers use it" "ancestor=" "$(cat "$TMP/engcalls" 2>/dev/null)"
# (i3) rmi refused (a container still uses it): kept, one hint, exit unchanged.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_RMI_FAIL="exasol/nano:2026.2.0-nano.8" bash "$TMP/run.sh" 2>&1)"
contains "i3: a refused rmi is kept with its remedy" "Kept image exasol/nano:2026.2.0-nano.8: docker did not remove it (a container may still use it, or docker did not answer). Remove it later with: docker rmi exasol/nano:2026.2.0-nano.8" "$out"
contains "i3: the other images still go" "Container images removed (docker): exasol/mcp-server, script-language-container" "$out"
contains "i3: and the run still answers 0" "RC=0" "$out"
# (i3b) the language container still in use by another container: the engine
# refuses, it is kept with its remedy, and the rest still goes.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_RMI_FAIL="exasol/script-language-container:standard-EXASOL-all-java-17-release_abc" bash "$TMP/run.sh" 2>&1)"
contains "i3b: an in-use language container is kept with its remedy" "Kept image exasol/script-language-container:standard-EXASOL-all-java-17-release_abc: docker did not remove it (a container may still use it, or docker did not answer). Remove it later with: docker rmi exasol/script-language-container:standard-EXASOL-all-java-17-release_abc" "$out"
contains "i3b: the others still go" "Container images removed (docker): exasol/nano, exasol/mcp-server" "$out"
lacks    "i3b: the kept one is not called removed" "mcp-server, script-language-container" "$out"
# (i3q) W1-03: the dry run listed them as "will remove", and the real run's
# per-image "Kept image" lines are quiet (the log leaves with the kit home).
# The images it kept are named on one line that outlives the quiet run.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_QUIET=1 STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_RMI_FAIL="exasol/nano:2026.2.0-nano.8 exasol/script-language-container:standard-EXASOL-all-java-17-release_abc" bash "$TMP/run.sh" 2>&1)"
contains "i3q: a quiet real run says which images it kept, and why" "INFO Container images kept (docker): exasol/nano, script-language-container. docker did not remove them (a container may still use them, or docker did not answer). Remove them later with: docker rmi exasol/nano:2026.2.0-nano.8 exasol/script-language-container:standard-EXASOL-all-java-17-release_abc" "$out"
contains "i3q: the one removed is still said" "Container images removed (docker): exasol/mcp-server" "$out"
check    "i3q: one line, not one per image" "1" "$(printf '%s\n' "$out" | grep -c 'Container images kept')"
out="$(STUB_QUIET=1 STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
lacks    "i3q: nothing kept: no such line" "Container images kept" "$out"
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_DRY=1 STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_RMI_FAIL="exasol/nano:2026.2.0-nano.8" bash "$TMP/run.sh" 2>&1)"
lacks    "i3q: a dry run removes nothing, so keeps nothing either" "Container images kept" "$out"
# (L1) ANOTHER INSTALLATION ON THE SAME ENGINE (audit LNX-01): a WSL kit on
# Podman and a Windows kit on Docker Desktop, or the reverse. The engine this
# deployment did not run on is never asked, and an image of the kit's
# repositories this deployment did not run from is kept, and said so.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_ENGINE=podman STUB_PODMAN_CTRS=exasol-db-exa-test1 STUB_PODMAN_OBJ_IDS=exasol-db-exa-test1=fff666 STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_PODMAN_IMAGES="$PODMAN_IMGS" bash "$TMP/run.sh" 2>&1)"
calls="$(cat "$TMP/engcalls" 2>/dev/null)"
contains "L1: a Podman deployment's own image goes" "podman rmi docker.io/exasol/nano:2026.2.0-nano.8" "$calls"
lacks    "L1: Docker, which it did not run on, is never asked" "docker " "$calls"
contains "L1: the removal names its engine" "Container images removed (podman): exasol/nano" "$out"
# (L2) the deployment's containers are gone and its state names no image: the
# kit cannot tell which images were its own, so it keeps every one, and says so.
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_DOCKER_CTRS= STUB_DOCKER_OBJ_IDS= STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
lacks    "L2: nothing it cannot prove is its own is removed" "rmi" "$(cat "$TMP/engcalls" 2>/dev/null)"
contains "L2: each kept image is said, with the command to remove it" "Kept image exasol/nano:2026.2.0-nano.8: the kit has no record that its database used it, so it may be another installation's. If nothing uses it, remove it with: docker rmi exasol/nano:2026.2.0-nano.8" "$out"
lacks    "L2: no removal is claimed" "Container images removed" "$out"
# (L4) a stopped deployment whose containers are gone: the images its launcher
# state names (the language container, the MCP sidecar in sidecars.yaml) are
# still its own and go; the database image nothing names is kept.
rm -f "$TMP/engcalls"; seed_img_deploy
printf 'sidecars:\n  - name: mcp\n    image: docker.io/exasol/mcp-server:2.4.0@sha256:ae13\n    imagePullPolicy: IfNotPresent\n' > "$DEPLOY/sidecars.yaml"
out="$(STUB_OS=linux STUB_DOCKER_CTRS= STUB_DOCKER_OBJ_IDS="docker.io/exasol/mcp-server:2.4.0@sha256:ae13=bbb222 exasol/script-language-container:standard-EXASOL-all-java-17-release_abc=hhh888" STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
calls="$(cat "$TMP/engcalls" 2>/dev/null)"
contains "L4: the language container its state names goes" "docker rmi exasol/script-language-container:standard-EXASOL-all-java-17-release_abc" "$calls"
contains "L4: the MCP image its sidecars.yaml names goes" "docker rmi bbb222" "$calls"
lacks    "L4: the database image nothing names is kept" "docker rmi exasol/nano" "$calls"
# (L3) the recorded engine is not on this machine, the other one is: not swept.
mkdir -p "$TMP/eng-docker-only"; cp "$TMP/eng/docker" "$TMP/eng-docker-only/docker"
if engines_sealed "$TMP/eng-docker-only" "L3"; then
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_ENG_DIR="$TMP/eng-docker-only" STUB_ENGINE=podman STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
check    "L3: the other engine is never asked" "" "$(cat "$TMP/engcalls" 2>/dev/null)"
contains "L3: it says the engine was not found" "podman, the engine the database ran on, was not found, so the kit's container images were not checked." "$out"
fi
# (i4) the engine does not answer: one hint, exit unchanged.
seed_img_deploy
out="$(STUB_OS=linux STUB_DOCKER_RC=1 bash "$TMP/run.sh" 2>&1)"
contains "i4: an engine that does not answer gets a hint" "Could not ask docker for the kit's container images" "$out"
contains "i4: and the run still answers 0" "RC=0" "$out"
# (i7) another deployment still runs from the image: no engine is asked.
rm -f "$TMP/engcalls"; seed_img_deploy; mkdir -p "$SBHOME/.exasol/personal/deployments/other"
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
lacks    "i7: another deployment keeps exasol/nano" "rmi" "$(cat "$TMP/engcalls" 2>/dev/null)"
rm -rf "$SBHOME/.exasol/personal/deployments/other"
# (i8) the database was left behind: no engine is asked either.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=linux STUB_TD_RC=1 STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
lacks    "i8: a database left behind keeps its image" "rmi" "$(cat "$TMP/engcalls" 2>/dev/null)"
rm -rf "$DEPLOY"
# (i9) no deployment on this machine at all (a sandboxed home): the engine is
# never asked. Without the had-a-deployment guard this case reaches the engine.
rm -f "$TMP/engcalls"; rm -rf "$DEPLOY"
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_PODMAN_IMAGES="$PODMAN_IMGS" bash "$TMP/run.sh" 2>&1)"
check    "i9: no deployment dir, no engine call" "" "$(cat "$TMP/engcalls" 2>/dev/null)"
fi
# (i5) no engine at all: one hint, exit unchanged.
if engines_sealed "$TMP/noeng" "i5 (no engine)"; then
seed_img_deploy
out="$(STUB_OS=linux STUB_ENG_DIR="$TMP/noeng" bash "$TMP/run.sh" 2>&1)"
contains "i5: no engine gets a hint" "Neither Docker nor Podman was found" "$out"
contains "i5: and the run still answers 0" "RC=0" "$out"
fi
# (i6) macOS: the database lives in the launcher's VM; the host engine is left alone.
rm -f "$TMP/engcalls"; seed_img_deploy
out="$(STUB_OS=macos STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
check    "i6: macOS asks no engine" "" "$(cat "$TMP/engcalls" 2>/dev/null)"
rm -rf "$SBHOME/.exasol"

# --- cmd_uninstall --yes: the final word and the exit code ---------------
echo
echo "cmd_uninstall --yes only says complete when it is:"
cat > "$TMP/cmd.sh" <<HARNESS
set -u
HOME="$SBHOME"; export HOME
EXAKIT_HOME="$SBHOME/.exasol-starter-kit"; EXAKIT_BIN_DIR="$SBHOME/.local/bin"
EXAKIT_MANIFEST="\$EXAKIT_HOME/manifest.json"; EXAKIT_EXAPUMP_PROFILE=x
info(){ printf 'INFO %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
ok(){ printf 'OK %s\n' "\$*"; }; error(){ printf 'ERROR %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }; reject(){ printf 'REJECT %s\n' "\$*"; exit 2; }
exakit_init_logging(){ :; }
exakit_uninstall_run(){ printf 'RUN dry=%s\n' "\$1"; [ "\$1" = 1 ] && return 0; return "\${STUB_RUN_RC:-0}"; }
exakit_uninstall_menu(){ printf 'MENU\n'; }
eval "\$(awk '/^cmd_uninstall\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/exakit")"
mkdir -p "\$EXAKIT_HOME" && : > "\$EXAKIT_MANIFEST"
cmd_uninstall "\$@"
HARNESS

out="$(STUB_RUN_RC=1 bash "$TMP/cmd.sh" --yes 2>&1)"; rc=$?
check    "a run that left the database exits 1" "1" "$rc"
lacks    "and never says 'Uninstall complete'" "Uninstall complete" "$out"
contains "and says it did not finish" "did not finish" "$out"
out="$(STUB_RUN_RC=0 bash "$TMP/cmd.sh" --yes 2>&1)"; rc=$?
check    "a clean run exits 0" "0" "$rc"
contains "and says 'Uninstall complete'" "Uninstall complete" "$out"
out="$(STUB_RUN_RC=1 bash "$TMP/cmd.sh" --dry-run 2>&1)"; rc=$?
check    "--dry-run still exits 0" "0" "$rc"
lacks    "and never runs the removal for real" "RUN dry=0" "$out"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
