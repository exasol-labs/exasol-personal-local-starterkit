#!/usr/bin/env bash
# personal-deploy-dir.sh - the kit finds the Exasol Personal deployment folder
# the way launcher 2.5.0 does, and its record follows the folder when the
# launcher moves it.
#
#   bash tests/personal-deploy-dir.sh
#
# Launcher 2.5.0 keeps deployments in ~/.exasol/launcher/deployments and moves
# a stopped one from ~/.exasol/personal/deployments there by itself, on its
# next command. Covered here, all in a scratch HOME with a stub launcher (no
# real launcher, database, container or kit home is touched):
#   fresh   nothing on disk: the 2.5.0 folder
#   legacy  a 2.4.0 layout: the old folder, the record untouched
#   moved   the launcher moved the folder after the kit recorded the old path:
#           status, ownership, the TLS disk check, the MCP sidecars.yaml, the
#           virtual-schema engine's --deployment-dir, the scheduler's folder,
#           uninstall and an installer re-run all find it, and the manifest and
#           the ownership receipt now name the new folder
#   race    the folder moves between two calls of one run
#   both    both folders on disk: the new one wins, and the recorded old one,
#           still there, is not claimed as moved
#   custom  EXAKIT_PERSONAL_DEPLOY_DIR naming another folder is kept
#   guard   only the kit's own deployment is followed: the folder's deployment
#           id must be the one the kit recorded. The user's own deployment at
#           the new default (another id, or no id recorded) is never claimed:
#           the record stays, the database reads as the user's, status and
#           uninstall say the kit's own was not found, and uninstall --dry-run
#           lists no removal of it. A kit that recorded no id gets it from its
#           folder while that is still where the record says.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" EXAKIT_HOME="$WORK/home/kit" EXAKIT_BIN_DIR="$WORK/home/bin"
export EXAKIT_VERSION_POLICY=pinned EXAKIT_NO_UPDATE_NOTICE=1 EXAKIT_NO_FANCY=1
unset EXAKIT_PERSONAL_DEPLOY_DIR EXAKIT_PERSONAL_BIN XDG_CACHE_HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
export PATH="$EXAKIT_BIN_DIR:$PATH"

# The kit's own deployment, starter-kit-local, in the launcher's two roots.
NEW="$HOME/.exasol/launcher/deployments/starter-kit-local"
OLD="$HOME/.exasol/personal/deployments/starter-kit-local"

# The stub launcher: `info` answers when a deployment is in either folder
# (new first, as 2.5.0 looks); with STUB_MIGRATE=1 any command but --help
# first moves a deployment from the old folder to the new one, as 2.5.0 does
# to a stopped deployment.
# `deployments list --json` answers STUB_LIST (exit STUB_LIST_RC) when it is
# set, as launcher 2.5.0 and later do; unset, the command is unknown, as to a
# 2.4.x launcher. With STUB_CALLS every call is logged there.
cat > "$EXAKIT_BIN_DIR/exasol" <<'STUB'
#!/bin/sh
[ -n "${STUB_CALLS:-}" ] && echo "$*" >> "$STUB_CALLS"
new="$HOME/.exasol/launcher/deployments/starter-kit-local"
old="$HOME/.exasol/personal/deployments/starter-kit-local"
if [ "${STUB_MIGRATE:-0}" = 1 ] && [ "${1:-}" != "--help" ] && [ -d "$old" ] && [ ! -e "$new" ]; then
    mkdir -p "$(dirname "$new")" && mv "$old" "$new"
    rmdir "$(dirname "$old")" "$(dirname "$(dirname "$old")")" 2>/dev/null
fi
dir=""; prev=""
for a in "$@"; do [ "$prev" = "--deployment-dir" ] && dir="$a"; prev="$a"; done
case "${1:-}" in
    version) echo 2.5.0 ;;
    info) if [ -n "$dir" ]; then [ -d "$dir" ] || exit 1
          else [ -d "$new" ] || [ -d "$old" ] || exit 1; fi; echo info ;;
    deployments)
        [ -n "${STUB_LIST+x}" ] || { echo 'Error: unknown command "deployments" for "exasol"' >&2; exit 1; }
        [ -z "${STUB_SLEEP:-}" ] || exec sleep "$STUB_SLEEP"   # a launcher that hangs
        printf '%s\n' "$STUB_LIST"; exit "${STUB_LIST_RC:-0}" ;;
    --help) printf 'Commands:\n  sidecar  Sidecars\n  mcp  MCP\n' ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$EXAKIT_BIN_DIR/exasol"
# The kit runs only its own launcher, in the kit folder (personal_cli): the
# stub is that one too (a link, so a stub written later counts as well).
mkdir -p "$EXAKIT_HOME/personal/bin" && ln -sf "$EXAKIT_BIN_DIR/exasol" "$EXAKIT_HOME/personal/bin/exasol"

. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/detect.sh"
. "$ROOT/setup/lib/runtime-personal.sh"
info(){ :; }; ok(){ :; }; warn(){ :; }; info_step(){ :; }; ok_step(){ :; }
fetch(){ echo 'Unexpected download' >&2; return 91; }

PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1))
    else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
reset_home() {
    rm -rf "$HOME/.exasol" "$HOME/Library" "$HOME/.cache"
    printf '{}\n' > "$EXAKIT_MANIFEST"
    unset _EXAKIT_PERSONAL_DEPLOY_FOLLOWED _EXAKIT_PERSONAL_DEPLOY_ID_SEEN _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST
    EXAKIT_PERSONAL_DEPLOY_DIR=""
    personal_deploy_dir_refresh
    # The next refresh is a new process's first: it reads the record anew.
    unset _EXAKIT_PERSONAL_LIST_DECIDED _EXAKIT_PERSONAL_DEPLOY_REC _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST
}
# seed <dir> <port>: a deployment as the launcher leaves it.
seed() {
    mkdir -p "$1/local/runtime/exa/certificates" "$1/local/runtime/exa/bucketfs/bfsdefault/default"
    printf '{"deploymentId": "exa-%s", "connection": {"host": "127.0.0.1", "dbPort": %s, "username": "sys"}}\n' "$2" "$2" > "$1/deployment.json"
    printf '2.4.0' > "$1/.exasolLauncher.version"
    printf 'cert-%s\n' "$2" > "$1/local/runtime/exa/certificates/fullchain.pem"
}
# record_noid <dir>: what a 0.3.0 install wrote about the deployment it made
# there. record <dir>: what 0.3.1 writes, the deployment's id as well.
record_noid() {
    manifest_set runtime.type personal
    manifest_set runtime.deployment_dir "$1"
    manifest_set runtime.launcher "$EXAKIT_BIN_DIR/exasol"
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
    exakit_record_ownership database kit "$1"
}
record() {
    record_noid "$1"
    manifest_set runtime.deployment_id "$(_personal_deployment_id_in "$1")"
}
# un_dry: `exakit uninstall --dry-run` on this sandbox, as a user runs it.
un_dry() {
    env -u EXAKIT_PERSONAL_DEPLOY_DIR HOME="$HOME" EXAKIT_HOME="$EXAKIT_HOME" EXAKIT_BIN_DIR="$EXAKIT_BIN_DIR" \
        bash "$ROOT/setup/exakit" uninstall --dry-run </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
st() {
    env -u EXAKIT_PERSONAL_DEPLOY_DIR HOME="$HOME" EXAKIT_HOME="$EXAKIT_HOME" EXAKIT_BIN_DIR="$EXAKIT_BIN_DIR" \
        bash "$ROOT/setup/exakit" status </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
has() { case "$3" in *"$2"*) check "$1" yes yes ;; *) check "$1" "has: $2" "$(printf '%s' "$3" | tail -40)" ;; esac; }
hasnt() { case "$3" in *"$2"*) check "$1" "not: $2" "$(printf '%s' "$3" | grep -F -- "$2" | head -3)" ;; *) check "$1" yes yes ;; esac; }

echo "the resolver itself:"
reset_home
check "fresh: nothing on disk is the 2.5.0 folder" "$NEW" "$(detect_personal_deploy_dir)"
check "fresh: the shell's folder is the 2.5.0 one" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
mkdir -p "$OLD"
check "legacy: only the old folder is the old folder" "$OLD" "$(detect_personal_deploy_dir)"
check "legacy: an old default given is the old folder" "$OLD" "$(detect_personal_deploy_dir "$OLD")"
mkdir -p "$NEW"
check "both: the new folder wins, as the launcher looks" "$NEW" "$(detect_personal_deploy_dir "$OLD")"
check "both: a recorded old folder still on disk stays itself" "$OLD" "$(detect_personal_deploy_dir "$OLD" recorded)"
rm -rf "$OLD"
printf '{"deploymentId": "exa-kit"}\n' > "$NEW/deployment.json"
check "moved: a recorded old folder that is gone is the new one, with the kit's id" "$NEW" "$(detect_personal_deploy_dir "$OLD" recorded exa-kit)"
check "guard: not with another id there" "$OLD" "$(detect_personal_deploy_dir "$OLD" recorded exa-other)"
check "guard: not with no id recorded" "$OLD" "$(detect_personal_deploy_dir "$OLD" recorded)"
printf '{\n  "connection": {},\n  "deploymentId" :\n    "exa-kit"\n}' > "$NEW/deployment.json"
check "guard: the id is read across lines" "$NEW" "$(detect_personal_deploy_dir "$OLD" recorded exa-kit)"
rm -f "$NEW/deployment.json"
check "guard: not when the folder names no id" "$OLD" "$(detect_personal_deploy_dir "$OLD" recorded exa-kit)"
printf '{"deploymentId": "exa-kit"}\n' > "$NEW/deployment.json"
check "custom: a folder the user chose is itself" "$WORK/mine" "$(detect_personal_deploy_dir "$WORK/mine")"
check "custom: even recorded and missing" "$WORK/mine" "$(detect_personal_deploy_dir "$WORK/mine" recorded)"
check "the common.sh wrapper: no id recorded, no follow" "$OLD" "$(exakit_personal_deploy_dir_now "$OLD")"
manifest_set runtime.deployment_id exa-kit
check "the common.sh wrapper: the recorded id follows" "$NEW" "$(exakit_personal_deploy_dir_now "$OLD")"
manifest_set runtime.deployment_id exa-other
check "the common.sh wrapper: another id does not" "$OLD" "$(exakit_personal_deploy_dir_now "$OLD")"
check "the common.sh wrapper: empty in, empty out" "" "$(exakit_personal_deploy_dir_now "")"

