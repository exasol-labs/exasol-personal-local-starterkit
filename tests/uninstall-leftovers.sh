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
DEPLOY="$SBHOME/.exasol/personal/deployments/default"

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
        [ "${STUB_DESTROY_REMOVES:-0}" = 1 ] && rm -rf "$STUB_DEPLOY"
        exit "${STUB_DESTROY_RC:-0}" ;;
esac
exit 0
STUB
# docker / podman: `ps -a` lists STUB_DOCKER_PS / STUB_PODMAN_PS. On PATH ahead
# of any real engine, so no real container is ever listed or touched.
printf '#!/usr/bin/env bash\n[ -n "${STUB_DOCKER_FAIL:-}" ] && { echo "$STUB_DOCKER_FAIL" >&2; exit 1; }\n[ "$1" = ps ] && printf "%%s\\n" "${STUB_DOCKER_PS:-}"\nexit 0\n' > "$TMP/bin/docker"
printf '#!/usr/bin/env bash\n[ "$1" = ps ] && printf "%%s\\n" "${STUB_PODMAN_PS:-}"\nexit 0\n' > "$TMP/bin/podman"
chmod +x "$TMP/bin/exasol" "$TMP/bin/docker" "$TMP/bin/podman"

# --- personal_teardown, the real function ---------------------------------
cat > "$TMP/teardown.sh" <<HARNESS
set -u
HOME="$SBHOME"; export HOME
export STUB_CALLS="$TMP/calls" STUB_DEPLOY="$DEPLOY"
export PATH="$TMP/bin:\$PATH"
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }
warn(){ printf 'WARN %s\n' "\$*"; }; error(){ printf 'ERROR %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
manifest_get(){ :; }; manifest_set(){ printf 'MANIFEST %s=%s\n' "\$1" "\$2"; }
manifest_del(){ :; }
detect_os(){ printf '%s' "\${STUB_OS:-macos}"; }
exakit_run_bounded(){ shift; "\$@"; }
run_logged(){ "\$@" >/dev/null 2>&1; }
port_in_use(){ return 1; }
EXAKIT_BIN_DIR="$TMP/bin"
EXAKIT_PERSONAL_DEPLOY_DIR="$DEPLOY"
source "$ROOT/setup/lib/runtime-personal.sh"
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
contains "g2: but it is a warning with the check command" "WARNINGS=Could not ask docker whether the database's container is gone (docker said: permission denied while trying to connect to the Docker daemon socket). Check by hand once docker answers: docker ps -a --filter name=exa-test1 (if docker needs sudo here: sudo docker ps -a --filter name=exa-test1)" "$out"
out="$(teardown STUB_OS=linux STUB_DESTROY_RC=0 STUB_DESTROY_REMOVES=1)"
contains "g2: an engine that answers gives no warning" "WARNINGS=" "$out"
lacks    "g2: none at all" "Could not ask" "$out"

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
info(){ printf 'INFO %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
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
exakit_run_bounded(){ shift; "\$@"; }
$(grep '^EXAKIT_KIT_IMAGE_REPOS=' "$ROOT/setup/lib/common.sh")
manifest_get(){ case "\$1" in runtime.type) [ "\${STUB_NO_TYPE:-0}" = 1 ] || echo personal ;; *) echo "" ;; esac; }
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
for _fn in personal_launcher_cache_dir personal_other_deployments personal_prunable_state_dirs; do
    eval "\$(awk -v n="\$_fn" '\$0 ~ ("^" n "\\\\(\\\\)") {f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/runtime-personal.sh")"
done
eval "\$(awk '/^_exakit_remove_installed_skills\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
for _fn in _exakit_uninstall_leftover_report _exakit_uninstall_recorded_db_port _exakit_uninstall_teardown_warnings _exakit_uninstall_component _exakit_uninstall_orphan_autostart _exakit_uninstall_kit_images exakit_uninstall_run; do
    eval "\$(awk -v n="\$_fn" '\$0 ~ ("^" n "\\\\(\\\\)") {f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
done
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
mkdir -p "$TMP/eng" "$TMP/noeng"
for _e in docker podman; do
    _uc="$(printf '%s' "$_e" | tr a-z A-Z)"
    cat > "$TMP/eng/$_e" <<STUB
