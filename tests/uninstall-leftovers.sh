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
printf '#!/usr/bin/env bash\n[ "$1" = ps ] && printf "%%s\\n" "${STUB_DOCKER_PS:-}"\nexit 0\n' > "$TMP/bin/docker"
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

# (f) nothing was ever deployed: success, nothing destroyed.
rm -rf "$DEPLOY"
out="$(teardown)"
contains "f: no deployment is success" "RC=0" "$out"
lacks    "f: and destroy is not called" "destroy" "$(cat "$TMP/calls" 2>/dev/null)"

# --- exakit_uninstall_run: the record line and the status ----------------
echo
echo "exakit_uninstall_run does not claim a removal that did not happen:"
cat > "$TMP/run.sh" <<HARNESS
set -u
HOME="$SBHOME"; export HOME
EXAKIT_HOME="$SBHOME/.exasol-starter-kit"; EXAKIT_BIN_DIR="$SBHOME/.local/bin"
EXAKIT_EXAPUMP_CONFIG_DIR="$SBHOME/.exapump"
EXAKIT_PERSONAL_DEPLOY_DIR="$DEPLOY"
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
manifest_get(){ case "\$1" in runtime.type) [ "\${STUB_NO_TYPE:-0}" = 1 ] || echo personal ;; *) echo "" ;; esac; }
exakit_repo_root(){ return 1; }
exakit_marketplace_addons(){ :; }
personal_teardown(){
    if [ "\${STUB_TD_RC:-0}" = 0 ]; then rm -rf "$DEPLOY"; EXAKIT_TEARDOWN_LEFTOVERS=""; EXAKIT_TEARDOWN_REMEDY=""; return 0; fi
    EXAKIT_TEARDOWN_LEFTOVERS="the deployment directory $DEPLOY"
    EXAKIT_TEARDOWN_REMEDY="rm -rf '$DEPLOY'"
    return 1
}
for _fn in personal_launcher_cache_dir personal_other_deployments personal_prunable_state_dirs; do
    eval "\$(awk -v n="\$_fn" '\$0 ~ ("^" n "\\\\(\\\\)") {f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/runtime-personal.sh")"
done
eval "\$(awk '/^_exakit_remove_installed_skills\(\)/{f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
for _fn in _exakit_uninstall_leftover_report _exakit_uninstall_orphan_autostart exakit_uninstall_run; do
    eval "\$(awk -v n="\$_fn" '\$0 ~ ("^" n "\\\\(\\\\)") {f=1} f{print} f&&/^}\$/{if(f)exit}' "$ROOT/setup/lib/common.sh")"
done
mkdir -p "\$EXAKIT_HOME" && : > "\$EXAKIT_HOME/manifest.json"
exakit_uninstall_run "\${STUB_DRY:-0}"
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