echo "fresh 2.5.0 layout:"
reset_home
seed "$NEW" 8601
record "$NEW"
personal_deploy_dir_refresh
check "fresh: the deployment is found" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "fresh: its port is read from it" 8601 "$(personal_db_port)"
check "fresh: it exists for the launcher" yes "$(personal_deployment_exists && echo yes || echo no)"
check "fresh: the database is the kit's" kit "$(exakit_component_ownership database)"
check "fresh: the preflight sees it (no second deploy)" yes "$(_detect_personal_deployment_present && echo yes || echo no)"
check "fresh: uninstall prunes deployments, launcher, .exasol" \
    "$HOME/.exasol/launcher/deployments $HOME/.exasol/launcher $HOME/.exasol" "$(personal_prunable_state_dirs | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$HOME/.exasol/launcher/history"
check "fresh: a launcher folder with its history in it stays" "$HOME/.exasol/launcher/deployments" "$(personal_prunable_state_dirs | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$HOME/.exasol/launcher/deployments/other"
check "fresh: another 2.5.0 deployment is seen" "$HOME/.exasol/launcher/deployments/other" "$(personal_other_deployments)"

echo "old 2.4.0 layout:"
reset_home
seed "$OLD" 8602
record "$OLD"
personal_deploy_dir_refresh
check "legacy: the deployment is found" "$OLD" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "legacy: its port" 8602 "$(personal_db_port)"
check "legacy: the record is untouched" "$OLD" "$(manifest_get runtime.deployment_dir)"
check "legacy: the receipt is untouched" "$OLD" "$(manifest_get runtime.ownership_path)"
check "legacy: the database is the kit's" kit "$(exakit_component_ownership database)"
check "legacy: uninstall prunes deployments, personal, .exasol" \
    "$HOME/.exasol/personal/deployments $HOME/.exasol/personal $HOME/.exasol" "$(personal_prunable_state_dirs | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$HOME/.exasol/launcher/deployments/theirs"
check "legacy: a deployment in the 2.5.0 root keeps the shared cache" "$HOME/.exasol/launcher/deployments/theirs" "$(personal_other_deployments)"

echo "migrated by the launcher after the install:"
reset_home
seed "$OLD" 8603
record "$OLD"
# What 2.5.0 does at the first command after `exakit stop`.
mkdir -p "$(dirname "$NEW")"; mv "$OLD" "$NEW"; rmdir "$HOME/.exasol/personal/deployments" "$HOME/.exasol/personal"
EXAKIT_PERSONAL_DEPLOY_DIR="$OLD"   # what the kit computed before the move
unset _EXAKIT_PERSONAL_DEPLOY_FOLLOWED
check "moved: status reads the moved deployment's port" 8603 "$(personal_db_port)"
personal_deploy_dir_refresh
check "moved: the shell's folder follows" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "moved: runtime.deployment_dir follows" "$NEW" "$(manifest_get runtime.deployment_dir)"
check "moved: the ownership receipt follows" "$NEW" "$(manifest_get runtime.ownership_path)"
check "moved: the receipt keeps its owner" kit "$(manifest_get runtime.ownership)"
check "moved: the database is still the kit's" kit "$(exakit_component_ownership database)"
check "moved: so update and uninstall manage it" yes "$(exakit_component_is_managed database && echo yes || echo no)"
check "moved: it exists for the launcher" yes "$(personal_deployment_exists && echo yes || echo no)"
check "moved: the preflight sees it (no second deploy)" yes "$(_detect_personal_deployment_present && echo yes || echo no)"
check "moved: the deployed version is read from it" 2.4.0 "$(personal_deployed_version)"
check "moved: the deployment id is read from it" exa-8603 "$(_personal_deployment_id)"
check "moved: uninstall prunes the 2.5.0 folders" \
    "$HOME/.exasol/launcher/deployments $HOME/.exasol/launcher $HOME/.exasol" "$(personal_prunable_state_dirs | tr '\n' ' ' | sed 's/ $//')"
check "moved: nothing else is another deployment" "" "$(personal_other_deployments)"
# The TLS "wrong database" guard reads the moved deployment's certificate.
EXAKIT_TLS_PIN_PY="$WORK/tls_pin.py"; : > "$EXAKIT_TLS_PIN_PY"
check "moved: the TLS disk check reads the moved certificate" "$(printf '%064d' 7)" "$(
    run_python_any() {
        [ "${2:-}" = file-fingerprint ] || { python3 "$@"; return; }
        [ "$3" = "$NEW/local/runtime/exa/certificates/fullchain.pem" ] && printf '%064d\n' 7; }
    exakit_tls_disk_fingerprint)"
# The virtual-schema engine is handed the moved folder (its bucket files).
check "moved: the virtual-schema engine gets the moved folder" 1 \
    "$(grep -c -- '--deployment-dir "$(exakit_personal_deploy_dir_now "$(manifest_get runtime.deployment_dir' "$ROOT/setup/lib/virtual-schemas.sh")"
# The MCP sidecar definition is written into the moved folder.
. "$ROOT/setup/lib/mcp.sh"
EXAKIT_UV_BIN="$WORK/uv"
cat > "$EXAKIT_UV_BIN" <<'UV'
#!/bin/sh
for a in "$@"; do case "$a" in */sidecars.yaml) printf '%s\n' "$a" > "$UVLOG" ;; esac; done
echo unchanged
UV
chmod +x "$EXAKIT_UV_BIN"; export UVLOG="$WORK/uv.log"
EXAKIT_PERSONAL_DEPLOY_DIR="$OLD"; unset _EXAKIT_PERSONAL_DEPLOY_FOLLOWED
_mcp_sidecar_definition() { printf 'name: mcp\n'; }
_mcp_sidecar_put mcp_readonly "$WORK/pw" 4896 >/dev/null 2>&1
check "moved: the MCP sidecars.yaml goes into the moved folder" "$NEW/sidecars.yaml" "$(cat "$UVLOG" 2>/dev/null)"
check "moved: the MCP sidecar is supported there" yes "$(EXAKIT_PERSONAL_DEPLOY_DIR="$OLD" mcp_sidecar_supported && echo yes || echo no)"

echo "the folder moves between two calls of one run:"
reset_home
seed "$OLD" 8604
record "$OLD"
personal_deploy_dir_refresh
check "race: before the move, the old folder" "$OLD" "$EXAKIT_PERSONAL_DEPLOY_DIR"
STUB_MIGRATE=1 "$(personal_cli)" status >/dev/null 2>&1   # the launcher call that moves it
check "race: the launcher moved it" yes "$([ -d "$NEW" ] && [ ! -e "$OLD" ] && echo yes || echo no)"
check "race: the next read finds it" 8604 "$(personal_db_port)"
personal_deployment_exists >/dev/null 2>&1
check "race: and the record has followed" "$NEW" "$(manifest_get runtime.deployment_dir)"
check "race: the database stays the kit's" kit "$(exakit_component_ownership database)"

echo "both folders on disk: the kit's 0.3.0 database the launcher could not move, the user's own 2.5 in the new one:"
reset_home
seed "$OLD" 8605
record "$OLD"
seed "$NEW" 8606
personal_deploy_dir_refresh
check "both: the kit stays on its recorded folder" "$OLD" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "both: its port, never the user's" 8605 "$(personal_db_port)"
check "both: the record is not rewritten (not a move)" "$OLD" "$(manifest_get runtime.deployment_dir)"
check "both: the receipt is not rewritten" "$OLD" "$(manifest_get runtime.ownership_path)"
check "both: the kit's own stays the kit's" kit "$(exakit_component_ownership database)"
check "both: the user's is another deployment, so the cache stays" "$NEW" "$(personal_other_deployments)"
out="$(un_dry)"
has   "both: uninstall --dry-run removes the kit's own database" "deployment and ALL its data" "$out"
check "...in the kit's folder (the one every launcher call names), the user's untouched" "$OLD|yes" \
    "$EXAKIT_PERSONAL_DEPLOY_DIR|$([ -f "$NEW/deployment.json" ] && echo yes || echo no)"

echo "the kit's own moved deployment is followed, and only it:"
reset_home
seed "$OLD" 8610
record "$OLD"
mkdir -p "$(dirname "$NEW")"; mv "$OLD" "$NEW"; rmdir "$HOME/.exasol/personal/deployments" "$HOME/.exasol/personal"
personal_deploy_dir_refresh
check "same id: the record follows" "$NEW" "$(manifest_get runtime.ownership_path)"
check "same id: the database is the kit's" kit "$(exakit_component_ownership database)"
check "same id: nothing is said missing" "" "$(exakit_personal_kit_missing)"
out="$(un_dry)"
has   "same id: uninstall --dry-run lists the removal" "deployment and ALL its data" "$out"