#!/bin/sh
printf '$_e %s\n' "\$*" >> "$TMP/engcalls"
case "\$1" in
    images) printf '%s\n' "\${STUB_${_uc}_IMAGES:-}"; exit "\${STUB_${_uc}_RC:-0}" ;;
    rmi) case " \${STUB_RMI_FAIL:-} " in *" \$2 "*) echo "conflict: image is being used by running container abc" >&2; exit 1 ;; esac ;;
esac
exit 0
STUB
    chmod +x "$TMP/eng/$_e"
done
DOCKER_IMGS="$(printf '%s\n' 'exasol/nano|2026.2.0-nano.8|aaa111|812MB' 'exasol/nano|<none>|ggg777|800MB' 'exasol/mcp-server|<none>|bbb222|426MB' 'exasol/nanoX|1|ccc333|1MB' 'library/postgres|16|ddd444|400MB' 'someone/exasol/nano|1|eee555|1MB')"
PODMAN_IMGS='docker.io/exasol/nano|2026.2.0-nano.8|fff666|812MB'
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
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_DRY=1 STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_PODMAN_IMAGES="$PODMAN_IMGS" bash "$TMP/run.sh" 2>&1)"
contains "i1: dry run lists exasol/nano" "will remove: docker image exasol/nano:2026.2.0-nano.8 (812MB)" "$out"
contains "i1: dry run lists the untagged nano" "will remove: docker image exasol/nano:<none> (800MB)" "$out"
lacks    "i1: exasol/mcp-server is not the kit's (MCP runs through uvx)" "exasol/mcp-server" "$out"
contains "i1: dry run lists podman's copy" "will remove: podman image exasol/nano:2026.2.0-nano.8 (812MB)" "$out"
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
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_PODMAN_IMAGES="$PODMAN_IMGS" bash "$TMP/run.sh" 2>&1)"
calls="$(cat "$TMP/engcalls" 2>/dev/null)"
contains "i2: exasol/nano removed by name" "docker rmi exasol/nano:2026.2.0-nano.8" "$calls"
contains "i2: the untagged image removed by id" "docker rmi ggg777" "$calls"
contains "i2: podman's copy removed by the exact listed reference" "podman rmi docker.io/exasol/nano:2026.2.0-nano.8" "$calls"
lacks    "i2: exasol/mcp-server is untouched" "bbb222" "$calls"
lacks    "i2: never with -f" "rmi -f" "$calls"
lacks    "i2: never --force" "--force" "$calls"
lacks    "i2: a foreign image is untouched" "ddd444" "$calls"
lacks    "i2: by name either" "postgres" "$calls"
lacks    "i2: a near-miss repository is untouched" "ccc333" "$calls"
lacks    "i2: an image ending in exasol/nano is untouched" "eee555" "$calls"
contains "i2: the removal is recorded" "Container images removed (docker): exasol/nano:2026.2.0-nano.8, exasol/nano:<none>" "$out"
contains "i2: and the run answers 0" "RC=0" "$out"
# (i2b) podman lists one image as a tag row AND a <none> row: one rmi, no "kept".
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_PODMAN_IMAGES="$(printf '%s\n' 'docker.io/exasol/nano|2026.2.0-nano.8|fff666|812MB' 'docker.io/exasol/nano|<none>|fff666|812MB')" bash "$TMP/run.sh" 2>&1)"
check    "i2b: one rmi for one image id" "1" "$(grep -c '^podman rmi' "$TMP/engcalls" 2>/dev/null)"
lacks    "i2b: the duplicate row is not reported kept" "Kept image" "$out"
# (i2b') the same, with the <none> row listed FIRST: tagged rows still go
# first, so the tag is removed by name and the <none> twin is skipped.
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_PODMAN_IMAGES="$(printf '%s\n' 'docker.io/exasol/nano|<none>|fff666|812MB' 'docker.io/exasol/nano|2026.2.0-nano.8|fff666|812MB')" bash "$TMP/run.sh" 2>&1)"
check    "i2b': <none> listed first: one rmi" "1" "$(grep -c '^podman rmi' "$TMP/engcalls" 2>/dev/null)"
contains "i2b': and it is the tag, by name" "podman rmi docker.io/exasol/nano:2026.2.0-nano.8" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i2b': no rmi by id" "podman rmi fff666" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i2b': nothing reported kept" "Kept image" "$out"
# (i2c) one image with TWO tags: each tag is removed by name, or the image stays.
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$(printf '%s\n' 'exasol/nano|2026.2.0|abc123|812MB' 'exasol/nano|latest|abc123|812MB')" bash "$TMP/run.sh" 2>&1)"
check    "i2c: both tags of one image are removed" "2" "$(grep -c '^docker rmi exasol/nano:' "$TMP/engcalls" 2>/dev/null)"
contains "i2c: the second tag by its name" "docker rmi exasol/nano:latest" "$(cat "$TMP/engcalls" 2>/dev/null)"
# (i2d) a <none> exasol/nano row whose id also carries a user's tag from
# another repository: podman would delete that tag with an rmi by id. Kept.
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_PODMAN_IMAGES="$(printf '%s\n' 'docker.io/exasol/nano|<none>|aaa999|812MB' 'localhost/myorg/foo|1|aaa999|812MB' 'docker.io/exasol/nano|<none>|bbb888|800MB')" bash "$TMP/run.sh" 2>&1)"
lacks    "i2d: no rmi by id for an image a user's tag shares" "podman rmi aaa999" "$(cat "$TMP/engcalls" 2>/dev/null)"
contains "i2d: it is reported kept" "Kept image exasol/nano:<none> (id aaa999): it also carries another repository's tag." "$out"
contains "i2d: a <none> row with no other name still goes" "podman rmi bbb888" "$(cat "$TMP/engcalls" 2>/dev/null)"
lacks    "i2d: the user's tag is never named" "myorg" "$(grep rmi "$TMP/engcalls" 2>/dev/null)"
# (i2f) no container query decides an image's fate: a dry run, where the
# deployment's own container still exists, lists the image as "will remove",
# and an image a container does use is kept by the engine's refusal (i3).
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_DRY=1 STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
contains "i2f: dry run lists the image as will remove" "will remove: docker image exasol/nano:2026.2.0-nano.8" "$out"
lacks    "i2f: no engine is asked which containers use it" "ancestor=" "$(cat "$TMP/engcalls" 2>/dev/null)"
# (i3) rmi refused (a container still uses it): kept, one hint, exit unchanged.
rm -f "$TMP/engcalls"; seed_deploy
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" STUB_RMI_FAIL="exasol/nano:2026.2.0-nano.8" bash "$TMP/run.sh" 2>&1)"
contains "i3: a refused rmi is kept with its remedy" "Kept image exasol/nano:2026.2.0-nano.8: docker did not remove it (a container may still use it, or docker did not answer). Remove it later with: docker rmi exasol/nano:2026.2.0-nano.8" "$out"
contains "i3: the other image still goes" "Container images removed (docker): exasol/nano:<none>" "$out"
contains "i3: and the run still answers 0" "RC=0" "$out"
# (i4) the engine does not answer: one hint, exit unchanged.
seed_deploy
out="$(STUB_OS=linux STUB_DOCKER_RC=1 bash "$TMP/run.sh" 2>&1)"
contains "i4: an engine that does not answer gets a hint" "Could not ask docker for the kit's container images" "$out"
contains "i4: and the run still answers 0" "RC=0" "$out"
# (i7) another deployment still runs from the image: no engine is asked.
rm -f "$TMP/engcalls"; seed_deploy; mkdir -p "$SBHOME/.exasol/personal/deployments/other"
out="$(STUB_OS=linux STUB_DOCKER_IMAGES="$DOCKER_IMGS" bash "$TMP/run.sh" 2>&1)"
lacks    "i7: another deployment keeps exasol/nano" "rmi" "$(cat "$TMP/engcalls" 2>/dev/null)"
rm -rf "$SBHOME/.exasol/personal/deployments/other"
# (i8) the database was left behind: no engine is asked either.
rm -f "$TMP/engcalls"; seed_deploy
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
seed_deploy
out="$(STUB_OS=linux STUB_ENG_DIR="$TMP/noeng" bash "$TMP/run.sh" 2>&1)"
contains "i5: no engine gets a hint" "Neither Docker nor Podman was found" "$out"
contains "i5: and the run still answers 0" "RC=0" "$out"
fi
# (i6) macOS: the database lives in the launcher's VM; the host engine is left alone.
rm -f "$TMP/engcalls"; seed_deploy
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