echo "the user's own deployment at the new default (another id) is not claimed:"
reset_home
seed "$OLD" 8611
record "$OLD"                       # the kit's own, id exa-8611
rm -rf "$HOME/.exasol/personal"     # gone (removed by hand)
seed "$NEW" 8612                    # the user's own, id exa-8612
personal_deploy_dir_refresh
check "another id: the kit's folder stays the one it recorded, never the user's" "$OLD" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "another id: runtime.deployment_dir is left as it is" "$OLD" "$(manifest_get runtime.deployment_dir)"
check "another id: the receipt is left as it is" "$OLD" "$(manifest_get runtime.ownership_path)"
check "another id: the recorded id is left as it is" exa-8611 "$(manifest_get runtime.deployment_id)"
check "another id: the receipt is not followed" "$OLD" "$(exakit_personal_deploy_dir_now "$OLD")"
check "another id: the database is the user's" user "$(exakit_component_ownership database)"
check "another id: so update and uninstall leave it" no "$(exakit_component_is_managed database && echo yes || echo no)"
check "another id: the TLS disk check reads nothing of it" "" "$(exakit_tls_disk_fingerprint 2>/dev/null)"
check "another id: the kit's own is said missing, with both folders" "$OLD|$NEW" "$(exakit_personal_kit_missing)"
out="$(un_dry)"
hasnt "another id: uninstall --dry-run lists no deployment removal" "deployment and ALL its data" "$out"
hasnt "another id: ...nor the MCP server beside it" "sidecar" "$out"
has   "another id: ...says the kit's own was not found, and where" "The kit's own database was not found at $OLD." "$out"
has   "another id: ...and that the one found is left" "The Exasol Personal deployment at $NEW is not the kit's, so it is not removed." "$out"
check "another id: the dry run touched nothing" yes "$([ -f "$NEW/deployment.json" ] && echo yes || echo no)"
# A start or update records the runtime again: it must not take the user's id
# (or folder) for the kit's, or the next uninstall would follow it.
personal_record_manifest healthy >/dev/null 2>&1
check "another id: (the record ran)" 2.5.0 "$(manifest_get runtime.version)"
check "another id: a later record keeps the kit's id" exa-8611 "$(manifest_get runtime.deployment_id)"
check "another id: ...and the kit's folder" "$OLD" "$(manifest_get runtime.deployment_dir)"
check "another id: ...so the database stays the user's" user "$(exakit_component_ownership database)"
out="$(st)"
has   "another id: status says the kit's own was not found" "Not found:" "$out"
has   "another id: ...with the folder it looked for" "the kit's own database, at" "$out"
has   "another id: ...and the user's is left alone" "is not the kit's, and the kit leaves it alone." "$out"

echo "no recorded id (a kit from before 0.3.1):"
reset_home
seed "$OLD" 8613
record_noid "$OLD"
personal_deploy_dir_refresh
check "no id, folder still there: the id is read from it" exa-8613 "$(manifest_get runtime.deployment_id)"
mkdir -p "$(dirname "$NEW")"; mv "$OLD" "$NEW"; rmdir "$HOME/.exasol/personal/deployments" "$HOME/.exasol/personal"
unset _EXAKIT_PERSONAL_DEPLOY_ID_SEEN
personal_deploy_dir_refresh
check "no id, folder still there: after the move it is followed" "$NEW" "$(manifest_get runtime.ownership_path)"
check "no id, folder still there: and stays the kit's" kit "$(exakit_component_ownership database)"
reset_home
seed "$OLD" 8614
record_noid "$OLD"
rm -rf "$HOME/.exasol/personal"     # the kit's own is gone before any 0.3.1 command ran
seed "$NEW" 8615                    # a deployment at the new default
personal_deploy_dir_refresh
check "no id + a folder at the new default: no id is taken from it" "" "$(manifest_get runtime.deployment_id)"
check "no id + a folder at the new default: the record is left" "$OLD" "$(manifest_get runtime.ownership_path)"
check "no id + a folder at the new default: not claimed" user "$(exakit_component_ownership database)"
check "no id + a folder at the new default: said missing" "$OLD|$NEW" "$(exakit_personal_kit_missing)"
personal_record_manifest healthy >/dev/null 2>&1
check "no id + a folder at the new default: a later record takes no id from it" "" "$(manifest_get runtime.deployment_id)"
check "no id + a folder at the new default: ...and it stays unclaimed" user "$(exakit_component_ownership database)"
out="$(un_dry)"
hasnt "no id: uninstall --dry-run lists no deployment removal" "deployment and ALL its data" "$out"
has   "no id: ...and says the kit's own was not found" "The kit's own database was not found at $OLD." "$out"
# No receipt at all (a kit up to 0.2.4): its recorded folder is not followed either.
manifest_del runtime.ownership; manifest_del runtime.ownership_path
check "no receipt, no id: not claimed" unknown "$(exakit_component_ownership database)"
out="$(un_dry)"
hasnt "no receipt, no id: uninstall --dry-run lists no deployment removal" "deployment and ALL its data" "$out"

echo "a folder the user chose:"
reset_home
seed "$NEW" 8607
seed "$WORK/custom" 8608
EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/custom"
record "$WORK/custom"
personal_deploy_dir_refresh
check "custom: kept although the 2.5.0 folder exists" "$WORK/custom" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "custom: its port" 8608 "$(personal_db_port)"
check "custom: the record is untouched" "$WORK/custom" "$(manifest_get runtime.deployment_dir)"
check "custom: the database is the kit's" kit "$(exakit_component_ownership database)"

echo "the launcher's own list (exasol deployments list --json):"
# list <name> <path> <status> ...: the launcher's answer, as 2.5.0 prints it.
list() {
    _l="["; _sep=""
    while [ "$#" -ge 3 ]; do
        _l="$_l$_sep{\"name\": \"$1\", \"path\": \"$2\", \"status\": \"$3\", \"infrastructure\": \"local\", \"installation\": \"local\"}"
        _sep=", "; shift 3
    done
    printf '%s]' "$_l"
}
# fresh_process: what a new exakit process starts with (nothing asked yet).
fresh_process() {
    unset _EXAKIT_PERSONAL_LIST_DECIDED _EXAKIT_PERSONAL_LIST_ASKED _EXAKIT_PERSONAL_DEPLOY_FOLLOWED _EXAKIT_PERSONAL_DEPLOY_ID_SEEN \
        _EXAKIT_PERSONAL_DEPLOY_REC _EXAKIT_PERSONAL_DEPLOY_AT _EXAKIT_PERSONAL_DEPLOY_LOST
    DETECT_PERSONAL_LAUNCHER_LISTED=0; DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS=""
    EXAKIT_PERSONAL_DEPLOY_DIR=""
}
TAB="$(printf '\t')"
CUSTOM="$HOME/.exasol/somewhere-new/deployments/default"
export STUB_CALLS="$WORK/calls"

# (a) a 2.5-like launcher: the list names its default, where the kit knows it.
reset_home
seed "$NEW" 8620
export STUB_LIST="$(list default "$NEW" database_ready)"
fresh_process; : > "$STUB_CALLS"
personal_deploy_dir_refresh
check "2.5 list: the launcher was asked" "deployments list --json" "$(grep '^deployments' "$STUB_CALLS")"
check "2.5 list: its default is the folder" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "2.5 list: with the launcher's status" database_ready "${DETECT_PERSONAL_DEPLOY_STATUS:-}"
check "2.5 list: the helper prints path and status" "$NEW${TAB}database_ready" "$(personal_launcher_deployments 2>&1)"
personal_deployment_exists >/dev/null 2>&1; personal_db_port >/dev/null
check "2.5 list: asked once per process" 1 "$(grep -c '^deployments' "$STUB_CALLS")"
check "2.5 list: 'again' asks anew" 2 "$(personal_launcher_deployments again >/dev/null; grep -c '^deployments' "$STUB_CALLS")"
# A user's own deployment, stopped, under another name, with a default the
# launcher has not initialized: the list finds it.
reset_home
mkdir -p "$NEW"; seed "$HOME/.exasol/launcher/deployments/mine" 8621
export STUB_LIST="$(list default "$NEW" not_initialized mine "$HOME/.exasol/launcher/deployments/mine" stopped)"
fresh_process
personal_deploy_dir_refresh
check "2.5 list: a user's deployment listed is never the kit's folder (no first-listed fallback)" \
    "$NEW|not_initialized" "$EXAKIT_PERSONAL_DEPLOY_DIR|${DETECT_PERSONAL_DEPLOY_STATUS:-}"
check "2.5 list: so its port is not the kit's" 8563 "$(personal_db_port)"
# An empty list: the launcher has no deployment, the kit deploys in its folder.
reset_home
export STUB_LIST="[]"
fresh_process
personal_deploy_dir_refresh
check "2.5 list: an empty list is an answer" "1|$NEW" "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|$EXAKIT_PERSONAL_DEPLOY_DIR"

# (b) a 2.4-like launcher: no such command, the two known folders.
reset_home
seed "$OLD" 8622
unset STUB_LIST
fresh_process
personal_deploy_dir_refresh
check "2.4 launcher: no list, the known folders" "0|$OLD" "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|$EXAKIT_PERSONAL_DEPLOY_DIR"
check "2.4 launcher: the helper says no answer" 1 "$(personal_launcher_deployments again >/dev/null; echo $?)"

# (c) a "2.6.0" that keeps its deployments somewhere new.
reset_home
seed "$CUSTOM" 8623
export STUB_LIST="$(list default "$CUSTOM" database_ready)"
fresh_process
personal_deploy_dir_refresh
check "2.6 list: the user's database is never the kit's folder" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "2.6 list: so its port is not the kit's" 8563 "$(personal_db_port)"
check "2.6 list: and no deployment is the kit's yet" no "$(personal_deployment_exists && echo yes || echo no)"
check "2.6 list: it is not the kit's" unknown "$(exakit_component_ownership database)"
# Adopted on "y": recorded as the user's (exakit_reuse_ownership), and a later
# process finds it from the record, without asking the launcher.
manifest_set runtime.type personal
manifest_set runtime.deployment_dir "$CUSTOM"
exakit_reuse_ownership database "$CUSTOM"
check "2.6 list: adopted as the user's" user "$(manifest_get runtime.ownership)"
fresh_process; : > "$STUB_CALLS"
personal_deploy_dir_refresh
check "2.6 list: a later process finds it from the record" "$CUSTOM" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "...without a launcher call" "" "$(grep '^deployments' "$STUB_CALLS")"
check "2.6 list: update and uninstall leave it" no "$(exakit_component_is_managed database && echo yes || echo no)"
out="$(un_dry)"
hasnt "2.6 list: uninstall --dry-run lists no removal of it" "deployment and ALL its data" "$out"
hasnt "...nor names its folder for removal" "will remove: $CUSTOM" "$out"
check "2.6 list: the dry run touched nothing" yes "$([ -f "$CUSTOM/deployment.json" ] && echo yes || echo no)"
# The kit's own deployment, moved by that launcher out of the 2.5 folder: the
# record follows it, the id guard holding.
reset_home
seed "$NEW" 8624
record "$NEW"
mkdir -p "$(dirname "$CUSTOM")"; mv "$NEW" "$CUSTOM"
export STUB_LIST="$(list default "$CUSTOM" stopped)"
fresh_process
personal_deploy_dir_refresh
check "2.6 move: the shell's folder follows" "$CUSTOM" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "2.6 move: runtime.deployment_dir follows" "$CUSTOM" "$(manifest_get runtime.deployment_dir)"
check "2.6 move: the ownership receipt follows" "$CUSTOM" "$(manifest_get runtime.ownership_path)"
check "2.6 move: still the kit's" kit "$(exakit_component_ownership database)"
check "2.6 move: nothing said missing" "" "$(exakit_personal_kit_missing)"
# Another id there: the user's own. Never claimed.
reset_home
seed "$NEW" 8625
record "$NEW"
rm -rf "$NEW"
seed "$CUSTOM" 8626
export STUB_LIST="$(list default "$CUSTOM" database_ready)"
fresh_process
personal_deploy_dir_refresh
check "2.6 guard: the kit's folder stays the one it recorded, never the user's" "$NEW" "$EXAKIT_PERSONAL_DEPLOY_DIR"
check "2.6 guard: the record is left as it is" "$NEW" "$(manifest_get runtime.deployment_dir)"
check "2.6 guard: the receipt is not followed" "$NEW" "$(exakit_personal_deploy_dir_now "$NEW")"
check "2.6 guard: the database is the user's" user "$(exakit_component_ownership database)"
check "2.6 guard: the kit's own is said missing, with both folders" "$NEW|$CUSTOM" "$(exakit_personal_kit_missing)"
out="$(un_dry)"
hasnt "2.6 guard: uninstall --dry-run lists no deployment removal" "deployment and ALL its data" "$out"
has   "2.6 guard: ...and says the one found is left" "The Exasol Personal deployment at $CUSTOM is not the kit's, so it is not removed." "$out"
# The uninstall sees the launcher's other deployments and the kit's moved copy.
reset_home
seed "$NEW" 8627
record "$NEW"
seed "$CUSTOM" 8628
export STUB_LIST="$(list default "$NEW" database_ready other "$CUSTOM" stopped)"
fresh_process
personal_deploy_dir_refresh
check "uninstall: a deployment the launcher lists elsewhere keeps the shared cache" "$CUSTOM" "$(personal_other_deployments)"
reset_home
seed "$CUSTOM" 8629
manifest_set runtime.deployment_id exa-8629
export STUB_LIST="$(list default "$CUSTOM" stopped)"
fresh_process
EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/gone/default"
personal_teardown_leftovers exa-8629 1 >/dev/null 2>&1
has "uninstall: the same deployment in a folder the launcher lists is named" "the deployment directory $CUSTOM (the database and ALL its data)" "$EXAKIT_TEARDOWN_LEFTOVERS"

# (d) an answer that is not the list: the known folders.
for _bad in "fails|1|$(list default "$CUSTOM" database_ready)" "garbage|0|Usage: exasol deployments list [flags]" \
            "not a list|0|{\"name\": \"default\", \"path\": \"$CUSTOM\"}" "half a list|0|[{\"name\": \"default\", \"path\": "; do
    reset_home
    seed "$NEW" 8630; seed "$CUSTOM" 8631
    export STUB_LIST="${_bad#*|*|}" STUB_LIST_RC="$(printf '%s' "$_bad" | cut -d'|' -f2)"
    fresh_process
    personal_deploy_dir_refresh
    check "bad answer (${_bad%%|*}): the known folders" "0|$NEW" "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|$EXAKIT_PERSONAL_DEPLOY_DIR"
done
unset STUB_LIST_RC
reset_home
seed "$NEW" 8632
export STUB_LIST="Migrated managed deployments to $HOME/.exasol/launcher/deployments
$(list default "$NEW" stopped)"
fresh_process
personal_deploy_dir_refresh
check "a notice before the list: the list is read" "1|$NEW|stopped" "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|$EXAKIT_PERSONAL_DEPLOY_DIR|${DETECT_PERSONAL_DEPLOY_STATUS:-}"
export STUB_LIST="$(list default "$NEW" database_ready)
A new version of Exasol Personal is available: 2.6.1 [see https://example.org]"
fresh_process
personal_deploy_dir_refresh
check "a notice after the list: the list is read (as the PowerShell twin reads it, OWN-05)" "1|$NEW|database_ready" "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|$EXAKIT_PERSONAL_DEPLOY_DIR|${DETECT_PERSONAL_DEPLOY_STATUS:-}"
export STUB_LIST="$(list default "relative/default" stopped)"
fresh_process
personal_deploy_dir_refresh
check "a relative path is no folder" "1||$NEW" "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|${DETECT_PERSONAL_LAUNCHER_DEPLOYMENTS:-}|$EXAKIT_PERSONAL_DEPLOY_DIR"
export STUB_LIST="$(list default "$CUSTOM" stopped)" STUB_SLEEP=5
fresh_process
_t0="$(date +%s)"
EXAKIT_PERSONAL_LIST_TIMEOUT=1 personal_deploy_dir_refresh
check "a launcher that hangs: the known folders, within the bound" "0|$NEW|yes" \
    "${DETECT_PERSONAL_LAUNCHER_LISTED:-}|$EXAKIT_PERSONAL_DEPLOY_DIR|$([ $(( $(date +%s) - _t0 )) -le 4 ] && echo yes || echo no)"
unset STUB_LIST STUB_SLEEP STUB_CALLS
fresh_process

echo "the deployment id: one reader, the launcher's state first (WSL-03, MCU-04):"
reset_home
mkdir -p "$NEW"
printf '{"deploymentId": "exa-state", "nested": {"deploymentId": "exa-deep"}}\n' > "$NEW/.exasolLauncherState.json"
printf '{"deploymentId": "local", "connection": {}}\n' > "$NEW/deployment.json"
check "id: the state file wins over deployment.json" exa-state "$(_personal_deployment_id_in "$NEW")"
check "id: the language container lookup reads the same" exa-state "$(EXAKIT_PERSONAL_DEPLOY_DIR="$NEW"; personal_slc_container_id)"
printf '{"deploymentId": "exa-old"}\n' > "$NEW/deployment.json"
check "id: both files differ: the state file" exa-state "$(_personal_deployment_id_in "$NEW")"
rm -f "$NEW/.exasolLauncherState.json"
check "id: deployment.json when the state file is not there" exa-old "$(_personal_deployment_id_in "$NEW")"
printf '{"deploymentId": "local"}\n' > "$NEW/deployment.json"
check "id: \"local\" is no id" "" "$(_personal_deployment_id_in "$NEW")"
printf '{"deploymentId": "  "}\n' > "$NEW/deployment.json"
check "id: blank is no id" "" "$(_personal_deployment_id_in "$NEW")"
printf '{"connection": {"deploymentId": "exa-deep"}}\n' > "$NEW/deployment.json"
check "id: a nested key is no id" "" "$(_personal_deployment_id_in "$NEW")"
printf '{"currentWorkflowState": {"running": {}}}\n' > "$NEW/.exasolLauncherState.json"
printf '{"deploymentId": "exa-json"}\n' > "$NEW/deployment.json"
check "id: a state file without one falls back to deployment.json" exa-json "$(_personal_deployment_id_in "$NEW")"
# The guard reads the same: a moved folder whose deployment.json says "local"
# is followed on its state's id, and one whose state names another id is not
# followed on a deployment.json that names the kit's.
printf '{"deploymentId": "exa-kit"}\n' > "$NEW/.exasolLauncherState.json"
printf '{"deploymentId": "local"}\n' > "$NEW/deployment.json"
check "guard: followed on the state's id" "$NEW" "$(detect_personal_deploy_dir "$OLD" recorded exa-kit)"
check "guard: never on \"local\"" "$OLD" "$(detect_personal_deploy_dir "$OLD" recorded local)"
printf '{"deploymentId": "exa-user"}\n' > "$NEW/.exasolLauncherState.json"
printf '{"deploymentId": "exa-kit"}\n' > "$NEW/deployment.json"
check "guard: not on a deployment.json the state contradicts" "$OLD" "$(detect_personal_deploy_dir "$OLD" recorded exa-kit)"
# The id the kit records comes from the same reader.
reset_home
seed "$NEW" 8640
printf '{"deploymentId": "exa-state-8640"}\n' > "$NEW/.exasolLauncherState.json"
printf '{"deploymentId": "local", "connection": {"dbPort": 8640}}\n' > "$NEW/deployment.json"
record_noid "$NEW"
personal_record_manifest healthy >/dev/null 2>&1
check "record: the id recorded is the state's" exa-state-8640 "$(manifest_get runtime.deployment_id)"

echo "another deployment made in the kit's own folder (MCU-02):"
reset_home
seed "$NEW" 8650
record "$NEW"                       # the kit's own, id exa-8650
check "same folder: the kit's own is the kit's" kit "$(exakit_component_ownership database)"
rm -rf "$NEW"; seed "$NEW" 8651     # destroyed with the launcher, the user's made in its place
check "same folder, another id: the database is the user's" user "$(exakit_component_ownership database)"
check "...so update and uninstall leave it" no "$(exakit_component_is_managed database && echo yes || echo no)"
out="$(un_dry)"
hasnt "...uninstall --dry-run lists no removal of it" "deployment and ALL its data" "$out"
# An installer re-run ("Use it instead?") or `exakit update personal` records
# the runtime again: the recorded id is kept and the user's stays the user's.
exakit_reuse_ownership database "$NEW"
personal_record_manifest healthy >/dev/null 2>&1
check "...a later record keeps the kit's id" exa-8650 "$(manifest_get runtime.deployment_id)"
check "...and records it as the user's" user "$(manifest_get runtime.ownership)"
check "...which stays the user's" user "$(exakit_component_ownership database)"
out="$(un_dry)"
hasnt "...uninstall --dry-run still lists no removal of it" "deployment and ALL its data" "$out"
check "...the dry run touched nothing" yes "$([ -f "$NEW/deployment.json" ] && echo yes || echo no)"
# A database the kit deploys itself there takes its new id.
PERSONAL_RECORD_FRESH=1 personal_record_manifest healthy >/dev/null 2>&1
check "a fresh deploy of the kit's: the new id is the kit's" exa-8651 "$(manifest_get runtime.deployment_id)"

echo "a start records that it runs, and leaves the version that created the deployment (F-02):"
reset_home
seed "$NEW" 8660
record "$NEW"
manifest_set runtime.deployment_version 2.4.0
manifest_set runtime.status stopped
# Whatever the version file says after the start, runtime.deployment_version
# is the version that created the deployment: a start does not move it (the
# live launcher 2.5.0 keeps 2.4.0 there for a deployment 2.4 made).
printf '2.5.0' > "$NEW/.exasolLauncher.version"
(
    _personal_start_engine_ok(){ return 0; }; personal_launcher_supports(){ return 0; }
    personal_launcher_state(){ echo stopped; }; personal_note_guest_rebuild(){ :; }
    personal_slc_dns_prepare(){ :; }; personal_slc_dns_repair(){ return 0; }
    run_logged(){ "$@" >/dev/null 2>&1; }; port_in_use(){ return 1; }; personal_auto_approve_flag(){ :; }
    personal_start >/dev/null 2>&1
)
check "start: runtime.deployment_version stays the creating version" 2.4.0 "$(manifest_get runtime.deployment_version)"
check "start: runtime.status says it runs" running "$(manifest_get runtime.status)"

echo "only the kit's own deployment, or one adopted, is ever acted on (OWN-01, AGT-01):"
# xk <args...>: `exakit <args>` as a user or an agent runs it; its exit code
# after the output, on the last line.
xk() {
    env -u EXAKIT_PERSONAL_DEPLOY_DIR HOME="$HOME" EXAKIT_HOME="$EXAKIT_HOME" EXAKIT_BIN_DIR="$EXAKIT_BIN_DIR" \
        bash "$ROOT/setup/exakit" "$@" </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    printf '\nrc=%s\n' "${PIPESTATUS[0]}"
}
# jq-less: the value at a dotted path of the first JSON object in the output.
jv() { printf '%s' "$2" | python3 -c '
import json, sys
text = sys.stdin.read()
start = text.find("{")
doc, _ = json.JSONDecoder().raw_decode(text[start:])
for key in sys.argv[1].split("."):
    doc = doc.get(key) if isinstance(doc, dict) else None
print("null" if doc is None else doc)' "$1"; }
# acted_on: the launcher calls that named a deployment folder, or changed one.
acted_on() { grep -E -- "--deployment-dir|^(start|stop|deploy|destroy|slc|sidecar|mcp)( |$)" "$STUB_CALLS" | grep -vE '^(status|info) ' ; }
EXP="$HOME/.exasol/launcher/deployments/experiments"
export STUB_CALLS="$WORK/calls"
# A start that went ahead would wait for an answer: not long, in a test.
export EXAKIT_PERSONAL_READY_TIMEOUT=2
# (a) the kit's own gone, the user's "experiments" listed (OWN hA).
reset_home
seed "$NEW" 8670
record "$NEW"                       # the kit's own, id exa-8670
rm -rf "$NEW"
seed "$EXP" 8671                    # the user's own, id exa-8671
export STUB_LIST="$(list experiments "$EXP" stopped)"
fresh_process
check "kit gone: the state names both folders" "kit_database_missing|$NEW|$EXP" "$(exakit_personal_db_state)"
: > "$STUB_CALLS"
out="$(xk start)"
check "kit gone: exakit start refuses, exit 3" "rc=3" "$(printf '%s' "$out" | tail -1)"
has   "kit gone: ...says the kit's own was not found" "The kit's own database was not found at $NEW." "$out"
has   "kit gone: ...and names the installer" "re-run the installer" "$out"
check "kit gone: ...with no launcher call on any deployment" "" "$(acted_on)"
: > "$STUB_CALLS"
out="$(xk stop)"
check "kit gone: exakit stop refuses, exit 3" "rc=3" "$(printf '%s' "$out" | tail -1)"
check "kit gone: ...with no launcher call on any deployment" "" "$(acted_on)"
: > "$STUB_CALLS"
out="$(xk start database)"
check "kit gone: exakit start database refuses, exit 3" "rc=3" "$(printf '%s' "$out" | tail -1)"
check "kit gone: ...with no launcher call" "" "$(acted_on)"
: > "$STUB_CALLS"
out="$(xk status --json)"
check "kit gone: status --json exit 3" "rc=3" "$(printf '%s' "$out" | tail -1)"
check "kit gone: ...status no database" "no database" "$(jv status "$out")"
check "kit gone: ...runtime.state names it" kit_database_missing "$(jv runtime.state "$out")"
check "kit gone: ...runtime.found names the user's folder" "$EXP" "$(jv runtime.found "$out")"
check "kit gone: ...the remedy is the installer, never exakit start" "$(exakit_install_command)" "$(jv remedy "$out")"
has   "kit gone: ...the hint says the installer asks" "The installer asks which database to use" "$(jv remedy_hint "$out")"
check "kit gone: ...and status asked the launcher nothing about it" "" "$(acted_on)"
check "kit gone: status --json names whose database, where, and the launcher (AGT-05)" "user|$NEW|2.5.0|yes" \
    "$(jv runtime.ownership "$out")|$(jv runtime.deployment_dir "$out")|$(jv runtime.launcher_version "$out")|$([ "$(jv runtime.launcher_tested_version "$out")" != null ] && echo yes)"
out="$(xk status)"
hasnt "kit gone: the status screen never says exakit start" "Start it:" "$out"
has   "kit gone: ...it names the installer" "Use it:" "$out"
has   "kit gone: ...and the user's is left alone" "is not the kit's, and the kit leaves it alone." "$out"
out="$(xk info --json)"
check "kit gone: info --json agrees" "no database|kit_database_missing|rc=3" \
    "$(jv status "$out")|$(jv runtime.state "$out")|$(printf '%s' "$out" | tail -1)"
check "kit gone: info --json shows the computed owner, the receipt beside it (AGT-05)" "user|kit" \
    "$(jv runtime.ownership "$out")|$(jv runtime.ownership_recorded "$out")"
out="$(xk mcp-doctor --json)"
check "kit gone: mcp-doctor --json agrees" "no database|kit_database_missing|rc=3" \
    "$(jv status "$out")|$(jv runtime.state "$out")|$(printf '%s' "$out" | tail -1)"
: > "$STUB_CALLS"
out="$(xk connect postgresql --name pg --json)"
check "kit gone: connect --json refuses before anything runs" "unreachable_db|rc=22" "$(jv kind "$out")|$(printf '%s' "$out" | tail -1)"
out="$(xk source check pg --json)"
check "kit gone: source check --json refuses too" "unreachable_db|rc=22" "$(jv kind "$out")|$(printf '%s' "$out" | tail -1)"
check "kit gone: ...with no launcher call" "" "$(acted_on)"
# The functions the commands reach say no as well, so no other path acts on it.
: > "$STUB_CALLS"
fresh_process
check "kit gone: personal_start returns 3" 3 "$(personal_start >/dev/null 2>&1; echo $?)"
check "kit gone: personal_stop returns 3" 3 "$(personal_stop >/dev/null 2>&1; echo $?)"
check "kit gone: the start-or-heal returns 3" 3 "$(exakit_ensure_runtime_running deploy >/dev/null 2>&1; echo $?)"
check "kit gone: the wait-or-deploy deploys nothing" 1 "$(personal_wait_ready_or_deploy >/dev/null 2>&1; echo $?)"
check "kit gone: the language-container DNS repair touches nothing" 1 "$(personal_slc_dns_repair >/dev/null 2>&1; echo $?)"
check "kit gone: personal_update touches nothing" 3 "$(exakit_component_is_managed() { return 0; }; personal_update >/dev/null 2>&1; echo $?)"
. "$ROOT/setup/lib/mcp.sh"
. "$ROOT/setup/lib/virtual-schemas.sh"
: > "$UVLOG"
check "kit gone: the MCP sidecar definition is not written" "1|" "$(_mcp_sidecar_put mcp_readonly "$WORK/pw" 4896 >/dev/null 2>&1; echo $?)|$(cat "$UVLOG")"
check "kit gone: nor the MCP sidecar applied" 1 "$(mcp_sidecar_apply >/dev/null 2>&1; echo $?)"
check "kit gone: nor the Java language container installed" 1 "$(_exakit_vs_java_add >/dev/null 2>&1; echo $?)"
check "kit gone: ...none of them called the launcher on a deployment" "" "$(acted_on)"
# The installer's "Use it instead?" adopts it: from then on it is the user's
# database the kit works with, and the refusal is gone.
exakit_reuse_ownership database "$EXP"
fresh_process
check "kit gone, then adopted: no state" "" "$(exakit_personal_db_state)"
check "kit gone, then adopted: the guard lets the kit act" 0 "$(exakit_kit_database_guard >/dev/null 2>&1; echo $?)"
# (b) another deployment made in the kit's own folder (MCU-02).
reset_home
seed "$NEW" 8672
record "$NEW"                       # the kit's own, id exa-8672
rm -rf "$NEW"; seed "$NEW" 8673     # the user's made in its place
export STUB_LIST="$(list default "$NEW" stopped)"
fresh_process
check "same folder, another id: the state names it" "kit_database_missing|$NEW|$NEW" "$(exakit_personal_db_state)"
: > "$STUB_CALLS"
out="$(xk start)"
check "same folder, another id: exakit start refuses, exit 3" "rc=3" "$(printf '%s' "$out" | tail -1)"
check "same folder, another id: ...with no launcher call on it" "" "$(acted_on)"
out="$(xk status --json)"
check "same folder, another id: status --json names it" "kit_database_missing|$NEW|rc=3" \
    "$(jv runtime.state "$out")|$(jv runtime.found "$out")|$(printf '%s' "$out" | tail -1)"
exakit_reuse_ownership database "$NEW"
fresh_process
check "same folder, adopted: no state" "" "$(exakit_personal_db_state)"
# (c) an adopted deployment gone, another listed: not the one adopted.
reset_home
seed "$CUSTOM" 8674
manifest_set runtime.type personal
manifest_set runtime.deployment_dir "$CUSTOM"
exakit_reuse_ownership database "$CUSTOM"
rm -rf "$CUSTOM"
seed "$EXP" 8675
export STUB_LIST="$(list experiments "$EXP" database_ready)"
fresh_process
check "adopted gone: the state names both folders" "kit_database_missing|$CUSTOM|$EXP" "$(exakit_personal_db_state)"
: > "$STUB_CALLS"
out="$(xk stop)"
check "adopted gone: exakit stop refuses, exit 3, no launcher call" "rc=3|" "$(printf '%s' "$out" | tail -1)|$(acted_on)"
# (d) the kit's own, where it is: nothing in the way.
reset_home
seed "$NEW" 8676
record "$NEW"
unset STUB_LIST
fresh_process
check "kit's own: no state" "" "$(exakit_personal_db_state)"
out="$(xk status --json)"
check "kit's own: status --json says it is the kit's, and where (AGT-05)" "kit|$NEW|null" \
    "$(jv runtime.ownership "$out")|$(jv runtime.deployment_dir "$out")|$(jv runtime.state "$out")"
check "kit's own: the guard lets it act" 0 "$(exakit_kit_database_guard >/dev/null 2>&1; echo $?)"
unset STUB_LIST STUB_CALLS EXAKIT_PERSONAL_READY_TIMEOUT
fresh_process

echo "the launcher cache:"
reset_home
case "$(uname -s)" in Darwin) CACHE_ROOT="$HOME/Library/Caches" ;; *) CACHE_ROOT="$HOME/.cache" ;; esac
check "cache: 2.5.0's folder when none is there" "$CACHE_ROOT/exasol/launcher/resources" "$(personal_launcher_cache_dir)"
mkdir -p "$CACHE_ROOT/.exasol"
check "cache: the earlier folder while it is the only one" "$CACHE_ROOT/.exasol" "$(personal_launcher_cache_dir)"
mkdir -p "$CACHE_ROOT/exasol/launcher/resources"
check "cache: 2.5.0's folder once it exists" "$CACHE_ROOT/exasol/launcher/resources" "$(personal_launcher_cache_dir)"

echo "only a kit that follows the folder installs 2.5.0:"
check "pin: the 2.5.0 row needs kit 0.3.1" 0.3.1 "$(exakit_versions_pin components.personal.min_kit_version)"
check "pin: a 0.3.0 kit is refused" no "$(exakit_component_current() { printf 0.3.0; }; exakit_min_kit_satisfied 0.3.1 && echo yes || echo no)"
check "pin: a 0.3.1 kit is not" yes "$(exakit_component_current() { printf 0.3.1; }; exakit_min_kit_satisfied 0.3.1 && echo yes || echo no)"

echo "the PowerShell twin is wired the same way:"
check "ps: one resolver in exakit-common.ps1" 1 "$(grep -c '^function Resolve-PersonalDeployDir' "$ROOT/setup/lib/exakit-common.ps1")"
check "ps: one refresher in runtime-personal.ps1" 1 "$(grep -c '^function Update-PersonalDeployDir' "$ROOT/setup/lib/runtime-personal.ps1")"
# The launcher's folders are spelled in one place per language.
# (In code: comments name them as ~/... or %USERPROFILE%\...)
check "sh: the launcher's folders are spelled only in detect.sh" "setup/lib/detect.sh" \
    "$(cd "$ROOT" && grep -lE 'HOME[:}-]*/\.exasol/(personal|launcher)' setup/lib/*.sh setup/exakit setup/*.sh 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "ps: the launcher's folders are spelled only in exakit-common.ps1" "setup/lib/exakit-common.ps1" \
    "$(cd "$ROOT" && grep -lE '"(\.exasol\\personal|exasol\\launcher)\\deployments' setup/lib/*.ps1 setup/*.ps1 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"


echo "the 20-session limit a 2.4 launcher set (personal_lift_session_limit):"
# The stub launcher once more, with a version (STUB_VERSION), a database state
# in STUB_STATE that stop and start change, a stop that fails with
# STUB_STOP_RC=1, and STUB_START_FAILS starts that fail before one works.
cat > "$EXAKIT_BIN_DIR/exasol" <<'STUB'
#!/bin/sh
[ -n "${STUB_CALLS:-}" ] && echo "$*" >> "$STUB_CALLS"
new="$HOME/.exasol/launcher/deployments/starter-kit-local"
old="$HOME/.exasol/personal/deployments/starter-kit-local"
dir=""; prev=""
for a in "$@"; do [ "$prev" = "--deployment-dir" ] && dir="$a"; prev="$a"; done
case "${1:-}" in
    version) echo "${STUB_VERSION:-2.5.0}" ;;
    info) if [ -n "$dir" ]; then [ -d "$dir" ] || exit 1
          else [ -d "$new" ] || [ -d "$old" ] || exit 1; fi; echo info ;;
    deployments)
        [ -n "${STUB_LIST+x}" ] || { echo 'Error: unknown command "deployments" for "exasol"' >&2; exit 1; }
        printf '%s\n' "$STUB_LIST"; exit "${STUB_LIST_RC:-0}" ;;
    stop) [ "${STUB_STOP_RC:-0}" = 0 ] || exit 1; echo stopped > "$STUB_STATE" ;;
    start)
        n="$(cat "$STUB_STATE.fails" 2>/dev/null || echo 0)"
        if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$STUB_STATE.fails"; exit 1; fi
        echo running > "$STUB_STATE" ;;
    --help) printf 'Commands:\n  start  Start\n  stop  Stop\n  sidecar  Sidecars\n  mcp  MCP\n' ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$EXAKIT_BIN_DIR/exasol"
export STUB_STATE="$WORK/dbstate" STUB_CALLS="$WORK/calls"
unset STUB_LIST STUB_VERSION STUB_STOP_RC
# The database's state is the stub's; a start is the launcher's start on the
# folder in use, as personal_start runs it, and the wait asks that state.
personal_status() { cat "$STUB_STATE" 2>/dev/null || echo stopped; }
personal_start() {
    personal_deploy_dir_refresh
    exakit_kit_database_guard || return 3
    echo personal_start >> "$WORK/kitcalls"
    run_logged "$(personal_cli)" start --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || die "Failed to start the database."
}
personal_wait_ready_or_deploy() { echo personal_wait_ready_or_deploy >> "$WORK/kitcalls"; [ "$(personal_status)" = running ]; }
SAID="$WORK/said"
info() { printf 'INFO %s\n' "$*" >> "$SAID"; }
warn() { printf 'WARN %s\n' "$*" >> "$SAID"; }
CONF_REL="local/runtime/exa/exasol.conf"
# conf <dir> <eol> [last]: an exasol.conf as a 2.4 launcher writes it, with
# <eol> line ends; "last" leaves the final line without one.
conf() {
    mkdir -p "$1/local/runtime/exa"
    printf '[Global]%s    Name = exa%s[DB_PARAMS]%smaxConnectionsLicenseLimit=20%s    Params = -etlJdbcJavaEnv=-Xmx2g%s' \
        "$2" "$2" "$2" "$2" "$2" > "$1/$CONF_REL"
    if [ "${3:-}" = last ]; then printf 'tail = 1' >> "$1/$CONF_REL"; else printf 'tail = 1%s' "$2" >> "$1/$CONF_REL"; fi
}
# without <dir> <eol> [last]: the same file with the limit line gone.
without() {
    printf '[Global]%s    Name = exa%s[DB_PARAMS]%s    Params = -etlJdbcJavaEnv=-Xmx2g%s' "$2" "$2" "$2" "$2"
    if [ "${3:-}" = last ]; then printf 'tail = 1'; else printf 'tail = 1%s' "$2"; fi
}
sha() { shasum -a 256 < "$1" 2>/dev/null | cut -d' ' -f1; }
lift_case() {     # lift_case <state> [failed starts]: a fresh run of the lift, its exit code in LIFT_RC
    printf '%s\n' "$1" > "$STUB_STATE"; printf '%s\n' "${2:-0}" > "$STUB_STATE.fails"
    : > "$STUB_CALLS"; : > "$WORK/kitcalls"; : > "$SAID"
    fresh_process
    LIFT_RC=0; personal_lift_session_limit || LIFT_RC=$?
}
LF='
'
CRLF="$(printf '\r')$LF"

# Running, launcher 2.5.0, the kit's own deployment: stop, edit, start.
reset_home
seed "$NEW" 8690; record "$NEW"; conf "$NEW" "$LF"
cp "$NEW/$CONF_REL" "$WORK/orig.conf"
lift_case running
check "lift running: succeeds" 0 "$LIFT_RC"
check "lift running: only the limit line is gone, every other byte kept" "$(without x "$LF" | shasum -a 256 | cut -d' ' -f1)" "$(sha "$NEW/$CONF_REL")"
check "lift running: the backup is the file as it was" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL.before-session-limit")"
check "lift running: stopped and started with the launcher, on the kit's folder" \
    "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
check "lift running: started and waited for as exakit start does" "personal_start|personal_wait_ready_or_deploy" "$(tr '\n' '|' < "$WORK/kitcalls" | sed 's/|$//')"
check "lift running: the database runs again" running "$(personal_status)"
check "lift running: the manifest records it" lifted "$(manifest_get runtime.session_limit)"
check "lift running: ...with the date" 1 "$(manifest_get runtime.session_limit_lifted_at | grep -cE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T.*Z$')"
check "lift running: one line says it, with the restart" \
    "INFO Removing the 20-session limit that Exasol Personal 2.4 set on this database. The database restarts once." "$(cat "$SAID")"
# Run again: recorded, so nothing at all, not even a launcher question.
lift_case running
check "lift again: nothing to do" 0 "$LIFT_RC"
check "lift again: no launcher call" "" "$(cat "$STUB_CALLS")"
# A line put back by hand after the lift is not removed a second time.
conf "$NEW" "$LF"
lift_case running
check "lift recorded: a line put back stays" yes "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes)"
check "lift recorded: no launcher call" "" "$(cat "$STUB_CALLS")"

# CRLF and no final line end are kept as they were.
reset_home
seed "$NEW" 8691; record "$NEW"; conf "$NEW" "$CRLF" last
lift_case stopped
check "lift crlf: succeeds" 0 "$LIFT_RC"
check "lift crlf: CRLF and the missing final line end are kept" "$(without x "$CRLF" last | shasum -a 256 | cut -d' ' -f1)" "$(sha "$NEW/$CONF_REL")"

# Stopped: the file only, no stop and no start; the next start applies it.
reset_home
seed "$NEW" 8692; record "$NEW"; conf "$NEW" "$LF"
lift_case stopped
check "lift stopped: succeeds" 0 "$LIFT_RC"
check "lift stopped: the line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "lift stopped: no stop and no start" "" "$(grep -E '^(stop|start)' "$STUB_CALLS")"
check "lift stopped: the database stays stopped" stopped "$(personal_status)"
check "lift stopped: one line says when it applies" \
    "INFO Removing the 20-session limit that Exasol Personal 2.4 set on this database. The change takes effect when the database next starts." "$(cat "$SAID")"

# No line (a deployment 2.5.0 made): nothing, no launcher call, no backup.
reset_home
seed "$NEW" 8693; record "$NEW"; conf "$NEW" "$LF"
without x "$LF" > "$NEW/$CONF_REL"
lift_case running
check "no line: nothing to do" 0 "$LIFT_RC"
check "no line: no launcher call" "" "$(cat "$STUB_CALLS")"
check "no line: no backup" no "$([ -e "$NEW/$CONF_REL.before-session-limit" ] && echo yes || echo no)"
check "no line: not recorded" "" "$(manifest_get runtime.session_limit 2>/dev/null)"

# Launcher before 2.5.0: untouched.
reset_home
seed "$NEW" 8694; record "$NEW"; conf "$NEW" "$LF"
cp "$NEW/$CONF_REL" "$WORK/orig.conf"
STUB_VERSION=2.4.0; export STUB_VERSION
lift_case running
unset STUB_VERSION
check "launcher 2.4.0: nothing to do" 0 "$LIFT_RC"
check "launcher 2.4.0: the file is untouched" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL")"
check "launcher 2.4.0: no stop or start" "" "$(grep -E '^(stop|start)' "$STUB_CALLS")"

# A database the user let the kit use (owner user): permission to use it is
# permission to lift its limit, the same way, never more.
reset_home
seed "$NEW" 8695; record "$NEW"; conf "$NEW" "$LF"
exakit_record_ownership database user "$NEW"
cp "$NEW/$CONF_REL" "$WORK/orig.conf"
lift_case running
check "user's database: succeeds" 0 "$LIFT_RC"
check "user's database: only the limit line is gone" "$(without x "$LF" | shasum -a 256 | cut -d' ' -f1)" "$(sha "$NEW/$CONF_REL")"
check "user's database: the backup is the file as it was" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL.before-session-limit")"
check "user's database: one restart, on its folder" \
    "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
check "user's database: still the user's" user "$(manifest_get runtime.ownership)"

# kit_database_missing: the kit's own gone, the user's in the launcher's folder.
reset_home
seed "$NEW" 8696; record "$NEW"
rm -rf "$NEW"
seed "$EXP" 8697; conf "$EXP" "$LF"
cp "$EXP/$CONF_REL" "$WORK/orig.conf"
export STUB_LIST="$(list experiments "$EXP" running)"
lift_case running
check "kit gone: the state is kit_database_missing" "kit_database_missing|$NEW|$EXP" "$(exakit_personal_db_state)"
check "kit gone: nothing to do" 0 "$LIFT_RC"
check "kit gone: the user's file is untouched" "$(sha "$WORK/orig.conf")" "$(sha "$EXP/$CONF_REL")"
check "kit gone: no backup beside it" no "$([ -e "$EXP/$CONF_REL.before-session-limit" ] && echo yes || echo no)"
check "kit gone: no launcher call that acts or names a folder" "" "$(grep -E -- '--deployment-dir|^(stop|start)' "$STUB_CALLS")"
unset STUB_LIST

# Failures. The start without the line fails: the file is put back, and the
# database is started again with it.
reset_home
seed "$NEW" 8698; record "$NEW"; conf "$NEW" "$LF"
cp "$NEW/$CONF_REL" "$WORK/orig.conf"
lift_case running 1
check "start fails: reported" 1 "$LIFT_RC"
check "start fails: the file is restored" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL")"
check "start fails: the database runs again" running "$(personal_status)"
check "start fails: not recorded" "" "$(manifest_get runtime.session_limit 2>/dev/null)"
has   "start fails: says why" "because the database did not start without it. The file is as it was, and the database is running again." "$(cat "$SAID")"
has   "start fails: names the remedy" "To remove the limit later, re-run the installer:" "$(cat "$SAID")"
hasnt "start fails: no semicolon in what it says" ";" "$(cat "$SAID")"
# The stop fails: nothing changed, the database still runs.
reset_home
seed "$NEW" 8699; record "$NEW"; conf "$NEW" "$LF"
cp "$NEW/$CONF_REL" "$WORK/orig.conf"
STUB_STOP_RC=1; export STUB_STOP_RC
lift_case running
unset STUB_STOP_RC
check "stop fails: reported" 1 "$LIFT_RC"
check "stop fails: the file is untouched" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL")"
check "stop fails: the database still runs" running "$(personal_status)"
has   "stop fails: says why" "because the database did not stop. Nothing was changed." "$(cat "$SAID")"
# The file cannot be changed (a folder that refuses the backup): the database
# that was running is started again, the file as it was.
if [ "$(id -u)" != 0 ]; then
    reset_home
    seed "$NEW" 8700; record "$NEW"; conf "$NEW" "$LF"
    cp "$NEW/$CONF_REL" "$WORK/orig.conf"
    chmod 555 "$NEW/local/runtime/exa"
    lift_case running
    chmod 755 "$NEW/local/runtime/exa"
    check "edit fails: reported" 1 "$LIFT_RC"
    check "edit fails: the file is as it was" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL")"
    check "edit fails: the database runs again" running "$(personal_status)"
    has   "edit fails: says why" "could not be changed. The file is as it was." "$(cat "$SAID")"
fi

echo "an update whose launcher is already current removes the limit (U1-alt):"
# A 2.4-made deployment already driven by launcher 2.5.0 (updated by hand, or
# installed by a 0.3.0 kit during a manifest race) kept maxConnectionsLicenseLimit
# through every `exakit update`: the lift ran only after a launcher swap. The
# update runs here as a user runs it, on the kit's own database, with the
# launcher (the stub, 2.5.0) and the record already at the pin.
# update_case <state> [args...]: `exakit update` on that state, its exit code in UPD_RC.
update_case() {
    _uc_state="$1"; shift
    printf '%s\n' "$_uc_state" > "$STUB_STATE"; printf '0\n' > "$STUB_STATE.fails"
    : > "$STUB_CALLS"; : > "$WORK/kitcalls"; : > "$SAID"
    fresh_process
    UPD_RC=0
    # Only the personal row: the rest of a whole-kit update (the kit copy,
    # the MCP server, boot entries, core tasks) is not this fixture's.
    ( exakit_update_targets() { printf 'personal\n'; }
      _exakit_marketplace_warm_about() { :; }
      exakit_versions_update_cache() { :; }
      mcp_sidecar_refresh() { :; }; exakit_autostart_refresh() { :; }; exakit_report_readonly_allowlist() { :; }
      exakit_core_update_check() { :; }; exakit_core_preprocessor_verify() { :; }
      exakit_update "$@" ) </dev/null >>"$SAID" 2>&1 || UPD_RC=$?
}
upd_seed() {
    reset_home
    seed "$NEW" "$1"; record "$NEW"; conf "$NEW" "$LF"
    printf '2.5.0' > "$NEW/.exasolLauncher.version"
    manifest_set runtime.version 2.5.0
    manifest_set runtime.launcher "$EXAKIT_BIN_DIR/exasol"
    exakit_record_ownership personal kit "$EXAKIT_BIN_DIR/exasol"
    # A 0.3.0 kit's record: its launcher is the receipt's, at ~/.local/bin, and
    # the kit folder has none. (One there with no receipt is an update cut
    # short, which the next update finishes.)
    rm -f "$EXAKIT_HOME/personal/bin/exasol"
    cp "$NEW/$CONF_REL" "$WORK/orig.conf"
}
upd_seed 8701
update_case running --yes
check "current launcher, update --yes: succeeds" 0 "$UPD_RC"
check "current launcher, update --yes: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "current launcher, update --yes: the backup is the file as it was" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL.before-session-limit")"
check "current launcher, update --yes: one restart, with the launcher, on the kit's folder" \
    "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
check "current launcher, update --yes: the database runs again" running "$(personal_status)"
check "current launcher, update --yes: recorded" lifted "$(manifest_get runtime.session_limit)"
update_case running --yes
check "second update: succeeds" 0 "$UPD_RC"
check "second update: no stop and no start" "" "$(grep -E '^(stop|start)' "$STUB_CALLS")"
hasnt "second update: says nothing about the limit" "20-session" "$(cat "$SAID")"
# No terminal and no --yes: nothing is asked, the limit goes with one restart.
upd_seed 8702
update_case running
check "current launcher, no answer: succeeds" 0 "$UPD_RC"
check "current launcher, no answer: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "current launcher, no answer: one restart" "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
check "current launcher, no answer: recorded" lifted "$(manifest_get runtime.session_limit)"
has   "current launcher, no answer: says the restart" "The database restarts once." "$(cat "$SAID")"
hasnt "current launcher, no answer: asks nothing" "[y/N]" "$(cat "$SAID")"
hasnt "current launcher, no answer: no opt-in hint" "routine update" "$(cat "$SAID")"
# `exakit update personal` names the database update itself: it lifts as it swaps.
upd_seed 8703
update_case running personal
check "update personal, current launcher: succeeds" 0 "$UPD_RC"
check "update personal, current launcher: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "update personal, current launcher: one restart" "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
# Stopped: no restart needed, so nothing is asked; the next start applies it.
upd_seed 8704
update_case stopped
check "current launcher, stopped: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "current launcher, stopped: no stop and no start" "" "$(grep -E '^(stop|start)' "$STUB_CALLS")"
# The user's database (owner user): its limit goes the same way.
upd_seed 8705
exakit_record_ownership database user "$NEW"
update_case running --yes
check "user's database, update --yes: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "user's database, update --yes: one restart" "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
check "user's database, update --yes: still the user's" user "$(manifest_get runtime.ownership)"

echo "a launcher the user replaced still lets an update remove the limit (U1-alt follow-up):"
# A 2.4-made kit deployment whose launcher the user replaced by hand with
# 2.5.0 at the kit's own path: its bytes no longer match the receipt, so the
# personal row took the foreign arm (kept as it is) before the lift, and the
# limit stayed. The launcher is still never touched (#41). The rows are read
# from the results file `exakit update --json` reads.
foreign_seed() {
    upd_seed "$1"
    manifest_set components.personal.ownership_sha256 0000000000000000000000000000000000000000000000000000000000000000
    sha "$EXAKIT_BIN_DIR/exasol" > "$WORK/launcher.sha"
}
export EXAKIT_UPDATE_RESULTS="$WORK/rows"
foreign_seed 8711
check "foreign launcher: the fixture is not the kit's" no "$(exakit_component_is_managed personal && echo yes || echo no)"
: > "$EXAKIT_UPDATE_RESULTS"
update_case running --yes
check "foreign launcher, update --yes: succeeds" 0 "$UPD_RC"
check "foreign launcher, update --yes: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "foreign launcher, update --yes: the backup is the file as it was" "$(sha "$WORK/orig.conf")" "$(sha "$NEW/$CONF_REL.before-session-limit")"
check "foreign launcher, update --yes: one restart, with the launcher, on the kit's folder" \
    "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
check "foreign launcher, update --yes: the database runs again" running "$(personal_status)"
check "foreign launcher, update --yes: recorded" lifted "$(manifest_get runtime.session_limit)"
check "foreign launcher, update --yes: the launcher is untouched" "$(cat "$WORK/launcher.sha")" "$(sha "$EXAKIT_BIN_DIR/exasol")"
check "foreign launcher, update --yes: still not the kit's" no "$(exakit_component_is_managed personal && echo yes || echo no)"
has   "foreign launcher, update --yes: says the launcher stays" "Leaving personal as it is" "$(cat "$SAID")"
check "foreign launcher, update --yes: one personal row, current" "personal|current" "$(grep '^personal|' "$EXAKIT_UPDATE_RESULTS" | cut -d'|' -f1-2 | tr '\n' ' ' | sed 's/ $//')"
: > "$EXAKIT_UPDATE_RESULTS"
update_case running --yes
check "foreign launcher, second update: no stop and no start" "" "$(grep -E '^(stop|start)' "$STUB_CALLS")"
hasnt "foreign launcher, second update: says nothing about the limit" "20-session" "$(cat "$SAID")"
check "foreign launcher, second update: kept as before" "personal|skipped" "$(grep '^personal|' "$EXAKIT_UPDATE_RESULTS" | cut -d'|' -f1-2)"
foreign_seed 8712
: > "$EXAKIT_UPDATE_RESULTS"
update_case running
check "foreign launcher, no answer: the limit line is gone" no "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "foreign launcher, no answer: one restart" "stop --deployment-dir $NEW|start --deployment-dir $NEW" "$(grep -E '^(stop|start)' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
hasnt "foreign launcher, no answer: asks nothing" "[y/N]" "$(cat "$SAID")"
check "foreign launcher, no answer: one personal row, current" "personal|current" "$(grep '^personal|' "$EXAKIT_UPDATE_RESULTS" | cut -d'|' -f1-2)"
check "foreign launcher, no answer: the launcher is untouched" "$(cat "$WORK/launcher.sha")" "$(sha "$EXAKIT_BIN_DIR/exasol")"
foreign_seed 8713
exakit_record_ownership database user "$NEW"
# THE USER'S DATABASE ON A LAUNCHER OF THEIRS gets the kit's own 2.5 in the kit
# folder (#41): here nothing can be downloaded, so it is left as it was, said,
# and the row waits for the next update.
: > "$EXAKIT_UPDATE_RESULTS"
update_case running --yes
check "foreign launcher, user's database, nothing to download: the limit line stays" yes "$(personal_session_limit_set "$NEW/$CONF_REL" && echo yes || echo no)"
check "foreign launcher, user's database, nothing to download: no stop and no start" "" "$(grep -E '^(stop|start)' "$STUB_CALLS")"
check "foreign launcher, user's database, nothing to download: one personal row, deferred" "personal|deferred" "$(grep '^personal|' "$EXAKIT_UPDATE_RESULTS" | cut -d'|' -f1-2)"
has   "foreign launcher, user's database, nothing to download: says why" "because the new launcher could not be installed. The launcher and the database are as they were." "$(cat "$SAID")"
check "foreign launcher, user's database, nothing to download: the launcher is untouched" "$(cat "$WORK/launcher.sha")" "$(sha "$EXAKIT_BIN_DIR/exasol")"
unset EXAKIT_UPDATE_RESULTS
ln -sf "$EXAKIT_BIN_DIR/exasol" "$EXAKIT_HOME/personal/bin/exasol"

echo "the lift runs where launcher 2.5.0 meets the kit's database:"
body() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }
check "update: personal_update lifts the limit after the launcher swap" 1 \
    "$(body "$ROOT/setup/lib/runtime-personal.sh" personal_update | sed -n '/personal_install_launcher$/,$p' | grep -v '^ *#' | grep -c 'personal_update_lift')"
check "...the lift of the update is the lift" 1 \
    "$(body "$ROOT/setup/lib/runtime-personal.sh" personal_update_lift | grep -v '^ *#' | grep -c 'personal_lift_session_limit')"
for _inst in setup-macos.sh setup-linux.sh; do
    check "installer: $_inst lifts it on the database it reuses" 1 \
        "$(sed -n '/personal_clear_stale_record$/,/exakit_personal_db_state 2/p' "$ROOT/setup/$_inst" | grep -c '^ *personal_lift_session_limit')"
done
check "ps: Update-Personal lifts it" 1 "$(awk '/^function Update-Personal \{/{on=1} on{print} on&&/^}/{exit}' "$ROOT/setup/lib/runtime-personal.ps1" | grep -v '^ *#' | grep -c 'Remove-PersonalSessionLimit')"
check "ps: setup-windows.ps1 lifts it on the database it reuses" 1 "$(grep -v '^ *#' "$ROOT/setup/setup-windows.ps1" | grep -c 'Remove-PersonalSessionLimit')"

printf '\npersonal-deploy-dir.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
